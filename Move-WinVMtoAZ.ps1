<#
    .SYNOPSIS
    Move a Virtual Machine and it's Disks to an Availability Zone
    
    .DESCRIPTION
    Move a Virtual Machine and it's Disks to an Availability Zone

    .NOTES
    1. Requires Contributor to Resource Group. 
    2. Key Vault Get secret permission.
    3. Valid backups for rollback

    .PARAMETER SubscriptionName
    Name of the Subscription

    .PARAMETER PathForVMExport
    Path to store VM JSON export

    .PARAMETER ResourceGroup
    Name of the Resource Group that contains the VM

    .PARAMETER VMName
    Name of the VM to move

    .PARAMETER Location
    Location of the VM

    .PARAMETER Zone
    Availabilty Zone number to move the VM to

    .PARAMETER LawKeyVault
    The key vault name that contains the Log Analytics Workspace secrets

    .PARAMETER WorkspaceIdSecret
    The key vault secret that contains the Workspace ID secret

    .PARAMETER WorkspaceKeySecret
    the key vault secret that contains the Workspace Key secret

    .PARAMETER SkipChecks
    Skip the prereq checks

    .EXAMPLE
    Measure-Command {./Move-WinVMtoAZ.ps1 -SubscriptionName "Visual Studio Enterprise Subscription – MPN" -ResourceGroup "moveazvmrg" -Location "uksouth" -VMName "moveazvm" -Zone 3 -PathForVMExport "/home/dale/clouddrive/" -LawKeyVault "moveazvmkeyvault" -WorkspaceIdSecret "workspaceid" -WorkspaceKeySecret "workspacekey" -SkipChecks $true}
#>
[CmdletBinding()]
Param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNull()]
    [String]$SubscriptionName,
    [Parameter(Mandatory = $true)]
    [ValidateNotNull()]
    [String]$ResourceGroup,
    [Parameter(Mandatory = $true)]
    [ValidateNotNull()]
    [String]$VMName,
    [Parameter(Mandatory = $true)]
    [ValidateSet("uksouth","UK South")]
    [ValidateNotNull()]
    [String]$Location,
    [Parameter(Mandatory = $true)]
    [ValidateNotNull()]
    [Int]$Zone,
    [Parameter(Mandatory = $true)]
    [ValidateNotNull()]
    [String]$PathForVMExport,
    [Parameter(Mandatory = $False)]
    [string]$LawKeyVault,
    [Parameter(Mandatory = $False)]
    [string]$WorkspaceIdSecret,
    [Parameter(Mandatory = $False)]
    [string]$WorkspaceKeySecret,
    [ValidateNotNullOrEmpty()]
    [Bool] $SkipChecks
)

$ResourceGroup = $ResourceGroup.ToLower()

Clear-Host

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$PSDefaultParameterValues['*:ErrorAction']='Stop'

if ($SkipChecks) {
    Write-Host -ForegroundColor Yellow "Prereq checks skipped..."
}
else {
    Write-Host "Checking if user has Contributor permissions to Resource Group: $ResourceGroup"
    $CurrentUser = az account show --query user.name --output tsv
    $RoleAssignment = Get-AzRoleAssignment -ResourceGroupName $ResourceGroup -SignInName $CurrentUser
    if ($RoleAssignment.RoleDefinitionName -ne "Contributor")
        {
            Throw "You need Contributor permissions to $ResourceGroup to run this script"
        }
    else {
        Write-Host -ForegroundColor Green "You have Contributor to Resource Group: $ResourceGroup"    
    }
    
    Write-Host "Checking if user has Get secret permissions on Key Vault: $LawKeyVault"
    try {
        Get-AzKeyVaultSecret -VaultName $LawKeyVault -Name $WorkspaceIdSecret -AsPlainText | Out-Null
        Write-Host -ForegroundColor Green "You have Get secret permissions"
    }
    catch {
        Write-Host -ForegroundColor Red "You need Get secret permission for $LawKeyVault Key Vault"
    }
}

Write-Host -ForegroundColor Red 'DO YOU HAVE A VALID BACKUP FOR ROLLBACK? THIS SCRIPT DOES NOT REVERT ANY CHANGES ON FAILURE...'
$confirmation = Read-Host "Are you sure you want to proceed (y / n)"
if ($confirmation -eq 'y') {
    # proceed
}
else {
    throw "Cancelled script"
}

function Export-VMConfig {
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $True,
        HelpMessage = 'Name of the Virtual Machine')]
        [Alias('vm')]
        [string]$VMName,

        [Parameter(Mandatory = $True,
        HelpMessage = 'Name of the Resource Group of the Virtual Machine')]
        [Alias('rg')]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $True,
        HelpMessage = 'Directory path for export file')]
        [Alias('path')]
        [string]$PathForVMExport      
    )
    try {
        Write-Host "Exporting configuration for VM $VMName and saving output into $PathForVMExport"
        $currentVm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction Stop
        $timeStamp = (Get-Date).ToString("MM-dd-yyyy-HH-mm-ss")
        $fileNameWithPath = ""
        if ($PathForVMExport.EndsWith('\')) {
            $fileNameWithPath = $PathForVMExport + $VMName + "-" + $timeStamp + '.json'
        }
        else {
            $fileNameWithPath = $PathForVMExport + "\" + $VMName + "-" + $timeStamp + '.json'
        }

        Write-Host "Configuration for VM $VMName exported at time $timeStamp"
        $currentVm | ConvertTo-Json -Depth 100 | Out-File -FilePath $fileNameWithPath
  
        Write-Host -ForegroundColor Green "Successfully exported the information for the VM $VMName"
    }
    catch [system.exception] {
        Write-Error $error[0].ToString() 
    }
}

function Move-VM {
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $True,
        HelpMessage = 'Name of the Virtual Machine')]
        [string]$VMName,

        [Parameter(Mandatory = $True,
        HelpMessage = 'Name of the Resource Group of the Virtual Machine')]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $True,
        HelpMessage = 'Name of location')]
        [string]$location,    
        
        [Parameter(Mandatory = $True,
        HelpMessage = 'The zone number')]
        [string]$zone,

        [Parameter(Mandatory = $False,
        HelpMessage = 'Key Vault that contains the Log Analytics secrets')]
        [string]$LawKeyVault,

        [Parameter(Mandatory = $False,
        HelpMessage = 'Log Analytics Workspace ID Secret')]
        [string]$WorkspaceIdSecret,

        [Parameter(Mandatory = $False,
        HelpMessage = 'Log Analytics Workspace Key Secret')]
        [string]$WorkspaceKeySecret
    )
    
    try {
        Write-Host "Storing the VM export as a variable"
        $originalVM = Get-AzVM -ResourceGroupName $ResourceGroup -Name $VMName -ErrorAction Stop
        
        Write-Host "Stopping $vmName"
        Stop-AzVM -ResourceGroupName $resourceGroup -Name $vmName -Force -ErrorAction Stop | Out-Null

        Write-Host "Creating a new OS disk snapshot"
        $snapshotOSConfig = New-AzSnapshotConfig -SourceUri $originalVM.StorageProfile.OsDisk.ManagedDisk.Id -Location $location -CreateOption copy -SkuName Standard_ZRS -ErrorAction Stop
        $OSSnapshot = New-AzSnapshot -Snapshot $snapshotOSConfig -SnapshotName ($originalVM.StorageProfile.OsDisk.Name + "-snapshot") -ResourceGroupName $resourceGroup -ErrorAction Stop
        $diskSkuOS = (Get-AzDisk -DiskName $originalVM.StorageProfile.OsDisk.Name -ResourceGroupName $originalVM.ResourceGroupName).Sku.Name 
        $diskConfig = New-AzDiskConfig -Location $OSSnapshot.Location -SourceResourceId $OSSnapshot.Id -CreateOption Copy -SkuName  $diskSkuOS -Zone $zone  -ErrorAction Stop

        Write-Host "Deleting the original VM"
        Remove-AzVM -ResourceGroupName $resourceGroup -Name $vmName -Force -ErrorAction Stop | Out-Null

        Write-Host "Removing original OS disk"
        Remove-AzDisk -ResourceGroupName $ResourceGroup -DiskName $originalVM.StorageProfile.OsDisk.Name -Force | Out-Null

        Write-Host "Create new OS disk from snapshot"
        $OSdisk = New-AzDisk -Disk $diskConfig -ResourceGroupName $resourceGroup -DiskName $originalVM.StorageProfile.OsDisk.Name -ErrorAction Stop

        Write-Host "Removing OS disk snapshot"
        Remove-AzSnapshot -ResourceGroupName $resourceGroup -SnapshotName ($originalVM.StorageProfile.OsDisk.Name + "-snapshot") -Force | Out-Null

        foreach ($disk in $originalVM.StorageProfile.DataDisks) { 
            Write-Host "Creating data disk snapshot for" $disk.name
            $snapshotDataConfig = New-AzSnapshotConfig -SourceUri $disk.ManagedDisk.Id -Location $location -CreateOption copy -SkuName Standard_ZRS -ErrorAction Stop
            $DataSnapshot = New-AzSnapshot -Snapshot $snapshotDataConfig -SnapshotName ($disk.Name + '-snapshot') -ResourceGroupName $resourceGroup -ErrorAction Stop
            $diskSkuData = (Get-AzDisk -DiskName $disk.Name -ResourceGroupName $originalVM.ResourceGroupName).Sku.Name
            $datadiskConfig = New-AzDiskConfig -Location $DataSnapshot.Location -SourceResourceId $DataSnapshot.Id -CreateOption Copy -SkuName $diskSkuData -Zone $zone -ErrorAction Stop
            Write-Host "Deleting original data disk"
            Remove-AzDisk -ResourceGroupName $ResourceGroup -DiskName $disk.name -Force | Out-Null
            Write-Host "Creating new data disk from snapshot"
            $datadisk = New-AzDisk -Disk $datadiskConfig -ResourceGroupName $resourceGroup -DiskName $disk.Name -ErrorAction Stop
            Write-Host "Deleting data disk snapshot"
            Remove-AzSnapshot -ResourceGroupName $resourceGroup -SnapshotName ($disk.Name + '-snapshot') -Force | Out-Null
            Write-Host "New data disk created successfully for" $disk.name
        }

        Write-Host "Create the VM configuration for the replacement VM"
        $newVM = New-AzVMConfig -VMName $originalVM.Name -VMSize $originalVM.HardwareProfile.VmSize -Zone $zone -ErrorAction Stop
        
        Write-Host "Retaining tags"
        $newVM.Tags = $originalVM.Tags

        Write-Host "Retaining the boot diagnostics storage account"
        $newVM.DiagnosticsProfile = $originalVM.DiagnosticsProfile      

        Write-Host "Setting the OS disk"
        if ($OSdisk.OsType -eq "Linux") {
            Set-AzVMOSDisk -VM $newVM -CreateOption Attach -ManagedDiskId $OSdisk.Id -Name $OSdisk.Name -Linux -ErrorAction Stop 
        }
        else {
            Set-AzVMOSDisk -VM $newVM -CreateOption Attach -ManagedDiskId $OSdisk.Id -Name $OSdisk.Name -Windows -ErrorAction Stop | Out-Null
        }

        Write-Host "Setting the data disks"
        $originalVM.StorageProfile.DataDisks
        foreach ($disk in $originalVM.StorageProfile.DataDisks) { 
            Write-Host "Setting disk" $disk.name
            $datadisk = Get-AzDisk -ResourceGroupName $resourceGroup -DiskName $disk.Name
            Add-AzVMDataDisk -VM $newVM -Name $datadisk.Name -ManagedDiskId $datadisk.Id -Caching $disk.Caching -Lun $disk.Lun -DiskSizeInGB $disk.DiskSizeGB -CreateOption Attach -ErrorAction Stop | Out-Null
        }

        write-host "Retaining the NIC"
        $originalVM.NetworkProfile.NetworkInterfaces
        #preserve the nic where possible
        foreach ($nic in $originalVM.NetworkProfile.NetworkInterfaces) {  
            if ($nic.Primary -eq "True") {
                Add-AzVMNetworkInterface -VM $newVM -Id $nic.Id -Primary -ErrorAction Stop  | Out-Null
            }
            else {
                Add-AzVMNetworkInterface -VM $newVM -Id $nic.Id -ErrorAction Stop 
            }
        }

        Write-Host "Create new VM resource for" $VMName
        New-AzVM -ResourceGroupName $resourceGroup -Location $originalVM.Location -VM $newVM -DisableBginfoExtension -ErrorAction Stop | Out-Null
        
        Write-Host "Retaining VM extension settings"
        $newVM.Extensions = $originalVM.Extensions  

        # Exclude MicrosoftMonitoringAgent due to additional settings required
        Write-Host "Setting applicable extensions"
        foreach ($extension in $originalVM.Extensions | Where-Object {$_.VirtualMachineExtensionType -ne 'MicrosoftMonitoringAgent'}) { 
            Write-Host "Setting extension" $extension.name
            Set-AzVMExtension -ResourceGroupName $resourceGroup -Location $originalVM.Location -VMName $vmName -Name $extension.Name -Publisher $extension.Publisher -ExtensionType $extension.VirtualMachineExtensionType  -TypeHandlerVersion $extension.TypeHandlerVersion | Out-Null
        }

        # Include MicrosoftMonitoringAgent if it exists
        Write-Host "Setting Log Analytics Workspace ID and Key"
        foreach ($extension in $originalVM.Extensions | Where-Object {$_.VirtualMachineExtensionType -eq 'MicrosoftMonitoringAgent'}) { 
            $WorkspaceId = Get-AzKeyVaultSecret -VaultName $LawKeyVault -Name $WorkspaceIdSecret -AsPlainText
            $WorkspaceKey = Get-AzKeyVaultSecret -VaultName $LawKeyVault -Name $WorkspaceKeySecret -AsPlainText
            Set-AzVMExtension -ResourceGroupName $resourceGroup -Location $location -VMName $vmName -Name "$vmName-mmaagent" -ExtensionType "MicrosoftMonitoringAgent" -TypeHandlerVersion "1.0" -Publisher "Microsoft.EnterpriseCloud.Monitoring" -Settings @{"workspaceId" = "$WorkspaceId" } -ProtectedSettings @{"workspaceKey" = "$WorkspaceKey" } | Out-Null   
        }

        }
        catch [system.exception] {
            Write-Error $error[0].ToString() 
            Write-Verbose "Error : $($_.Exception.Message) "
            Write-Host "Error : $($_.Exception.Message) "
            Write-Verbose "Error Details are: "
            Write-Verbose $Error[0].ToString()
        }

}

function Search-VM {
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $True,
            HelpMessage = 'Name of the Virtual Machine')]
        [Alias('vm')]
        [string]$VMName,

        [Parameter(Mandatory = $True,
            HelpMessage = 'Name of the Resource Group of the Virtual Machine')]
        [Alias('rg')]
        [string]$ResourceGroupName
    )
    try {
        Write-Host "Searching for the VM"
        $output = Get-AzVM -ResourceGroupName $resourceGroup -Name $VMName  -Status -UserData | Out-Null
        $output
        Write-Host -ForegroundColor Green "$VMName has been moved to Availability Zone $zone"
    }
    catch [system.exception] {
        Write-Error $error[0].ToString() 
    }
}


Write-Host -ForegroundColor Yellow "Switching context to $SubscriptionName"
Set-AzContext -SubscriptionName $SubscriptionName | Out-Null

Write-Host -ForegroundColor Yellow "## 1. Starting to export the VM configuration to a JSON file"
Export-VMConfig -VMName $VMName -ResourceGroupName $ResourceGroup -PathForVMExport $PathForVMExport -ErrorAction Stop

Write-Host -ForegroundColor Yellow "## 2. Starting to move the VM to Availability Zone $zone"
Move-VM -VMName $VMName -ResourceGroupName $ResourceGroup -location $Location -zone $Zone -LawKeyVault $LawKeyVault -WorkspaceIdSecret $WorkspaceIdSecret -WorkspaceKeySecret $WorkspaceKeySecret -ErrorAction Stop

Write-Host -ForegroundColor Yellow "## 3. Starting to confirm the VM has been moved to the Availability Zone $zone successfully."
Search-VM -VMName $VMName -ResourceGroupName $ResourceGroup