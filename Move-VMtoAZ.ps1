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
    ./Move-VMtoAZ.ps1 -SubscriptionName "Visual Studio Enterprise Subscription – MPN" -ResourceGroup "moveazvmrg" -Location "uksouth" -VMName "moveazvm" -Zone 3 -PathForVMExport "/home/dale/clouddrive/" -LawKeyVault "moveazvmkeyvault" -WorkspaceIdSecret "workspaceid" -WorkspaceKeySecret "workspacekey" -SkipChecks $true
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

Clear-Host

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$PSDefaultParameterValues['*:ErrorAction']='Stop'

Import-Module ./Export-VMConfig.ps1 -Force
Import-Module ./Move-VM.ps1 -Force
Import-Module ./Search-VM.ps1 -Force

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

Write-Host -ForegroundColor Yellow "## 1. Starting to export the VM configuration to a JSON file"
Export-VMConfig -VMName $VMName -ResourceGroupName $ResourceGroup -PathForVMExport $PathForVMExport -ErrorAction Stop

Write-Host -ForegroundColor Yellow "## 2. Starting to move the VM to Availability Zone $zone"
Move-VM -VMName $VMName -ResourceGroupName $ResourceGroup -location $Location -zone $Zone -LawKeyVault $LawKeyVault -WorkspaceIdSecret $WorkspaceIdSecret -WorkspaceKeySecret $WorkspaceKeySecret -ErrorAction Stop

Write-Host -ForegroundColor Yellow "## 3. Starting to confirm the VM has been moved to the Availability Zone $zone successfully."
Search-VM -VMName $VMName -ResourceGroupName $ResourceGroup