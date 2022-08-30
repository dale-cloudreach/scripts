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
        Stop-AzVM -ResourceGroupName $resourceGroup -Name $vmName -Force -ErrorAction Stop 

        Write-Host "Creating a new OS disk snapshot"
        $snapshotOSConfig = New-AzSnapshotConfig -SourceUri $originalVM.StorageProfile.OsDisk.ManagedDisk.Id -Location $location -CreateOption copy -SkuName Standard_ZRS -ErrorAction Stop
        $OSSnapshot = New-AzSnapshot -Snapshot $snapshotOSConfig -SnapshotName ($originalVM.StorageProfile.OsDisk.Name + "-snapshot") -ResourceGroupName $resourceGroup -ErrorAction Stop
        $diskSkuOS = (Get-AzDisk -DiskName $originalVM.StorageProfile.OsDisk.Name -ResourceGroupName $originalVM.ResourceGroupName).Sku.Name 
        $diskConfig = New-AzDiskConfig -Location $OSSnapshot.Location -SourceResourceId $OSSnapshot.Id -CreateOption Copy -SkuName  $diskSkuOS -Zone $zone  -ErrorAction Stop

        Write-Host "Removing the original VM"
        Remove-AzVM -ResourceGroupName $resourceGroup -Name $vmName -Force -ErrorAction Stop 

        Write-Host "Removing original OS disk"
        Remove-AzDisk -ResourceGroupName $ResourceGroup -DiskName $originalVM.StorageProfile.OsDisk.Name -Force

        Write-Host "Create new disk from snapshot"
        $OSdisk = New-AzDisk -Disk $diskConfig -ResourceGroupName $resourceGroup -DiskName $originalVM.StorageProfile.OsDisk.Name -ErrorAction Stop

        Write-Host "Removing OS disk snapshot"
        Remove-AzSnapshot -ResourceGroupName $resourceGroup -SnapshotName ($originalVM.StorageProfile.OsDisk.Name + "-snapshot") -Force

        foreach ($disk in $originalVM.StorageProfile.DataDisks) { 
            Write-Host "Creating data disk snapshot"
            $snapshotDataConfig = New-AzSnapshotConfig -SourceUri $disk.ManagedDisk.Id -Location $location -CreateOption copy -SkuName Standard_ZRS -ErrorAction Stop
            $DataSnapshot = New-AzSnapshot -Snapshot $snapshotDataConfig -SnapshotName ($disk.Name + '-snapshot') -ResourceGroupName $resourceGroup -ErrorAction Stop
            $diskSkuData = (Get-AzDisk -DiskName $disk.Name -ResourceGroupName $originalVM.ResourceGroupName).Sku.Name
            $datadiskConfig = New-AzDiskConfig -Location $DataSnapshot.Location -SourceResourceId $DataSnapshot.Id -CreateOption Copy -SkuName $diskSkuData -Zone $zone -ErrorAction Stop
            Write-Host "Delete original data disk"
            Remove-AzDisk -ResourceGroupName $ResourceGroup -DiskName $disk.name -Force
            Write-Host "Creating new data disk from snapshot"
            $datadisk = New-AzDisk -Disk $datadiskConfig -ResourceGroupName $resourceGroup -DiskName $disk.Name -ErrorAction Stop
            Write-Host "Deleting data disk snapshot"
            Remove-AzSnapshot -ResourceGroupName $resourceGroup -SnapshotName ($disk.Name + '-snapshot') -Force
            Write-Host "New data disk created successfully"
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
            Set-AzVMOSDisk -VM $newVM -CreateOption Attach -ManagedDiskId $OSdisk.Id -Name $OSdisk.Name -Windows -ErrorAction Stop 
        }

        Write-Host "Setting the data disks"
        $originalVM.StorageProfile.DataDisks
        foreach ($disk in $originalVM.StorageProfile.DataDisks) { 
            Write-Host "Setting disk: $disk.name"
            $datadisk = Get-AzDisk -ResourceGroupName $resourceGroup -DiskName $disk.Name
            Add-AzVMDataDisk -VM $newVM -Name $datadisk.Name -ManagedDiskId $datadisk.Id -Caching $disk.Caching -Lun $disk.Lun -DiskSizeInGB $disk.DiskSizeGB -CreateOption Attach -ErrorAction Stop
        }

        write-host "Retaining the NIC"
        $originalVM.NetworkProfile.NetworkInterfaces
        #preserve the nic where possible
        foreach ($nic in $originalVM.NetworkProfile.NetworkInterfaces) {  
            if ($nic.Primary -eq "True") {
                Add-AzVMNetworkInterface -VM $newVM -Id $nic.Id -Primary -ErrorAction Stop 
            }
            else {
                Add-AzVMNetworkInterface -VM $newVM -Id $nic.Id -ErrorAction Stop 
            }
        }

        Write-Host "Create a new VM"
        New-AzVM -ResourceGroupName $resourceGroup -Location $originalVM.Location -VM $newVM -DisableBginfoExtension -ErrorAction Stop
        
        Write-Host "Retaining VM extension settings"
        $newVM.Extensions = $originalVM.Extensions  

        # Exclude MicrosoftMonitoringAgent due to additional settings required
        Write-Host "Setting applicable extensions"
        foreach ($extension in $originalVM.Extensions | Where-Object {$_.VirtualMachineExtensionType -ne 'MicrosoftMonitoringAgent'}) { 
            Set-AzVMExtension -ResourceGroupName $resourceGroup -Location $originalVM.Location -VMName $vmName -Name $extension.Name -Publisher $extension.Publisher -ExtensionType $extension.VirtualMachineExtensionType  -TypeHandlerVersion $extension.TypeHandlerVersion
        }

        # Include MicrosoftMonitoringAgent if it exists
        Write-Host "Setting Log Analytics Workspace ID and Key"
        foreach ($extension in $originalVM.Extensions | Where-Object {$_.VirtualMachineExtensionType -eq 'MicrosoftMonitoringAgent'}) { 
            $WorkspaceId = Get-AzKeyVaultSecret -VaultName $LawKeyVault -Name $WorkspaceIdSecret -AsPlainText
            $WorkspaceKey = Get-AzKeyVaultSecret -VaultName $LawKeyVault -Name $WorkspaceKeySecret -AsPlainText
            Set-AzVMExtension -ResourceGroupName $resourceGroup -Location $location -VMName $vmName -Name "$vmName-mmaagent" -ExtensionType "MicrosoftMonitoringAgent" -TypeHandlerVersion "1.0" -Publisher "Microsoft.EnterpriseCloud.Monitoring" -Settings @{"workspaceId" = "$WorkspaceId" } -ProtectedSettings @{"workspaceKey" = "$WorkspaceKey" }   
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