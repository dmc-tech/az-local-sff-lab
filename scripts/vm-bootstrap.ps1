#Requires -Version 5.1
# Runs from Azure Custom Script Extension download folder (with setup / voucher scripts).
# Replaces fragile inline powershell -Command strings in ARM/Bicep.

param(
    [Parameter(Mandatory = $true)][string]$SetupScriptFileName,
    [Parameter(Mandatory = $true)][string]$VoucherScriptFileName,
    [Parameter(Mandatory = $true)][string]$BootstrapScriptFileName,
    [Parameter(Mandatory = $true)][string]$K3sArcScriptFileName,
    [Parameter(Mandatory = $true)][string]$K3sJoinAgentScriptFileName,
    [Parameter(Mandatory = $true)][string]$K3sBootstrapAgentsScriptFileName,
    [Parameter(Mandatory = $true)][string]$K3sSetupInstructionsFileName,
    [Parameter(Mandatory = $true)][string]$OsImagePackageUrl,
    [Parameter(Mandatory = $true)][string]$ConfiguratorAppUrl,
    [Parameter(Mandatory = $true)][string]$NestedVmPrefix,
    [Parameter(Mandatory = $true)][string]$AdminUsername,
    [Parameter(Mandatory = $true)][string]$AdminPassword
)

# CSE runs commandToExecute via cmd.exe: single quotes are literal, so args can arrive as 'setup.ps1'.
function Shrink-CseArg([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    $t = $Value.Trim()
    if ($t.Length -ge 2) {
        $a, $b = $t[0], $t[$t.Length - 1]
        if ($a -eq $b -and ($a -eq [char]0x27 -or $a -eq [char]0x22)) {
            return $t.Substring(1, $t.Length - 2)
        }
    }
    return $t
}
$SetupScriptFileName = Shrink-CseArg $SetupScriptFileName
$VoucherScriptFileName = Shrink-CseArg $VoucherScriptFileName
$BootstrapScriptFileName = Shrink-CseArg $BootstrapScriptFileName
$K3sArcScriptFileName = Shrink-CseArg $K3sArcScriptFileName
$K3sJoinAgentScriptFileName = Shrink-CseArg $K3sJoinAgentScriptFileName
$K3sBootstrapAgentsScriptFileName = Shrink-CseArg $K3sBootstrapAgentsScriptFileName
$K3sSetupInstructionsFileName = Shrink-CseArg $K3sSetupInstructionsFileName
$OsImagePackageUrl = Shrink-CseArg $OsImagePackageUrl
$ConfiguratorAppUrl = Shrink-CseArg $ConfiguratorAppUrl
$NestedVmPrefix = Shrink-CseArg $NestedVmPrefix
$AdminUsername = Shrink-CseArg $AdminUsername
$AdminPassword = Shrink-CseArg $AdminPassword

$ErrorActionPreference = 'Stop'

Install-WindowsFeature -Name Hyper-V, DHCP -IncludeManagementTools

New-Item -Path 'C:\Scripts' -ItemType Directory -Force | Out-Null
Copy-Item -Path ".\$SetupScriptFileName" -Destination "C:\Scripts\$SetupScriptFileName" -Force
Copy-Item -Path ".\$VoucherScriptFileName" -Destination "C:\Scripts\$VoucherScriptFileName" -Force
Copy-Item -Path ".\$BootstrapScriptFileName" -Destination "C:\Scripts\$BootstrapScriptFileName" -Force
Copy-Item -Path ".\$K3sArcScriptFileName" -Destination "C:\Scripts\$K3sArcScriptFileName" -Force
Copy-Item -Path ".\$K3sJoinAgentScriptFileName" -Destination "C:\Scripts\$K3sJoinAgentScriptFileName" -Force
Copy-Item -Path ".\$K3sBootstrapAgentsScriptFileName" -Destination "C:\Scripts\$K3sBootstrapAgentsScriptFileName" -Force
Copy-Item -Path ".\$K3sSetupInstructionsFileName" -Destination "C:\Scripts\$K3sSetupInstructionsFileName" -Force

New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' -Name 'HideSCAHealth' -Value 1 -PropertyType DWord -Force
# Use .NET for this key: PowerShell's registry provider + New-Item -Force can throw "Cannot delete a subkey tree..." on some Server images.
$smParent = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft', $true)
if ($null -eq $smParent) { throw 'Cannot open HKLM\SOFTWARE\Microsoft for write (ServerManager policy).' }
try {
    $null = $smParent.CreateSubKey('ServerManager', $true)
} finally {
    $smParent.Dispose()
}
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Name 'DoNotOpenServerManagerAtLogon' -Value 1 -PropertyType DWord -Force
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Name 'DoNotPopWACConsoleAtSMLaunch' -Value 1 -PropertyType DWord -Force
Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'AzureArcSetup' -ErrorAction SilentlyContinue

$arcFeat = Get-WindowsOptionalFeature -Online -FeatureName AzureArcSetup -ErrorAction SilentlyContinue
if ($null -ne $arcFeat -and $arcFeat.State -eq 'Enabled') {
    Disable-WindowsOptionalFeature -Online -FeatureName AzureArcSetup -NoRestart | Out-Null
}

if (Get-Command Get-WindowsCapability -ErrorAction SilentlyContinue) {
    Get-WindowsCapability -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'AzureArcSetup*' -and $_.State -eq 'Installed' } |
        ForEach-Object { Remove-WindowsCapability -Online -Name $_.Name -ErrorAction SilentlyContinue | Out-Null }
}

New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE' -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE' -Name 'DisablePrivacyExperience' -Value 1 -PropertyType DWord -Force
New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -Value 0 -PropertyType DWord -Force
New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowDeviceNameInTelemetry' -Value 0 -PropertyType DWord -Force
New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'DoNotShowFeedbackNotifications' -Value 1 -PropertyType DWord -Force
New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTailoredExperiencesWithDiagnosticData' -Value 0 -PropertyType DWord -Force
New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows' -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows' -Name 'CEIPEnable' -Value 0 -PropertyType DWord -Force
New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' -Name 'Disabled' -Value 1 -PropertyType DWord -Force

$runOnceValue = "powershell.exe -NoExit -ExecutionPolicy Bypass -File C:\Scripts\$SetupScriptFileName -OsImagePackageUrl '$OsImagePackageUrl' -ConfiguratorAppUrl '$ConfiguratorAppUrl' -VMPrefix '$NestedVmPrefix'"
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'RunSetupScript' -Value $runOnceValue

$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $winlogon -Name 'AutoAdminLogon' -Value '1'
Set-ItemProperty -Path $winlogon -Name 'DefaultUserName' -Value $AdminUsername
Set-ItemProperty -Path $winlogon -Name 'DefaultPassword' -Value $AdminPassword
Set-ItemProperty -Path $winlogon -Name 'AutoLogonCount' -Value 1 -Type DWord

Restart-Computer -Force
