<#
.SYNOPSIS
    Deploys a K3s Kubernetes cluster across the Azure Local SFF nested VMs from
    the Hyper-V host - the last phase of the lab lifecycle.

.DESCRIPTION
    Lab lifecycle (see C:\Scripts\K3S-CLUSTER-SETUP.txt):

      Phase 1  setup.ps1 creates the nested VMs, which boot the SFF bootstrap
               loader ISO (SSH: edgeuser / Password1).
      Phase 2  Get-SffNodeVoucher.ps1 collects the FDO vouchers from the loader.
      Phase 3  In Azure, the vouchers are used to deploy Small Form Factor Linux
               onto each node. Wait until Azure reports deployment complete.
      Phase 4  THIS SCRIPT installs K3s on the deployed SFF Linux nodes.

    Running K3s against the bootstrap loader would be wasted (the loader is
    replaced by phase 3), so the script asks you to confirm phase 3 finished,
    or takes -SffLinuxDeployed for unattended runs. It then:

      1. Discovers the nested VM IPs (Hyper-V MAC -> DHCP lease), or uses -NodeIPs
      2. Waits (with -Wait) until every node accepts SSH and sudo
      3. Uploads the Linux scripts to /tmp/k3s-lab on every node over SSH
      4. Runs k3s-node-prep.sh on every node (kernel modules, sysctl, firewall, egress)
      5. Installs the first K3s server on the first node (NestedVM-01)
      6. Joins the remaining nodes, as agents (-Topology ServerAgents, default)
         or as additional embedded-etcd servers (-Topology HA)
      7. Waits for all nodes to be Ready and labels agent nodes as workers
      8. Saves a kubeconfig for the host to <OutputPath>\kubeconfig, and with
         -InstallKubectl downloads a matching kubectl.exe
      9. With -EnableArc, connects the cluster to Azure Arc via setup-k3s-arc.sh
         (service principal for unattended runs, device code otherwise)

    Every step is idempotent: re-running skips nodes that already run K3s.
    Secrets (cluster token, service principal secret) are sent to the nodes
    over SSH stdin into mode-600 files that are deleted afterwards.

.PARAMETER SffLinuxDeployed
    Confirms Azure has finished deploying SFF Linux on every node (phase 3).
    Without it the script asks interactively.

.PARAMETER AuthMode
    Password (default): log in as -SshUser with -SshPassword using PuTTY plink
    (installed by setup.ps1). Key: OpenSSH ssh.exe with -SshKeyPath, or keys
    in -SshKeyDirectory named <VMName>.pem / <IP>.pem / the only file there.

.PARAMETER SshUser
    Default edgeuser.

.PARAMETER SshPassword
    Default Password1 (the lab's hard-coded node password). Also used for sudo
    when the user does not have passwordless sudo.

.PARAMETER NodeIPs
    Node IPs in role order (first = initial server). When omitted, nodes are
    discovered from Hyper-V VMs named <NestedVmPrefix>-* and the DHCP scope.

.PARAMETER Topology
    ServerAgents (default): one server + agents, matching NestedVM-01 as the
    management node. HA: every node is a server with embedded etcd (needs an
    odd node count, so 3 for this lab).

.PARAMETER Wait
    Poll until nodes are discovered and SSH works, up to -TimeoutMinutes.
    Useful while nodes reboot at the end of the SFF Linux deployment.

.PARAMETER EnableArc
    Connect the K3s cluster to Azure Arc after it is built. For unattended runs
    pass -ArcServicePrincipal (user name = appId, password = secret) and
    -ArcTenantId, or set AZURE_CLIENT_ID / AZURE_CLIENT_SECRET / AZURE_TENANT_ID
    in the environment. Otherwise a device code is shown in this console.

.EXAMPLE
    C:\Scripts\Deploy-K3sCluster.ps1 -InstallKubectl

    Asks you to confirm SFF Linux is deployed, then builds a 1 server + 2 agent
    cluster as edgeuser / Password1 and installs kubectl on the host.

.EXAMPLE
    C:\Scripts\Deploy-K3sCluster.ps1 -SffLinuxDeployed -Topology HA -Wait

    Unattended: waits for SSH on all nodes, then builds a three-server HA cluster.

.EXAMPLE
    $sp = Get-Credential   # appId / client secret
    C:\Scripts\Deploy-K3sCluster.ps1 -SffLinuxDeployed -EnableArc -ArcServicePrincipal $sp `
        -ArcTenantId <tenant> -ArcSubscriptionId <sub> -ArcResourceGroup rg-arc-k3s -ArcLocation uksouth

    Builds the cluster and connects it to Azure Arc unattended.

.NOTES
    Password mode needs PuTTY plink.exe (installed by setup.ps1). Key mode needs
    the OpenSSH client (built into Windows Server 2025). Logs to
    <OutputPath>\deploy-k3s.log.
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$SffLinuxDeployed,

    [string[]]$NodeIPs,
    [string]$NestedVmPrefix = "NestedVM",
    [string]$DhcpScopeId = "192.168.100.0",
    [string]$NodeCidr = "192.168.100.0/24",

    [ValidateSet("Password", "Key")]
    [string]$AuthMode = "Password",
    [string]$SshUser = "edgeuser",
    [string]$SshPassword = "Password1",
    [string]$SshKeyPath,
    [string]$SshKeyDirectory = "C:\Scripts\keys",

    [ValidateSet("ServerAgents", "HA")]
    [string]$Topology = "ServerAgents",
    [string]$K3sVersion,
    [string]$ClusterName = "sff-k3s",

    [string]$ScriptsPath = "C:\Scripts",
    [string]$OutputPath = "C:\Scripts\k3s",

    [switch]$Wait,
    [int]$PollIntervalSeconds = 60,
    [int]$TimeoutMinutes = 120,
    [int]$NodeReadyTimeoutMinutes = 15,

    [switch]$InstallKubectl,

    [switch]$EnableArc,
    [string]$ArcResourceGroup = "arc-k3s-rg",
    [string]$ArcClusterName = "arc-k3s-cluster",
    [string]$ArcLocation = "eastus",
    [System.Management.Automation.PSCredential]$ArcServicePrincipal,
    [string]$ArcTenantId,
    [string]$ArcSubscriptionId,
    [switch]$SkipAzureRbac
)

$ErrorActionPreference = "Stop"
$ScriptVersion = "1.1.0"
$RemoteDir = "/tmp/k3s-lab"
# Text piped to ssh.exe is base64 (see Send-RemoteText), so ASCII is all that is needed.
$OutputEncoding = [System.Text.Encoding]::ASCII

if (-not (Test-Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}
$LogFile = Join-Path $OutputPath "deploy-k3s.log"
$KnownHostsFile = Join-Path $OutputPath "known_hosts"
$KeyCacheDir = Join-Path $OutputPath "keys"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-Status {
    param([string]$Message, [string]$Color = "White")
    $line = "{0} - [Deploy-K3sCluster.ps1 v{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $ScriptVersion, $Message
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Status "=== $Message ===" "Cyan"
}

# ---------------------------------------------------------------------------
# File ACL: OpenSSH refuses private keys readable by other users
# ---------------------------------------------------------------------------
function Set-OwnerOnlyAcl {
    param([string]$Path)
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $null = & icacls.exe $Path /inheritance:r /grant:r "${me}:(F)" "*S-1-5-18:(F)" "*S-1-5-32-544:(F)"
    if ($LASTEXITCODE -ne 0) {
        throw "icacls failed to restrict permissions on $Path"
    }
}

# Writes UTF-8 (no BOM) text with LF line endings.
function Write-LfFile {
    param([string]$Path, [string]$Content)
    $normalized = $Content.Replace("`r`n", "`n")
    [System.IO.File]::WriteAllText($Path, $normalized, (New-Object System.Text.UTF8Encoding $false))
}

# ---------------------------------------------------------------------------
# SSH clients: PuTTY plink for password auth (Windows OpenSSH cannot take a
# password non-interactively), OpenSSH ssh.exe for key auth.
# ---------------------------------------------------------------------------
function Resolve-PlinkExe {
    $cmd = Get-Command "plink.exe" -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Path) { return $cmd.Path }
    $fallback = "C:\Program Files\PuTTY\plink.exe"
    if (Test-Path $fallback) { return $fallback }
    throw "plink.exe not found. setup.ps1 installs PuTTY; install it or use -AuthMode Key."
}

function Resolve-SshExe {
    $cmd = Get-Command "ssh.exe" -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Path) { return $cmd.Path }
    $builtin = Join-Path $env:WINDIR "System32\OpenSSH\ssh.exe"
    if (Test-Path $builtin) { return $builtin }

    Write-Status "OpenSSH client not found - installing Windows capability OpenSSH.Client..." "Yellow"
    $cap = Get-WindowsCapability -Online -Name "OpenSSH.Client*" | Select-Object -First 1
    if (-not $cap) { throw "OpenSSH.Client capability is not available on this host." }
    Add-WindowsCapability -Online -Name $cap.Name | Out-Null
    if (Test-Path $builtin) { return $builtin }
    throw "OpenSSH client install did not produce $builtin"
}

# ---------------------------------------------------------------------------
# Native command runner. Streams output to the console/log and returns it.
# Remote commands must not contain double quotes: Windows PowerShell 5.1 does
# not escape them when passing arguments to native executables.
# ---------------------------------------------------------------------------
function Invoke-Native {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$InputText,
        [switch]$Quiet,
        [switch]$Interactive
    )

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if ($Interactive) {
            & $FilePath @Arguments
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ""; Lines = @() }
        }

        $handler = {
            $l = "$_"
            if (-not $Quiet) {
                Write-Host "    $l" -ForegroundColor DarkGray
                Add-Content -Path $LogFile -Value "    $l" -ErrorAction SilentlyContinue
            }
            $l
        }
        if ($PSBoundParameters.ContainsKey("InputText")) {
            $lines = @($InputText | & $FilePath @Arguments 2>&1 | ForEach-Object $handler)
        } else {
            $lines = @(& $FilePath @Arguments 2>&1 | ForEach-Object $handler)
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }

    return [pscustomobject]@{ ExitCode = $code; Output = ($lines -join "`n").Trim(); Lines = $lines }
}

# Host key fingerprint for plink -hostkey (trust on first use per run).
# plink -batch refuses unknown host keys, and the key changes when Azure
# replaces the bootstrap loader with SFF Linux, so it is looked up each run.
function Get-PlinkHostKey {
    param($Node)
    $r = Invoke-Native -FilePath $script:PlinkExe -Arguments @("-ssh", "-batch", "-l", $SshUser, $Node.IP, "exit") -Quiet
    $m = [regex]::Match($r.Output, "SHA256:[A-Za-z0-9+/=]+")
    if ($m.Success) { return $m.Value }
    return $null   # already cached in PuTTY's registry, or host unreachable
}

function Get-RemoteArgs {
    param($Node, [switch]$Tty, [switch]$NoStdin)
    if ($AuthMode -eq "Password") {
        $a = @("-ssh", "-batch", "-no-antispoof", "-l", $SshUser, "-pw", $SshPassword)
        if ($Node.HostKey) { $a += @("-hostkey", $Node.HostKey) }
        if ($Tty) { $a += "-t" } else { $a += "-T" }
        $a += $Node.IP
        return $a
    }
    $sshArgs = @(
        "-i", $Node.KeyPath,
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "UserKnownHostsFile=$KnownHostsFile",
        "-o", "ConnectTimeout=15",
        "-o", "ServerAliveInterval=30",
        "-o", "LogLevel=ERROR"
    )
    if ($Tty) { $sshArgs += "-t" }
    if ($NoStdin) { $sshArgs += "-n" }
    $sshArgs += "$SshUser@$($Node.IP)"
    return $sshArgs
}

# When the SSH user needs a password for sudo, feed it to sudo -S. For
# interactive (tty) commands the credential is cached with sudo -v first so the
# real command keeps the terminal as stdin.
function Add-SudoPassword {
    param($Node, [string]$Command, [switch]$Interactive)
    if (-not $Node.SudoNeedsPassword -or -not $Command.StartsWith("sudo ")) { return $Command }
    $feed = "printf '%s\n' $(ConvertTo-ShellLiteral $SshPassword)"
    if ($Interactive) {
        return "$feed | sudo -S -p '' -v && $Command"
    }
    return "$feed | sudo -S -p '' " + $Command.Substring(5)
}

function Invoke-Remote {
    param(
        $Node,
        [string]$Command,
        [string]$InputText,
        [switch]$Quiet,
        [switch]$Interactive,
        [switch]$AllowFailure
    )
    $hasInput = $PSBoundParameters.ContainsKey("InputText")
    $noStdin = -not $hasInput -and -not $Interactive
    $remoteCommand = Add-SudoPassword -Node $Node -Command $Command -Interactive:$Interactive
    $exe = $script:SshExe
    if ($AuthMode -eq "Password") { $exe = $script:PlinkExe }
    $params = @{
        FilePath    = $exe
        Arguments   = @(Get-RemoteArgs -Node $Node -Tty:$Interactive -NoStdin:$noStdin) + @($remoteCommand)
        Quiet       = $Quiet
        Interactive = $Interactive
    }
    if ($hasInput) { $params.InputText = $InputText }
    $result = Invoke-Native @params
    if ($result.ExitCode -ne 0 -and -not $AllowFailure) {
        # Log the caller's command, not the one carrying the sudo password.
        throw "Command failed on $($Node.Name) ($($Node.IP)) with exit code $($result.ExitCode): $Command"
    }
    return $result
}

# Upload text to a file under $RemoteDir via SSH stdin (no scp/sftp dependency).
# Content travels as base64 so encoding, BOMs and CRLF cannot corrupt it; the
# file is LF-only UTF-8, mode 600, in a mode-700 directory owned by the SSH user.
function Send-RemoteText {
    param($Node, [string]$Content, [string]$FileName)
    $normalized = $Content.TrimStart([char]0xFEFF).Replace("`r`n", "`n")
    $b64 = [Convert]::ToBase64String((New-Object System.Text.UTF8Encoding $false).GetBytes($normalized))
    # tr keeps only base64 characters, dropping any BOM/CRLF the console adds to stdin.
    $cmd = "umask 077; mkdir -p $RemoteDir; chmod 700 $RemoteDir; tr -cd 'A-Za-z0-9+/=' | base64 -d > $RemoteDir/$FileName"
    $null = Invoke-Remote -Node $Node -Command $cmd -InputText $b64 -Quiet
}

# Runs a k3s subcommand as root. PATH covers /opt/bin, used on read-only images.
function Invoke-K3s {
    param($Node, [string]$Arguments, [switch]$Quiet, [switch]$AllowFailure)
    $cmd = "sudo /bin/sh -c 'PATH=`$PATH:/usr/local/bin:/opt/bin; k3s $Arguments'"
    return Invoke-Remote -Node $Node -Command $cmd -Quiet:$Quiet -AllowFailure:$AllowFailure
}

# Single-quote a value for a POSIX shell env file.
function ConvertTo-ShellLiteral {
    param([string]$Value)
    return "'" + $Value.Replace("'", "'\''") + "'"
}

function New-EnvFileContent {
    param([System.Collections.IDictionary]$Values)
    $lines = foreach ($k in $Values.Keys) {
        if ($null -ne $Values[$k] -and "$($Values[$k])" -ne "") {
            "{0}={1}" -f $k, (ConvertTo-ShellLiteral "$($Values[$k])")
        }
    }
    return (($lines -join "`n") + "`n")
}

# ---------------------------------------------------------------------------
# Node discovery (same MAC -> DHCP lease approach as Get-SffNodeVoucher.ps1)
# ---------------------------------------------------------------------------
function Normalize-MacAddress {
    param([string]$Mac)
    if ([string]::IsNullOrWhiteSpace($Mac)) { return "" }
    return (($Mac -replace "[-:\.]", "").ToUpperInvariant())
}

function New-NodeObject {
    param([string]$Name, [string]$IP)
    return [pscustomobject]@{
        Name              = $Name
        IP                = $IP
        KeyPath           = $null
        HostKey           = $null
        SudoNeedsPassword = $false
        Ready             = $false
        HostName          = $null
        NodeName          = $null
        Role              = $null
    }
}

function Get-ClusterNodes {
    if ($NodeIPs) {
        return @($NodeIPs | ForEach-Object { New-NodeObject -Name $_ -IP $_ })
    }

    $vms = @(Get-VM -ErrorAction Stop | Where-Object { $_.Name -like "$NestedVmPrefix-*" } | Sort-Object Name)
    if ($vms.Count -eq 0) {
        throw "No Hyper-V VMs named '$NestedVmPrefix-*' found. Pass -NodeIPs explicitly."
    }
    $notRunning = @($vms | Where-Object { $_.State -ne "Running" })
    if ($notRunning.Count -gt 0) {
        throw "VM(s) not running: $(($notRunning | ForEach-Object { $_.Name }) -join ', ')"
    }

    $leases = @(Get-DhcpServerV4Lease -ScopeId $DhcpScopeId -ErrorAction Stop |
                Where-Object { $_.AddressState -like "*Active*" -and -not [string]::IsNullOrWhiteSpace($_.ClientId) })

    $nodes = @()
    foreach ($vm in $vms) {
        $adapter = Get-VMNetworkAdapter -VMName $vm.Name | Select-Object -First 1
        $mac = Normalize-MacAddress $adapter.MacAddress
        $lease = $leases | Where-Object { (Normalize-MacAddress $_.ClientId) -eq $mac } | Select-Object -First 1
        if (-not $lease) {
            throw "No active DHCP lease in scope $DhcpScopeId for $($vm.Name) (MAC $mac)."
        }
        $nodes += New-NodeObject -Name $vm.Name -IP $lease.IPAddress.IPAddressToString
    }
    return $nodes
}

# Key mode: copies the node's private key to a private, LF-normalised cache file.
function Resolve-NodeKey {
    param($Node)
    $source = $null
    if ($SshKeyPath) {
        $source = $SshKeyPath
    } else {
        foreach ($candidate in @("$($Node.Name).pem", "$($Node.IP).pem", "$($Node.Name)", "$($Node.IP)")) {
            $p = Join-Path $SshKeyDirectory $candidate
            if (Test-Path $p -PathType Leaf) { $source = $p; break }
        }
        if (-not $source -and (Test-Path $SshKeyDirectory)) {
            $all = @(Get-ChildItem -Path $SshKeyDirectory -File | Where-Object { $_.Extension -ne ".pub" })
            if ($all.Count -eq 1) { $source = $all[0].FullName }
        }
    }
    if (-not $source -or -not (Test-Path $source -PathType Leaf)) {
        throw "No SSH key for $($Node.Name). Put the key in $SshKeyDirectory (as $($Node.Name).pem, or a single key for all nodes), pass -SshKeyPath, or use -AuthMode Password."
    }

    if (-not (Test-Path $KeyCacheDir)) {
        New-Item -Path $KeyCacheDir -ItemType Directory -Force | Out-Null
    }
    $dest = Join-Path $KeyCacheDir ("{0}.key" -f ($Node.Name -replace "[^A-Za-z0-9\.-]", "_"))
    Write-LfFile -Path $dest -Content ([System.IO.File]::ReadAllText($source))
    Set-OwnerOnlyAcl -Path $dest
    return $dest
}

# Returns $null when ready, otherwise a reason string. Also records the
# hostname and whether sudo needs the SSH password.
function Test-NodeReady {
    param($Node)
    if ($AuthMode -eq "Password") {
        $Node.HostKey = Get-PlinkHostKey -Node $Node
    }
    # Always exits 0 once logged in, so a non-zero code means SSH itself failed.
    $r = Invoke-Remote -Node $Node -Command "hostname; if sudo -n true 2>/dev/null; then echo SUDO_OK; else echo SUDO_PW; fi" -Quiet -AllowFailure
    if ($r.ExitCode -ne 0) {
        $detail = ($r.Lines | Where-Object { $_ } | Select-Object -Last 1)
        return "SSH as $SshUser not possible yet ($detail)"
    }
    if ($r.Output -match "SUDO_PW") {
        if ($AuthMode -ne "Password") {
            throw "$($Node.Name): SSH works but '$SshUser' has no passwordless sudo. Use -AuthMode Password (sudo with -SshPassword) or grant NOPASSWD sudo."
        }
        $Node.SudoNeedsPassword = $true
        $check = Invoke-Remote -Node $Node -Command "sudo true && echo SUDO_OK" -Quiet -AllowFailure
        if ($check.Output -notmatch "SUDO_OK") {
            throw "$($Node.Name): '$SshUser' cannot sudo with the supplied password. Check -SshPassword or the node's sudoers."
        }
    }
    $name = $r.Lines | Where-Object { $_ -and $_ -notmatch "^SUDO_(OK|PW)$" } | Select-Object -Last 1
    if (-not $name) { $name = $Node.Name }
    $Node.HostName = "$name".Trim().ToLowerInvariant()
    $Node.Ready = $true
    return $null
}

function Wait-ForNodes {
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $attempt = 0
    while ($true) {
        $attempt++
        $problems = @()
        $nodes = $null
        try {
            $nodes = @(Get-ClusterNodes)
            foreach ($n in $nodes) {
                try {
                    if ($AuthMode -eq "Key") { $n.KeyPath = Resolve-NodeKey -Node $n }
                    $reason = Test-NodeReady -Node $n
                    if ($reason) { $problems += "$($n.Name) ($($n.IP)): $reason" }
                } catch {
                    if ($_.Exception.Message -match "sudo") { throw }
                    $problems += "$($n.Name): $($_.Exception.Message)"
                }
            }
        } catch {
            if ($_.Exception.Message -match "sudo") { throw }
            $problems += $_.Exception.Message
        }

        if ($problems.Count -eq 0) { return $nodes }

        foreach ($p in $problems) { Write-Status $p "Yellow" }
        if (-not $Wait) {
            throw "Nodes are not ready. Fix the issues above or re-run with -Wait to poll until they are."
        }
        if ((Get-Date) -ge $deadline) {
            throw "Timed out after $TimeoutMinutes minutes waiting for nodes."
        }
        $remaining = [math]::Round(($deadline - (Get-Date)).TotalMinutes, 1)
        Write-Status "Attempt $attempt - not ready yet; retrying in ${PollIntervalSeconds}s (${remaining}m left)" "DarkGray"
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

# ---------------------------------------------------------------------------
# Script staging
# ---------------------------------------------------------------------------
function Find-LocalScript {
    param([string[]]$Names)
    foreach ($dir in @($ScriptsPath, $PSScriptRoot)) {
        foreach ($name in $Names) {
            $p = Join-Path $dir $name
            if (Test-Path $p -PathType Leaf) { return $p }
        }
    }
    throw "Could not find $($Names -join ' / ') in $ScriptsPath or $PSScriptRoot."
}

function Get-StagedScripts {
    $map = [ordered]@{
        "k3s-node-prep.sh"      = @("k3s-node-prep.sh")
        "k3s-install-server.sh" = @("k3s-install-server.sh")
        "k3s-join-agent.sh"     = @("k3s-join-agent.sh")
    }
    if ($EnableArc) {
        # Blob name on the host is setup_k3s_arc.sh; repo name is setup-k3s-arc.sh.
        $map["setup-k3s-arc.sh"] = @("setup_k3s_arc.sh", "setup-k3s-arc.sh")
    }
    $result = [ordered]@{}
    foreach ($remoteName in $map.Keys) {
        $local = Find-LocalScript -Names $map[$remoteName]
        # Strip any UTF-8 BOM; Send-RemoteText normalises line endings.
        $result[$remoteName] = [System.IO.File]::ReadAllText($local).TrimStart([char]0xFEFF)
    }
    return $result
}

# ---------------------------------------------------------------------------
# Cluster steps
# ---------------------------------------------------------------------------
function Get-ClusterNodeTable {
    param($Server)
    $r = Invoke-K3s -Node $Server -Arguments "kubectl get nodes -o wide --no-headers" -Quiet -AllowFailure
    $rows = @()
    if ($r.ExitCode -ne 0) { return $rows }
    foreach ($line in $r.Lines) {
        $cols = @($line -split "\s+" | Where-Object { $_ })
        if ($cols.Count -ge 6) {
            $rows += [pscustomobject]@{ Name = $cols[0]; Status = $cols[1]; Roles = $cols[2]; Version = $cols[4]; IP = $cols[5] }
        }
    }
    return $rows
}

function Wait-ClusterReady {
    param($Server, [int]$Expected)
    $deadline = (Get-Date).AddMinutes($NodeReadyTimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        $rows = @(Get-ClusterNodeTable -Server $Server)
        $ready = @($rows | Where-Object { $_.Status -eq "Ready" })
        if ($ready.Count -ge $Expected) { return $rows }
        Write-Status "Nodes Ready: $($ready.Count)/$Expected - waiting..." "DarkGray"
        Start-Sleep -Seconds 10
    }
    throw "Timed out after $NodeReadyTimeoutMinutes minutes waiting for $Expected Ready nodes."
}

function Save-Kubeconfig {
    param($Server)
    $r = Invoke-Remote -Node $Server -Command "sudo cat /etc/rancher/k3s/k3s.yaml" -Quiet
    $yaml = ($r.Lines -join "`n")
    $yaml = $yaml.Replace("https://127.0.0.1:6443", "https://$($Server.IP):6443")
    $yaml = $yaml -replace "(?m)^(\s*(?:-\s+)?(?:name|cluster|user|current-context):\s+)default\s*$", "`${1}$ClusterName"
    $path = Join-Path $OutputPath "kubeconfig"
    Write-LfFile -Path $path -Content ($yaml + "`n")
    Set-OwnerOnlyAcl -Path $path
    return $path
}

function Install-HostKubectl {
    param([string]$KubernetesVersion)
    $binDir = Join-Path $OutputPath "bin"
    $exe = Join-Path $binDir "kubectl.exe"
    if (-not (Test-Path $binDir)) { New-Item -Path $binDir -ItemType Directory -Force | Out-Null }

    $url = "https://dl.k8s.io/release/$KubernetesVersion/bin/windows/amd64/kubectl.exe"
    Write-Status "Downloading kubectl $KubernetesVersion from $url"
    $ProgressPreference = "SilentlyContinue"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing
    $expected = (Invoke-WebRequest -Uri "$url.sha256" -UseBasicParsing).Content
    if ($expected -is [byte[]]) { $expected = [System.Text.Encoding]::ASCII.GetString($expected) }
    $expected = $expected.Trim().Split(" ")[0]
    $actual = (Get-FileHash -Path $exe -Algorithm SHA256).Hash
    if ($actual -ne $expected.ToUpperInvariant()) {
        Remove-Item $exe -Force
        throw "kubectl.exe checksum mismatch (expected $expected, got $actual)."
    }
    Write-Status "kubectl installed at $exe (checksum verified)" "Green"
    return $exe
}

function Invoke-ArcOnboarding {
    param($Server, $OtherServers)

    $values = [ordered]@{
        RESOURCE_GROUP  = $ArcResourceGroup
        CLUSTER_NAME    = $ArcClusterName
        LOCATION        = $ArcLocation
        SKIP_AZURE_RBAC = $(if ($SkipAzureRbac) { "true" } else { "false" })
    }

    $clientId = $env:AZURE_CLIENT_ID
    $secret = $env:AZURE_CLIENT_SECRET
    $tenant = $env:AZURE_TENANT_ID
    $subscription = $env:AZURE_SUBSCRIPTION_ID
    if ($ArcServicePrincipal) {
        $clientId = $ArcServicePrincipal.UserName
        $secret = $ArcServicePrincipal.GetNetworkCredential().Password
    }
    if ($ArcTenantId) { $tenant = $ArcTenantId }
    if ($ArcSubscriptionId) { $subscription = $ArcSubscriptionId }

    $unattended = $clientId -and $secret -and $tenant
    if ($unattended) {
        $values["AZURE_CLIENT_ID"] = $clientId
        $values["AZURE_CLIENT_SECRET"] = $secret
        $values["AZURE_TENANT_ID"] = $tenant
    }
    if ($subscription) { $values["AZURE_SUBSCRIPTION_ID"] = $subscription }

    Send-RemoteText -Node $Server -FileName "arc.env" -Content (New-EnvFileContent $values)
    try {
        if ($unattended) {
            Write-Status "Connecting to Azure Arc with service principal $clientId..."
            $null = Invoke-Remote -Node $Server -Command "sudo bash $RemoteDir/setup-k3s-arc.sh"
        } else {
            Write-Status "No service principal supplied - setup-k3s-arc.sh will show a device code below. Sign in at https://microsoft.com/devicelogin." "Yellow"
            $null = Invoke-Remote -Node $Server -Command "sudo bash $RemoteDir/setup-k3s-arc.sh" -Interactive
        }
    } finally {
        $null = Invoke-Remote -Node $Server -Command "rm -f $RemoteDir/arc.env" -Quiet -AllowFailure
    }

    # Azure RBAC webhooks are kube-apiserver flags, so every server needs them.
    if (-not $SkipAzureRbac) {
        foreach ($s in $OtherServers) {
            Write-Status "Configuring Azure RBAC webhooks on additional server $($s.Name)..."
            Send-RemoteText -Node $s -FileName "arc.env" -Content (New-EnvFileContent ([ordered]@{ ARC_WEBHOOKS_ONLY = "true" }))
            try {
                $null = Invoke-Remote -Node $s -Command "sudo bash $RemoteDir/setup-k3s-arc.sh"
            } finally {
                $null = Invoke-Remote -Node $s -Command "rm -f $RemoteDir/arc.env" -Quiet -AllowFailure
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Phase gate: K3s goes on the deployed SFF Linux, never on the bootstrap loader
# ---------------------------------------------------------------------------
function Confirm-SffLinuxDeployed {
    if ($SffLinuxDeployed) {
        Write-Status "-SffLinuxDeployed given: Azure has deployed SFF Linux on all nodes (phase 3 complete)."
        return
    }
    Write-Host ""
    Write-Host "K3s must be installed on the SFF Linux that Azure deploys, NOT on the bootstrap loader." -ForegroundColor Yellow
    Write-Host "Before continuing, make sure that:" -ForegroundColor Yellow
    Write-Host "  1. setup.ps1 completed and the nodes booted the bootstrap loader" -ForegroundColor Yellow
    Write-Host "  2. Get-SffNodeVoucher.ps1 retrieved a voucher for every node (C:\vouchers)" -ForegroundColor Yellow
    Write-Host "  3. Azure has finished deploying SFF Linux on every node (check the portal)" -ForegroundColor Yellow
    Write-Host ""
    if (-not [Environment]::UserInteractive -or $Host.Name -ne "ConsoleHost") {
        throw "SFF Linux deployment not confirmed. Re-run with -SffLinuxDeployed once Azure has finished deploying all nodes."
    }
    $answer = Read-Host "Has Azure finished deploying SFF Linux on ALL nodes? (y/N)"
    if ($answer -notmatch "^(y|yes)$") {
        throw "Stopped: finish the SFF Linux deployment in Azure first (see C:\Scripts\K3S-CLUSTER-SETUP.txt), then re-run."
    }
    Write-Status "Operator confirmed SFF Linux is deployed on all nodes."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
$nodes = @()
try {
    Write-Step "K3s cluster deployment started (topology: $Topology)"
    Confirm-SffLinuxDeployed

    if ($AuthMode -eq "Password") {
        $script:PlinkExe = Resolve-PlinkExe
        Write-Status "Auth: password for '$SshUser' via $script:PlinkExe"
        if ($SshPassword.Contains('"')) {
            throw "-SshPassword cannot contain a double quote (Windows PowerShell 5.1 cannot pass it to plink safely)."
        }
    } else {
        $script:SshExe = Resolve-SshExe
        Write-Status "Auth: SSH key for '$SshUser' via $script:SshExe"
    }

    $scripts = Get-StagedScripts

    Write-Step "Waiting for nodes (SSH as $SshUser, sudo)"
    $nodes = @(Wait-ForNodes)
    if ($Topology -eq "HA" -and ($nodes.Count -lt 3 -or $nodes.Count % 2 -eq 0)) {
        throw "Topology HA needs an odd number of nodes (3+); found $($nodes.Count). Use -Topology ServerAgents."
    }

    # Duplicate hostnames would make nodes collide in K3s; fall back to VM names.
    $dupes = @($nodes | Group-Object HostName | Where-Object { $_.Count -gt 1 })
    foreach ($n in $nodes) {
        if ($dupes.Count -gt 0) {
            $n.NodeName = ($n.Name.ToLowerInvariant() -replace "[^a-z0-9\-\.]", "-")
        } else {
            $n.NodeName = $n.HostName
        }
    }
    if ($dupes.Count -gt 0) {
        Write-Status "Nodes share hostnames ($(($dupes | ForEach-Object { $_.Name }) -join ', ')); using VM names as K3s node names." "Yellow"
    }

    $server = $nodes[0]
    $server.Role = "server (init)"
    for ($i = 1; $i -lt $nodes.Count; $i++) {
        if ($Topology -eq "HA") { $nodes[$i].Role = "server" } else { $nodes[$i].Role = "agent" }
    }
    $nodes | Format-Table Name, IP, NodeName, Role -AutoSize | Out-String | ForEach-Object { Write-Host $_ }

    $useNodeNameOverride = $dupes.Count -gt 0
    $serverIps = @($nodes | Where-Object { $_.Role -like "server*" } | ForEach-Object { $_.IP })

    Write-Step "Uploading scripts to $RemoteDir on each node"
    foreach ($n in $nodes) {
        foreach ($name in $scripts.Keys) {
            Send-RemoteText -Node $n -FileName $name -Content $scripts[$name]
        }
        Write-Status "$($n.Name): uploaded $($scripts.Keys -join ', ')" "Green"
    }

    Write-Step "Preparing nodes (k3s-node-prep.sh)"
    foreach ($n in $nodes) {
        Write-Status "Preparing $($n.Name) ($($n.IP))..."
        $null = Invoke-Remote -Node $n -Command "sudo env NODE_CIDR=$NodeCidr bash $RemoteDir/k3s-node-prep.sh"
    }

    Write-Step "Installing first K3s server on $($server.Name) ($($server.IP))"
    $envValues = [ordered]@{
        K3S_ROLE            = "init"
        CLUSTER_INIT        = $(if ($Topology -eq "HA") { "true" } else { "false" })
        NODE_IP             = $server.IP
        NODE_NAME           = $(if ($useNodeNameOverride) { $server.NodeName } else { "" })
        TLS_SANS            = ($serverIps -join " ")
        INSTALL_K3S_VERSION = $K3sVersion
    }
    Send-RemoteText -Node $server -FileName "k3s.env" -Content (New-EnvFileContent $envValues)
    try {
        $null = Invoke-Remote -Node $server -Command "sudo bash $RemoteDir/k3s-install-server.sh"
    } finally {
        $null = Invoke-Remote -Node $server -Command "rm -f $RemoteDir/k3s.env" -Quiet -AllowFailure
    }

    $token = (Invoke-Remote -Node $server -Command "sudo cat /var/lib/rancher/k3s/server/token" -Quiet).Output.Trim()
    if (-not $token) { throw "Could not read the cluster token from $($server.Name)." }
    $versionLine = (Invoke-K3s -Node $server -Arguments "--version" -Quiet).Lines | Select-Object -First 1
    $installedVersion = ($versionLine -split "\s+")[2]
    Write-Status "Server running K3s $installedVersion; other nodes will be pinned to it." "Green"

    $k3sUrl = "https://$($server.IP):6443"
    $others = @($nodes | Select-Object -Skip 1)
    foreach ($n in $others) {
        Write-Step "Joining $($n.Name) ($($n.IP)) as $($n.Role)"
        if ($n.Role -eq "server") {
            $envValues = [ordered]@{
                K3S_ROLE            = "join"
                K3S_URL             = $k3sUrl
                K3S_TOKEN           = $token
                NODE_IP             = $n.IP
                NODE_NAME           = $(if ($useNodeNameOverride) { $n.NodeName } else { "" })
                TLS_SANS            = ($serverIps -join " ")
                INSTALL_K3S_VERSION = $installedVersion
            }
            $joinScript = "k3s-install-server.sh"
        } else {
            $envValues = [ordered]@{
                K3S_URL             = $k3sUrl
                K3S_TOKEN           = $token
                NODE_IP             = $n.IP
                NODE_NAME           = $(if ($useNodeNameOverride) { $n.NodeName } else { "" })
                INSTALL_K3S_VERSION = $installedVersion
            }
            $joinScript = "k3s-join-agent.sh"
        }
        Send-RemoteText -Node $n -FileName "k3s.env" -Content (New-EnvFileContent $envValues)
        try {
            $null = Invoke-Remote -Node $n -Command "sudo bash $RemoteDir/$joinScript"
        } finally {
            $null = Invoke-Remote -Node $n -Command "rm -f $RemoteDir/k3s.env" -Quiet -AllowFailure
        }
    }
    $token = $null

    Write-Step "Waiting for $($nodes.Count) node(s) to be Ready"
    $rows = @(Wait-ClusterReady -Server $server -Expected $nodes.Count)
    foreach ($n in ($nodes | Where-Object { $_.Role -eq "agent" })) {
        $row = $rows | Where-Object { $_.IP -eq $n.IP } | Select-Object -First 1
        if ($row) {
            $null = Invoke-K3s -Node $server -Arguments "kubectl label node $($row.Name) node-role.kubernetes.io/worker=worker --overwrite" -Quiet
        }
    }
    $rows = @(Get-ClusterNodeTable -Server $server)
    $rows | Format-Table Name, Status, Roles, Version, IP -AutoSize | Out-String | ForEach-Object { Write-Host $_ }

    Write-Step "Saving kubeconfig for the host"
    $kubeconfig = Save-Kubeconfig -Server $server
    Write-Status "Kubeconfig written to $kubeconfig (API: $k3sUrl)" "Green"

    $kubectl = $null
    if ($InstallKubectl) {
        $k8sVersion = ($installedVersion -split "\+")[0]
        $kubectl = Install-HostKubectl -KubernetesVersion $k8sVersion
        $check = Invoke-Native -FilePath $kubectl -Arguments @("--kubeconfig", $kubeconfig, "get", "nodes", "-o", "wide")
        if ($check.ExitCode -ne 0) {
            Write-Status "kubectl from the host could not reach $k3sUrl - check the node firewall." "Yellow"
        }
    }

    $state = [ordered]@{
        clusterName = $ClusterName
        topology    = $Topology
        k3sVersion  = $installedVersion
        apiServer   = $k3sUrl
        kubeconfig  = $kubeconfig
        deployedAt  = (Get-Date -Format "o")
        nodes       = @($nodes | ForEach-Object { [ordered]@{ vm = $_.Name; ip = $_.IP; nodeName = $_.NodeName; role = $_.Role } })
    }
    $state | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $OutputPath "cluster.json") -Encoding UTF8

    if ($EnableArc) {
        Write-Step "Connecting cluster to Azure Arc ($ArcResourceGroup/$ArcClusterName, $ArcLocation)"
        $otherServers = @($nodes | Where-Object { $_.Role -eq "server" })
        Invoke-ArcOnboarding -Server $server -OtherServers $otherServers
        Write-Status "Azure Arc onboarding complete." "Green"
    }

    Write-Host ""
    Write-Status "*** K3S CLUSTER READY: $($nodes.Count) node(s), $Topology, K3s $installedVersion ***" "Green"
    Write-Host ""
    Write-Host "Use the cluster from this host:" -ForegroundColor Cyan
    Write-Host "  `$env:KUBECONFIG = '$kubeconfig'" -ForegroundColor White
    if ($kubectl) {
        Write-Host "  & '$kubectl' get nodes -o wide" -ForegroundColor White
    } else {
        Write-Host "  kubectl get nodes -o wide        (re-run with -InstallKubectl to get kubectl.exe)" -ForegroundColor White
    }
    Write-Host "Or on the server node:" -ForegroundColor Cyan
    if ($AuthMode -eq "Password") {
        Write-Host "  plink -ssh $SshUser@$($server.IP) sudo k3s kubectl get nodes   (password: -SshPassword)" -ForegroundColor White
    } else {
        Write-Host "  ssh -i $($server.KeyPath) $SshUser@$($server.IP) sudo k3s kubectl get nodes" -ForegroundColor White
    }
    Write-Host "Log: $LogFile" -ForegroundColor Cyan
}
catch {
    Write-Status "ERROR: $($_.Exception.Message)" "Red"
    Write-Status "Stack trace: $($_.ScriptStackTrace)" "DarkGray"
    Write-Host ""
    Write-Host "Deployment failed - see $LogFile. The script is idempotent; fix the issue and re-run." -ForegroundColor Red
    exit 1
}
finally {
    # Best effort: make sure no secret-bearing env files are left on the nodes.
    if ($script:SshExe -or $script:PlinkExe) {
        foreach ($n in $nodes) {
            if ($n.Ready) {
                $null = Invoke-Remote -Node $n -Command "rm -f $RemoteDir/k3s.env $RemoteDir/arc.env" -Quiet -AllowFailure
            }
        }
    }
}
