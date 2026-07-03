Param (
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]
    $InputVariable # 
)

# show parameter value
Write-STLog "Parameter InputVariable: $InputVariable."

# test custom Write-Host
Write-Host "Write-Host with colors execution test" -ForegroundColor Blue -BackgroundColor Yelllow

# test for variable cross-bleed
Write-Output "Test against cross-bleeding of normal variables. Initial value for CBTest is: $CBTest."
$CBTest = "CrossBleeding!!!"
Write-Output "Test against cross-bleeding of global variables. Initial value for GCBTest is: $GCBTest."
$Global:GCBTest = "GlobalCrossBleeding!!!"

# test ExecPath
Write-STLog "Current working folder: $((Get-Location).Path)."

# test the access to the OrchVars
Write-STLog "OrchVars.TestVariable value: $($OrchVars.TestVariable)."
Write-STLog "OrchVars.TestCredential UserName: $($OrchVars.TestCredential.GetNetworkCredential().UserName)."

# testing safe exit handling inside the execution runspace
exit 0
    