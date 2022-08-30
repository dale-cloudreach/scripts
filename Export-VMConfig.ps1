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
        Write-Host "Exporting configuration for VM $VMName"
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