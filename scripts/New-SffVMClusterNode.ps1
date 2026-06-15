<#
.SYNOPSIS
    Creates Hyper-V VM nodes configured for Azure Local Linux.

.DESCRIPTION
    This script creates Hyper-V VM nodes ready for Azure Local Linux provisioning with the following default configuration:
    - Generation 2 VMs with TPM enabled and Secure Boot disabled
    - 16GB RAM and 20 virtual processors per VM
    - 512GB dynamic VHDX disks
    - Network connectivity via specified virtual switch
    - Optional ISO attachment for OS installation
    
    The script performs comprehensive validation including:
    - Administrator privilege verification
    - Hyper-V installation and service status checks
    - Virtual switch availability verification
    - Existing VM conflict detection and resolution
    
    VMs are created in parallel for improved performance and can be automatically started upon creation.

.PARAMETER ClusterPrefix
    The prefix for the cluster VM names. VMs will be named as {ClusterPrefix}-1, {ClusterPrefix}-2, etc.
    This parameter is mandatory.

.PARAMETER VMPath
    The path where VM configuration files will be stored. Default is "c:\vms".

.PARAMETER VHDPath
    The path where VHDX files will be stored. Default is "c:\vms".

.PARAMETER SwitchName
    The name of the virtual switch to connect VMs to. 
    Default is "Intel(R) Ethernet 10G X520 LOM #2 - Virtual Switch".

.PARAMETER MemoryGB
    The amount of memory in GB to allocate to each VM. Default is 16 GB.

.PARAMETER DiskGB
    The size of the VHDX disk in GB for each VM. Default is 512 GB.

.PARAMETER ProcessorCount
    The number of virtual processors to allocate to each VM. Default is 20.

.PARAMETER VMCount
    The number of VMs to create in the cluster. Default is 3.

.PARAMETER ISOPath
    Optional path to an ISO file to attach to all VMs for OS installation.

.PARAMETER StartVMs
    Switch parameter to automatically start VMs after creation. Default is $true.

.PARAMETER GetIPAddresses
    Switch parameter to retrieve and display IP addresses of started VMs. Default is $true.

.EXAMPLE
    .\New-SffVMClusterNode.ps1 -ClusterPrefix "MyCluster"
    
    Creates a 3-VM cluster with default settings using "MyCluster" as the prefix.

.EXAMPLE
    .\New-SffVMClusterNode.ps1 -ClusterPrefix "TestCluster" -VMCount 5 -MemoryGB 32 -ProcessorCount 8
    
    Creates a 5-VM cluster with 32GB RAM and 8 processors per VM.

.EXAMPLE
    .\New-SffVMClusterNode.ps1 -ClusterPrefix "ProdCluster" -ISOPath "C:\ISOs\Windows2022.iso" -StartVMs:$false
    
    Creates a cluster with ISO attached but doesn't start the VMs automatically.

.EXAMPLE
    .\New-SffVMClusterNode.ps1 -ClusterPrefix "DevCluster" -VMPath "D:\VMs" -VHDPath "E:\VHDs" -SwitchName "External Switch"
    
    Creates a cluster with custom paths and network switch.

.NOTES
    Author: Danny McDermott
    Version: 1.0
    Requires: Windows PowerShell 5.1 or later, Hyper-V feature enabled, Administrator privileges
    
    Prerequisites:
    - Hyper-V feature must be installed and enabled
    - Virtual switch must exist and be accessible
    - Sufficient disk space for VM files and VHDX disks
    - Administrator privileges required for Hyper-V operations
    
    Security Features:
    - TPM (Trusted Platform Module) enabled for enhanced security
    - Secure Boot disabled for compatibility with various operating systems
    - Local key protector configured for TPM functionality
    
    Performance Considerations:
    - VMs are created in parallel for faster deployment
    - Dynamic VHDX disks are used to save initial disk space
    - Memory is statically allocated for consistent performance

.INPUTS
    None. This script does not accept pipeline input.

.OUTPUTS
    The script provides detailed console output including:
    - Validation results and error messages
    - VM creation progress and status
    - IP address information for created VMs
    - Summary statistics and next steps

.LINK
    https://docs.microsoft.com/en-us/virtualization/hyper-v-on-windows/
    
.LINK
    https://docs.microsoft.com/en-us/powershell/module/hyper-v/
#>



param(
    [Parameter(Mandatory=$true)]
    [string]$ClusterPrefix,
    
    [Parameter(Mandatory=$false)]
    [string]$VMPath = "c:\vms",
    
    [Parameter(Mandatory=$false)]
    [string]$VHDPath = "c:\vms",
    
    [Parameter(Mandatory=$false)]
    [string]$SwitchName = "Intel(R) Ethernet 10G X520 LOM #2 - Virtual Switch",
    
    [Parameter(Mandatory=$false)]
    [int]$MemoryGB = 16,

    
    [Parameter(Mandatory=$false)]
    [int]$DiskGB = 512,
    
    [Parameter(Mandatory=$false)]
    [int]$ProcessorCount = 20,
    
    [Parameter(Mandatory=$false)]
    [int]$VMCount = 3,
    
    [Parameter(Mandatory=$false)]
    [string]$ISOPath,
    
    [Parameter(Mandatory=$false)]
    [switch]$StartVMs = $true,
    
    [Parameter(Mandatory=$false)]
    [switch]$GetIPAddresses = $true
)

# Check if running as Administrator
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "This script must be run as Administrator"
    exit 1
}

# Check if Hyper-V is installed and enabled
try {
    # Method 1: Check if Hyper-V PowerShell module is available
    $hyperVModule = Get-Module -ListAvailable -Name Hyper-V
    if (-not $hyperVModule) {
        Write-Error "Hyper-V PowerShell module is not available. Hyper-V may not be installed."
        exit 1
    }
    
    # Method 2: Try to get Hyper-V service status
    $hyperVService = Get-Service -Name vmms -ErrorAction SilentlyContinue
    if (-not $hyperVService -or $hyperVService.Status -ne "Running") {
        Write-Error "Hyper-V Virtual Machine Management service is not running. Please enable Hyper-V and restart the computer."
        exit 1
    }
    
    # Method 3: Try to list VMs to verify Hyper-V is functional
    $vmList = Get-VM -ErrorAction SilentlyContinue
    if ($vmList -eq $null -and $LASTEXITCODE -ne 0) {
        Write-Error "Hyper-V is not properly configured or enabled."
        exit 1
    }
    
    Write-Host "Hyper-V is installed and running." -ForegroundColor Green
    
} catch {
    Write-Error "Failed to verify Hyper-V installation: $($_.Exception.Message)"
    exit 1
}

# Check if the specified VM switch exists
$vmSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
if (-not $vmSwitch) {
    Write-Warning "VM Switch '$SwitchName' does not exist."
    Write-Host "`nAvailable VM Switches:" -ForegroundColor Yellow
    $availableSwitches = Get-VMSwitch
    if ($availableSwitches) {
        foreach ($switch in $availableSwitches) {
            Write-Host "  - $($switch.Name) (Type: $($switch.SwitchType))" -ForegroundColor White
        }
    } else {
        Write-Host "  No VM switches found. You may need to create one first." -ForegroundColor Red
    }
    Write-Host "`nPlease specify a valid switch name using the -SwitchName parameter." -ForegroundColor Cyan
    exit 1
}

# Check for existing VMs with the same names
$existingVMs = @()
for ($i = 1; $i -le $VMCount; $i++) {
    $vmName = "$ClusterPrefix-$i"
    $existingVM = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($existingVM) {
        $existingVMs += $vmName
    }
}

if ($existingVMs.Count -gt 0) {
    Write-Warning "The following VMs already exist: $($existingVMs -join ', ')"
    Write-Host "`nExisting VM Details:" -ForegroundColor Yellow
    foreach ($vmName in $existingVMs) {
        $vm = Get-VM -Name $vmName
        Write-Host "  - $($vm.Name) (State: $($vm.State), Generation: $($vm.Generation))" -ForegroundColor White
    }
    
    $response = Read-Host "`nDo you want to delete the existing VMs and create new ones? (y/N)"
    if ($response -eq 'y' -or $response -eq 'Y') {
        Write-Host "Stopping and removing existing VMs..." -ForegroundColor Yellow
        foreach ($vmName in $existingVMs) {
            $vm = Get-VM -Name $vmName
            if ($vm.State -ne "Off") {
                Stop-VM -Name $vmName -Force -ErrorAction SilentlyContinue
            }
            Remove-VM -Name $vmName -Force
            Write-Host "  Removed VM: $vmName" -ForegroundColor Green
        }
        Write-Host "All existing VMs removed successfully." -ForegroundColor Green
    } else {
        Write-Host "Cluster creation cancelled. Please choose a different cluster prefix or remove the existing VMs manually." -ForegroundColor Cyan
        exit 0
    }
}

# Function to get VM IP addresses
function Get-VMIPAddresses {
    param(
        [string]$ClusterPrefix,
        [int]$VMCount
    )
    
    Write-Host "`nRetrieving IP addresses for cluster VMs..." -ForegroundColor Cyan
    $vmIPs = @()
    $vmsWithoutIPs = @()
    
    for ($i = 1; $i -le $VMCount; $i++) {
        $vmName = "$ClusterPrefix-$i"
        try {
            # Get VM network adapter
            $vmNetworkAdapter = Get-VMNetworkAdapter -VMName $vmName -ErrorAction SilentlyContinue
            
            if ($vmNetworkAdapter) {
                # Wait a moment for IP assignment
                Start-Sleep -Seconds 2
                
                # Try to get IP address from VM integration service
                $ipAddress = $vmNetworkAdapter.IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
                
                if ($ipAddress) {
                    $vmIPs += @{
                        VMName = $vmName
                        IPAddress = $ipAddress
                        Status = "Running"
                    }
                    Write-Host "✓ $vmName`: $ipAddress" -ForegroundColor Green
                } else {
                    # Try alternative method using Get-VMNetworkAdapter
                    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
                    if ($vm -and $vm.State -eq "Running") {
                        $vmIPs += @{
                            VMName = $vmName
                            IPAddress = "IP assignment pending"
                            Status = "Running - No IP yet"
                        }
                        Write-Host "⚠ $vmName`: IP assignment pending" -ForegroundColor Yellow
                    } else {
                        $vmsWithoutIPs += $vmName
                        Write-Host "✗ $vmName`: VM not running or not found" -ForegroundColor Red
                    }
                }
            } else {
                $vmsWithoutIPs += $vmName
                Write-Host "✗ $vmName`: Network adapter not found" -ForegroundColor Red
            }
        } catch {
            $vmsWithoutIPs += $vmName
            Write-Host "✗ $vmName`: Error retrieving IP - $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    
    # Display summary
    Write-Host "`nIP Address Summary:" -ForegroundColor Yellow
    Write-Host "  - VMs with IP addresses: $($vmIPs.Count)" -ForegroundColor Green
    Write-Host "  - VMs without IP addresses: $($vmsWithoutIPs.Count)" -ForegroundColor Red
    
    if ($vmIPs.Count -gt 0) {
        Write-Host "`nVM IP Addresses:" -ForegroundColor Green
        foreach ($vm in $vmIPs) {
            Write-Host "  - $($vm.VMName): $($vm.IPAddress) ($($vm.Status))" -ForegroundColor White
        }
    }
    
    if ($vmsWithoutIPs.Count -gt 0) {
        Write-Host "`nVMs without IP addresses:" -ForegroundColor Red
        foreach ($vm in $vmsWithoutIPs) {
            Write-Host "  - $vm" -ForegroundColor White
        }
        Write-Host "`nNote: VMs may need more time to obtain IP addresses or may require manual network configuration." -ForegroundColor Yellow
    }
    
    return $vmIPs
}

# Create the cluster VMs using parallel jobs
Write-Host "`nStarting parallel cluster creation with $VMCount VMs..." -ForegroundColor Cyan
Write-Host "Cluster prefix: $ClusterPrefix" -ForegroundColor Yellow
Write-Host "VM names will be: $($ClusterPrefix)-1, $($ClusterPrefix)-2, $($ClusterPrefix)-3" -ForegroundColor Yellow

# Start parallel VM creation jobs
$jobs = @()
for ($i = 1; $i -le $VMCount; $i++) {
    $vmName = "$ClusterPrefix-$i"
    Write-Host "Starting job for VM: $vmName" -ForegroundColor Magenta
    
    $job = Start-Job -ScriptBlock {
        param($VMName, $VMPath, $VHDPath, $SwitchName, $DiskGB, $MemoryGB, $ProcessorCount, $ISOPath)
        
        # Import Hyper-V module in the job
        Import-Module Hyper-V -ErrorAction SilentlyContinue
        
        try {
            Write-Output "Creating Hyper-V VM: $VMName"
            
            # Create the VM
            New-VM -Name $VMName -Path $VMPath -Generation 2 -MemoryStartupBytes ($MemoryGB * 1GB)
            
            # Configure memory
            Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false -StartupBytes ($MemoryGB * 1GB)
            
            # Configure processors
            Set-VMProcessor -VMName $VMName -Count $ProcessorCount
            
            # Create and attach VHDX
            $VHDPathFull = Join-Path "$VHDPath\$VMName" "$VMName.vhdx"
            New-VHD -Path $VHDPathFull -SizeBytes ($DiskGB * 1GB) -Dynamic
            Add-VMHardDiskDrive -VMName $VMName -Path $VHDPathFull
            
            # Configure network adapter
            $networkAdapter = Get-VMNetworkAdapter -VMName $VMName
            Connect-VMNetworkAdapter -VMNetworkAdapter $networkAdapter -SwitchName $SwitchName
            
            # Configure security settings
            # First, disable Secure Boot (Generation 2 VMs have Secure Boot enabled by default)
            Set-VMFirmware -VMName $VMName -EnableSecureBoot Off

            Set-VMKeyProtector -VMName $VMName -NewLocalKeyProtector
            
            # Enable TPM (try without key protector first)
            try {
                Enable-VMTPM -VMName $VMName
                Write-Output "TPM enabled successfully for $VMName"
            } catch {
                Write-Output "Failed to enable TPM for $VMName`: $($_.Exception.Message)"
                Write-Output "TPM will need to be configured manually for $VMName after VM creation"
            }
            
            # Configure additional settings for better performance
            Set-VM -VMName $VMName -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
            
            # Remove network boot from boot order
            try {
                $bootOrder = @()
                # Get hard drives
                $hardDrives = Get-VMHardDiskDrive -VMName $VMName
                if ($hardDrives) {
                    $bootOrder += $hardDrives
                }
                # Get DVD drives
                $dvdDrives = Get-VMDvdDrive -VMName $VMName
                if ($dvdDrives) {
                    $bootOrder += $dvdDrives
                }
                # Set boot order if we have devices
                if ($bootOrder.Count -gt 0) {
                    Set-VMFirmware -VMName $VMName -BootOrder $bootOrder
                    Write-Output "Boot order configured for $VMName"
                }
            } catch {
                Write-Output "Warning: Could not configure boot order for $VMName`: $($_.Exception.Message)"
            }
            
            # Attach ISO if specified
            if ($ISOPath) {
                if (Test-Path $ISOPath) {
                    Add-VMDvdDrive -VMName $VMName -Path $ISOPath
                    Write-Output "ISO attached to VM ${VMName}: $ISOPath"
                } else {
                    Write-Output "ISO file not found: $ISOPath"
                    Write-Output "VM $VMName created without ISO attachment"
                }
            }
            
            Write-Output "VM '$VMName' created successfully!"
            return @{ Success = $true; VMName = $VMName; Message = "Created successfully" }
            
        } catch {
            Write-Output "Failed to create VM '$VMName': $($_.Exception.Message)"
            return @{ Success = $false; VMName = $VMName; Message = $_.Exception.Message }
        }
    } -ArgumentList $vmName, $VMPath, $VHDPath, $SwitchName, $DiskGB, $MemoryGB, $ProcessorCount, $ISOPath
    
    $jobs += $job
}

# Wait for all jobs to complete and collect results
Write-Host "`nWaiting for all VM creation jobs to complete..." -ForegroundColor Yellow
$results = @()
$successCount = 0
$failedVMs = @()

foreach ($job in $jobs) {
    $result = Wait-Job $job | Receive-Job
    Remove-Job $job
    
    if ($result.Success) {
        $successCount++
        Write-Host "✓ $($result.VMName): $($result.Message)" -ForegroundColor Green
    } else {
        $failedVMs += $result.VMName
        Write-Host "✗ $($result.VMName): $($result.Message)" -ForegroundColor Red
    }
}

# Summary
Write-Host "`n=== CLUSTER CREATION SUMMARY ===" -ForegroundColor Cyan
Write-Host "Total VMs requested: $VMCount" -ForegroundColor White
Write-Host "Successfully created: $successCount" -ForegroundColor Green
Write-Host "Failed: $($failedVMs.Count)" -ForegroundColor Red

if ($failedVMs.Count -gt 0) {
    Write-Host "Failed VMs: $($failedVMs -join ', ')" -ForegroundColor Red
}

if ($successCount -eq $VMCount) {
    Write-Host "`nAll VMs created successfully!" -ForegroundColor Green
    Write-Host "`nCluster Configuration:" -ForegroundColor Yellow
    Write-Host "  - Cluster prefix: $ClusterPrefix" -ForegroundColor White
    Write-Host "  - VM count: $VMCount" -ForegroundColor White
    Write-Host "  - Memory per VM: $MemoryGB GB" -ForegroundColor White
    Write-Host "  - Processors per VM: $ProcessorCount" -ForegroundColor White
    Write-Host "  - TPM: Enabled (where possible)" -ForegroundColor White
    Write-Host "  - Secure Boot: Disabled" -ForegroundColor White
    Write-Host "  - Network Switch: $SwitchName" -ForegroundColor White
    if ($ISOPath) {
        Write-Host "  - ISO: $ISOPath" -ForegroundColor White
    }
    
    # Start VMs if requested
    if ($StartVMs) {
        Write-Host "`nStarting VMs..." -ForegroundColor Cyan
        $startedVMs = @()
        $failedStarts = @()
        
        for ($i = 1; $i -le $VMCount; $i++) {
            $vmName = "$ClusterPrefix-$i"
            try {
                Start-VM -Name $vmName
                $startedVMs += $vmName
                Write-Host "✓ Started VM: $vmName" -ForegroundColor Green
            } catch {
                $failedStarts += $vmName
                Write-Host "✗ Failed to start VM: $vmName - $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        
        Write-Host "`nVM Startup Summary:" -ForegroundColor Yellow
        Write-Host "  - Successfully started: $($startedVMs.Count)" -ForegroundColor Green
        Write-Host "  - Failed to start: $($failedStarts.Count)" -ForegroundColor Red
        
        if ($startedVMs.Count -gt 0) {
            Write-Host "`nStarted VMs:" -ForegroundColor Green
            foreach ($vm in $startedVMs) {
                Write-Host "  - $vm" -ForegroundColor White
            }
        }
        
        if ($failedStarts.Count -gt 0) {
            Write-Host "`nFailed to start:" -ForegroundColor Red
            foreach ($vm in $failedStarts) {
                Write-Host "  - $vm" -ForegroundColor White
            }
        }
    }
    
    # Get IP addresses if requested
    if ($GetIPAddresses -and $StartVMs) {
        # Wait a bit for VMs to fully boot and get IP addresses
        Write-Host "`nWaiting for VMs to obtain IP addresses..." -ForegroundColor Yellow
        Start-Sleep -Seconds 10
        
        $vmIPs = Get-VMIPAddresses -ClusterPrefix $ClusterPrefix -VMCount $VMCount
    }
    
    Write-Host "`nNext steps:" -ForegroundColor Cyan
    if (-not $StartVMs) {
        Write-Host "1. Start VMs using: Start-VM -Name '$ClusterPrefix-*'" -ForegroundColor White
        Write-Host "2. Obtain vouchers from each VM" -ForegroundColor White
        Write-Host "3. Provision new device in via Azure Arc blade in Azure Portal" -ForegroundColor White

    } else {
        Write-Host "1. Obtain vouchers from each VM" -ForegroundColor White
        Write-Host "2. Provision new device in via Azure Arc blade in Azure Portal" -ForegroundColor White
    }
} else {
    Write-Host "`nSome VMs failed to create. Please check the errors above and retry." -ForegroundColor Red
    exit 1
}

Write-Host "`n*** COMPLETE ***" -ForegroundColor Cyan
