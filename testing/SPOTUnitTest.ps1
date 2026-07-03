
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.Management.Automation.PSCredential]
        # the local credential to perform the tests
        $Credential
    )

Import-Module -Name SPOT -WarningAction Ignore -ErrorAction Stop
$module = Get-Module -Name SPOT
$ParHashTable = @{ExecPath = "$env:windir\Temp"; Credential = $Credential}
& $module {
######################################################################################################################

    Param ($ParHashTable)
    $ExecPath = $ParHashTable.ExecPath
    $Credential = $ParHashTable.Credential

    #################################################
    Write-SPOTLog "===== Starting function Execute-SPOTUnitTests ====="

    #####################
    # define first some Unit Test functions
    
    function Start-UTFunction {
        Param (
            [Parameter(Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [string]
            $InputParameter, #
            [Parameter(Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [string]
            $NotNeededParameter #
        )
        #################
        Write-Output " > Starting function Start-UTFunction."

        #################
        Write-Output " >> InputParameter is: $InputParameter"
        Write-Output " >> OrchVars.TestVariable is: $($OrchVars.TestVariable)"
        Write-Output " >> ExecPath is: $((Get-Location).Path)."
        Write-Output " >> ExecUser is: $(whoami)."
        
        #################
        $InnerVariable = "InnerValue"
        Write-Output " >> InnerVariable value is: $InnerVariable"

        #################
        Start-Sleep -Seconds 5

        #################
        if ($InputParameter -eq "TETest") {
            Write-Output " >> Terminating Error test detected."
            throw "Start-UTFunction: Terminating Error test!"
        }
        elseif ($InputParameter -eq "NTETest") {
            Write-Output " >> Non-Terminating Error test detected."
            Write-Error "Non-Terminating Error test!"
        }

        #################
        Write-Output " > Finished function Start-UTFunction."

        #################
        exit 0
    }

    function Start-UTSimpleFunction {
        Param (
            [Parameter(Mandatory=$false)]
            [AllowNull()]
            [string]
            $NotNeededParameter #
        )

        if ($NotNeededParameter) {
            Write-Output "A parameter value was supplied: $NotNeededParameter"
        }
        else {
            Write-Output "No parameter value was supplied."
        }
    }

    #####################
    # prepare test Vars hashtables
    $global:PublishedData = [hashtable]::Synchronized(@{})
    $global:SVars = [hashtable]::Synchronized(@{})
    $global:OrchVars = [hashtable]::Synchronized(@{})
    $OrchVars._SPOTPath = (Get-SPOTPath)
    $OrchVars._Debug = $true
    $OrchVars._StepTimeout = 3600
    $OrchVars.TestVariable = "OrchTestValue"
    $OrchVars.TestVariable2 = "Orch TestValue"
    $OrchVars.ConditionFlag = $true
    $OrchVars._ProjectFunctions = @("Start-UTFunction","Start-UTSimpleFunction")
    $OrchVars._StepFunctions = $OrchVars._ProjectFunctions + ("Write-SPOTLog",
                                "Get-SPOTSshNetPath",
                                "New-SPOTSSHSession",
                                "New-SPOTSFTPSession",
                                "New-SPOTTelnetSession",
                                "Extract-SPOTArchive",
                                "Recompose-SPOTHashTableVariable",
                                "Test-SPOTTCPPort",
                                "Ping-SPOTHostWMI",
                                "Execute-SPOTScheduledJob",
                                "Get-SPOTDeepClone",
                                "Get-SPOTEncryptedToSecString",
                                "Replace-SPOTLineVars",
                                "Replace-SPOTLineCred",
                                "Process-SPOTCommandParamsRF",
                                "Process-SPOTCommandParamsLocalRF",
                                "Transfer-SPOTDataOverPipe",
                                "Replace-SPOTExitInCode")
    $OrchVars._StepFunctions = $OrchVars._StepFunctions | Select-Object -Unique
    $OrchVars._RunbookFunctions += $OrchVars._StepFunctions
    $OrchVars._RunbookFunctions += (Get-Command | Where {($_.ScriptBlock.File -eq "$($OrchVars._SPOTPath)\SPOTRunbookFunctions.ps1")}).Name
    $OrchVars._RunbookFunctions = $OrchVars._RunbookFunctions | Select-Object -Unique
    $OrchVars._SPOTRsPoolMax = 20
    if ((Show-SPOTCapability) -eq "Extended") {
        $OrchVars._PsExecPath = "$($OrchVars._SPOTPath)\tools\psexec\psexec64.exe"
    }
    $OrchVars._SPOTHostFunctions = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([System.IO.File]::ReadAllText("$($OrchVars._SPOTPath)\SPOTHostFunctions.ps1")))

    #####################
    # load the SPOT classes
    . "$($OrchVars._SPOTPath)\classes\Classes.ps1"

    #####################
    # start the runspacepool
    $global:_spot_MainWorkerPool = Create-SPOTRsPool -MaxNumber $OrchVars._SPOTRsPoolMax

    ##########################################
    #region: Type Function tests

    ###################################################################
    ###################################################################
    Write-SPOTLog "##########################################################################################"
    Write-SPOTLog " ###> Starting ""PowershellCommandLocal"" unit test (NoError)."
    $Job = PowershellCommandLocal -CommandName Start-UTFunction -CommandParameters @{InputParameter = "Test"} -ExecPath $ExecPath -VariablesToPublish @("InnerVariable=StepVariable","_spot_Output=StepOutput")
    while (!$Job.handle.IsCompleted) {
        Write-SPOTLog " >> Waiting for ""PowershellCommandLocal"" job."
        Start-Sleep -Seconds 1
    }
    $JobOutput = $Job.powershell.EndInvoke($Job.handle)
    $Job.powershell.runspace.Close()
    $Job.powershell.Dispose()
    
    Write-SPOTLog " >> ""PowershellCommandLocal"" job output: $JobOutput" -Output $false
    ###
    if ($JobOutput[$JobOutput.Count-1] -eq $true) { 
        Write-SPOTLog " >> unit test (NoError) overall execution - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError) overall execution - FAILED." }
    if ($PublishedData["StepVariable"] -eq "InnerValue") { 
        Write-SPOTLog " >> unit test (NoError) publish inner variable - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError) publish inner variable - FAILED." }
    if ($PublishedData["StepOutput"][0].Trim() -eq "> Starting function Start-UTFunction.") {
        Write-SPOTLog " >> unit test (NoError) publish step output - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError) publish step output - FAILED." }
    if ($PublishedData["StepOutput"][1].Trim() -eq ">> InputParameter is: Test") {
        Write-SPOTLog " >> unit test (NoError) assign CommandParameter - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError) assign CommandParameter - FAILED." }
    if ($PublishedData["StepOutput"][2].Trim() -eq ">> OrchVars.TestVariable is: OrchTestValue") {
        Write-SPOTLog " >> unit test (NoError) access OrchVars inside step - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError) access OrchVars inside step - FAILED." }
    if ($PublishedData["StepOutput"][3].Trim() -eq ">> ExecPath is: $ExecPath.") {
        Write-SPOTLog " >> unit test (NoError) set execution path - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError) set execution path - FAILED." }
    if ($PublishedData["StepOutput"] -like "*SPOT Intercepted 'exit' with code: 0*") {
        Write-SPOTLog " >> unit test (NoError) intercept exit command - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError) intercept exit command - FAILED." }
    $JobOutput = $null
    $Job = $null
    $global:PublishedData = [hashtable]::Synchronized(@{})


    #####################
    Write-SPOTLog "##########################################################################################"
    Write-SPOTLog " ###> Starting ""PowershellCommandLocal"" unit test (TerminatingError)."
    $Job = PowershellCommandLocal -CommandName Start-UTFunction -CommandParameters @{InputParameter = "TETest"} -ExecPath $ExecPath -VariablesToPublish @("InnerVariable=StepVariable","_spot_Output=StepOutput")
    while (!$Job.handle.IsCompleted) {
        Write-SPOTLog " >> Waiting for ""PowershellCommandLocal"" job."
        Start-Sleep -Seconds 1
    }
    $JobOutput = $Job.powershell.EndInvoke($Job.handle)
    $Job.powershell.runspace.Close()
    $Job.powershell.Dispose()
    Write-SPOTLog " >> ""PowershellCommandLocal"" job output: $JobOutput" -Output $false
    ###
    if ($JobOutput[$JobOutput.Count-1] -eq $false) { 
        Write-SPOTLog " >> unit test (TerminatingError) overall execution - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) overall execution - FAILED." }
    if ($PublishedData["StepVariable"] -eq "InnerValue") { 
        Write-SPOTLog " >> unit test (TerminatingError) publish inner variable - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) publish inner variable - FAILED." }
    if ($PublishedData["StepOutput"][0].Trim() -eq "> Starting function Start-UTFunction.") {
        Write-SPOTLog " >> unit test (TerminatingError) publish step output - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) publish step output - FAILED." }
    if ($PublishedData["StepOutput"][1].Trim() -eq ">> InputParameter is: TETest") {
        Write-SPOTLog " >> unit test (TerminatingError) assign CommandParameter - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) assign CommandParameter - FAILED." }
    if ($PublishedData["StepOutput"][2].Trim() -eq ">> OrchVars.TestVariable is: OrchTestValue") {
        Write-SPOTLog " >> unit test (TerminatingError) access OrchVars inside step - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) access OrchVars inside step - FAILED." }
    if ($PublishedData["StepOutput"][3].Trim() -eq ">> ExecPath is: $ExecPath.") {
        Write-SPOTLog " >> unit test (TerminatingError) set execution path - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) set execution path - FAILED." }
    if ($PublishedData["StepOutput"] -like "*throw ""Start-UTFunction: Terminating Error test!""*") {
        Write-SPOTLog " >> unit test (TerminatingError) detect error line - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) detect error line - FAILED." }
    $JobOutput = $null
    $Job = $null
    $global:PublishedData = [hashtable]::Synchronized(@{})


    #####################
    Write-SPOTLog "##########################################################################################"
    Write-SPOTLog " ###> Starting ""PowershellCommandLocal"" unit test (NonTerminatingError)."
    $Job = PowershellCommandLocal -CommandName Start-UTFunction -CommandParameters @{InputParameter = "NTETest"} -ExecPath $ExecPath -VariablesToPublish @("InnerVariable=StepVariable","_spot_Output=StepOutput")
    while (!$Job.handle.IsCompleted) {
        Write-SPOTLog " >> Waiting for ""PowershellCommandLocal"" job."
        Start-Sleep -Seconds 1
    }
    $JobOutput = $Job.powershell.EndInvoke($Job.handle)
    $Job.powershell.runspace.Close()
    $Job.powershell.Dispose()
    Write-SPOTLog " >> ""PowershellCommandLocal"" job output: $JobOutput." -Output $false
    ###
    if ($JobOutput[$JobOutput.Count-1] -eq $true) { 
        Write-SPOTLog " >> unit test (NonTerminatingError) overall execution - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) overall execution - FAILED." }
    if ($PublishedData["StepVariable"] -eq "InnerValue") { 
        Write-SPOTLog " >> unit test (NonTerminatingError) publish inner variable - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) publish inner variable - FAILED." }
    if ($PublishedData["StepOutput"][0].Trim() -eq "> Starting function Start-UTFunction.") {
        Write-SPOTLog " >> unit test (NonTerminatingError) publish step output - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) publish step output - FAILED." }
    if ($PublishedData["StepOutput"][1].Trim() -eq ">> InputParameter is: NTETest") {
        Write-SPOTLog " >> unit test (NonTerminatingError) assign CommandParameter - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) assign CommandParameter - FAILED." }
    if ($PublishedData["StepOutput"][2].Trim() -eq ">> OrchVars.TestVariable is: OrchTestValue") {
        Write-SPOTLog " >> unit test (NonTerminatingError) access OrchVars inside step - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) access OrchVars inside step - FAILED." }
    if ($PublishedData["StepOutput"][3].Trim() -eq ">> ExecPath is: $ExecPath.") {
        Write-SPOTLog " >> unit test (NonTerminatingError) set execution path - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) set execution path - FAILED." }
    if ($PublishedData["StepOutput"] -like "*Start-UTFunction : Non-Terminating Error test!*") {
        Write-SPOTLog " >> unit test (NonTerminatingError) detect error name - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) detect error name - FAILED." }
    if ($PublishedData["StepOutput"] -like "*SPOT Intercepted 'exit' with code: 0*") {
        Write-SPOTLog " >> unit test (NonTerminatingError) intercept exit command - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) intercept exit command - FAILED." }
    $JobOutput = $null
    $Job = $null
    $global:PublishedData = [hashtable]::Synchronized(@{})


    ###################################################################
    ###################################################################
    Write-SPOTLog "##########################################################################################"
    Write-SPOTLog " ###> Starting ""PowershellCommandRemote"" unit test (NoError)."
    $Job = PowershellCommandRemote -CommandName Start-UTFunction -CommandParameters @{InputParameter = "test"} -RemoteComputer "127.0.0.1" -Credential $Credential -ExecPath $ExecPath -VariablesToPublish @("InnerVariable=StepVariable","_spot_Output=StepOutput")
    while (!$Job.handle.IsCompleted) {
        Write-SPOTLog " >> Waiting for ""PowershellCommandRemote"" job."
        Start-Sleep -Seconds 1
    }
    $JobOutput = $Job.powershell.EndInvoke($Job.handle)
    $Job.powershell.Dispose()
    Write-SPOTLog " >> ""PowershellCommandRemote"" job output: $JobOutput." -Output $false
    ###
    if ($JobOutput[$JobOutput.Count-1] -eq $true) { 
        Write-SPOTLog " >> unit test (NoError) overall execution - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError) overall execution - FAILED." }
    if ($PublishedData["StepVariable"] -eq "InnerValue") { 
        Write-SPOTLog " >> unit test (NoError) publish inner variable - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError) publish inner variable - FAILED." }
    if ($PublishedData["StepOutput"][0].Trim() -eq "> Starting function Start-UTFunction.") {
        Write-SPOTLog " >> unit test (NoError) publish step output - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError) publish step output - FAILED." }
    if ($PublishedData["StepOutput"][1].Trim() -eq ">> InputParameter is: Test") {
        Write-SPOTLog " >> unit test (NoError) assign CommandParameter - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError) assign CommandParameter - FAILED." }
    if ($PublishedData["StepOutput"][2].Trim() -eq ">> OrchVars.TestVariable is: OrchTestValue") {
        Write-SPOTLog " >> unit test (NoError) access OrchVars inside step - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError) access OrchVars inside step - FAILED." }
    if ($PublishedData["StepOutput"][3].Trim() -eq ">> ExecPath is: $ExecPath.") {
        Write-SPOTLog " >> unit test (NoError) set execution path - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError) set execution path - FAILED." }
    if ($PublishedData["StepOutput"] -like "*SPOT Intercepted 'exit' with code: 0*") {
        Write-SPOTLog " >> unit test (NoError) intercept exit command - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError) intercept exit command - FAILED." }
    $JobOutput = $null
    $Job = $null
    $global:PublishedData = [hashtable]::Synchronized(@{})


    #####################
    Write-SPOTLog "##########################################################################################"
    Write-SPOTLog " ###> Starting ""PowershellCommandRemote"" unit test (TerminatingError)."
    $Job = PowershellCommandRemote -CommandName Start-UTFunction -CommandParameters @{InputParameter = "TETest"} -RemoteComputer "127.0.0.1" -Credential $Credential -ExecPath $ExecPath -VariablesToPublish @("InnerVariable=StepVariable","_spot_Output=StepOutput")
    while (!$Job.handle.IsCompleted) {
        Write-SPOTLog " >> Waiting for ""PowershellCommandRemote"" job."
        Start-Sleep -Seconds 1
    }
    $JobOutput = $Job.powershell.EndInvoke($Job.handle)
    $Job.powershell.Dispose()
    Write-SPOTLog " >> ""PowershellCommandRemote"" job output: $JobOutput" -Output $false
    ###
    if ($JobOutput[$JobOutput.Count-1] -eq $false) { 
        Write-SPOTLog " >> unit test (TerminatingError) overall execution - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) overall execution - FAILED." }
    if ($PublishedData["StepVariable"] -eq "InnerValue") { 
        Write-SPOTLog " >> unit test (TerminatingError) publish inner variable - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) publish inner variable - FAILED." }
    if ($PublishedData["StepOutput"][0].Trim() -eq "> Starting function Start-UTFunction.") {
        Write-SPOTLog " >> unit test (TerminatingError) publish step output - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) publish step output - FAILED." }
    if ($PublishedData["StepOutput"][1].Trim() -eq ">> InputParameter is: TETest") {
        Write-SPOTLog " >> unit test (TerminatingError) assign CommandParameter - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) assign CommandParameter - FAILED." }
    if ($PublishedData["StepOutput"][2].Trim() -eq ">> OrchVars.TestVariable is: OrchTestValue") {
        Write-SPOTLog " >> unit test (TerminatingError) access OrchVars inside step - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) access OrchVars inside step - FAILED." }
    if ($PublishedData["StepOutput"][3].Trim() -eq ">> ExecPath is: $ExecPath.") {
        Write-SPOTLog " >> unit test (TerminatingError) set execution path - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) set execution path - FAILED." }
    if ($PublishedData["StepOutput"] -like "*throw ""Start-UTFunction: Terminating Error test!""*") {
        Write-SPOTLog " >> unit test (TerminatingError) detect error line - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) detect error line - FAILED." }
    $JobOutput = $null
    $Job = $null
    $global:PublishedData = [hashtable]::Synchronized(@{})


    #####################
    Write-SPOTLog "##########################################################################################"
    Write-SPOTLog " ###> Starting ""PowershellCommandRemote"" unit test (NonTerminatingError)."
    $Job = PowershellCommandRemote -CommandName Start-UTFunction -CommandParameters @{InputParameter = "NTETest"} -RemoteComputer "127.0.0.1" -Credential $Credential -ExecPath $ExecPath -VariablesToPublish @("InnerVariable=StepVariable","_spot_Output=StepOutput")
    while (!$Job.handle.IsCompleted) {
        Write-SPOTLog " >> Waiting for ""PowershellCommandRemote"" job."
        Start-Sleep -Seconds 1
    }
    $JobOutput = $Job.powershell.EndInvoke($Job.handle)
    $Job.powershell.Dispose()
    Write-SPOTLog " >> ""PowershellCommandRemote"" job output: $JobOutput." -Output $false
    ###
    if ($JobOutput[$JobOutput.Count-1] -eq $true) { 
        Write-SPOTLog " >> unit test (NonTerminatingError) overall execution - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) overall execution - FAILED." }
    if ($PublishedData["StepVariable"] -eq "InnerValue") { 
        Write-SPOTLog " >> unit test (NonTerminatingError) publish inner variable - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) publish inner variable - FAILED." }
    if ($PublishedData["StepOutput"][0].Trim() -eq "> Starting function Start-UTFunction.") {
        Write-SPOTLog " >> unit test (NonTerminatingError) publish step output - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) publish step output - FAILED." }
    if ($PublishedData["StepOutput"][1].Trim() -eq ">> InputParameter is: NTETest") {
        Write-SPOTLog " >> unit test (NonTerminatingError) assign CommandParameter - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) assign CommandParameter - FAILED." }
    if ($PublishedData["StepOutput"][2].Trim() -eq ">> OrchVars.TestVariable is: OrchTestValue") {
        Write-SPOTLog " >> unit test (NonTerminatingError) access OrchVars inside step - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) access OrchVars inside step - FAILED." }
    if ($PublishedData["StepOutput"][3].Trim() -eq ">> ExecPath is: $ExecPath.") {
        Write-SPOTLog " >> unit test (NonTerminatingError) set execution path - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) set execution path - FAILED." }
    if ($PublishedData["StepOutput"] -like "*Start-UTFunction : Non-Terminating Error test!*") {
        Write-SPOTLog " >> unit test (NonTerminatingError) detect error name - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) detect error name - FAILED." }
    if ($PublishedData["StepOutput"] -like "*SPOT Intercepted 'exit' with code: 0*") {
        Write-SPOTLog " >> unit test (NonTerminatingError) intercept exit command - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) intercept exit command - FAILED." }
    $JobOutput = $null
    $Job = $null
    $global:PublishedData = [hashtable]::Synchronized(@{})


    ###################################################################
    ###################################################################
    Write-SPOTLog "##########################################################################################"
    Write-SPOTLog " ###> Starting ""PowershellCommandRemoteSJ"" unit test (NoError)(AsSystem)."
    $Job = PowershellCommandRemoteSJ -CommandName Start-UTFunction -CommandParameters @{InputParameter = "test"} -RemoteComputer "127.0.0.1" -Credential $Credential -ExecPath $ExecPath -AsSystem $true -VariablesToPublish @("InnerVariable=StepVariable","_spot_Output=StepOutput")
    while (!$Job.handle.IsCompleted) {
        Write-SPOTLog " >> Waiting for ""PowershellCommandRemoteSJ"" job."
        Start-Sleep -Seconds 1
    }
    $JobOutput = $Job.powershell.EndInvoke($Job.handle)
    $Job.powershell.Dispose()
    Write-SPOTLog " >> ""PowershellCommandRemoteSJ"" job output: $JobOutput." -Output $false
    ###
    if ($JobOutput[$JobOutput.Count-1] -eq $true) { 
        Write-SPOTLog " >> unit test (NoError)(AsSystem) overall execution - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError)(AsSystem) overall execution - FAILED." }
    if ($PublishedData["StepVariable"] -eq "InnerValue") { 
        Write-SPOTLog " >> unit test (NoError)(AsSystem) publish inner variable - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError)(AsSystem) publish inner variable - FAILED." }
    if ($PublishedData["StepOutput"][0].Trim() -eq "> Starting function Start-UTFunction.") {
        Write-SPOTLog " >> unit test (NoError)(AsSystem) publish step output - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError)(AsSystem) publish step output - FAILED." }
    if ($PublishedData["StepOutput"][1].Trim() -eq ">> InputParameter is: Test") {
        Write-SPOTLog " >> unit test (NoError)(AsSystem) assign CommandParameter - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError)(AsSystem) assign CommandParameter - FAILED." }
    if ($PublishedData["StepOutput"][2].Trim() -eq ">> OrchVars.TestVariable is: OrchTestValue") {
        Write-SPOTLog " >> unit test (NoError)(AsSystem) access OrchVars inside step - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError)(AsSystem) access OrchVars inside step - FAILED." }
    if ($PublishedData["StepOutput"][3].Trim() -eq ">> ExecPath is: $ExecPath.") {
        Write-SPOTLog " >> unit test (NoError)(AsSystem) set execution path - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError)(AsSystem) set execution path - FAILED." }
    if ($PublishedData["StepOutput"] -like "*SPOT Intercepted 'exit' with code: 0*") {
        Write-SPOTLog " >> unit test (NoError)(AsSystem) intercept exit command - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError)(AsSystem) intercept exit command - FAILED." }
    if ($PublishedData["StepOutput"][4].Trim() -eq ">> ExecUser is: nt authority\system.") {
        Write-SPOTLog " >> unit test (NoError)(AsSystem) running as system - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError)(AsSystem) running as system - FAILED." }
    $JobOutput = $null
    $Job = $null
    $global:PublishedData = [hashtable]::Synchronized(@{})


    #####################
    Write-SPOTLog "##########################################################################################"
    Write-SPOTLog " ###> Starting ""PowershellCommandRemoteSJ"" unit test (TerminatingError)."
    $Job = PowershellCommandRemoteSJ -CommandName Start-UTFunction -CommandParameters @{InputParameter = "TETest"} -RemoteComputer "127.0.0.1" -Credential $Credential -ExecPath $ExecPath -VariablesToPublish @("InnerVariable=StepVariable","_spot_Output=StepOutput")
    while (!$Job.handle.IsCompleted) {
        Write-SPOTLog " >> Waiting for ""PowershellCommandRemoteSJ"" job."
        Start-Sleep -Seconds 1
    }
    $JobOutput = $Job.powershell.EndInvoke($Job.handle)
    $Job.powershell.Dispose()
    Write-SPOTLog " >> ""PowershellCommandRemoteSJ"" job output: $JobOutput" -Output $false
    ###
    if ($JobOutput[$JobOutput.Count-1] -eq $false) { 
        Write-SPOTLog " >> unit test (TerminatingError) overall execution - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) overall execution - FAILED." }
    if ($PublishedData["StepVariable"] -eq "InnerValue") { 
        Write-SPOTLog " >> unit test (TerminatingError) publish inner variable - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) publish inner variable - FAILED." }
    if ($PublishedData["StepOutput"][0].Trim() -eq "> Starting function Start-UTFunction.") {
        Write-SPOTLog " >> unit test (TerminatingError) publish step output - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) publish step output - FAILED." }
    if ($PublishedData["StepOutput"][1].Trim() -eq ">> InputParameter is: TETest") {
        Write-SPOTLog " >> unit test (TerminatingError) assign CommandParameter - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) assign CommandParameter - FAILED." }
    if ($PublishedData["StepOutput"][2].Trim() -eq ">> OrchVars.TestVariable is: OrchTestValue") {
        Write-SPOTLog " >> unit test (TerminatingError) access OrchVars inside step - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) access OrchVars inside step - FAILED." }
    if ($PublishedData["StepOutput"][3].Trim() -eq ">> ExecPath is: $ExecPath.") {
        Write-SPOTLog " >> unit test (TerminatingError) set execution path - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) set execution path - FAILED." }
    if ($PublishedData["StepOutput"] -like "*throw ""Start-UTFunction: Terminating Error test!""*") {
        Write-SPOTLog " >> unit test (TerminatingError) detect error line - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) detect error line - FAILED." }
    $JobOutput = $null
    $Job = $null
    $global:PublishedData = [hashtable]::Synchronized(@{})


    #####################
    Write-SPOTLog "##########################################################################################"
    Write-SPOTLog " ###> Starting ""PowershellCommandRemoteSJ"" unit test (NonTerminatingError)."
    $Job = PowershellCommandRemoteSJ -CommandName Start-UTFunction -CommandParameters @{InputParameter = "NTETest"} -RemoteComputer "127.0.0.1" -Credential $Credential -ExecPath $ExecPath -VariablesToPublish @("InnerVariable=StepVariable","_spot_Output=StepOutput")
    while (!$Job.handle.IsCompleted) {
        Write-SPOTLog " >> Waiting for ""PowershellCommandRemoteSJ"" job."
        Start-Sleep -Seconds 1
    }
    $JobOutput = $Job.powershell.EndInvoke($Job.handle)
    $Job.powershell.Dispose()
    Write-SPOTLog " >> ""PowershellCommandRemoteSJ"" job output: $JobOutput." -Output $false
    ###
    if ($JobOutput[$JobOutput.Count-1] -eq $true) { 
        Write-SPOTLog " >> unit test (NonTerminatingError) overall execution - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) overall execution - FAILED." }
    if ($PublishedData["StepVariable"] -eq "InnerValue") { 
        Write-SPOTLog " >> unit test (NonTerminatingError) publish inner variable - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) publish inner variable - FAILED." }
    if ($PublishedData["StepOutput"][0].Trim() -eq "> Starting function Start-UTFunction.") {
        Write-SPOTLog " >> unit test (NonTerminatingError) publish step output - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) publish step output - FAILED." }
    if ($PublishedData["StepOutput"][1].Trim() -eq ">> InputParameter is: NTETest") {
        Write-SPOTLog " >> unit test (NonTerminatingError) assign CommandParameter - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) assign CommandParameter - FAILED." }
    if ($PublishedData["StepOutput"][2].Trim() -eq ">> OrchVars.TestVariable is: OrchTestValue") {
        Write-SPOTLog " >> unit test (NonTerminatingError) access OrchVars inside step - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) access OrchVars inside step - FAILED." }
    if ($PublishedData["StepOutput"][3].Trim() -eq ">> ExecPath is: $ExecPath.") {
        Write-SPOTLog " >> unit test (NonTerminatingError) set execution path - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) set execution path - FAILED." }
    if ($PublishedData["StepOutput"] -like "*Start-UTFunction : Non-Terminating Error test!*") {
        Write-SPOTLog " >> unit test (NonTerminatingError) detect error name - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) detect error name - FAILED." }
    if ($PublishedData["StepOutput"] -like "*SPOT Intercepted 'exit' with code: 0*") {
        Write-SPOTLog " >> unit test (NonTerminatingError) intercept exit command - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) intercept exit command - FAILED." }
    $JobOutput = $null
    $Job = $null
    $global:PublishedData = [hashtable]::Synchronized(@{})


    ###################################################################
    ###################################################################
    Write-SPOTLog "##########################################################################################"
    Write-SPOTLog " ###> Starting ""PowershellCommandRemoteWMI"" unit test (NoError)."
    $Job = PowershellCommandRemoteWMI -CommandName Start-UTFunction -CommandParameters @{InputParameter = "test"} -RemoteComputer "127.0.0.1" -Credential $Credential -ExecPath $ExecPath -VariablesToPublish @("InnerVariable=StepVariable","_spot_Output=StepOutput")
    while (!$Job.handle.IsCompleted) {
        Write-SPOTLog " >> Waiting for ""PowershellCommandRemoteWMI"" job."
        Start-Sleep -Seconds 1
    }
    $JobOutput = $Job.powershell.EndInvoke($Job.handle)
    $Job.powershell.Dispose()
    Write-SPOTLog " >> ""PowershellCommandRemoteWMI"" job output: $JobOutput." -Output $false
    ###
    if ($JobOutput[$JobOutput.Count-1] -eq $true) { 
        Write-SPOTLog " >> unit test (NoError) overall execution - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError) overall execution - FAILED." }
    if ($PublishedData["StepVariable"] -eq "InnerValue") { 
        Write-SPOTLog " >> unit test (NoError) publish inner variable - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError) publish inner variable - FAILED." }
    if ($PublishedData["StepOutput"][0].Trim() -eq "> Starting function Start-UTFunction.") {
        Write-SPOTLog " >> unit test (NoError) publish step output - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError) publish step output - FAILED." }
    if ($PublishedData["StepOutput"][1].Trim() -eq ">> InputParameter is: Test") {
        Write-SPOTLog " >> unit test (NoError) assign CommandParameter - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError) assign CommandParameter - FAILED." }
    if ($PublishedData["StepOutput"][2].Trim() -eq ">> OrchVars.TestVariable is: OrchTestValue") {
        Write-SPOTLog " >> unit test (NoError) access OrchVars inside step - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError) access OrchVars inside step - FAILED." }
    if ($PublishedData["StepOutput"][3].Trim() -eq ">> ExecPath is: $ExecPath.") {
        Write-SPOTLog " >> unit test (NoError) set execution path - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError) set execution path - FAILED." }
    if ($PublishedData["StepOutput"] -like "*SPOT Intercepted 'exit' with code: 0*") {
        Write-SPOTLog " >> unit test (NoError) intercept exit command - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError) intercept exit command - FAILED." }
    $JobOutput = $null
    $Job = $null
    $global:PublishedData = [hashtable]::Synchronized(@{})


    #####################
    Write-SPOTLog "##########################################################################################"
    Write-SPOTLog " ###> Starting ""PowershellCommandRemoteWMI"" unit test (TerminatingError)."
    $Job = PowershellCommandRemoteWMI -CommandName Start-UTFunction -CommandParameters @{InputParameter = "TETest"} -RemoteComputer "127.0.0.1" -Credential $Credential -ExecPath $ExecPath -VariablesToPublish @("InnerVariable=StepVariable","_spot_Output=StepOutput")
    while (!$Job.handle.IsCompleted) {
        Write-SPOTLog " >> Waiting for ""PowershellCommandRemoteWMI"" job."
        Start-Sleep -Seconds 1
    }
    $JobOutput = $Job.powershell.EndInvoke($Job.handle)
    $Job.powershell.Dispose()
    Write-SPOTLog " >> ""PowershellCommandRemoteWMI"" job output: $JobOutput" -Output $false
    ###
    if ($JobOutput[$JobOutput.Count-1] -eq $false) { 
        Write-SPOTLog " >> unit test (TerminatingError) overall execution - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) overall execution - FAILED." }
    if ($PublishedData["StepVariable"] -eq "InnerValue") { 
        Write-SPOTLog " >> unit test (TerminatingError) publish inner variable - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) publish inner variable - FAILED." }
    if ($PublishedData["StepOutput"][0].Trim() -eq "> Starting function Start-UTFunction.") {
        Write-SPOTLog " >> unit test (TerminatingError) publish step output - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) publish step output - FAILED." }
    if ($PublishedData["StepOutput"][1].Trim() -eq ">> InputParameter is: TETest") {
        Write-SPOTLog " >> unit test (TerminatingError) assign CommandParameter - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) assign CommandParameter - FAILED." }
    if ($PublishedData["StepOutput"][2].Trim() -eq ">> OrchVars.TestVariable is: OrchTestValue") {
        Write-SPOTLog " >> unit test (TerminatingError) access OrchVars inside step - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) access OrchVars inside step - FAILED." }
    if ($PublishedData["StepOutput"][3].Trim() -eq ">> ExecPath is: $ExecPath.") {
        Write-SPOTLog " >> unit test (TerminatingError) set execution path - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) set execution path - FAILED." }
    if ($PublishedData["StepOutput"] -like "*throw ""Start-UTFunction: Terminating Error test!""*") {
        Write-SPOTLog " >> unit test (TerminatingError) detect error line - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) detect error line - FAILED." }
    $JobOutput = $null
    $Job = $null
    $global:PublishedData = [hashtable]::Synchronized(@{})


    #####################
    Write-SPOTLog "##########################################################################################"
    Write-SPOTLog " ###> Starting ""PowershellCommandRemoteWMI"" unit test (NonTerminatingError)."
    $Job = PowershellCommandRemoteWMI -CommandName Start-UTFunction -CommandParameters @{InputParameter = "NTETest"} -RemoteComputer "127.0.0.1" -Credential $Credential -ExecPath $ExecPath -VariablesToPublish @("InnerVariable=StepVariable","_spot_Output=StepOutput")
    while (!$Job.handle.IsCompleted) {
        Write-SPOTLog " >> Waiting for ""PowershellCommandRemoteWMI"" job."
        Start-Sleep -Seconds 1
    }
    $JobOutput = $Job.powershell.EndInvoke($Job.handle)
    $Job.powershell.Dispose()
    Write-SPOTLog " >> ""PowershellCommandRemoteWMI"" job output: $JobOutput." -Output $false
    ###
    if ($JobOutput[$JobOutput.Count-1] -eq $true) { 
        Write-SPOTLog " >> unit test (NonTerminatingError) overall execution - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) overall execution - FAILED." }
    if ($PublishedData["StepVariable"] -eq "InnerValue") { 
        Write-SPOTLog " >> unit test (NonTerminatingError) publish inner variable - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) publish inner variable - FAILED." }
    if ($PublishedData["StepOutput"][0].Trim() -eq "> Starting function Start-UTFunction.") {
        Write-SPOTLog " >> unit test (NonTerminatingError) publish step output - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) publish step output - FAILED." }
    if ($PublishedData["StepOutput"][1].Trim() -eq ">> InputParameter is: NTETest") {
        Write-SPOTLog " >> unit test (NonTerminatingError) assign CommandParameter - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) assign CommandParameter - FAILED." }
    if ($PublishedData["StepOutput"][2].Trim() -eq ">> OrchVars.TestVariable is: OrchTestValue") {
        Write-SPOTLog " >> unit test (NonTerminatingError) access OrchVars inside step - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) access OrchVars inside step - FAILED." }
    if ($PublishedData["StepOutput"][3].Trim() -eq ">> ExecPath is: $ExecPath.") {
        Write-SPOTLog " >> unit test (NonTerminatingError) set execution path - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) set execution path - FAILED." }
    if ($PublishedData["StepOutput"] -like "*Start-UTFunction : Non-Terminating Error test!*") {
        Write-SPOTLog " >> unit test (NonTerminatingError) detect error name - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) detect error name - FAILED." }
    if ($PublishedData["StepOutput"] -like "*SPOT Intercepted 'exit' with code: 0*") {
        Write-SPOTLog " >> unit test (NonTerminatingError) intercept exit command - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) intercept exit command - FAILED." }
    $JobOutput = $null
    $Job = $null
    $global:PublishedData = [hashtable]::Synchronized(@{})


    ###################################################################
    ###################################################################
    if ($OrchVars._PsExecPath) {
        Write-SPOTLog "##########################################################################################"
        Write-SPOTLog " ###> Starting ""PowershellCommandRemotePsExec"" unit test (NoError)(AsSystem)."
        $Job = PowershellCommandRemotePsExec -CommandName Start-UTFunction -CommandParameters @{InputParameter = "test"} -RemoteComputer "127.0.0.1" -Credential $Credential -ExecPath $ExecPath -AsSystem $true -VariablesToPublish @("InnerVariable=StepVariable","_spot_Output=StepOutput")
        while (!$Job.handle.IsCompleted) {
            Write-SPOTLog " >> Waiting for ""PowershellCommandRemotePsExec"" job."
            Start-Sleep -Seconds 1
        }
        $JobOutput = $Job.powershell.EndInvoke($Job.handle)
        $Job.powershell.Dispose()
        Write-SPOTLog " >> ""PowershellCommandRemotePsExec"" job output: $JobOutput." -Output $false
        ###
        if ($JobOutput[$JobOutput.Count-1] -eq $true) { 
            Write-SPOTLog " >> unit test (NoError) overall execution - SUCCESS." 
        } else { Write-SPOTLog " >> unit test (NoError) overall execution - FAILED." }
        if ($PublishedData["StepVariable"] -eq "InnerValue") { 
            Write-SPOTLog " >> unit test (NoError)(AsSystem) publish inner variable - SUCCESS." 
        } else { Write-SPOTLog " >> unit test (NoError)(AsSystem) publish inner variable - FAILED." }
        if ($PublishedData["StepOutput"][0].Trim() -eq "> Starting function Start-UTFunction.") {
            Write-SPOTLog " >> unit test (NoError)(AsSystem) publish step output - SUCCESS." 
        } else { Write-SPOTLog " >> unit test (NoError)(AsSystem) publish step output - FAILED." }
        if ($PublishedData["StepOutput"][1].Trim() -eq ">> InputParameter is: Test") {
            Write-SPOTLog " >> unit test (NoError)(AsSystem) assign CommandParameter - SUCCESS." 
        } else { Write-SPOTLog " >> unit test (NoError)(AsSystem) assign CommandParameter - FAILED." }
        if ($PublishedData["StepOutput"][2].Trim() -eq ">> OrchVars.TestVariable is: OrchTestValue") {
            Write-SPOTLog " >> unit test (NoError)(AsSystem) access OrchVars inside step - SUCCESS." 
        } else { Write-SPOTLog " >> unit test (NoError)(AsSystem) access OrchVars inside step - FAILED." }
        if ($PublishedData["StepOutput"][3].Trim() -eq ">> ExecPath is: $ExecPath.") {
            Write-SPOTLog " >> unit test (NoError)(AsSystem) set execution path - SUCCESS." 
        } else { Write-SPOTLog " >> unit test (NoError)(AsSystem) set execution path - FAILED." }
        if ($PublishedData["StepOutput"] -like "*SPOT Intercepted 'exit' with code: 0*") {
            Write-SPOTLog " >> unit test (NoError)(AsSystem) intercept exit command - SUCCESS." 
        } else { Write-SPOTLog " >> unit test (NoError)(AsSystem) intercept exit command - FAILED." }
        if ($PublishedData["StepOutput"][4].Trim() -eq ">> ExecUser is: nt authority\system.") {
        Write-SPOTLog " >> unit test (NoError)(AsSystem) running as system - SUCCESS." 
        } else { Write-SPOTLog " >> unit test (NoError)(AsSystem) running as system - FAILED." }
        $JobOutput = $null
        $Job = $null
        $global:PublishedData = [hashtable]::Synchronized(@{})


        #####################
        Write-SPOTLog "##########################################################################################"
        Write-SPOTLog " ###> Starting ""PowershellCommandRemotePsExec"" unit test (TerminatingError)."
        $Job = PowershellCommandRemotePsExec -CommandName Start-UTFunction -CommandParameters @{InputParameter = "TETest"} -RemoteComputer "127.0.0.1" -Credential $Credential -ExecPath $ExecPath -VariablesToPublish @("InnerVariable=StepVariable","_spot_Output=StepOutput")
        while (!$Job.handle.IsCompleted) {
            Write-SPOTLog " >> Waiting for ""PowershellCommandRemotePsExec"" job."
            Start-Sleep -Seconds 1
        }
        $JobOutput = $Job.powershell.EndInvoke($Job.handle)
        $Job.powershell.Dispose()
        Write-SPOTLog " >> ""PowershellCommandRemotePsExec"" job output: $JobOutput" -Output $false
        ###
        if ($JobOutput[$JobOutput.Count-1] -eq $false) { 
            Write-SPOTLog " >> unit test (TerminatingError) overall execution - SUCCESS." 
        } else { Write-SPOTLog " >> unit test (TerminatingError) overall execution - FAILED." }
        if ($PublishedData["StepVariable"] -eq "InnerValue") { 
            Write-SPOTLog " >> unit test (TerminatingError) publish inner variable - SUCCESS." 
        } else { Write-SPOTLog " >> unit test (TerminatingError) publish inner variable - FAILED." }
        if ($PublishedData["StepOutput"][0].Trim() -eq "> Starting function Start-UTFunction.") {
            Write-SPOTLog " >> unit test (TerminatingError) publish step output - SUCCESS." 
        } else { Write-SPOTLog " >> unit test (TerminatingError) publish step output - FAILED." }
        if ($PublishedData["StepOutput"][1].Trim() -eq ">> InputParameter is: TETest") {
            Write-SPOTLog " >> unit test (TerminatingError) assign CommandParameter - SUCCESS." 
        } else { Write-SPOTLog " >> unit test (TerminatingError) assign CommandParameter - FAILED." }
        if ($PublishedData["StepOutput"][2].Trim() -eq ">> OrchVars.TestVariable is: OrchTestValue") {
            Write-SPOTLog " >> unit test (TerminatingError) access OrchVars inside step - SUCCESS." 
        } else { Write-SPOTLog " >> unit test (TerminatingError) access OrchVars inside step - FAILED." }
        if ($PublishedData["StepOutput"][3].Trim() -eq ">> ExecPath is: $ExecPath.") {
            Write-SPOTLog " >> unit test (TerminatingError) set execution path - SUCCESS." 
        } else { Write-SPOTLog " >> unit test (TerminatingError) set execution path - FAILED." }
        if ($PublishedData["StepOutput"] -like "*throw ""Start-UTFunction: Terminating Error test!""*") {
            Write-SPOTLog " >> unit test (TerminatingError) detect error line - SUCCESS." 
        } else { Write-SPOTLog " >> unit test (TerminatingError) detect error line - FAILED." }
        $JobOutput = $null
        $Job = $null
        $global:PublishedData = [hashtable]::Synchronized(@{})


        #####################
        Write-SPOTLog "##########################################################################################"
        Write-SPOTLog " ###> Starting ""PowershellCommandRemotePsExec"" unit test (NonTerminatingError)."
        $Job = PowershellCommandRemotePsExec -CommandName Start-UTFunction -CommandParameters @{InputParameter = "NTETest"} -RemoteComputer "127.0.0.1" -Credential $Credential -ExecPath $ExecPath -VariablesToPublish @("InnerVariable=StepVariable","_spot_Output=StepOutput")
        while (!$Job.handle.IsCompleted) {
            Write-SPOTLog " >> Waiting for ""PowershellCommandRemotePsExec"" job."
            Start-Sleep -Seconds 1
        }
        $JobOutput = $Job.powershell.EndInvoke($Job.handle)
        $Job.powershell.Dispose()
        Write-SPOTLog " >> ""PowershellCommandRemotePsExec"" job output: $JobOutput." -Output $false
        ###
        if ($JobOutput[$JobOutput.Count-1] -eq $true) { 
            Write-SPOTLog " >> unit test (NonTerminatingError) overall execution - SUCCESS." 
        } else { Write-SPOTLog " >> unit test (NonTerminatingError) overall execution - FAILED." }
        if ($PublishedData["StepVariable"] -eq "InnerValue") { 
            Write-SPOTLog " >> unit test (NonTerminatingError) publish inner variable - SUCCESS." 
        } else { Write-SPOTLog " >> unit test (NonTerminatingError) publish inner variable - FAILED." }
        if ($PublishedData["StepOutput"][0].Trim() -eq "> Starting function Start-UTFunction.") {
            Write-SPOTLog " >> unit test (NonTerminatingError) publish step output - SUCCESS." 
        } else { Write-SPOTLog " >> unit test (NonTerminatingError) publish step output - FAILED." }
        if ($PublishedData["StepOutput"][1].Trim() -eq ">> InputParameter is: NTETest") {
            Write-SPOTLog " >> unit test (NonTerminatingError) assign CommandParameter - SUCCESS." 
        } else { Write-SPOTLog " >> unit test (NonTerminatingError) assign CommandParameter - FAILED." }
        if ($PublishedData["StepOutput"][2].Trim() -eq ">> OrchVars.TestVariable is: OrchTestValue") {
            Write-SPOTLog " >> unit test (NonTerminatingError) access OrchVars inside step - SUCCESS." 
        } else { Write-SPOTLog " >> unit test (NonTerminatingError) access OrchVars inside step - FAILED." }
        if ($PublishedData["StepOutput"][3].Trim() -eq ">> ExecPath is: $ExecPath.") {
            Write-SPOTLog " >> unit test (NonTerminatingError) set execution path - SUCCESS." 
        } else { Write-SPOTLog " >> unit test (NonTerminatingError) set execution path - FAILED." }
        if ($PublishedData["StepOutput"] -like "*Start-UTFunction : Non-Terminating Error test!*") {
            Write-SPOTLog " >> unit test (NonTerminatingError) detect error name - SUCCESS." 
        } else { Write-SPOTLog " >> unit test (NonTerminatingError) detect error name - FAILED." }
        if ($PublishedData["StepOutput"] -like "*SPOT Intercepted 'exit' with code: 0*") {
            Write-SPOTLog " >> unit test (NonTerminatingError) intercept exit command - SUCCESS." 
        } else { Write-SPOTLog " >> unit test (NonTerminatingError) intercept exit command - FAILED." }
        $JobOutput = $null
        $Job = $null
        $global:PublishedData = [hashtable]::Synchronized(@{})

    }
    ###################################################################
    ###################################################################
    Write-SPOTLog "##########################################################################################"
    Write-SPOTLog " ###> Starting ""PowershellCommandRemoteOWMI"" unit test (NoError)."
    $Job = PowershellCommandRemoteOWMI -CommandName Start-UTFunction -CommandParameters @{InputParameter = "test"} -RemoteComputer "127.0.0.1" -Credential $Credential -ExecPath $ExecPath -VariablesToPublish @("InnerVariable=StepVariable","_spot_Output=StepOutput")
    while (!$Job.handle.IsCompleted) {
        Write-SPOTLog " >> Waiting for ""PowershellCommandRemoteOWMI"" job."
        Start-Sleep -Seconds 1
    }
    $JobOutput = $Job.powershell.EndInvoke($Job.handle)
    $Job.powershell.Dispose()
    Write-SPOTLog " >> ""PowershellCommandRemoteOWMI"" job output: $JobOutput." -Output $false
    ###
    if ($JobOutput[$JobOutput.Count-1] -eq $true) { 
        Write-SPOTLog " >> unit test (NoError) overall execution - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError) overall execution - FAILED." }
    if ($PublishedData["StepVariable"] -eq "InnerValue") { 
        Write-SPOTLog " >> unit test (NoError) publish inner variable - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError) publish inner variable - FAILED." }
    if ($PublishedData["StepOutput"][0].Trim() -eq "> Starting function Start-UTFunction.") {
        Write-SPOTLog " >> unit test (NoError) publish step output - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError) publish step output - FAILED." }
    if ($PublishedData["StepOutput"][1].Trim() -eq ">> InputParameter is: Test") {
        Write-SPOTLog " >> unit test (NoError) assign CommandParameter - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError) assign CommandParameter - FAILED." }
    if ($PublishedData["StepOutput"][2].Trim() -eq ">> OrchVars.TestVariable is: OrchTestValue") {
        Write-SPOTLog " >> unit test (NoError) access OrchVars inside step - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError) access OrchVars inside step - FAILED." }
    if ($PublishedData["StepOutput"][3].Trim() -eq ">> ExecPath is: $ExecPath.") {
        Write-SPOTLog " >> unit test (NoError) set execution path - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError) set execution path - FAILED." }
    if ($PublishedData["StepOutput"] -like "*SPOT Intercepted 'exit' with code: 0*") {
        Write-SPOTLog " >> unit test (NoError) intercept exit command - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NoError) intercept exit command - FAILED." }
    $JobOutput = $null
    $Job = $null
    $global:PublishedData = [hashtable]::Synchronized(@{})


    #####################
    Write-SPOTLog "##########################################################################################"
    Write-SPOTLog " ###> Starting ""PowershellCommandRemoteOWMI"" unit test (TerminatingError)."
    $Job = PowershellCommandRemoteOWMI -CommandName Start-UTFunction -CommandParameters @{InputParameter = "TETest"} -RemoteComputer "127.0.0.1" -Credential $Credential -ExecPath $ExecPath -VariablesToPublish @("InnerVariable=StepVariable","_spot_Output=StepOutput")
    while (!$Job.handle.IsCompleted) {
        Write-SPOTLog " >> Waiting for ""PowershellCommandRemoteOWMI"" job."
        Start-Sleep -Seconds 1
    }
    $JobOutput = $Job.powershell.EndInvoke($Job.handle)
    $Job.powershell.Dispose()
    Write-SPOTLog " >> ""PowershellCommandRemoteOWMI"" job output: $JobOutput" -Output $false
    ###
    if ($JobOutput[$JobOutput.Count-1] -eq $false) { 
        Write-SPOTLog " >> unit test (TerminatingError) overall execution - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) overall execution - FAILED." }
    if ($PublishedData["StepVariable"] -eq "InnerValue") { 
        Write-SPOTLog " >> unit test (TerminatingError) publish inner variable - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) publish inner variable - FAILED." }
    if ($PublishedData["StepOutput"][0].Trim() -eq "> Starting function Start-UTFunction.") {
        Write-SPOTLog " >> unit test (TerminatingError) publish step output - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) publish step output - FAILED." }
    if ($PublishedData["StepOutput"][1].Trim() -eq ">> InputParameter is: TETest") {
        Write-SPOTLog " >> unit test (TerminatingError) assign CommandParameter - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) assign CommandParameter - FAILED." }
    if ($PublishedData["StepOutput"][2].Trim() -eq ">> OrchVars.TestVariable is: OrchTestValue") {
        Write-SPOTLog " >> unit test (TerminatingError) access OrchVars inside step - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) access OrchVars inside step - FAILED." }
    if ($PublishedData["StepOutput"][3].Trim() -eq ">> ExecPath is: $ExecPath.") {
        Write-SPOTLog " >> unit test (TerminatingError) set execution path - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) set execution path - FAILED." }
    if ($PublishedData["StepOutput"] -like "*throw ""Start-UTFunction: Terminating Error test!""*") {
        Write-SPOTLog " >> unit test (TerminatingError) detect error line - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (TerminatingError) detect error line - FAILED." }
    $JobOutput = $null
    $Job = $null
    $global:PublishedData = [hashtable]::Synchronized(@{})


    #####################
    Write-SPOTLog "##########################################################################################"
    Write-SPOTLog " ###> Starting ""PowershellCommandRemoteOWMI"" unit test (NonTerminatingError)."
    $Job = PowershellCommandRemoteOWMI -CommandName Start-UTFunction -CommandParameters @{InputParameter = "NTETest"} -RemoteComputer "127.0.0.1" -Credential $Credential -ExecPath $ExecPath -VariablesToPublish @("InnerVariable=StepVariable","_spot_Output=StepOutput")
    while (!$Job.handle.IsCompleted) {
        Write-SPOTLog " >> Waiting for ""PowershellCommandRemoteOWMI"" job."
        Start-Sleep -Seconds 1
    }
    $JobOutput = $Job.powershell.EndInvoke($Job.handle)
    $Job.powershell.Dispose()
    Write-SPOTLog " >> ""PowershellCommandRemoteOWMI"" job output: $JobOutput." -Output $false
    ###
    if ($JobOutput[$JobOutput.Count-1] -eq $true) { 
        Write-SPOTLog " >> unit test (NonTerminatingError) overall execution - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) overall execution - FAILED." }
    if ($PublishedData["StepVariable"] -eq "InnerValue") { 
        Write-SPOTLog " >> unit test (NonTerminatingError) publish inner variable - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) publish inner variable - FAILED." }
    if ($PublishedData["StepOutput"][0].Trim() -eq "> Starting function Start-UTFunction.") {
        Write-SPOTLog " >> unit test (NonTerminatingError) publish step output - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) publish step output - FAILED." }
    if ($PublishedData["StepOutput"][1].Trim() -eq ">> InputParameter is: NTETest") {
        Write-SPOTLog " >> unit test (NonTerminatingError) assign CommandParameter - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) assign CommandParameter - FAILED." }
    if ($PublishedData["StepOutput"][2].Trim() -eq ">> OrchVars.TestVariable is: OrchTestValue") {
        Write-SPOTLog " >> unit test (NonTerminatingError) access OrchVars inside step - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) access OrchVars inside step - FAILED." }
    if ($PublishedData["StepOutput"][3].Trim() -eq ">> ExecPath is: $ExecPath.") {
        Write-SPOTLog " >> unit test (NonTerminatingError) set execution path - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) set execution path - FAILED." }
    if ($PublishedData["StepOutput"] -like "*Start-UTFunction : Non-Terminating Error test!*") {
        Write-SPOTLog " >> unit test (NonTerminatingError) detect error name - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) detect error name - FAILED." }
    if ($PublishedData["StepOutput"] -like "*SPOT Intercepted 'exit' with code: 0*") {
        Write-SPOTLog " >> unit test (NonTerminatingError) intercept exit command - SUCCESS." 
    } else { Write-SPOTLog " >> unit test (NonTerminatingError) intercept exit command - FAILED." }
    $JobOutput = $null
    $Job = $null
    $global:PublishedData = [hashtable]::Synchronized(@{})

    #endregion: Type Function tests
    
    ##########################################
    #region: perform Runbook related unit tests

    #region: prepare test objects
    Write-SPOTLog " ###> Starting runbook related unit tests."

    $global:AllRunbooks = [hashtable]::Synchronized(@{})
    $global:AllRunbookSteps = [hashtable]::Synchronized(@{})
    $PublishedData.PVar1 = "SingleString"
    $PublishedData.PVar2 = "Two Strings"
    $PublishedData.PVar3 = @{k1 = "v1"; k2 = "v2"}
    $SVars.TestCred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList ("TestUsername",(ConvertTo-SecureString -String "SecretPassword" -AsPlainText -Force))
    $SVars.TestSecret = ConvertTo-SecureString -String "TestSecretString" -AsPlainText -Force

    ##############################################################
    # create the test runbook
    $RunbookName                = "UnitTestRunbook"
    $RunbookSeq                 = 5
    $Runbook                    = [Runbook]::new($RunbookName,$RunbookSeq)
    $Runbook.Description        = "UnitTestRunbook"
    $Runbook.Conditions         = "`$OV:ConditionFlag"
    $Runbook.RemoteParameters   = @{ExecFunction = "PowershellCommandRemote"; RemoteComputer = '$OV:TestVariable'; Credential = "`$SV:TestCred"}
    $Runbook.ContinueOnError    = $false
    $Runbook.RunbookParameters  = @{TRBPar1 = "DefaultRBValue1"; TRBPar2 = "DefaultRBValue2"; TRBPar3 = "`$PV:PVar3.k2"}
    $AllRunbooks[$Runbook.GUID] = $Runbook

    ##############################################################
    # create the test runbookstep
    $RunbookStepName                    = "UnitTestRunbookStep"
    $RunbookStepSeq                     = 2
    $RunbookStepParameters              = @{CommandName = "Start-UTFunction"; CommandParameters = @{InputParameter = "UnitTestParameter"}; ExecPath = "C:\temp"; VariablesToPublish = @("InnerVariable=StepVariable","_spot_Output=StepOutput")}
    $RunbookStep                        = [RunbookStep]::new($RunbookStepName, $RunbookStepSeq, "PowershellCommandLocal", $RunbookStepParameters)
    $RunbookStep.Description            = "UnitTestRunbookStep"
    $RunbookStep.Conditions             = "`$OV:ConditionFlag"
    $RunbookStep.ContinueOnError        = $false
    $Runbook.RunbookSteps              += $RunbookStep
    $AllRunbookSteps[$RunbookStep.GUID] = $RunbookStep

    #endregion: prepare test objects

    #region: testing runbook conditions
    ##############################################################
    # TESTING RUNBOOK CONDITIONS

    ######################
    # no conditions
    Write-SPOTLog " > Testing ""no conditions"" in Runbook"
    $Runbook.Conditions = $null
    Replace-SPOTVarsInRunbook -Runbook $Runbook
    Replace-SPOTVarsInRunbookJIT -Runbook $Runbook
    if (!$Runbook.Conditions) { 
        Write-SPOTLog " >>> OK" 
    }
    else {
        Write-SPOTLog " >>> FAILED" 
    }

    ######################
    # one static condition
    Write-SPOTLog " > Testing ""one static condition"" in Runbook"
    $Runbook.Conditions = $false
    Replace-SPOTVarsInRunbook -Runbook $Runbook
    Replace-SPOTVarsInRunbookJIT -Runbook $Runbook
    if ($Runbook.Conditions[0] -eq $false) {
        Write-SPOTLog " >>> OK"
    }
    else {
        Write-SPOTLog " >>> FAILED"
    }

    ######################
    # false and null condition
    Write-SPOTLog " > Testing ""false and null condition"" in Runbook"
    $Runbook.Conditions = $null,$false
    Replace-SPOTVarsInRunbook -Runbook $Runbook
    Replace-SPOTVarsInRunbookJIT -Runbook $Runbook
    if (($null -in $Runbook.Conditions) -and ($false -in $Runbook.Conditions) -and ($Runbook.Conditions.Count -eq 2)) {
        Write-SPOTLog " >>> OK"
    }
    else {
        Write-SPOTLog " >>> FAILED"
    }

    ######################
    # multiple conditions with references
    Write-SPOTLog " > Testing ""multiple conditions with references"" in Runbook"
    $Runbook.Conditions = "`$OV:ConditionFlag","`$PV:PVar3.k1","`$RP:TRBPar3"
    Replace-SPOTVarsInRunbook -Runbook $Runbook
    Replace-SPOTVarsInRunbookJIT -Runbook $Runbook
    if (!(Compare-Object -ReferenceObject $Runbook.Conditions -DifferenceObject $true,"v1","v2")) {
        Write-SPOTLog " >>> OK"
    }
    else {
        Write-SPOTLog " >>> FAILED"
    }
    
    ######################
    # mixed string in condition (to fail)
    ##########
    Write-SPOTLog " > Testing ""mixed string in condition"" in Runbook (case 1) rejection"
    $Runbook.Conditions = 'Prefix$OV:ConditionFlag'
    try {
        Replace-SPOTVarsInRunbook -Runbook $Runbook
        Replace-SPOTVarsInRunbookJIT -Runbook $Runbook
    }
    catch {
        if ($_.Exception -like '*unexpected ":" usage in condition*') {
            Write-SPOTLog " >>> OK"
        }
        else {
            Write-SPOTLog " >>> FAILED"
            Write-SPOTLog " >>>> Actual encountered exception is: $_."
        }
    }
    if ($Runbook.Conditions -ne 'Prefix$OV:ConditionFlag') {
        Write-SPOTLog " >>> FAILED"
        Write-SPOTLog " >>>> The value of the condition changed from ""Prefix`$OV:ConditionFlag"" to ""$($Runbook.Conditions)""."
    }
    
    ##########
    Write-SPOTLog " > Testing ""mixed string in condition"" in Runbook (case 2) rejection"
    $Runbook.Conditions = 'Prefix$RP:TRBPar1:$RPSuffix'
    try {
        Replace-SPOTVarsInRunbook -Runbook $Runbook
        Replace-SPOTVarsInRunbookJIT -Runbook $Runbook
    }
    catch {
        if ($_.Exception -like '*unexpected mixed string reference*') {
            Write-SPOTLog " >>> OK"
        }
        else {
            Write-SPOTLog " >>> FAILED"
            Write-SPOTLog " >>>> Actual encountered exception is: $_."
        }
    }
    if ($Runbook.Conditions -ne 'Prefix$RP:TRBPar1:$RPSuffix') {
        Write-SPOTLog " >>> FAILED"
        Write-SPOTLog " >>>> The value of the condition changed from ""Prefix`$RP:TRBPar1:`$RPSuffix"" to ""$($Runbook.Conditions)""."
    }

    ######################
    # multi-word in condition (to fail)
    ##########
    Write-SPOTLog " > Testing ""multi-word in condition"" in Runbook rejection"
    $Runbook.Conditions = "two strings"
    try {
        Replace-SPOTVarsInRunbook -Runbook $Runbook
        Replace-SPOTVarsInRunbookJIT -Runbook $Runbook
    }
    catch {
        if ($_.Exception -like '*unexpected mixed string reference*') {
            Write-SPOTLog " >>> OK"
        }
        else {
            Write-SPOTLog " >>> FAILED"
            Write-SPOTLog " >>>> Actual encountered exception is: $_."
        }
    }
    if ($Runbook.Conditions -ne "two strings") {
        Write-SPOTLog " >>> FAILED"
        Write-SPOTLog " >>>> The value of the condition changed from ""two strings"" to ""$($Runbook.Conditions)""."
    }

    ##########
    # reset conditions
    $Runbook.Conditions = $null

    #endregion: testing runbook conditions

    #region: testing runbook parameters

    ##############################################################
    # TESTING RUNBOOK PARAMETERS

    ######################
    # OV, SV and PV ref in RunbookParameter
    Write-SPOTLog " > Testing ""OV, SV and PV ref in RunbookParameter"" in Runbook"
    $Runbook.RunbookParameters  = @{TRBPar1 = "`$OV:TestVariable"; TRBPar2 = "`$SV:TestCred"; TRBPar3 = "`$PV:PVar3.k2"}
    Replace-SPOTVarsInRunbook -Runbook $Runbook
    Replace-SPOTVarsInRunbookJIT -Runbook $Runbook
    if (($Runbook.RunbookParameters.TRBPar2 -eq $SVars.TestCred) -and ($Runbook.RunbookParameters.TRBPar1 -eq "OrchTestValue") -and ($Runbook.RunbookParameters.TRBPar3 -eq "v2")) {
        Write-SPOTLog " >>> OK"
    }
    else {
        Write-SPOTLog " >>> FAILED"
    }

    ######################
    # mixed string in RunbookParameter (to fail)
    Write-SPOTLog " > Testing ""mixed string in RunbookParameter"" in Runbook (case 1) rejection"
    $Runbook.RunbookParameters.TRBPar1 = 'Prefix$OV:TestVariable'
    try {
        Replace-SPOTVarsInRunbook -Runbook $Runbook
        Replace-SPOTVarsInRunbookJIT -Runbook $Runbook
    }
    catch {
        if ($_.Exception -like '*unexpected ":" usage in RunbookParameter*') {
            Write-SPOTLog " >>> OK"
        }
        else {
            Write-SPOTLog " >>> FAILED"
            Write-SPOTLog " >>>> Actual encountered exception is: $_."
        }
    }
    if ($Runbook.RunbookParameters.TRBPar1 -ne 'Prefix$OV:TestVariable') {
        Write-SPOTLog " >>> FAILED"
        Write-SPOTLog " >>>> The value of the RunbookParameter changed from ""Prefix`$OV:TestVariable"" to ""$($Runbook.RunbookParameters.TRBPar1)""."
    }

    ######################
    # mixed string in RunbookParameter (to fail)
    Write-SPOTLog " > Testing ""mixed string in RunbookParameter"" in Runbook (case 2) rejection"
    $Runbook.RunbookParameters.TRBPar1 = 'Prefix$PV:PVar1:$PVSuffix'
    try {
        Replace-SPOTVarsInRunbook -Runbook $Runbook
        Replace-SPOTVarsInRunbookJIT -Runbook $Runbook
    }
    catch {
        if ($_.Exception -like '*unexpected mixed string reference*') {
            Write-SPOTLog " >>> OK"
        }
        else {
            Write-SPOTLog " >>> FAILED"
            Write-SPOTLog " >>>> Actual encountered exception is: $_."
        }
    }
    if ($Runbook.RunbookParameters.TRBPar1 -ne 'Prefix$PV:PVar1:$PVSuffix') {
        Write-SPOTLog " >>> FAILED"
        Write-SPOTLog " >>>> The value of the RunbookParameter changed from ""Prefix`$PV:PVar1:`$PVSuffix"" to ""$($Runbook.RunbookParameters.TRBPar1)""."
    }

    ######################
    # reset runbook parameters
    $Runbook.RunbookParameters  = @{TRBPar1 = "DefaultRBValue1"; TRBPar2 = "DefaultRBValue2"; TRBPar3 = "`$PV:PVar3.k2"}

    #endregion: testing runbook parameters

    #region: testing remote parameters

    ##############################################################
    # TESTING REMOTE PARAMETERS

    ######################
    # RP and SV ref in RemoteParameter
    Write-SPOTLog " > Testing ""RP and SV ref in RemoteParameter"" in Runbook"
    $Runbook.RemoteParameters = @{ExecFunction = "PowershellCommandRemote"; RemoteComputer = '$RP:TRBPar3'; Credential = "`$SV:TestCred"}
    Replace-SPOTVarsInRunbook -Runbook $Runbook
    $validation = $null
    $validation = Validate-SPOTRunbookRemoteParameters -Runbook $Runbook
    Replace-SPOTVarsInRunbookJIT -Runbook $Runbook
    if ($validation -and ($Runbook.RemoteParameters.RemoteComputer -eq "v2") -and ($Runbook.RemoteParameters.Credential -eq $SVars.TestCred) -and ($Runbook.RemoteParameters.ExecFunction -eq "PowershellCommandRemote")) {
        Write-SPOTLog " >>> OK"
    }
    else {
        Write-SPOTLog " >>> FAILED"
    }

    ######################
    # PV and SV ref in RemoteParameter
    Write-SPOTLog " > Testing ""PV and SV ref in RemoteParameter"" in Runbook"
    $Runbook.RemoteParameters = @{ExecFunction = "PowershellCommandRemote"; RemoteComputer = '$PV:PVar1'; Credential = "`$SV:TestCred"}
    Replace-SPOTVarsInRunbook -Runbook $Runbook
    $validation = $null
    $validation = Validate-SPOTRunbookRemoteParameters -Runbook $Runbook
    Replace-SPOTVarsInRunbookJIT -Runbook $Runbook
    if ($validation -and ($Runbook.RemoteParameters.RemoteComputer -eq "SingleString") -and ($Runbook.RemoteParameters.Credential -eq $SVars.TestCred) -and ($Runbook.RemoteParameters.ExecFunction -eq "PowershellCommandRemote")) {
        Write-SPOTLog " >>> OK"
    }
    else {
        Write-SPOTLog " >>> FAILED"
    }

    ######################
    # OV and SV ref in RemoteParameter
    Write-SPOTLog " > Testing ""OV and SV ref in RemoteParameter"" in Runbook"
    $Runbook.RemoteParameters = @{ExecFunction = "PowershellCommandRemote"; RemoteComputer = '$OV:TestVariable'; Credential = "`$SV:TestCred"}
    Replace-SPOTVarsInRunbook -Runbook $Runbook
    $validation = $null
    $validation = Validate-SPOTRunbookRemoteParameters -Runbook $Runbook
    Replace-SPOTVarsInRunbookJIT -Runbook $Runbook
    if ($validation -and ($Runbook.RemoteParameters.RemoteComputer -eq "OrchTestValue") -and ($Runbook.RemoteParameters.Credential -eq $SVars.TestCred) -and ($Runbook.RemoteParameters.ExecFunction -eq "PowershellCommandRemote")) {
        Write-SPOTLog " >>> OK"
    }
    else {
        Write-SPOTLog " >>> FAILED"
    }

    ######################
    # mixed string in RemoteParameter (to fail)
    Write-SPOTLog " > Testing ""mixed string in RemoteParameter"" in Runbook (case 1) rejection"
    $Runbook.RemoteParameters = @{ExecFunction = "PowershellCommandRemote"; RemoteComputer = 'Prefix$OV:TestVariable'; Credential = "`$SV:TestCred"}
    try {
        Replace-SPOTVarsInRunbook -Runbook $Runbook
        $validation = $null
        $validation = Validate-SPOTRunbookRemoteParameters -Runbook $Runbook
        Replace-SPOTVarsInRunbookJIT -Runbook $Runbook
    }
    catch {
        if ($_.Exception -like '*unexpected ":" usage in RemoteParameter*') {
            Write-SPOTLog " >>> OK"
        }
        else {
            Write-SPOTLog " >>> FAILED"
            Write-SPOTLog " >>>> Actual encountered exception is: $_."
        }
    }
    if ($Runbook.RemoteParameters.RemoteComputer -ne 'Prefix$OV:TestVariable') {
        Write-SPOTLog " >>> FAILED"
        Write-SPOTLog " >>>> The value of the RemoteParameter changed from ""Prefix`$OV:TestVariable"" to ""$($Runbook.RemoteParameters.RemoteComputer)"". Validation was: $validation."
    }

    ######################
    # mixed string in RemoteParameter (to fail)
    Write-SPOTLog " > Testing ""mixed string in RemoteParameter"" in Runbook (case 2) rejection"
    $Runbook.RemoteParameters = @{ExecFunction = "PowershellCommandRemote"; RemoteComputer = 'Prefix$PV:PVar1:$PVSuffix'; Credential = "`$SV:TestCred"}
    try {
        Replace-SPOTVarsInRunbook -Runbook $Runbook
        $validation = $null
        $validation = Validate-SPOTRunbookRemoteParameters -Runbook $Runbook
        Replace-SPOTVarsInRunbookJIT -Runbook $Runbook
    }
    catch {
        if ($_.Exception -like '*unexpected mixed string reference*') {
            Write-SPOTLog " >>> OK"
        }
        else {
            Write-SPOTLog " >>> FAILED"
            Write-SPOTLog " >>>> Actual encountered exception is: $_."
        }
    }
    if ($Runbook.RemoteParameters.RemoteComputer -ne 'Prefix$PV:PVar1:$PVSuffix') {
        Write-SPOTLog " >>> FAILED"
        Write-SPOTLog " >>>> The value of the RemoteParameter changed from ""Prefix`$PV:PVar1:`$PVSuffix"" to ""$($Runbook.RemoteParameters.RemoteComputer)"". Validation was: $validation."
    }

    ######################
    # reset remote parameters
    $Runbook.RemoteParameters   = @{ExecFunction = "PowershellCommandRemote"; RemoteComputer = '$OV:TestVariable'; Credential = "`$SV:TestCred"}

    #endregion: testing remote parameters

    #region: testing runbookstep conditions

    ##############################################################
    # TESTING RUNBOOKSTEP CONDITIONS

    ######################
    # no conditions
    Write-SPOTLog " > Testing ""no conditions"" in RunbookStep"
    $RunbookStep.Conditions = $null
    Replace-SPOTVarsInRunbookStep -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    Replace-SPOTVarsInRunbookStepJIT -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    if (!$RunbookStep.Conditions) { 
        Write-SPOTLog " >>> OK" 
    }
    else {
        Write-SPOTLog " >>> FAILED"
    }

    ######################
    # one static condition
    Write-SPOTLog " > Testing ""one static condition"" in RunbookStep"
    $RunbookStep.Conditions = $false
    Replace-SPOTVarsInRunbookStep -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    Replace-SPOTVarsInRunbookStepJIT -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    if ($RunbookStep.Conditions[0] -eq $false) {
        Write-SPOTLog " >>> OK"
    }
    else {
        Write-SPOTLog " >>> FAILED"
    }

    ######################
    # false and null condition
    Write-SPOTLog " > Testing ""false and null condition"" in RunbookStep"
    $RunbookStep.Conditions = $null,$false
    Replace-SPOTVarsInRunbookStep -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    Replace-SPOTVarsInRunbookStepJIT -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    if (($null -in $RunbookStep.Conditions) -and ($false -in $RunbookStep.Conditions) -and ($RunbookStep.Conditions.Count -eq 2)) {
        Write-SPOTLog " >>> OK"
    }
    else {
        Write-SPOTLog " >>> FAILED"
    }

    ######################
    # multiple conditions with references
    Write-SPOTLog " > Testing ""multiple conditions with references"" in RunbookStep"
    $RunbookStep.Conditions = "`$OV:ConditionFlag","`$PV:PVar3.k1","`$RP:TRBPar3"
    Replace-SPOTVarsInRunbookStep -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    Replace-SPOTVarsInRunbookStepJIT -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    if (!(Compare-Object -ReferenceObject $RunbookStep.Conditions -DifferenceObject $true,"v1","v2")) {
        Write-SPOTLog " >>> OK"
    }
    else {
        Write-SPOTLog " >>> FAILED"
    }
    
    ######################
    # mixed string in condition (to fail)
    ##########
    Write-SPOTLog " > Testing ""mixed string in condition"" in RunbookStep (case 1) rejection"
    $RunbookStep.Conditions = 'Prefix$OV:ConditionFlag'
    try {
        Replace-SPOTVarsInRunbookStep -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
        Replace-SPOTVarsInRunbookStepJIT -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    }
    catch {
        if ($_.Exception -like '*unexpected ":" usage in condition*') {
            Write-SPOTLog " >>> OK"
        }
        else {
            Write-SPOTLog " >>> FAILED"
            Write-SPOTLog " >>>> Actual encountered exception is: $_."
        }
    }
    if ($RunbookStep.Conditions -ne 'Prefix$OV:ConditionFlag') {
        Write-SPOTLog " >>> FAILED"
        Write-SPOTLog " >>>> The value of the condition changed from ""Prefix`$OV:ConditionFlag"" to ""$($RunbookStep.Conditions)""."
    }
    
    ##########
    Write-SPOTLog " > Testing ""mixed string in condition"" in RunbookStep (case 2) rejection"
    $RunbookStep.Conditions = 'Prefix$RP:TRBPar1:$RPSuffix'
    try {
        Replace-SPOTVarsInRunbookStep -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
        Replace-SPOTVarsInRunbookStepJIT -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    }
    catch {
        if ($_.Exception -like '*unexpected mixed string reference*') {
            Write-SPOTLog " >>> OK"
        }
        else {
            Write-SPOTLog " >>> FAILED"
            Write-SPOTLog " >>>> Actual encountered exception is: $_."
        }
    }
    if ($RunbookStep.Conditions -ne 'Prefix$RP:TRBPar1:$RPSuffix') {
        Write-SPOTLog " >>> FAILED"
        Write-SPOTLog " >>>> The value of the condition changed from ""Prefix`$RP:TRBPar1:`$RPSuffix"" to ""$($RunbookStep.Conditions)""."
    }

    ######################
    # multi-word in condition (to fail)
    ##########
    Write-SPOTLog " > Testing ""multi-word in condition"" in RunbookStep"
    $RunbookStep.Conditions = "two strings"
    try {
        Replace-SPOTVarsInRunbookStep -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
        Replace-SPOTVarsInRunbookStepJIT -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    }
    catch {
        if ($_.Exception -like '*unexpected mixed string reference*') {
            Write-SPOTLog " >>> OK"
        }
        else {
            Write-SPOTLog " >>> FAILED"
            Write-SPOTLog " >>>> Actual encountered exception is: $_."
        }
    }
    if ($RunbookStep.Conditions -ne "two strings") {
        Write-SPOTLog " >>> FAILED"
        Write-SPOTLog " >>>> The value of the condition changed from ""two strings"" to ""$($RunbookStep.Conditions)""."
    }

    ##########
    # reset conditions
    $RunbookStep.Conditions = $null

    #endregion: testing runbookstep conditions

    #region: testing runbookstep variablestopublish

    ##############################################################
    # TESTING RUNBOOKSTEP VARIABLESTOPUBLISH

    ######################
    # no VariablesToPublish
    Write-SPOTLog " > Testing ""no VariablesToPublish"" in RunbookStep"
    $RunbookStep.StepParameters.VariablesToPublish = $null
    Replace-SPOTVarsInRunbookStep -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    $validation = $null
    $validation = Validate-SPOTRunbookStep -RunbookStep $RunbookStep
    Replace-SPOTVarsInRunbookStepJIT -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    if (!$RunbookStep.StepParameters.VariablesToPublish) { 
        Write-SPOTLog " >>> OK >>> step validation was: $validation." 
    }
    else {
        Write-SPOTLog " >>> FAILED >>> step validation was: $validation."
    }

    ######################
    # one static VariablesToPublish
    Write-SPOTLog " > Testing ""one static VariablesToPublish"" in RunbookStep"
    $RunbookStep.StepParameters.VariablesToPublish = "InnerVar = OutVar"
    Replace-SPOTVarsInRunbookStep -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    $validation = $null
    $validation = Validate-SPOTRunbookStep -RunbookStep $RunbookStep
    Replace-SPOTVarsInRunbookStepJIT -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    if ($RunbookStep.StepParameters.VariablesToPublish -eq "InnerVar=OutVar") {
        Write-SPOTLog " >>> OK >>> step validation was: $validation."
    }
    else {
        Write-SPOTLog " >>> FAILED >>> step validation was: $validation."
    }

    ######################
    # one VariablesToPublish with wrong referencing (to fail)
    Write-SPOTLog " > Testing ""one VariablesToPublish with wrong referencing"" in RunbookStep rejection"
    $RunbookStep.StepParameters.VariablesToPublish = "InnerVar`$PV:PVar1 = OutVar"
    try {
        Replace-SPOTVarsInRunbookStep -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
        $validation = $null
        $validation = Validate-SPOTRunbookStep -RunbookStep $RunbookStep
        Replace-SPOTVarsInRunbookStepJIT -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    }
    catch {
        if ($_.Exception -like '*unsupported Var reference*') {
            Write-SPOTLog " >>> OK"
        }
        else {
            Write-SPOTLog " >>> FAILED"
            Write-SPOTLog " >>>> Actual encountered exception is: $_."
        }
    }
    if ($RunbookStep.StepParameters.VariablesToPublish -ne 'InnerVar$PV:PVar1 = OutVar') {
        Write-SPOTLog " >>> FAILED"
        Write-SPOTLog " >>>> The value of the VariablesToPublish changed from ""InnerVar`$PV:PVar1=OutVar"" to ""$($RunbookStep.StepParameters.VariablesToPublish)"". Validation was: $validation."
    }
    
    ######################
    # multiple static VariablesToPublish
    Write-SPOTLog " > Testing ""multiple static VariablesToPublish"" in RunbookStep"
    $RunbookStep.StepParameters.VariablesToPublish = "InnerVar1 = OutVar1","InnerVar2 = OutVar2"
    Replace-SPOTVarsInRunbookStep -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    $validation = $null
    $validation = Validate-SPOTRunbookStep -RunbookStep $RunbookStep
    Replace-SPOTVarsInRunbookStepJIT -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    if ($validation -and !(Compare-Object -ReferenceObject $RunbookStep.StepParameters.VariablesToPublish -DifferenceObject "InnerVar1=OutVar1","InnerVar2=OutVar2")) {
        Write-SPOTLog " >>> OK >>> step validation was: $validation."
    }
    else {
        Write-SPOTLog " >>> FAILED >>> step validation was: $validation."
    }

    ######################
    # multiple VariablesToPublish with references
    Write-SPOTLog " > Testing ""multiple VariablesToPublish with references"" in RunbookStep"
    $RunbookStep.StepParameters.VariablesToPublish = 'InnerVar$RP:TRBPar1:$RP = OutVar$RP:TRBPar1','InnerVar2 = OutVar$PV:PVar1:$PVSuffix'
    Replace-SPOTVarsInRunbookStep -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    $validation = $null
    $validation = Validate-SPOTRunbookStep -RunbookStep $RunbookStep
    Replace-SPOTVarsInRunbookStepJIT -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    if ($validation -and !(Compare-Object -ReferenceObject $RunbookStep.StepParameters.VariablesToPublish -DifferenceObject "InnerVarDefaultRBValue1=OutVarDefaultRBValue1","InnerVar2=OutVarSingleStringSuffix")) {
        Write-SPOTLog " >>> OK >>> step validation was: $validation."
    }
    else {
        Write-SPOTLog " >>> FAILED >>> step validation was: $validation."
    }

    ##########
    # reset VariablesToPublish
    $RunbookStep.StepParameters.VariablesToPublish = $null

    #endregion: testing runbookstep variablestopublish

    #region: testing runbookstep StepParameters
    
    ##############################################################
    # TESTING RUNBOOKSTEP STEPPARAMETERS

    ######################
    # no CommandName in StepParameters
    Write-SPOTLog " > Testing ""no CommandName in StepParameters"" in RunbookStep is invalidated"
    $RunbookStep.StepParameters = @{CommandName = $null; CommandParameters = @{InputParameter = "UnitTestParameter"}; ExecPath = "C:\temp"; VariablesToPublish = @("InnerVariable=StepVariable","_spot_Output=StepOutput")}
    Replace-SPOTVarsInRunbookStep -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    $validation = $null
    $validation = Validate-SPOTRunbookStep -RunbookStep $RunbookStep
    Replace-SPOTVarsInRunbookStepJIT -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    if (!$RunbookStep.StepParameters.CommandName -and ($validation -eq $false)) {
        Write-SPOTLog " >>> OK"
    }
    else {
        Write-SPOTLog " >>> FAILED"
    }

    ######################
    # single references in StepParameters
    Write-SPOTLog " > Testing ""single references in StepParameters"" in RunbookStep"
    $RunbookStep.Type = "PowershellCommandRemoteOWMI"
    $Runbook.RunbookParameters.TRBPar1 = "DefaultRBValue1"
    $RunbookStep.StepParameters.CommandName = "Start-UTFunction"
    $RunbookStep.StepParameters.ExecPath = "`$RP:TRBPar1"
    $RunbookStep.StepParameters.RemoteComputer = "`$OV:TestVariable"
    $RunbookStep.StepParameters.Credential = "`$SV:TestCred"
    Replace-SPOTVarsInRunbookStep -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    $validation = $null
    $validation = Validate-SPOTRunbookStep -RunbookStep $RunbookStep
    Replace-SPOTVarsInRunbookStepJIT -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    if ($validation -and ($RunbookStep.StepParameters.ExecPath -eq "DefaultRBValue1") -and ($RunbookStep.StepParameters.RemoteComputer -eq "OrchTestValue") -and ($RunbookStep.StepParameters.Credential -eq $SVars.TestCred)) {
        Write-SPOTLog " >>> OK"
    }
    else {
        Write-SPOTLog " >>> FAILED"
    }

    ######################
    # mixed references in StepParameters
    Write-SPOTLog " > Testing ""mixed references in StepParameters"" in RunbookStep"
    $RunbookStep.Type = "PowershellCommandRemoteOWMI"
    $Runbook.RunbookParameters.TRBPar1 = "DefaultRBValue1"
    $RunbookStep.StepParameters.CommandName = "Start-UTFunction"
    $RunbookStep.StepParameters.ExecPath = "`$RP:TRBPar1:`$RP_`$PV:PVar3.k1"
    $RunbookStep.StepParameters.RemoteComputer = "Prefix`$OV:TestVariable"
    $RunbookStep.StepParameters.Credential = "`$SV:TestCred"
    Replace-SPOTVarsInRunbookStep -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    $validation = $null
    $validation = Validate-SPOTRunbookStep -RunbookStep $RunbookStep
    Replace-SPOTVarsInRunbookStepJIT -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    if ($validation -and ($RunbookStep.StepParameters.ExecPath -eq "DefaultRBValue1_v1") -and ($RunbookStep.StepParameters.RemoteComputer -eq "PrefixOrchTestValue") -and ($RunbookStep.StepParameters.Credential -eq $SVars.TestCred)) {
        Write-SPOTLog " >>> OK"
    }
    else {
        Write-SPOTLog " >>> FAILED"
    }

    ######################
    # extra step parameter (to fail)
    Write-SPOTLog " > Testing ""extra step parameter"" in RunbookStep is invalidated"
    $RunbookStep.Type = "PowershellCommandRemoteOWMI"
    $RunbookStep.StepParameters.ExecPath = "C:\temp"
    $RunbookStep.StepParameters.RemoteComputer = "RemoteHostname"
    $RunbookStep.StepParameters.Credential = "`$SV:TestCred"
    $RunbookStep.StepParameters.AsSystem = $true
    Replace-SPOTVarsInRunbookStep -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    $validation = $null
    $validation = Validate-SPOTRunbookStep -RunbookStep $RunbookStep
    if ($validation -eq $false) {
        Write-SPOTLog " >>> OK"
    }
    else {
        Write-SPOTLog " >>> FAILED"
    }

    ##########
    # reset StepParameters
    $RunbookStep.StepParameters = @{CommandName = "Start-UTFunction"; CommandParameters = @{InputParameter = "UnitTestParameter"}; ExecPath = "C:\temp"; VariablesToPublish = @("InnerVariable=StepVariable","_spot_Output=StepOutput")}

    #endregion: testing runbookstep StepParameters

    #region: testing runbookstep CommandParameters

    ##############################################################
    # TESTING RUNBOOKSTEP COMMANDPARAMETERS

    ######################
    # no CommandParameters
    Write-SPOTLog " > Testing ""no CommandParameters"" in RunbookStep"
    $RunbookStep.Type = "PowershellCommandRemoteOWMI"
    $RunbookStep.StepParameters.CommandName = "Start-UTSimpleFunction"
    $RunbookStep.StepParameters.RemoteComputer = "`$OV:TestVariable"
    $RunbookStep.StepParameters.Credential = "`$SV:TestCred"
    $RunbookStep.StepParameters.CommandParameters = $null
    Replace-SPOTVarsInRunbookStep -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    $validation = $null
    $validation = Validate-SPOTRunbookStep -RunbookStep $RunbookStep
    Replace-SPOTVarsInRunbookStepJIT -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    if (!$RunbookStep.StepParameters.CommandParameters -and ($validation -eq $true)) {
        Write-SPOTLog " >>> OK"
    }
    else {
        Write-SPOTLog " >>> FAILED"
    }

    ######################
    # single reference in CommandParameter
    Write-SPOTLog " > Testing ""single reference in CommandParameter"" in RunbookStep"
    $RunbookStep.Type = "PowershellCommandRemoteOWMI"
    $Runbook.RunbookParameters  = @{TRBPar1 = "DefaultRBValue1"; TRBPar2 = "DefaultRBValue2"}
    $RunbookStep.StepParameters.CommandName = "Start-UTFunction"
    $RunbookStep.StepParameters.RemoteComputer = "`$OV:TestVariable"
    $RunbookStep.StepParameters.Credential = "`$SV:TestCred"
    $RunbookStep.StepParameters.CommandParameters = @{InputParameter = "`$PV:PVar2"; NotNeededParameter = "`$RP:TRBPar1"}
    Replace-SPOTVarsInRunbookStep -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    $validation = $null
    $validation = Validate-SPOTRunbookStep -RunbookStep $RunbookStep
    Replace-SPOTVarsInRunbookStepJIT -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    if ($validation -and ($RunbookStep.StepParameters.CommandParameters.InputParameter -eq "Two Strings") -and ($RunbookStep.StepParameters.CommandParameters.NotNeededParameter -eq "DefaultRBValue1")) {
        Write-SPOTLog " >>> OK"
    }
    else {
        Write-SPOTLog " >>> FAILED"
    }

    ######################
    # mixed references in CommandParameter
    Write-SPOTLog " > Testing ""mixed references in CommandParameter"" in RunbookStep"
    $RunbookStep.Type = "PowershellCommandRemoteOWMI"
    $Runbook.RunbookParameters  = @{TRBPar1 = "DefaultRBValue1"; TRBPar2 = "DefaultRBValue2"}
    $RunbookStep.StepParameters.CommandName = "Start-UTFunction"
    $RunbookStep.StepParameters.RemoteComputer = "`$OV:TestVariable"
    $RunbookStep.StepParameters.Credential = "`$SV:TestCred"
    $RunbookStep.StepParameters.CommandParameters = @{InputParameter = "Prefix`$PV:PVar2"; NotNeededParameter = "Prefix`$RP:TRBPar1:`$RP_and`$OV:TestVariable"}
    Replace-SPOTVarsInRunbookStep -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    $validation = $null
    $validation = Validate-SPOTRunbookStep -RunbookStep $RunbookStep
    Replace-SPOTVarsInRunbookStepJIT -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    if ($validation -and ($RunbookStep.StepParameters.CommandParameters.InputParameter -eq "PrefixTwo Strings") -and ($RunbookStep.StepParameters.CommandParameters.NotNeededParameter -eq "PrefixDefaultRBValue1_andOrchTestValue")) {
        Write-SPOTLog " >>> OK"
    }
    else {
        Write-SPOTLog " >>> FAILED"
    }

    ######################
    # extra CommandParameter (to fail)
    Write-SPOTLog " > Testing ""extra CommandParameter"" in RunbookStep rejection"
    $RunbookStep.Type = "PowershellCommandRemoteOWMI"
    $Runbook.RunbookParameters  = @{TRBPar1 = "DefaultRBValue1"; TRBPar2 = "DefaultRBValue2"}
    $RunbookStep.StepParameters.CommandName = "Start-UTFunction"
    $RunbookStep.StepParameters.RemoteComputer = "`$OV:TestVariable"
    $RunbookStep.StepParameters.Credential = "`$SV:TestCred"
    $RunbookStep.StepParameters.CommandParameters = @{InputParameter = "Prefix`$PV:PVar2"; ExtraParameter = "StaticValue"}
    Replace-SPOTVarsInRunbookStep -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    $validation = $null
    $validation = Validate-SPOTRunbookStep -RunbookStep $RunbookStep
    Replace-SPOTVarsInRunbookStepJIT -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    if ($validation -eq $false) {
        Write-SPOTLog " >>> OK >>> step validation was: $validation."
    }
    else {
        Write-SPOTLog " >>> FAILED >>> step validation was: $validation."
    }

    ######################
    # missing required CommandParameter (to fail)
    Write-SPOTLog " > Testing ""missing required CommandParameter"" in RunbookStep rejection"
    $RunbookStep.Type = "PowershellCommandRemoteOWMI"
    $Runbook.RunbookParameters  = @{TRBPar1 = "DefaultRBValue1"; TRBPar2 = "DefaultRBValue2"}
    $RunbookStep.StepParameters.CommandName = "Start-UTFunction"
    $RunbookStep.StepParameters.RemoteComputer = "`$OV:TestVariable"
    $RunbookStep.StepParameters.Credential = "`$SV:TestCred"
    $RunbookStep.StepParameters.CommandParameters = @{ NotNeededParameter = "StaticValue"}
    Replace-SPOTVarsInRunbookStep -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    $validation = $null
    $validation = Validate-SPOTRunbookStep -RunbookStep $RunbookStep
    Replace-SPOTVarsInRunbookStepJIT -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters
    if ($validation -eq $false) {
        Write-SPOTLog " >>> OK >>> step validation was: $validation."
    }
    else {
        Write-SPOTLog " >>> FAILED >>> step validation was: $validation."
    }

    # reset commandParameters
    $RunbookStep.StepParameters.CommandParameters = @{InputParameter = "UnitTestParameter"}

    #endregion: testing runbookstep CommandParameters

    Write-SPOTLog " ###> Finished runbook related unit tests."
    #endregion: perform Runbook related unit tests


    ##########################################
    # stop the runspacepool
    $_spot_MainWorkerPool.Dispose()

    #################################################
    Write-SPOTLog "===== Finished function Execute-SPOTUnitTests ====="

} $ParHashTable
