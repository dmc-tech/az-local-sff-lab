
<#
.SYNOPSIS
    Retrieves FDO vouchers from Small Form Factor Azure Local nodes. Supports
    one-shot and automated polling modes.

.DESCRIPTION
    This script connects to nested Hyper-V VMs via PuTTY (plink/pscp) over SSH, waits for the FDO PEM
    voucher file to be generated, and downloads it to a local directory.

    In polling mode (-Wait), the script periodically checks each node until
    either all vouchers have been retrieved or the timeout is reached. This
    allows it to be launched immediately after the VMs boot from the installer
    ISO — it will keep retrying until the nodes finish provisioning and produce
    the voucher files.

    SSH key-based authentication is required for unattended / polling operation.
    Generate a key pair and distribute the public key to the nodes, or pass
    -SshKeyPath to point at an existing private key.

.PARAMETER RemoteHosts
    Array of IP addresses for the remote edge nodes. When omitted, the script
    auto-discovers active VM IPs from the local DHCP server scope.

.PARAMETER BasePath
    Local base directory where vouchers will be stored. Default is "c:\vouchers".
    Subdirectories will be created for each remote host.

.PARAMETER SshUser
    SSH username for connecting to remote hosts. Default is "edgeuser".

.PARAMETER SshKeyPath
    Path to a PuTTY/OpenSSH private key file for key-based authentication. When
    provided, the script uses -i with plink/pscp and disables password prompts,
    enabling fully unattended operation.

.PARAMETER SshPassword
    SSH password for password-based authentication with plink/pscp. If both
    -SshKeyPath and -SshPassword are supplied, key-based auth takes precedence.

.PARAMETER DhcpScopeId
    DHCP scope ID used for auto-discovery when RemoteHosts is not specified.
    Default is "192.168.100.0" (the NAT subnet configured by setup.ps1).

.PARAMETER NestedVmPrefix
    VM name prefix used to identify nested VMs on the local Hyper-V host when
    auto-discovering RemoteHosts via VM MAC-to-DHCP lease matching.

.PARAMETER Wait
    Enable polling mode. The script will periodically check each node for the
    voucher file until all are retrieved or -TimeoutMinutes is reached.

.PARAMETER CollectHostKeys
    Helper mode that probes each target host and prints ready-to-copy
    host=fingerprint entries for use with -HostKeyFingerprint.

.PARAMETER AutoTrustHostKeys
    When set, automatically performs TOFU (trust on first use): retrieves each
    host fingerprint using plink in batch mode, then uses -hostkey for all
    subsequent SSH/SCP operations in this run.

.PARAMETER PollIntervalSeconds
    Seconds between polling attempts in -Wait mode. Default is 60.

.PARAMETER TimeoutMinutes
    Maximum time to wait in -Wait mode before giving up. Default is 120 (2 hours).

.EXAMPLE
    .\Get-SffNodeVoucher.ps1 -Wait -SshKeyPath C:\Users\azureadmin\.ssh\id_rsa

    Description:
    Auto-discovers VM IPs from DHCP, polls every 60 seconds until all vouchers
    are retrieved (or 2-hour timeout), using SSH key auth.

.EXAMPLE
    .\Get-SffNodeVoucher.ps1 -Wait -PollIntervalSeconds 30 -TimeoutMinutes 60

    Description:
    Polls every 30 seconds with a 1-hour timeout, prompting for SSH passwords.

.EXAMPLE
    .\Get-SffNodeVoucher.ps1 -RemoteHosts @("192.168.100.100", "192.168.100.101")

    Description:
    One-shot retrieval from specific hosts (prompts for SSH password).

.NOTES
    - For unattended polling, set up SSH key-based auth and pass -SshKeyPath
    - Requires PuTTY tools: plink.exe and pscp.exe
    - Voucher files are expected in /mnt/data/var-overlay/upper/staging/export/vouchers
    - The script skips nodes that already have a voucher downloaded locally
    - Logs are written to <BasePath>\voucher-retrieval.log when -Wait is used

.INPUTS
    None. You cannot pipe objects to this script.

.OUTPUTS
    None. The script creates local directories and downloads files.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string[]]$RemoteHosts,

    [Parameter(Mandatory=$false)]
    [string]$BasePath = "c:\vouchers",

    [Parameter(Mandatory=$false)]
    [string]$SshUser = "edgeuser",

    [Parameter(Mandatory=$false)]
    [string]$SshKeyPath,

    [Parameter(Mandatory=$false)]
    [string]$SshPassword = "Password1",

    [Parameter(Mandatory=$false)]
    [string]$DhcpScopeId = "192.168.100.0",

    [Parameter(Mandatory=$false)]
    [string]$NestedVmPrefix = "NestedVM",

    [Parameter(Mandatory=$false)]
    [string[]]$HostKeyFingerprint,

    [switch]$Wait,

    [switch]$CollectHostKeys,

    [switch]$AutoTrustHostKeys,

    [Parameter(Mandatory=$false)]
    [int]$PollIntervalSeconds = 60,

    [Parameter(Mandatory=$false)]
    [int]$TimeoutMinutes = 120
)

# Validate PowerShell console environment
if ($host.Name -ne "ConsoleHost") {
    Write-Warning "This script must be run in the standard PowerShell console"
    exit
}

$ScriptVersion = "1.3.5"
$LogFile = "$BasePath\voucher-retrieval.log"
$script:DiscoveredHostKeys = @{}

# Ensure BasePath exists before any Write-Status may append to the log (e.g. when -Wait is used)
if (-not (Test-Path $BasePath)) {
    New-Item -Path $BasePath -ItemType Directory -Force | Out-Null
}

function Write-Status {
    param([string]$Message, [string]$Color = "White")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$ts - [Get-SffNodeVoucher.ps1 v$ScriptVersion] $Message"
    Write-Host $line -ForegroundColor $Color
    if ($Wait) {
        $line | Out-File -Append -FilePath $LogFile -ErrorAction SilentlyContinue
    }
}

function Get-HostKeyForHost {
    param([string]$HostIP)

    if ($script:DiscoveredHostKeys.ContainsKey($HostIP)) {
        return $script:DiscoveredHostKeys[$HostIP]
    }

    if (-not $HostKeyFingerprint -or $HostKeyFingerprint.Count -eq 0) {
        return $null
    }

    if ($HostKeyFingerprint.Count -eq 1 -and $HostKeyFingerprint[0] -notmatch "=") {
        return $HostKeyFingerprint[0]
    }

    foreach ($entry in $HostKeyFingerprint) {
        if ($entry -match "^\s*([^=]+)\s*=\s*(.+)\s*$") {
            $hostPart = $Matches[1].Trim()
            $keyPart = $Matches[2].Trim()
            if ($hostPart -ieq $HostIP) {
                return $keyPart
            }
        }
    }

    return $null
}

function Get-PuttyArgs {
    param([string]$HostIP)

    $puttyArgs = @("-ssh", "-l", $SshUser)
    # Use batch mode for unattended flows. AutoTrustHostKeys discovers host keys
    # up front, so it is also safe to run non-interactively.
    if ($Wait -or $SshKeyPath -or $AutoTrustHostKeys) {
        $puttyArgs += @("-batch")
    }

    $resolvedHostKey = Get-HostKeyForHost -HostIP $HostIP
    if (-not [string]::IsNullOrWhiteSpace($resolvedHostKey)) {
        $puttyArgs += @("-hostkey", $resolvedHostKey)
    }

    if ($SshKeyPath) {
        $puttyArgs += @("-i", $SshKeyPath)
    } elseif (-not [string]::IsNullOrWhiteSpace($SshPassword)) {
        $puttyArgs += @("-pw", $SshPassword)
    }
    return $puttyArgs
}

function Resolve-PuttyToolPath {
    param([string]$ToolName)

    $cmd = Get-Command $ToolName -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Path) {
        return $cmd.Path
    }

    $fallback = "C:\Program Files\PuTTY\$ToolName"
    if (Test-Path $fallback) {
        return $fallback
    }

    return $null
}

function Normalize-MacAddress {
    param([string]$Mac)
    if ([string]::IsNullOrWhiteSpace($Mac)) {
        return ""
    }
    return (($Mac -replace "[-:\.]", "").ToUpperInvariant())
}

function Test-VoucherExists {
    param([string]$HostIP)
    $targetPath = "$BasePath\$HostIP"
    if (Test-Path $targetPath) {
        $existing = Get-ChildItem -Path $targetPath -Filter "*.pem" -ErrorAction SilentlyContinue
        if ($existing) { return $true }
    }
    return $false
}

function Get-VoucherFromNode {
    param([string]$HostIP)

    $targetPath = "$BasePath\$HostIP"
    if (-not (Test-Path $targetPath)) {
        New-Item -Path $targetPath -ItemType Directory -Force | Out-Null
    }

    $pemFilesCommand = "find /mnt/data/var-overlay/upper/staging/export/vouchers -type f -name '*.pem' 2>/dev/null"
    $puttyCommonArgs = Get-PuttyArgs -HostIP $HostIP

    try {
        $sshResult = Invoke-ProcessCapture -FilePath $script:PlinkPath -Arguments (@($puttyCommonArgs) + @($HostIP, $pemFilesCommand))
        if ($sshResult.ExitCode -ne 0) {
            $errText = ($sshResult.StdErr -split "(`r`n|`n)" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
            if (-not $errText) { $errText = "SSH command failed (exit $($sshResult.ExitCode))" }
            Write-Status "Error connecting to ${HostIP}: $errText" "Red"
            return "ssh_failed"
        }

        $pemFile = ($sshResult.StdOut -split "(`r`n|`n)" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
        if ([string]::IsNullOrWhiteSpace($pemFile)) {
            return "not_ready"
        }

        Write-Status "Copying voucher from ${HostIP}:${pemFile} to $targetPath" "Green"
        $scpResult = Invoke-ProcessCapture -FilePath $script:PscpPath -Arguments (@($puttyCommonArgs) + @("${HostIP}:${pemFile}", $targetPath))

        if ($scpResult.ExitCode -eq 0) {
            $pemName = [System.IO.Path]::GetFileName($pemFile)
            $ipScopedPemPath = Join-Path $targetPath $pemName
            $rootPemPath = Join-Path $BasePath $pemName
            if (Test-Path $ipScopedPemPath) {
                Copy-Item -Path $ipScopedPemPath -Destination $rootPemPath -Force
                Write-Status "Copied voucher to root path: $rootPemPath" "DarkGray"
            }
            Write-Status "Successfully retrieved voucher from $HostIP" "Green"
            return "success"
        } else {
            $errText = ($scpResult.StdErr -split "(`r`n|`n)" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
            if ($errText) {
                Write-Status "SCP error for ${HostIP}: $errText" "Yellow"
            }
            return "scp_failed"
        }
    }
    catch {
        Write-Status "Unexpected error connecting to ${HostIP}: $($_.Exception.Message)" "Red"
        return "error"
    }
}

function Invoke-ProcessCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($Arguments) {
        $psi.Arguments = [string]::Join(" ", ($Arguments | ForEach-Object {
            if ($_ -match '\s') { '"' + $_.Replace('"', '\"') + '"' } else { $_ }
        }))
    }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $null = $proc.Start()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    return @{
        ExitCode = $proc.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
}

function Get-HostFingerprintFromPlink {
    param([string]$HostIP)

    $scanArgs = @("-batch", "-ssh", "-l", $SshUser, $HostIP, "exit")
    $result = Invoke-ProcessCapture -FilePath $script:PlinkPath -Arguments $scanArgs
    $scanOutput = "$($result.StdOut)`n$($result.StdErr)"

    $lines = $scanOutput -split "(`r`n|`n)"
    foreach ($line in $lines) {
        if ($line -match "(ssh-[a-z0-9-]+\s+\d+\s+SHA256:[A-Za-z0-9+/=]+)") {
            return $Matches[1]
        }
    }

    return $null
}

function Initialize-TrustedHostKeys {
    if (-not $AutoTrustHostKeys) {
        return
    }

    Write-Status "Auto-trust mode enabled. Discovering SSH host fingerprints..." "Cyan"
    foreach ($hostIp in $RemoteHosts) {
        if ($script:DiscoveredHostKeys.ContainsKey($hostIp)) {
            continue
        }

        $fp = Get-HostFingerprintFromPlink -HostIP $hostIp
        if ([string]::IsNullOrWhiteSpace($fp)) {
            Write-Status "Could not auto-discover host key for $hostIp. SSH may still prompt/fail for this host." "Yellow"
            continue
        }

        $script:DiscoveredHostKeys[$hostIp] = $fp
        Write-Status "Discovered host key for ${hostIp}: $fp" "DarkGray"
    }
}

$script:PlinkPath = Resolve-PuttyToolPath -ToolName "plink.exe"
$script:PscpPath  = Resolve-PuttyToolPath -ToolName "pscp.exe"
if (-not $script:PlinkPath -or -not $script:PscpPath) {
    Write-Status "PuTTY tools not found. Ensure plink.exe and pscp.exe are installed and available in PATH." "Red"
    exit 1
}

Write-Status "Script started. Version: $ScriptVersion" "Cyan"
if ($Wait -and (-not $HostKeyFingerprint -or $HostKeyFingerprint.Count -eq 0)) {
    Write-Status "WARNING: Polling mode is non-interactive; provide -HostKeyFingerprint or pre-cache host keys for plink/pscp." "Yellow"
}

# --- Auto-discover VM IPs from DHCP if not provided ---
if (-not $RemoteHosts) {
    Write-Status "No RemoteHosts specified - resolving VM IPs from Hyper-V MAC addresses via DHCP scope $DhcpScopeId ..." "Yellow"
    try {
        $targetVms = Get-VM -ErrorAction Stop | Where-Object { $_.Name -like "$NestedVmPrefix-*" }
        if (-not $targetVms) {
            Write-Status "No VMs found with prefix '$NestedVmPrefix-' on this host." "Red"
            exit 1
        }

        $vmMacToName = @{}
        foreach ($vm in $targetVms) {
            $adapter = Get-VMNetworkAdapter -VMName $vm.Name -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $adapter) {
                continue
            }

            $normalizedMac = Normalize-MacAddress $adapter.MacAddress
            if (-not [string]::IsNullOrWhiteSpace($normalizedMac)) {
                $vmMacToName[$normalizedMac] = $vm.Name
            }
        }

        if ($vmMacToName.Count -eq 0) {
            Write-Status "Could not read MAC addresses from any VMs matching '$NestedVmPrefix-*'." "Red"
            exit 1
        }

        $leases = Get-DhcpServerV4Lease -ScopeId $DhcpScopeId -ErrorAction Stop |
                  Where-Object { $_.AddressState -like "*Active*" -and -not [string]::IsNullOrWhiteSpace($_.ClientId) }
        if (-not $leases) {
            Write-Status "No active DHCP leases found in scope $DhcpScopeId. Are the VMs running?" "Red"
            exit 1
        }

        $resolvedHosts = @()
        foreach ($lease in $leases) {
            $leaseMac = Normalize-MacAddress $lease.ClientId
            if ($vmMacToName.ContainsKey($leaseMac)) {
                $resolvedHosts += $lease.IPAddress.IPAddressToString
            }
        }

        $RemoteHosts = $resolvedHosts | Sort-Object -Unique
        if (-not $RemoteHosts) {
            Write-Status "No DHCP leases matched VM MAC addresses for '$NestedVmPrefix-*' in scope $DhcpScopeId." "Red"
            exit 1
        }

        Write-Status "Discovered $($RemoteHosts.Count) VM(s) by MAC-to-DHCP match: $($RemoteHosts -join ', ')" "Green"
    }
    catch {
        Write-Status "Failed VM MAC/DHCP discovery: $($_.Exception.Message). Pass -RemoteHosts explicitly." "Red"
        exit 1
    }
}

if (-not (Test-Path $BasePath)) {
    New-Item -Path $BasePath -ItemType Directory -Force | Out-Null
}

Initialize-TrustedHostKeys

# --- Host-key helper mode ---
if ($CollectHostKeys) {
    Write-Status "=== Host key helper mode ===" "Cyan"
    Write-Status "Collecting fingerprints for $($RemoteHosts.Count) host(s) ..." "Cyan"
    Write-Host ""
    Write-Host "Use the following values with -HostKeyFingerprint:" -ForegroundColor Green

    $found = 0
    foreach ($remoteHost in $RemoteHosts) {
        $fp = Get-HostFingerprintFromPlink -HostIP $remoteHost
        if ($fp) {
            Write-Host ("`"{0}={1}`"" -f $remoteHost, $fp) -ForegroundColor Green
            $found++
        } else {
            Write-Status "Could not extract host fingerprint from $remoteHost. Ensure SSH is reachable and try again." "Yellow"
        }
    }

    Write-Host ""
    Write-Status "Collected $found of $($RemoteHosts.Count) host fingerprints." "Cyan"
    exit
}

# --- One-shot mode ---
if (-not $Wait) {
    foreach ($remoteHost in $RemoteHosts) {
        Write-Status "Processing $remoteHost ..." "Cyan"
        if (Test-VoucherExists $remoteHost) {
            Write-Status "Voucher already downloaded for $remoteHost - skipping" "Yellow"
            continue
        }
        $result = Get-VoucherFromNode $remoteHost
        switch ($result) {
            "not_ready"  { Write-Status "No voucher file found yet on $remoteHost" "Yellow" }
            "ssh_failed" { Write-Status "SSH connection failed to $remoteHost" "Red" }
            "scp_failed" { Write-Status "SCP transfer failed from $remoteHost" "Red" }
            "error"      { }  # already logged
            "success"    { }  # already logged
        }
    }
    Write-Host ""
    Write-Host "*** VOUCHER RETRIEVAL COMPLETE ***" -ForegroundColor Cyan
    Write-Host "Vouchers directory: $BasePath" -ForegroundColor Cyan
    exit
}

# --- Polling mode ---
Write-Status "=== Polling mode enabled ===" "Cyan"
Write-Status "Poll interval: ${PollIntervalSeconds}s | Timeout: ${TimeoutMinutes}m | Nodes: $($RemoteHosts.Count)" "Cyan"
if ($SshKeyPath) {
    Write-Status "SSH key: $SshKeyPath" "Cyan"
} elseif (-not [string]::IsNullOrWhiteSpace($SshPassword)) {
    Write-Status "Using SSH password authentication for user '$SshUser'." "Cyan"
} else {
    Write-Status "WARNING: No -SshKeyPath or -SshPassword specified. SSH may prompt for passwords on each attempt." "Yellow"
}

$pendingHosts = [System.Collections.Generic.List[string]]::new($RemoteHosts)
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$attempt = 0

while ($pendingHosts.Count -gt 0 -and (Get-Date) -lt $deadline) {
    $attempt++
    $remaining = [math]::Round(($deadline - (Get-Date)).TotalMinutes, 1)
    Write-Status "--- Attempt $attempt | Pending: $($pendingHosts.Count) node(s) | Time remaining: ${remaining}m ---" "Cyan"

    $completed = @()
    foreach ($remoteHost in $pendingHosts) {
        if (Test-VoucherExists $remoteHost) {
            Write-Status "Voucher already exists locally for $remoteHost" "Green"
            $completed += $remoteHost
            continue
        }

        $result = Get-VoucherFromNode $remoteHost
        switch ($result) {
            "success"    { $completed += $remoteHost }
            "not_ready"  { Write-Status "$remoteHost - voucher not yet available, will retry" "Yellow" }
            "ssh_failed" { Write-Status "$remoteHost - node not reachable via SSH yet, will retry" "Yellow" }
            "scp_failed" { Write-Status "$remoteHost - SCP failed, will retry" "Yellow" }
            "error"      { }  # already logged
        }
    }

    foreach ($done in $completed) {
        $pendingHosts.Remove($done) | Out-Null
    }

    if ($pendingHosts.Count -eq 0) {
        break
    }

    Write-Status "Waiting ${PollIntervalSeconds}s before next check ..." "DarkGray"
    Start-Sleep -Seconds $PollIntervalSeconds
}

Write-Host ""
$retrieved = $RemoteHosts.Count - $pendingHosts.Count
if ($pendingHosts.Count -eq 0) {
    Write-Host "*** ALL $retrieved VOUCHER(S) RETRIEVED SUCCESSFULLY ***" -ForegroundColor Green
} else {
    Write-Host "*** TIMEOUT: Retrieved $retrieved of $($RemoteHosts.Count) voucher(s) ***" -ForegroundColor Yellow
    Write-Host "Still pending: $($pendingHosts -join ', ')" -ForegroundColor Yellow
}
Write-Host "Vouchers directory: $BasePath" -ForegroundColor Cyan
Write-Host "Log file: $LogFile" -ForegroundColor Cyan
