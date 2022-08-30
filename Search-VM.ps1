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
        $output = Get-AzVM -ResourceGroupName $resourceGroup -Name $VMName  -Status -UserData 
        $output
        Write-Host -ForegroundColor Green "$VMName has been moved to Availability Zone $zone successfully."
    }
    catch [system.exception] {
        Write-Error $error[0].ToString() 
    }
}
