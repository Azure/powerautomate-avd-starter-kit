# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

<#
.SYNOPSIS
Executes PAD install on a VM

.DESCRIPTION
This Runbook takes a PowerShell scriptblock supplied at runtime or an existing script and runs it on a defined Azure VM, optionally returning the output of the script or scriptblock.

.PARAMETER ServiceName
Specifies the name of the Cloud Service that contains the Azure VM to target.
        
.PARAMETER VMName
Specifies the name of the Azure VM which the script will run on.
        
.PARAMETER AzureOrgIdCredential
Specifies the Azure Active Directory OrgID user credential object used to authenticate to Azure.
        
.PARAMETER AzureSubscriptionName
Specifies the name of the Azure Subscription containing the resources targetted by this runbook.

.PARAMETER AzureAppId
Specifies the client app ID to be used for authentication when registering the machine in the target group.

.PARAMETER AzureAppSecret
Specifies the client app secret to be used for authentication when registering the machine in the target group.

.PARAMETER EnvironmentId
Specifies the Dataverse environment ID in which to register the machine.

.PARAMETER TenantId
Specifies the tenant where the Dataverse instance to be used is located.

.PARAMETER GroupId
Specifies the ID of the group where to register the machine.

.PARAMETER GroupPassword
Specifies the password required for registering the machine to the group.

.INPUTS
None. You cannot pipe objects to Push-Command.
        
.OUTPUTS
System.String Returns a string with either a success message, or the output of the PAD install script run on the Azure VM (if WaitForCompletion is set to $true).  
#>


param
(
    [parameter(Mandatory=$true)]
    [string]$ServiceName,

    [parameter(Mandatory=$true)]
    [string]$VMName,

    [parameter(Mandatory=$true)]
    [PSCredential]$AzureOrgIdCredential,

    [parameter(Mandatory=$true)]
    [string]$AzureSubscriptionName,

    [parameter(Mandatory=$true)]
    [string]$AzureAppId,

    [parameter(Mandatory=$true)]
    [string]$AzureAppSecret,

    [parameter(Mandatory=$true)]
    [string]$EnvironmentId,

    [parameter(Mandatory=$true)]
    [string]$TenantId,

    [parameter(Mandatory=$true)]
    [string]$GroupId,

    [parameter(Mandatory=$true)]
    [string]$GroupPassword
)
# By default, errors in PowerShell do not cause execution to suspend, like exceptions do.
# This means a runbook can still reach 'completed' state, even if it encounters errors
# during execution. The below command will cause all errors in the runbook to be thrown as
# exceptions, therefore causing the runbook to suspend when an error is hit.
# see https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_preference_variables?view=powershell-7.1#erroractionpreference 
$ErrorActionPreference = "Stop"

[Byte[]]$secretKey = (1..16)

# Authenticate to Azure
Write-Output "Authenticating to Azure and selecting subscription..."

Connect-AzAccount -Credential $AzureOrgIdCredential -SubscriptionName $AzureSubscriptionName | Write-Verbose

Write-Output "Successfully authenticated, attempting to run pad install script on VM $VMName"
           
# Get the VM to run script against
$vm = Get-AzVM -ResourceGroupName $ServiceName -Name $VMName
if ($vm -eq $null)
{
    Write-Error "Could not find VM $VMName in resource group $ServiceName."
}

# This code is meant to be executed on the VMs so they will install PAD, register themselves and join the machine group
$InstallPadScriptBlock = {
    param($EncryptedAzureAppSecret, $AzureAppId, $TenantId, $EnvironmentId, $GroupId, $EncryptedGroupPassword)

    $ErrorActionPreference = "Stop"
    [Byte[]]$secretKey = (1..16)

    function decode($secret) {
        $secretSecureString = $secret | ConvertTo-SecureString -key $secretKey
        return [System.Net.NetworkCredential]::new("", $secretSecureString).Password
    }

    $azureAppSecret = decode($EncryptedAzureAppSecret)  
    $groupPassword = decode($EncryptedGroupPassword)

    $tempDirectoryOnVM = $env:temp
    $padInstallerLocation =  "$tempDirectoryOnVM\Setup.Microsoft.PowerAutomateDesktop.exe"

    $padSilentRegistrationExe = "C:\Program Files (x86)\Power Automate Desktop\PAD.MachineRegistration.Silent.exe"

    if (-not(Test-Path -Path $tempDirectoryOnVM -PathType Container )) {
        Write-Output "Temp directory $tempDirectoryOnVM does not exist, creating..."
        New-Item -ItemType Directory -Force -Path $env:temp
    }

    if (-not(Test-Path -Path $padInstallerLocation -PathType Leaf)) {
        try {
            Write-Output "Downloading PAD installer to $padInstallerLocation"
            invoke-WebRequest -Uri https://go.microsoft.com/fwlink/?linkid=2164365 -OutFile $padInstallerLocation
        } catch {
            Write-Error "Could not download PAD installer, error was $Error"
        }
    }
    try {
        Write-Output "Installing PAD from $padInstallerLocation"
        Start-Process -FilePath $padInstallerLocation -ArgumentList '-Silent', '-Install', '-ACCEPTEULA' -Wait
    }
    catch {
        Write-Error "Could not install PAD, error was $Error"
    }
    
    Write-Output "Registering machine"
    try {
        Invoke-Expression "echo $azureAppSecret | &'$padSilentRegistrationExe' -register -force -applicationid $AzureAppId -tenantid $TenantId -environmentid $EnvironmentId -clientsecret | Out-Null"
    } catch {
        Write-Error "Could not register machine through PAD, error was $Error"
    }
    
    Write-Output "Joining machine group"
    try {
        Invoke-Expression "echo `"$azureAppSecret`n$groupPassword`" | &'$padSilentRegistrationExe' -joinmachinegroup -groupid $GroupId -applicationid $AzureAppId -tenantid $TenantId -environmentid $EnvironmentId -clientsecret -grouppassword | Out-Null"
    } catch {
        Write-Error "Could not join machine group through PAD, error was $Error"
    }

    Write-Output "Cleaning up installer at $padInstallerLocation"
    Remove-Item -Path $padInstallerLocation -Force -ErrorAction SilentlyContinue
}.ToString()

$padInstallScriptPath = "$env:tempInstallPad.ps1"
Write-Output "Writing the install PAD script to $padInstallScriptPath"
Out-File -FilePath $padInstallScriptPath -InputObject $InstallPadScriptBlock -NoNewline

function encode($secret)
{
    return $secret | ConvertTo-SecureString -AsPlainText -Force | ConvertFrom-SecureString -key $secretKey
}

try
{
    Write-Output "Executing PAD Install script on VM"
    $encryptedGroupPassword = encode($GroupPassword)
    $encryptedAzureAppSecret = encode($AzureAppSecret)
    $padInstallScriptParameters = @{ EncryptedAzureAppSecret = "$encryptedAzureAppSecret"; AzureAppId = "$AzureAppId"; TenantId="$TenantId"; EnvironmentId="$EnvironmentId"; GroupId="$GroupId"; EncryptedGroupPassword="$encryptedGroupPassword" }
    $invokeReturnedValue = Invoke-AzVMRunCommand -ResourceGroupName $ServiceName -Name $VMName -CommandId 'RunPowerShellScript' -ScriptPath $padInstallScriptPath -Parameter $padInstallScriptParameters
    $invokeOutput = $invokeReturnedValue.value.Message
    if ($invokeOutput.ToLower() -like '*error*') {
        Write-Error "Error: `n$invokeOutput"
    } else {
        Write-Output "Success: `n$invokeOutput"
    }
}
catch
{
    Write-Error "Error while executing pad install script: $Error"
}
Remove-Item -Path $padInstallScriptPath -Force -ErrorAction SilentlyContinue
Write-Verbose "Successfully installed PAD VM"
    
Write-Output "Runbook complete."

