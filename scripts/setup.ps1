# ---------------------------------------------------------------------------
# setup.ps1 - Post-reboot configuration script for the Hyper-V host
# This script is delivered to the VM via a CustomScriptExtension and
# registered to run once on the next reboot via a RunOnce registry entry.
#
# Creates:
#   - An internal Hyper-V switch with NAT for internet access
#   - Downloads the OS image package and extracts provision-os.iso
#   - 1 or 3 nested VMs (8 vCPUs, 16 GB RAM each) using the downloaded image
# ---------------------------------------------------------------------------

#Requires -RunAsAdministrator

param(
    [string]$OsImagePackageUrl = "https://azurestackreleases.download.prss.microsoft.com/dbazure/AzureLocal/OS-Composition-Linux/10.2604.0.3096/roe-10.2604.0.3096.zip",
    [string]$DotNetWindowsDesktopRuntimeUrl = "https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/9.0.14/windowsdesktop-runtime-9.0.14-win-x64.exe",
    # Direct download URL (.msix / .appx / .exe). Install path is inferred from ZIP (MSIX) vs MZ (EXE) headers if URL suffix mismatches payload.
    [string]$ConfiguratorAppUrl = "https://azurestackreleases.download.prss.microsoft.com/dbazure/AzureLocal/ConfiguratorApp/10.3372.1.3007/V2/ConfiguratorAppV2-10.3372.1.3007.msix",
    [string]$VMPrefix = "NestedVM",
    [ValidateSet(1, 3)]
    [int]$VMCount = 3
)

$ErrorActionPreference = "Stop"
$ScriptVersion = "1.3.0"
$LogFile       = "C:\Scripts\setup.log"
$CompletedFlag = "C:\Scripts\.setup-completed"
# Data-disk paths ($VHDRoot, $VMRoot, $OSImageDir, ...) are set by Set-DataPaths
# once Initialize-DataDisk has found the data volume's drive letter.

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$SwitchName   = "NATSwitch"
$NATName      = "HyperVNAT"
$NATSubnet    = "192.168.100.0/24"
$HostIP       = "192.168.100.1"
$PrefixLength = 24

# Normalise command-line parameters coming from RunOnce/extension quoting.
# This prevents malformed URI errors when values are wrapped in quotes.
function Normalize-StringParam {
    param([string]$Value)
    if ($null -eq $Value) { return $Value }
    return $Value.Trim().Trim("'`"")
}

$OsImagePackageUrl = Normalize-StringParam $OsImagePackageUrl
$DotNetWindowsDesktopRuntimeUrl = Normalize-StringParam $DotNetWindowsDesktopRuntimeUrl
$ConfiguratorAppUrl = Normalize-StringParam $ConfiguratorAppUrl
$VMPrefix = Normalize-StringParam $VMPrefix

$VMMemory = 16GB
$VMCPUs   = 8

$OSImageUrl  = $OsImagePackageUrl
$configuratorLeaf = [System.IO.Path]::GetFileName(([Uri]$ConfiguratorAppUrl).LocalPath)
if ([string]::IsNullOrWhiteSpace($configuratorLeaf)) {
    $configuratorLeaf = "ConfiguratorAppInstaller"
}
# Version-less filename follows /latest/ redirects to the current PuTTY release.
$PuttyInstallerUrl = "https://the.earth.li/~sgtatham/putty/latest/w64/putty-64bit-installer.msi"

# Sets every path that lives on the data volume, for whatever letter it has.
function Set-DataPaths {
    param([string]$DriveLetter)
    $root = "${DriveLetter}:\Hyper-V"
    $script:VMRoot                     = $root
    $script:VHDRoot                    = "$root\Virtual Hard Disks"
    $script:OSImageDir                 = "$root\Images"
    $script:OSImageZipPath             = "$script:OSImageDir\InstallerPackage.zip"
    $script:OSImageExtractDir          = "$script:OSImageDir\extracted"
    $script:OSImagePath                = "$script:OSImageDir\InstallOS.iso"
    $script:DotNetRuntimeInstallerPath = "$script:OSImageDir\windowsdesktop-runtime-9.0.14-win-x64.exe"
    $script:ConfiguratorInstallerPath  = [System.IO.Path]::Combine($script:OSImageDir, $configuratorLeaf)
    $script:PuttyInstallerPath         = "$script:OSImageDir\putty-64bit-installer.msi"
}

$VHDSize     = 500GB   # Thin-provisioned (dynamic) VHDX per VM
$DownloadTimeoutSeconds = 1800
$DownloadMaxAttempts = 8
$DownloadRetryDelaySeconds = 60

# DHCP scope for nested VMs
$DHCPScopeName  = "NestedVMs"
$DHCPScopeStart = "192.168.100.100"
$DHCPScopeEnd   = "192.168.100.200"
$DHCPSubnetMask = "255.255.255.0"

# ---------------------------------------------------------------------------
# Logging helper
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$ts - [setup.ps1 v$ScriptVersion] $Message"
    $line | Out-File -Append -FilePath $LogFile
    Write-Output $line
}

# ---------------------------------------------------------------------------
# Find and prepare the data disk, keeping whatever drive letter it has.
# - New (RAW) disk: GPT, one partition, Windows assigns the next free letter,
#   formatted NTFS "Data".
# - Existing volume (earlier run, or a data disk reused from a deleted VM):
#   used as-is - never relabelled or reformatted. A letter is only assigned
#   if the partition has none.
# Sets $script:DataDriveLetter; paths are derived from it by Set-DataPaths.
# ---------------------------------------------------------------------------
function Get-DataDiskCandidate {
    # Data disk = not the OS disk and not Azure's temporary disk; pick the largest.
    Get-Disk | Where-Object {
        $_.Size -gt 0 -and -not $_.IsBoot -and -not $_.IsSystem -and
        -not (Get-Partition -DiskNumber $_.Number -ErrorAction SilentlyContinue |
              Get-Volume -ErrorAction SilentlyContinue |
              Where-Object { $_.FileSystemLabel -eq "Temporary Storage" })
    } | Sort-Object Size -Descending | Select-Object -First 1
}

function Get-PartitionLetter {
    param($Partition)
    # DriveLetter is [char]0 when the partition has no letter.
    return "$($Partition.DriveLetter)".Trim([char]0).Trim()
}

function Initialize-DataDisk {
    # The managed data disk can surface a little after first boot; wait for it.
    Write-Log "Looking for the data disk..."
    $deadline = (Get-Date).AddMinutes(10)
    $disk = $null
    while ($true) {
        Update-HostStorageCache -ErrorAction SilentlyContinue
        $disk = Get-DataDiskCandidate
        if ($disk -or (Get-Date) -ge $deadline) { break }
        Write-Log "Data disk not visible yet - retrying in 15s"
        Start-Sleep -Seconds 15
    }
    if (-not $disk) {
        $seen = (Get-Disk | ForEach-Object { "#$($_.Number) $([math]::Round($_.Size / 1GB))GB $($_.PartitionStyle) boot=$($_.IsBoot)" }) -join "; "
        throw "No data disk found after 10 minutes (disks seen: $seen). Check the 1 TB disk is attached to the VM at LUN 0."
    }
    Write-Log "Data disk: Number=$($disk.Number), Size=$([math]::Round($disk.Size / 1GB)) GB, PartitionStyle=$($disk.PartitionStyle), Offline=$($disk.IsOffline)"

    if ($disk.IsOffline) {
        Set-Disk -Number $disk.Number -IsOffline $false
        Write-Log "Disk $($disk.Number) brought online"
    }
    if ($disk.IsReadOnly) {
        Set-Disk -Number $disk.Number -IsReadOnly $false
        Write-Log "Disk $($disk.Number) read-only cleared"
    }

    $disk = Get-Disk -Number $disk.Number
    if ($disk.PartitionStyle -eq "RAW") {
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT -Confirm:$false
        Write-Log "Disk $($disk.Number) initialised as GPT"
    } else {
        Write-Log "Disk $($disk.Number) already initialised ($($disk.PartitionStyle)) - reusing it"
    }

    # Reuse the existing data partition (earlier run / reused disk) or create one.
    $partition = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
                 Where-Object { $_.Type -eq "Basic" -or $_.Type -eq "IFS" } |
                 Sort-Object Size -Descending | Select-Object -First 1
    if (-not $partition) {
        $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
        Write-Log "Created partition $($partition.PartitionNumber) on disk $($disk.Number)"
    }

    $letter = Get-PartitionLetter $partition
    if (-not $letter) {
        $partition | Add-PartitionAccessPath -AssignDriveLetter
        $partition = Get-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber
        $letter = Get-PartitionLetter $partition
        if (-not $letter) {
            throw "Could not assign a drive letter to partition $($partition.PartitionNumber) on disk $($disk.Number)."
        }
        Write-Log "Assigned next available drive letter ${letter}:"
    } else {
        Write-Log "Using existing drive letter ${letter}:"
    }

    $volume = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
    if (-not $volume -or [string]::IsNullOrEmpty($volume.FileSystem) -or $volume.FileSystem -eq "RAW") {
        Format-Volume -DriveLetter $letter -FileSystem NTFS -NewFileSystemLabel "Data" -Confirm:$false | Out-Null
        Write-Log "Volume ${letter}: formatted as NTFS"
    } else {
        Write-Log "Volume ${letter}: already formatted ($($volume.FileSystem), label '$($volume.FileSystemLabel)') - reusing existing contents"
    }

    if (-not (Test-Path "${letter}:\")) {
        throw "Data disk setup finished but ${letter}:\ is not accessible."
    }
    $script:DataDriveLetter = $letter
}

# ---------------------------------------------------------------------------
# Ensure VHD / VM / image directories exist
# ---------------------------------------------------------------------------
function Initialize-Directories {
    foreach ($dir in @($VHDRoot, $VMRoot, $OSImageDir)) {
        if (-not (Test-Path $dir)) {
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
            Write-Log "Created directory: $dir"
        }
    }
}

function Test-UriHostResolvable {
    param([string]$UriString)

    try {
        $uri = [System.Uri]::new($UriString)
        if ([string]::IsNullOrWhiteSpace($uri.Host)) {
            return $false
        }
        [System.Net.Dns]::GetHostAddresses($uri.Host) | Out-Null
        return $true
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Download/extract the OS image if not already present
# ---------------------------------------------------------------------------
function Get-OSImage {
    if (Test-Path $OSImagePath) {
        Write-Log "OS ISO already exists at $OSImagePath - skipping download"
        return
    }

    if ($OSImageUrl.ToLower().EndsWith(".iso")) {
        Write-Log "Downloading OS ISO from $OSImageUrl ..."
        Write-Log "Destination: $OSImagePath (this may take a while)"
        $downloaded = $false
        for ($attempt = 1; $attempt -le $DownloadMaxAttempts; $attempt++) {
            try {
                if (-not (Test-UriHostResolvable -UriString $OSImageUrl)) {
                    throw "Hostname could not be resolved for URI: $OSImageUrl"
                }

                $ProgressPreference = "SilentlyContinue"   # speeds up Invoke-WebRequest significantly
                Invoke-WebRequest -Uri $OSImageUrl -OutFile $OSImagePath -UseBasicParsing -TimeoutSec $DownloadTimeoutSeconds
                $ProgressPreference = "Continue"
                $downloaded = $true
                Write-Log "OS ISO download succeeded on attempt $attempt of $DownloadMaxAttempts"
                break
            } catch {
                $ProgressPreference = "Continue"
                if ($attempt -lt $DownloadMaxAttempts) {
                    Write-Log "OS ISO download attempt $attempt failed: $($_.Exception.Message). Retrying in $DownloadRetryDelaySeconds seconds..."
                    Start-Sleep -Seconds $DownloadRetryDelaySeconds
                } else {
                    throw "OS ISO download failed after $DownloadMaxAttempts attempts. Last error: $($_.Exception.Message)"
                }
            }
        }
        if (-not $downloaded) {
            throw "OS ISO download failed after $DownloadMaxAttempts attempts."
        }
    } else {
        if (-not (Test-Path $OSImageZipPath)) {
            Write-Log "Downloading OS image package from $OSImageUrl ..."
            Write-Log "Destination: $OSImageZipPath (this may take a while)"

            $downloaded = $false

            for ($attempt = 1; $attempt -le $DownloadMaxAttempts; $attempt++) {
                try {
                    if (-not (Test-UriHostResolvable -UriString $OSImageUrl)) {
                        throw "Hostname could not be resolved for URI: $OSImageUrl"
                    }

                    $ProgressPreference = "SilentlyContinue"
                    Invoke-WebRequest -Uri $OSImageUrl -OutFile $OSImageZipPath -UseBasicParsing -TimeoutSec $DownloadTimeoutSeconds
                    $ProgressPreference = "Continue"
                    $downloaded = $true
                    Write-Log "OS image package download succeeded on attempt $attempt of $DownloadMaxAttempts"
                    break
                } catch {
                    $ProgressPreference = "Continue"
                    if ($attempt -lt $DownloadMaxAttempts) {
                        Write-Log "OS image package download attempt $attempt failed: $($_.Exception.Message). Retrying in $DownloadRetryDelaySeconds seconds..."
                        Start-Sleep -Seconds $DownloadRetryDelaySeconds
                    } else {
                        throw "OS image package download failed after $DownloadMaxAttempts attempts. Last error: $($_.Exception.Message)"
                    }
                }
            }

            if (-not $downloaded) {
                throw "OS image package download failed after $DownloadMaxAttempts attempts."
            }
        } else {
            Write-Log "OS image package already exists at $OSImageZipPath - skipping download"
        }

        if (-not (Test-Path $OSImageExtractDir)) {
            New-Item -Path $OSImageExtractDir -ItemType Directory -Force | Out-Null
        }

        Write-Log "Extracting OS image package to $OSImageExtractDir ..."
        Expand-Archive -Path $OSImageZipPath -DestinationPath $OSImageExtractDir -Force

        $provisionIso = Get-ChildItem -Path $OSImageExtractDir -Filter "provision-os.iso" -Recurse -File -ErrorAction SilentlyContinue |
                        Select-Object -First 1
        if (-not $provisionIso) {
            throw "Could not find provision-os.iso in extracted package at $OSImageExtractDir"
        }

        Copy-Item -Path $provisionIso.FullName -Destination $OSImagePath -Force
        Write-Log "Copied provision ISO to $OSImagePath"
    }

    $sizeMB = [math]::Round((Get-Item $OSImagePath).Length / 1MB)
    Write-Log "OS ISO ready at $OSImagePath ($sizeMB MB)"
}

# ---------------------------------------------------------------------------
# Download and install .NET Windows Desktop runtime required by Configurator
# ---------------------------------------------------------------------------
function Install-DotNetWindowsDesktopRuntime {
    if (-not (Test-Path $DotNetRuntimeInstallerPath)) {
        Write-Log "Downloading .NET Windows Desktop Runtime from $DotNetWindowsDesktopRuntimeUrl ..."
        Write-Log "Destination: $DotNetRuntimeInstallerPath"
        $ProgressPreference = "SilentlyContinue"
        Invoke-WebRequest -Uri $DotNetWindowsDesktopRuntimeUrl -OutFile $DotNetRuntimeInstallerPath -UseBasicParsing
        $ProgressPreference = "Continue"
    } else {
        Write-Log ".NET runtime installer already exists at $DotNetRuntimeInstallerPath - skipping download"
    }

    Write-Log "Installing .NET Windows Desktop Runtime ..."
    $process = Start-Process -FilePath $DotNetRuntimeInstallerPath -ArgumentList "/install", "/quiet", "/norestart" -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw ".NET Windows Desktop Runtime installer failed with exit code $($process.ExitCode)"
    }
    Write-Log ".NET Windows Desktop Runtime installed successfully"
}

# ---------------------------------------------------------------------------
# Peek installer payload: MSI is EXE; MSIX/APPX are ZIP (PK)
# ---------------------------------------------------------------------------
function Get-ConfiguratorPayloadKindFromFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) {
        return $null
    }

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.Length -lt 4096) {
        return $null
    }

    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $head = New-Object byte[] 512
        $read = $fs.Read($head, 0, 512)
    } finally {
        $fs.Dispose()
    }

    $safeLen = [Math]::Max(0, [Math]::Min(63, $read - 1))
    if ($safeLen -gt 0) {
        $textStart = [System.Text.Encoding]::ASCII.GetString($head[0..$safeLen])
    } else {
        $textStart = ""
    }
    if ($textStart -match '^\s*<\!DOCTYPE|^\s*<\?xml|^\s*<html') {
        return 'Html'
    }

    if ($read -ge 2 -and $head[0] -eq 0x4D -and $head[1] -eq 0x5A) {
        return 'Exe'
    }

    if ($read -ge 4 -and $head[0] -eq 0x50 -and $head[1] -eq 0x4B -and ($head[2] -eq 0x03 -or $head[2] -eq 0x05) -and ($head[3] -eq 0x04 -or $head[3] -eq 0x06)) {
        return 'Msix'
    }

    return 'Unknown'
}

# ---------------------------------------------------------------------------
# Validate downloaded installer bytes (MSIX/APPX are ZIP; EXE is MZ)
# ---------------------------------------------------------------------------
function Test-ConfiguratorInstallerBytes {
    param(
        [string]$Path,
        [string]$ExpectedKind
    )

    if (-not (Test-Path $Path)) {
        return @{ Ok = $false; Reason = "file missing" }
    }

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.Length -lt 4096) {
        return @{ Ok = $false; Reason = "file too small ($($item.Length) bytes); likely failed download" }
    }

    $kind = Get-ConfiguratorPayloadKindFromFile -Path $Path
    if ($kind -eq 'Html') {
        return @{ Ok = $false; Reason = "file looks like HTML/XML, not an installer; check URL or network" }
    }
    if ($kind -eq 'Unknown' -or $null -eq $kind) {
        return @{ Ok = $false; Reason = "file is not a recognizable EXE (MZ) or MSIX/APPX (ZIP/OPC); check URL or delete and re-download" }
    }

    $exp = $ExpectedKind
    if ($exp -eq 'Exe' -and $kind -ne 'Exe') {
        return @{ Ok = $false; Reason = "expected EXE (MZ) but payload looks like $kind" }
    }
    if ($exp -eq 'Msix' -and $kind -ne 'Msix') {
        return @{ Ok = $false; Reason = "expected MSIX/APPX (ZIP) but payload looks like $kind" }
    }

    $reason = if ($kind -eq 'Exe') { "MZ executable" } else { "ZIP/MSIX container" }
    return @{ Ok = $true; Reason = $reason }
}

# Decide whether to run Add-AppxPackage vs EXE installer (URL extension can lie or be missing).
function Resolve-ConfiguratorInstallKind {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ConfiguratorAppUrl
    )

    $leafExt = [System.IO.Path]::GetExtension(([Uri]$ConfiguratorAppUrl).LocalPath).ToLowerInvariant()
    $byMagic = Get-ConfiguratorPayloadKindFromFile -Path $Path

    if ($null -eq $byMagic -or $byMagic -eq 'Html' -or $byMagic -eq 'Unknown') {
        throw "Cannot resolve Configurator installer type (magic-bytes): $byMagic. Check -ConfiguratorAppUrl and file at '$Path'"
    }

    # Filename hints — common case: URL ends in .exe or .msix/.appx
    $declaredExe = ($leafExt -eq ".exe")
    $declaredMsix = ($leafExt -eq ".msix" -or $leafExt -eq ".appx")

    if ($declaredExe -and $byMagic -eq 'Msix') {
        Write-Log "Configurator URL path ends with .exe but downloaded file is an MSIX/APPX bundle (ZIP header); installing with Add-AppxPackage"
        return 'Msix'
    }
    if ($declaredMsix -and $byMagic -eq 'Exe') {
        Write-Log "Configurator URL path ends with $($leafExt) but downloaded file is a Windows EXE (MZ header); running silent EXE installer"
        return 'Exe'
    }

    if ($declaredExe -and $byMagic -eq 'Exe') { return 'Exe' }
    if ($declaredMsix -and $byMagic -eq 'Msix') { return 'Msix' }

    # No/neutral suffix (or odd extension): trust magic bytes only
    if ($byMagic -eq 'Exe') {
        Write-Log "Configurator install kind inferred as EXE from file contents (URL path suffix: '$leafExt')"
        return 'Exe'
    }
    Write-Log "Configurator install kind inferred as MSIX/APPX from file contents (URL path suffix: '$leafExt')"
    return 'Msix'
}

# ---------------------------------------------------------------------------
# Configurator version helpers (skip reinstall when equal/newer MSIX is present)
# ---------------------------------------------------------------------------
function Get-ConfiguratorTargetVersion {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $null
    }

    if ($Url -match '(\d+\.\d+\.\d+\.\d+)') {
        return [Version]$Matches[1]
    }

    return $null
}

function Get-InstalledConfiguratorAppxVersion {
    $packages = @(Get-AppxPackage -Name '*configurator*' -ErrorAction SilentlyContinue)
    if ($packages.Count -eq 0) {
        return $null
    }

    $maxVersion = $null
    foreach ($pkg in $packages) {
        $version = [Version]$pkg.Version
        if ($null -eq $maxVersion -or $version -gt $maxVersion) {
            $maxVersion = $version
        }
    }

    return $maxVersion
}

function Test-ConfiguratorSatisfied {
    param([string]$Url)

    $targetVersion = Get-ConfiguratorTargetVersion -Url $Url
    $installedVersion = Get-InstalledConfiguratorAppxVersion

    if ($null -ne $installedVersion -and ($null -eq $targetVersion -or $installedVersion -ge $targetVersion)) {
        return @{
            Satisfied = $true
            Installed = $installedVersion
            Target    = $targetVersion
        }
    }

    return @{
        Satisfied = $false
        Installed = $installedVersion
        Target    = $targetVersion
    }
}

# ---------------------------------------------------------------------------
# Download and install Azure Local Configurator app on host
# ---------------------------------------------------------------------------
function Install-ConfiguratorApp {
    $satisfied = Test-ConfiguratorSatisfied -Url $ConfiguratorAppUrl
    if ($satisfied.Satisfied) {
        if ($null -eq $satisfied.Target) {
            Write-Log "Configurator app already installed (version $($satisfied.Installed)); could not parse target version from URL - skipping install"
        } else {
            Write-Log "Configurator app already installed (version $($satisfied.Installed)); target package is $($satisfied.Target) - skipping download and install"
        }
        return
    }

    $pathExt = [System.IO.Path]::GetExtension($ConfiguratorInstallerPath).ToLowerInvariant()
    if ($pathExt -and $pathExt -notin ".exe", ".msix", ".appx") {
        Write-Log "Configurator download path uses extension '$pathExt' (non-standard); install method will be chosen from file contents (EXE vs MSIX)"
    }

    function Download-ConfiguratorPackage {
        Write-Log "Downloading Configurator app from $ConfiguratorAppUrl ..."
        Write-Log "Destination: $ConfiguratorInstallerPath"
        if (-not (Test-UriHostResolvable -UriString $ConfiguratorAppUrl)) {
            throw "Hostname could not be resolved for URI: $ConfiguratorAppUrl"
        }
        $ProgressPreference = "SilentlyContinue"
        $webParams = @{
            Uri             = $ConfiguratorAppUrl
            OutFile         = $ConfiguratorInstallerPath
            UseBasicParsing = $true
            TimeoutSec      = $DownloadTimeoutSeconds
            UserAgent       = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
        }
        Invoke-WebRequest @webParams
        $ProgressPreference = "Continue"
    }

    $needDownload = $false
    if (-not (Test-Path $ConfiguratorInstallerPath)) {
        $needDownload = $true
    } else {
        try {
            $kindProbe = Resolve-ConfiguratorInstallKind -Path $ConfiguratorInstallerPath -ConfiguratorAppUrl $ConfiguratorAppUrl
        } catch {
            Write-Log "Existing Configurator file could not be classified ($_.Exception.Message); removing and re-downloading"
            Remove-Item -LiteralPath $ConfiguratorInstallerPath -Force -ErrorAction Stop
            $needDownload = $true
            $kindProbe = $null
        }
        if (-not $needDownload) {
            $validation = Test-ConfiguratorInstallerBytes -Path $ConfiguratorInstallerPath -ExpectedKind $kindProbe
            if (-not $validation.Ok) {
                Write-Log "Existing Configurator file failed validation ($($validation.Reason)); removing and re-downloading"
                Remove-Item -LiteralPath $ConfiguratorInstallerPath -Force -ErrorAction Stop
                $needDownload = $true
            } else {
                Write-Log "Configurator installer already present and valid at $ConfiguratorInstallerPath; skipping download"
            }
        }
    }

    if ($needDownload) {
        Download-ConfiguratorPackage
    }

    $installKind = Resolve-ConfiguratorInstallKind -Path $ConfiguratorInstallerPath -ConfiguratorAppUrl $ConfiguratorAppUrl
    $validationFinal = Test-ConfiguratorInstallerBytes -Path $ConfiguratorInstallerPath -ExpectedKind $installKind
    if (-not $validationFinal.Ok) {
        throw "Configurator download failed validation: $($validationFinal.Reason). Remove '$ConfiguratorInstallerPath' and verify -ConfiguratorAppUrl points to the real MSIX/APPX/EXE."
    }
    Write-Log "Configurator package validated ($($validationFinal.Reason)); install via $installKind"

    Write-Log "Installing Configurator app (method: $installKind) ..."

    if ($installKind -eq 'Exe') {
        $process = Start-Process -FilePath $ConfiguratorInstallerPath -ArgumentList "/quiet", "/norestart" -Wait -PassThru
        if (($process.ExitCode -ne 0) -and ($process.ExitCode -ne 3010)) {
            throw "Configurator EXE installer failed with exit code $($process.ExitCode). If the vendor uses different silent switches, adjust Install-ConfiguratorApp in setup.ps1."
        }
    } elseif ($installKind -eq 'Msix') {
        try {
            Add-AppxPackage -Path $ConfiguratorInstallerPath
        } catch {
            if ($_.Exception.Message -match '0x80073D06|higher version of this package is already installed') {
                $installedVersion = Get-InstalledConfiguratorAppxVersion
                Write-Log "Configurator package not installed because version $installedVersion is already present (equal or newer than target); continuing"
            } else {
                throw
            }
        }
    } else {
        throw "Unsupported Configurator install kind '$installKind'"
    }

    Write-Log "Configurator app installed successfully"
}

# ---------------------------------------------------------------------------
# Install PuTTY client tools (putty.exe + plink.exe) for SSH access
# ---------------------------------------------------------------------------
function Install-PuttyClient {
    $puttyDir = "C:\Program Files\PuTTY"
    $puttyExe = "C:\Program Files\PuTTY\putty.exe"
    $plinkExe = "C:\Program Files\PuTTY\plink.exe"
    $puttyInstalled = (Test-Path $puttyExe) -and (Test-Path $plinkExe)

    if (-not $puttyInstalled) {
        if (-not (Test-Path $PuttyInstallerPath)) {
            Write-Log "Downloading PuTTY installer from $PuttyInstallerUrl ..."
            Write-Log "Destination: $PuttyInstallerPath"

            if (-not (Test-UriHostResolvable -UriString $PuttyInstallerUrl)) {
                throw "Hostname could not be resolved for URI: $PuttyInstallerUrl"
            }

            $ProgressPreference = "SilentlyContinue"
            Invoke-WebRequest -Uri $PuttyInstallerUrl -OutFile $PuttyInstallerPath -UseBasicParsing -TimeoutSec $DownloadTimeoutSeconds
            $ProgressPreference = "Continue"
        } else {
            Write-Log "PuTTY installer already exists at $PuttyInstallerPath - skipping download"
        }

        Write-Log "Installing PuTTY client tools ..."
        $process = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$PuttyInstallerPath`" /qn /norestart" -Wait -PassThru
        if (($process.ExitCode -ne 0) -and ($process.ExitCode -ne 3010)) {
            throw "PuTTY installer failed with exit code $($process.ExitCode)"
        }
    }

    if ((Test-Path $puttyExe) -and (Test-Path $plinkExe)) {
        $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        $pathParts = @($machinePath -split ";" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $hasPuttyPath = $pathParts | Where-Object { $_.TrimEnd('\') -ieq $puttyDir.TrimEnd('\') }

        if (-not $hasPuttyPath) {
            $newMachinePath = (($pathParts + $puttyDir) -join ";")
            [Environment]::SetEnvironmentVariable("Path", $newMachinePath, "Machine")
            Write-Log "Appended '$puttyDir' to system PATH"
        } else {
            Write-Log "System PATH already contains '$puttyDir' - skipping PATH update"
        }

        if ($puttyInstalled) {
            Write-Log "PuTTY client and plink already installed"
        } else {
            Write-Log "PuTTY client tools installed successfully"
        }
    } else {
        throw "PuTTY installation completed but putty.exe/plink.exe were not found in 'C:\Program Files\PuTTY'"
    }
}

# ---------------------------------------------------------------------------
# Create internal Hyper-V switch + NAT
# ---------------------------------------------------------------------------
function New-NATSwitch {
    # Create the internal switch if it doesn't already exist
    if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
        New-VMSwitch -SwitchType Internal -Name $SwitchName | Out-Null
        Write-Log "Created internal Hyper-V switch: $SwitchName"
    } else {
        Write-Log "Hyper-V switch '$SwitchName' already exists - skipping"
    }

    # Get the interface index of the vNIC created by the switch
    $ifIndex = (Get-NetAdapter | Where-Object { $_.Name -like "*$SwitchName*" }).ifIndex
    if (-not $ifIndex) {
        throw "Could not find network adapter for switch '$SwitchName'"
    }

    # Assign the host/gateway IP on the switch adapter (if not already set)
    $existing = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -eq $HostIP }
    if (-not $existing) {
        New-NetIPAddress -IPAddress $HostIP -PrefixLength $PrefixLength -InterfaceIndex $ifIndex | Out-Null
        Write-Log "Assigned $HostIP/$PrefixLength to switch adapter (ifIndex $ifIndex)"
    } else {
        Write-Log "Host IP $HostIP already assigned to switch adapter - skipping"
    }

    # Create the NAT object if it doesn't already exist
    if (-not (Get-NetNat -Name $NATName -ErrorAction SilentlyContinue)) {
        New-NetNat -Name $NATName -InternalIPInterfaceAddressPrefix $NATSubnet | Out-Null
        Write-Log "Created NAT '$NATName' for subnet $NATSubnet"
    } else {
        Write-Log "NAT '$NATName' already exists - skipping"
    }
}

# ---------------------------------------------------------------------------
# Install and configure DHCP Server on the host for the NAT subnet
# ---------------------------------------------------------------------------
function Install-DHCPServer {
    # Install the DHCP Server role if not present
    $dhcpFeature = Get-WindowsFeature -Name DHCP
    if (-not $dhcpFeature.Installed) {
        Install-WindowsFeature -Name DHCP -IncludeManagementTools | Out-Null
        Write-Log "Installed DHCP Server role"
    } else {
        Write-Log "DHCP Server role already installed"
    }

    # Authorise the DHCP server in the local registry (standalone / non-domain)
    $regPath = "HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12"
    if (Test-Path $regPath) {
        Set-ItemProperty -Path $regPath -Name "ConfigurationState" -Value 2 -ErrorAction SilentlyContinue
    }

    # Suppress the post-install configuration flag
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12" `
                     -Name "ConfigurationState" -Value 2 -ErrorAction SilentlyContinue

    # Restart DHCP service to pick up the role
    Restart-Service -Name DHCPServer -ErrorAction SilentlyContinue

    # Create the scope if it doesn't already exist
    $existingScope = Get-DhcpServerV4Scope -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -eq $DHCPScopeName }
    if (-not $existingScope) {
        Add-DhcpServerV4Scope -Name $DHCPScopeName `
                              -StartRange $DHCPScopeStart `
                              -EndRange   $DHCPScopeEnd `
                              -SubnetMask $DHCPSubnetMask `
                              -State Active
        Write-Log "Created DHCP scope '$DHCPScopeName' ($DHCPScopeStart - $DHCPScopeEnd)"
    } else {
        Write-Log "DHCP scope '$DHCPScopeName' already exists - skipping"
    }

    # Set scope options: default gateway and DNS servers
    $scopeId = ($NATSubnet -split "/")[0]   # 192.168.100.0
    Set-DhcpServerV4OptionValue -ScopeId $scopeId -Router $HostIP
    Set-DhcpServerV4OptionValue -ScopeId $scopeId -DnsServer 8.8.8.8, 8.8.4.4
    Write-Log "DHCP scope options set: gateway=$HostIP, DNS=8.8.8.8/8.8.4.4"

    # Bind DHCP to the NAT switch adapter only
    $ifIndex = (Get-NetAdapter | Where-Object { $_.Name -like "*$SwitchName*" }).ifIndex
    if ($ifIndex) {
        $binding = Get-DhcpServerV4Binding -ErrorAction SilentlyContinue |
                   Where-Object { $_.InterfaceAlias -like "*$SwitchName*" }
        if ($binding -and -not $binding.BindingState) {
            Set-DhcpServerV4Binding -InterfaceAlias $binding.InterfaceAlias -BindingState $true
            Write-Log "DHCP bound to '$($binding.InterfaceAlias)'"
        }
    }

    Write-Log "DHCP Server configured and running"
}

# ---------------------------------------------------------------------------
# Create a single nested VM
# ---------------------------------------------------------------------------
function New-NestedVM {
    param(
        [string]$Name,
        [int]$Index
    )

    $existingVM = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if ($existingVM) {
        if ($existingVM.State -ne "Off") {
            Write-Log "VM '$Name' already exists and is $($existingVM.State) - shutting down..."
            Stop-VM -Name $Name -Force -TurnOff
            Write-Log "VM '$Name' stopped"
        } else {
            Write-Log "VM '$Name' already exists and is Off"
        }
        Write-Log "Continuing with configuration for '$Name'"
    }

    $VHDPath = Join-Path $VHDRoot "$Name.vhdx"

    # Only create VHD and VM if it doesn't already exist
    if (-not $existingVM) {
        if (-not (Test-Path $VHDPath)) {
            New-VHD -Path $VHDPath -SizeBytes $VHDSize -Dynamic | Out-Null
            Write-Log "Created VHDX: $VHDPath ($([math]::Round($VHDSize / 1GB)) GB dynamic)"
        }

        New-VM -Name $Name `
               -MemoryStartupBytes $VMMemory `
               -Generation 2 `
               -Path $VMRoot `
               -VHDPath $VHDPath `
               -SwitchName $SwitchName | Out-Null
        Write-Log "Created VM '$Name'"
    }

    # Apply/reapply configuration (runs for both new and existing VMs)
    Set-VM -Name $Name `
           -ProcessorCount $VMCPUs `
           -StaticMemory `
           -AutomaticStartAction Start `
           -AutomaticStopAction ShutDown

    Set-VMFirmware -VMName $Name -EnableSecureBoot Off
    Set-VMProcessor -VMName $Name -ExposeVirtualizationExtensions $true
    Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false
    Get-VMNetworkAdapter -VMName $Name | Set-VMNetworkAdapter -MacAddressSpoofing On
    Set-VMSecurity -VMName $Name -VirtualizationBasedSecurityOptOut $true
    Set-VMKeyProtector -VMName $Name -NewLocalKeyProtector
    Enable-VMTPM -VMName $Name

    Write-Log "Configured VM '$Name': $VMCPUs vCPUs, $([math]::Round($VMMemory / 1GB)) GB RAM, Gen 2, vTPM enabled, connected to '$SwitchName'"
}

# ---------------------------------------------------------------------------
# Deny traffic to/from Azure Instance Metadata Service (169.254.169.254) on the
# first vNIC so nested guests are treated as non-Azure for Azure Arc onboarding.
# ---------------------------------------------------------------------------
function Add-NestedVMAzureArcImdsBlock {
    param(
        [string]$VMName
    )

    if (-not (Get-VM -Name $VMName -ErrorAction SilentlyContinue)) {
        Write-Log "VM '$VMName' not found - skipping IMDS block ACLs"
        return
    }

    $adapter = (Get-VMNetworkAdapter -VMName $VMName)[0]

    function Add-ImdsAclSafely {
        param(
            [object]$VmAdapter,
            [string]$Direction
        )

        try {
            Add-VMNetworkAdapterAcl -VMNetworkAdapter $VmAdapter -Action Deny -Direction $Direction -RemoteIPAddress "169.254.169.254"
            Write-Log "Added $($Direction.ToLower()) IMDS deny ACL for '$VMName'"
        } catch {
            $msg = $_.Exception.Message
            if ($msg -match "0x800700B7" -or $msg -match "already exists" -or $msg -match "Cannot create a file when that file already exists") {
                Write-Log "$Direction IMDS deny ACL already present for '$VMName' - continuing"
            } else {
                throw
            }
        }
    }

    $existingAcls = @(Get-VMNetworkAdapterAcl -VMNetworkAdapter $adapter -ErrorAction SilentlyContinue)

    $inboundExists = $existingAcls | Where-Object {
        $_.Action -eq "Deny" -and $_.Direction -eq "Inbound" -and $_.RemoteIPAddress -eq "169.254.169.254"
    }
    if (-not $inboundExists) {
        Add-ImdsAclSafely -VmAdapter $adapter -Direction "Inbound"
    } else {
        Write-Log "Inbound IMDS deny ACL already present for '$VMName' - skipping"
    }

    $outboundExists = $existingAcls | Where-Object {
        $_.Action -eq "Deny" -and $_.Direction -eq "Outbound" -and $_.RemoteIPAddress -eq "169.254.169.254"
    }
    if (-not $outboundExists) {
        Add-ImdsAclSafely -VmAdapter $adapter -Direction "Outbound"
    } else {
        Write-Log "Outbound IMDS deny ACL already present for '$VMName' - skipping"
    }
}

# ---------------------------------------------------------------------------
# Attach the ISO to a VM (shut down first if running, then start)
# ---------------------------------------------------------------------------
function Set-VMISO {
    param(
        [string]$Name
    )

    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Log "VM '$Name' not found - skipping ISO attach"
        return
    }

    # Check if a DVD drive with this ISO is already attached
    $dvd = Get-VMDvdDrive -VMName $Name -ErrorAction SilentlyContinue |
           Where-Object { $_.Path -eq $OSImagePath }
    function Start-NestedVMWithRecovery {
        param([string]$VmName)

        try {
            Start-VM -Name $VmName -ErrorAction Stop | Out-Null
            return
        } catch {
            $msg = $_.Exception.Message
            if ($msg -match "0xC000A002" -or $msg -match "authentication tag") {
                Write-Log "Start failed for '$VmName' due to vTPM/key protector state. Regenerating local key protector and retrying..."
                Disable-VMTPM -VMName $VmName -ErrorAction SilentlyContinue
                Set-VMKeyProtector -VMName $VmName -NewLocalKeyProtector
                Enable-VMTPM -VMName $VmName
                Start-VM -Name $VmName -ErrorAction Stop | Out-Null
                Write-Log "Recovered vTPM/key protector state and started '$VmName'"
                return
            }
            throw
        }
    }

    if ($dvd) {
        if ($vm.State -eq "Off") {
            Start-NestedVMWithRecovery -VmName $Name
            Write-Log "ISO already attached to '$Name' - VM was Off and has been started"
        } else {
            Write-Log "ISO already attached to '$Name' - VM already running"
        }
        return
    }

    # Shut down the VM if it is running
    if ($vm.State -ne "Off") {
        Write-Log "Shutting down '$Name' (state: $($vm.State)) to attach ISO..."
        Stop-VM -Name $Name -Force -TurnOff
        Write-Log "'$Name' stopped"
    }

    # Add a DVD drive with the ISO (or set path on existing empty drive)
    $existingDvd = Get-VMDvdDrive -VMName $Name -ErrorAction SilentlyContinue |
                   Where-Object { -not $_.Path } | Select-Object -First 1
    if ($existingDvd) {
        Set-VMDvdDrive -VMName $Name `
                       -ControllerNumber $existingDvd.ControllerNumber `
                       -ControllerLocation $existingDvd.ControllerLocation `
                       -Path $OSImagePath
        Write-Log "Set ISO on existing DVD drive for '$Name'"
    } else {
        Add-VMDvdDrive -VMName $Name -Path $OSImagePath
        Write-Log "Added DVD drive with ISO to '$Name'"
    }

    # Set firmware boot order: DVD first, then hard drive
    $dvdDrive  = Get-VMDvdDrive -VMName $Name | Where-Object { $_.Path -eq $OSImagePath }
    $hardDrive = Get-VMHardDiskDrive -VMName $Name | Select-Object -First 1
    $firmware  = @($dvdDrive)
    if ($hardDrive) { $firmware += $hardDrive }
    Set-VMFirmware -VMName $Name -BootOrder $firmware
    Write-Log "Boot order set: DVD (ISO) first for '$Name'"

    # Start the VM
    Start-NestedVMWithRecovery -VmName $Name
    Write-Log "'$Name' started with ISO attached"
}

# ---------------------------------------------------------------------------
# Ensure a nested VM is running
# ---------------------------------------------------------------------------
function Ensure-VMRunning {
    param(
        [string]$Name
    )

    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Log "VM '$Name' not found - skipping power-on check"
        return
    }

    if ($vm.State -eq "Off") {
        try {
            Start-VM -Name $Name -ErrorAction Stop | Out-Null
            Write-Log "VM '$Name' was Off and has been started"
        } catch {
            $msg = $_.Exception.Message
            if ($msg -match "0xC000A002" -or $msg -match "authentication tag") {
                Write-Log "Start failed for '$Name' due to vTPM/key protector state. Regenerating local key protector and retrying..."
                Disable-VMTPM -VMName $Name -ErrorAction SilentlyContinue
                Set-VMKeyProtector -VMName $Name -NewLocalKeyProtector
                Enable-VMTPM -VMName $Name
                Start-VM -Name $Name -ErrorAction Stop | Out-Null
                Write-Log "Recovered vTPM/key protector state and started '$Name'"
            } else {
                throw
            }
        }
    } else {
        Write-Log "VM '$Name' already $($vm.State) - no power-on action needed"
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {
    # Skip entirely if a previous run completed successfully
    if (Test-Path $CompletedFlag) {
        Write-Log "========== setup.ps1 skipped (already completed on $(Get-Content $CompletedFlag)) =========="
        return
    }

    Write-Log "========== setup.ps1 started =========="
    Write-Log "Script version: $ScriptVersion"
    Write-Log "Nested VM count: $VMCount"

    Write-Log "--- Initialising data disk ---"
    Initialize-DataDisk
    Set-DataPaths -DriveLetter $script:DataDriveLetter
    Write-Log "Data volume: $($script:DataDriveLetter): (VMs and images under $VMRoot)"

    Write-Log "--- Creating directories ---"
    Initialize-Directories

    Write-Log "--- Downloading OS image ---"
    Get-OSImage

    Write-Log "--- Installing .NET Windows Desktop Runtime ---"
    Install-DotNetWindowsDesktopRuntime

    Write-Log "--- Installing Configurator app ---"
    Install-ConfiguratorApp

    Write-Log "--- Installing PuTTY client tools (putty/plink) ---"
    Install-PuttyClient

    Write-Log "--- Configuring NAT switch ---"
    New-NATSwitch

    Write-Log "--- Installing and configuring DHCP Server ---"
    Install-DHCPServer

    Write-Log "--- Creating $VMCount nested VMs ---"
    for ($i = 1; $i -le $VMCount; $i++) {
        $vmName = "{0}-{1:D2}" -f $VMPrefix, $i
        New-NestedVM -Name $vmName -Index $i
    }

    Write-Log "--- Blocking Azure IMDS (169.254.169.254) on nested VMs for Azure Arc ---"
    for ($i = 1; $i -le $VMCount; $i++) {
        $vmName = "{0}-{1:D2}" -f $VMPrefix, $i
        Add-NestedVMAzureArcImdsBlock -VMName $vmName
    }

    Write-Log "--- Attaching OS ISO to VMs ---"
    for ($i = 1; $i -le $VMCount; $i++) {
        $vmName = "{0}-{1:D2}" -f $VMPrefix, $i
        Set-VMISO -Name $vmName
    }

    Write-Log "--- Ensuring nested VMs are powered on ---"
    for ($i = 1; $i -le $VMCount; $i++) {
        $vmName = "{0}-{1:D2}" -f $VMPrefix, $i
        Ensure-VMRunning -Name $vmName
    }

    Write-Log "--- Placing Hyper-V Manager shortcut on desktop ---"
    $hvShortcut = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\Hyper-V Manager.lnk"
    $publicDesktop = "C:\Users\Public\Desktop"
    if (Test-Path $hvShortcut) {
        Copy-Item -Path $hvShortcut -Destination $publicDesktop -Force
        Write-Log "Hyper-V Manager shortcut copied to $publicDesktop"
    } else {
        Write-Log "Hyper-V Manager shortcut not found at $hvShortcut - skipping"
    }

    Write-Log "--- Summary ---"
    Write-Log "NAT switch : $SwitchName ($NATSubnet, gateway $HostIP)"
    Write-Log "VMs created: $VMCount x $VMCPUs vCPU / $([math]::Round($VMMemory / 1GB)) GB"
    Write-Log "Guest IPs  : DHCP range ${DHCPScopeStart}-${DHCPScopeEnd} (gateway $HostIP, DNS 8.8.8.8)"

    # Write completion flag so future runs are skipped
    Get-Date -Format "yyyy-MM-dd HH:mm:ss" | Out-File -FilePath $CompletedFlag -Force
    Write-Log "Completion flag written to $CompletedFlag"
    Write-Log "========== setup.ps1 completed =========="

   # Write-Log "--- Starting voucher retrieval (polling mode) in new window ---"
   # Start-Process powershell.exe -ArgumentList "-NoExit", "-ExecutionPolicy", "Bypass", "-File", "C:\Scripts\Get-SffNodeVoucher.ps1", "-Wait"
}
catch {
    Write-Log "ERROR: $_"
    Write-Log "Stack trace: $($_.ScriptStackTrace)"
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Red
    Write-Host " setup.ps1 FAILED - see error above"        -ForegroundColor Red
    Write-Host " Log file: $LogFile"                         -ForegroundColor Red
    Write-Host "============================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "Press any key to close..." -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
