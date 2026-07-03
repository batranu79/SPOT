
Param ( 
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [System.Management.Automation.PSCredential]
    # The local admin credential for running the SPOT SelfTest 
    $LocalAdminCredential,
    [Parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string]
    # The password to be used for unlocking the secret store, if it is not prestaged
    $MasterPassword
    )

#########################################################
Write-Output "===== Starting the SPOTSelfTest script. ====="

#########################################################
$SourcePath = $PSScriptRoot.TrimEnd('\')

#########################################################
#### test the yaml module
Import-Module -Name powershell-yaml -ErrorAction SilentlyContinue
if (!(Get-Module -Name powershell-yaml)) {
    Write-Output "ERROR: The powershell-yaml module could not be loaded. Cannot continue." -Output $false
    throw "Start-SPOTSelfTest: error loading powershell-yaml module!"
}

#########################################################
#### get the SPOT status
if ($MasterPassword) {
    $SPOTStatus = Get-SPOTStatus -MasterPassword $MasterPassword
}
else {
    $SPOTStatus = Get-SPOTStatus
}

#########################################################
#### check for SPOT initialization
if ($SPOTStatus -ne "Initialized") {
    Write-Output "ERROR: cannot run SPOT SelfTest on an uninitialized SPOT system!"
    return
}

#########################################################
#### initialize a temporary project
Write-Output " > Initialize a temporary SPOT project."
if ($MasterPassword) {
    Initialize-SPOTProject -ProjectPath "$env:windir\Temp\SPOTSelfTest" -MasterPassword $MasterPassword
}
else {
    Initialize-SPOTProject -ProjectPath "$env:windir\Temp\SPOTSelfTest"
}

#########################################################
#### configure the project
Write-Output " > Configure the temporary SPOT project with the SelfTest content."
Copy-Item -Path "$SourcePath\*.yaml" -Destination "$env:windir\Temp\SPOTSelfTest\__SPOT_Runbooks" -Confirm:$false -Force
Copy-Item -Path "$SourcePath\__HelperFunctionsSelfTest.ps1" -Destination "$env:windir\Temp\SPOTSelfTest\_HelperFunctions" -Confirm:$false -Force
Copy-Item -Path "$SourcePath\Start-STScript.ps1" -Destination "$env:windir\Temp\SPOTSelfTest\_Scripts" -Confirm:$false -Force

$SInputsHashtable = @{
    Credentials = @{
        LocalCred = @{
            Username = $LocalAdminCredential.UserName
            Password = $LocalAdminCredential.GetNetworkCredential().Password
        }
    }
}
$OVarsHashtable = @{
    ConditionFlag = $true
    _Debug = $true
    TestVariable = "TestValue"
    TestCredential = '$SV:LocalCred'
}

ConvertTo-Yaml -Data $SInputsHashtable -OutFile "$env:windir\Temp\SPOTSelfTest\__SPOT_Config\SInputs.yaml" -Force
ConvertTo-Yaml -Data $OVarsHashtable -OutFile "$env:windir\Temp\SPOTSelfTest\__SPOT_Config\OrchVars.yaml" -Force

#########################################################
#### start the test runbook execution
Write-Output " > Start execution of the temporary SPOT project."
if ($MasterPassword) {
    Start-SPOT -ProjectPath "$env:windir\Temp\SPOTSelfTest" -MainRunbookName "TestRbkLCL" -MasterPassword $MasterPassword
}
else {
    Start-SPOT -ProjectPath "$env:windir\Temp\SPOTSelfTest" -MainRunbookName "TestRbkLCL"
}

#########################################################
#### save artefacts and cleanup the project
Write-Output " > Save artefacts and cleanup the temporary SPOT project."
Copy-Item -Path "$env:windir\Temp\SPOTSelfTest\__SPOT_Artefacts" -Destination "$env:windir\Temp\$(Get-Date -Format "yyyyMMdd-HHmmss")-SPOTSelfTestArtefacts" -Container -Recurse -Confirm:$false -Force
Remove-Item -Path "$env:windir\Temp\SPOTSelfTest" -Recurse -Confirm:$false -Force
if ($MasterPassword) {
    Remove-SPOTProjectSecrets -VaultName SPOTSelfTest -MasterPassword $MasterPassword
}
else {
    Remove-SPOTProjectSecrets -VaultName SPOTSelfTest
}

#########################################################
Write-Output "===== Finished the SPOTSelfTest script. ====="