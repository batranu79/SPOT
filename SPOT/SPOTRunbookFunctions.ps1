# SPOT Runbook Functions file
# v1.0 - 26.04.2026 - initial version
# v1.1 - 17.05.2026 - added the RunbookParameters functionality in Execute-SPOTRunbook, Replace-SPOTLineVars
#                   - introduced Replace-SPOTVarsInRunbookJIT and Replace-SPOTVarsInRunbookStepJIT (just in time replace functions)
#                   - fixed single line step output in PowershellCommandRemote reported as failed
# v1.2 - 03.07.2026 - changed the error behavior of some internal functions to use throw; corrected Process-SPOTCommandParamsRF
#                   - improved the type functions to better handle step output in case of error; added Process-SPOTCommandParamsLocalRF
#                   - better error handling in Execute-SPOTRunbook, Get-SPOTRunbookJobResult and Finalize-SPOTRemoteExecution
#                     for remote runbook execution; for WMI related step types the remote powershell process has been set to hidden 
#                   - improved the custom PSSessionConfiguration handling inside the PowershellCommandRemote type function
#                   - added AsSystem for remote runbook execution with supporting ExecFunctions; 
#                   - improved PowershellCommandRemote, PowershellCommandRemoteSJ and Start-SPOTRunbookJobRemote
#                   - added support for references (including mixed strings) inside multiple VariablesToPublish entries
# v1.3 - 31.08.2026 - added support for WinRM SSL in PowershellCommandRemote and PowershellCommandRemoteSJ step types 
# 
#
#
######################################################################################################################
# Runbook Type Functions
######################################################################################################################
function PowershellCommandRemote {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the payload script/function name to be executed remotely (without extension for scripts)
        $CommandName,   
        [Parameter(Mandatory=$false)]
        [hashtable]
        # the hashtable with the parameters to the payload script/function to be executed remotely
        $CommandParameters, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the remote computer where to execute the payload script/function
        $RemoteComputer, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.Management.Automation.PSCredential]
        # the credential to connect to the remote computer
        $Credential,  
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the execution path for the payload script/function
        $ExecPath,
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [bool]
        # specify if the WinRM session should be created with SSL
        $UseSSL = $false,
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string[]]
        # the array of variable names to publish, from inside the payload script/function
        $VariablesToPublish 
        )

    # should be the most used method of remote execution; it uses only the WinRM port
    # sync method
    # main known limitation is that there is no access to the credential store (cmdkey) on the remote computer
    # but as always, credentials from the SPOT secret vault can be assigned as parameters to the step function

    ######################################
    # create the powershell object
    if ($CommandName -eq "Execute-SPOTRunbook") {
        # create an individual Runspace with all functions and variables required for Runbook executions
        $runspace = Create-SPOTRunbookRunspace
        $powershell = [powershell]::Create()
        $powershell.Runspace = $runspace
    }
    else {
        # create the pipeline inside the MainWorkerPool with all functions and variables required for RunbookStep executions
        $powershell = [powershell]::Create()
	    $powershell.RunspacePool = $_spot_MainWorkerPool
    }

    ######################################
    # prepare the pipeline parameters
    $ParamList = @{
        CommandName         = $CommandName
        CommandParameters   = $CommandParameters
        RemoteComputer      = $RemoteComputer
        Credential          = $Credential
        _spot_VTPs          = Get-SPOTVTPObjects -VariablesToPublish $VariablesToPublish
        ExecPath            = $ExecPath
        UseSSL              = $UseSSL
        _spot_PublishedData = $null
    }
    ######
    if ($VariablesToPublish -or ($CommandName -in ("Execute-SSHScript","Execute-TelnetScript"))) {
        # add the PublishedData variable only if needed to publish something or for commands that need it (otherwise it is a waste of resources)
        $ParamList._spot_PublishedData = $PublishedData
    }

    #############################################################################################
    $powershell.AddScript({
        Param (
        [string]$RemoteComputer,
        [System.Management.Automation.PSCredential]$Credential,
        [string]$CommandName,
        [object[]]$_spot_VTPs,
        [hashtable]$CommandParameters,
        [string]$ExecPath,
        [bool]$UseSSL,
        [hashtable]$_spot_PublishedData
        )

        $innerParams = @{
            RemoteComputer      = [string]$RemoteComputer
            Credential          = [System.Management.Automation.PSCredential]$Credential
            CommandName         = [string]$CommandName
            _spot_VTPs          = [object[]]$_spot_VTPs
            CommandParameters   = [hashtable]$CommandParameters
            ExecPath            = [string]$ExecPath
            UseSSL              = [bool]$UseSSL
            _spot_PublishedData = [hashtable]$_spot_PublishedData
        }
# child scope against cross bleeding of variables inside the runspacepool
& {
    Param (
    [string]$RemoteComputer,
    [System.Management.Automation.PSCredential]$Credential,
    [string]$CommandName,
    [object[]]$_spot_VTPs,
    [hashtable]$CommandParameters,
    [string]$ExecPath,
    [bool]$UseSSL,
    [hashtable]$_spot_PublishedData
    )
######################################
Write-SPOTLog " ############# ORCHESTRATOR LOGGING: Launching step function ""$CommandName"" with credential ""$($Credential.UserName)"" on remote computer ""$RemoteComputer"". #############"

######################################
# stamp all SPOT related functions inside the runspace
foreach ($funcName in $_spot_FunctionNames) {
    (Get-Command -Name $funcName -CommandType Function -ErrorAction Stop).Description = "#SPOT"
}

######################################
# set the target port depending on the UseSSL parameter
if ($UseSSL) {
    $Port = 5986
}
else {
    $Port = 5985
}

######################################
# testing the availability of the remote execution TCP port on the remote computer
$TCPTestResult = Test-SPOTTCPPort -TargetIP $RemoteComputer -TCPPort $Port
if (!($TCPTestResult.TcpTestSucceeded)) {
    Write-SPOTLog " ############# ORCHESTRATOR LOGGING: ERROR: Connecting to the WinRM port ""$Port"" on remote computer ""$RemoteComputer"" failed! Ping test result was: $($TCPTestResult.PingSucceeded). #############"
    return $false
}

######################################
# setup the remote PSSessionConfiguration to avoid "double hop" limitations
$SbSPOTConfig = {
    # get all sessions (includes the current one due to this Invoke-Command)
    $WinRMSessions = Get-WSManInstance -ResourceURI Shell -Enumerate
    # check SPOTConfig existence and usage
    $SpotConfig = Get-PSSessionConfiguration -ErrorAction SilentlyContinue | Where {$_.Name -eq "SPOTConfig"}
    if ($SpotConfig) {
        # the SPOT PSSession Config already exists
        ########################################
        # check first if the existing SPOT PSSession Config is in use
        $InUse = $false
        if ($WinRMSessions | Where {($_.ResourceUri -like "*SPOTConfig") -and ($_.State -eq "Connected")}) {
            $InUse = $true
        }
        ########################################
        # check if the same credentials are used or not 
        if ($SpotConfig.RunAsUser -ne $args[0].UserName) {
            # other credentials used in the SPOT PSSession Config
            if ($InUse) {
                # return error and stop the step as this may break a parent runbook
                throw "PowershellCommandRemote: the SPOTConfig PSSessionConfiguration is already in use with another credential!"
            }
            else {
                # before restarting the WinRM service, check if other PSSessions are connected
                if (($WinRMSessions | Where {($_.ResourceUri -like "*Microsoft.PowerShell") -and ($_.State -eq "Connected")}).Count -gt 1) {
                    # return error and stop the step as this may break a parent runbook
                    throw "PowershellCommandRemote: there is already another PSSession connected to the same target computer!"
                }
                else {
                    Unregister-PSSessionConfiguration -Name "SPOTConfig" -Force -ErrorAction SilentlyContinue | Out-Null
                    $true
                    Register-PSSessionConfiguration -Name "SPOTConfig" -RunAsCredential $args[0] -Force -ErrorAction Stop | Out-Null
                }
            }
        }
        else {
            # the same credentials are used in the SPOT PSSession Config; it can be used as is
            if ($InUse) {
                # return false to avoid deleting the already existing SPOT PSSession Config at the end
                return $false
            }
            else {
                # return true to delete the already existing SPOT PSSession Config at the end
                return $true
            }
        }
    }
    else {
        if (($WinRMSessions | Where {($_.ResourceUri -like "*Microsoft.PowerShell") -and ($_.State -eq "Connected")}).Count -gt 1) {
            # return error and stop the step as this may break a parent runbook
            throw "PowershellCommandRemote: there is already another PSSession connected to the same target computer!"
        }
        else {
            $true
            Register-PSSessionConfiguration -Name "SPOTConfig" -RunAsCredential $args[0] -Force -ErrorAction Stop | Out-Null
        }
    }
}

try {
    if ($UseSSL) {
        $CleanupSPOTConfig = Invoke-Command -ComputerName $RemoteComputer -Credential $Credential -ScriptBlock $SbSPOTConfig -ArgumentList $Credential -UseSSL
    }
    else {
        $CleanupSPOTConfig = Invoke-Command -ComputerName $RemoteComputer -Credential $Credential -ScriptBlock $SbSPOTConfig -ArgumentList $Credential
    }
}
catch {
    Write-SPOTLog ">>> ERROR while creating the SPOT PSSession Admin Config on the ""$RemoteComputer"" remote computer: $_."
    # cleanup in case of error
    if ($UseSSL) {
        Invoke-Command -ComputerName $RemoteComputer -Credential $Credential -ScriptBlock {
            Get-PSSessionConfiguration -ErrorAction SilentlyContinue | Where {$_.Name -eq "SPOTConfig"} | Unregister-PSSessionConfiguration -Force -ErrorAction SilentlyContinue
        } -UseSSL
    }
    else {
        Invoke-Command -ComputerName $RemoteComputer -Credential $Credential -ScriptBlock {
            Get-PSSessionConfiguration -ErrorAction SilentlyContinue | Where {$_.Name -eq "SPOTConfig"} | Unregister-PSSessionConfiguration -Force -ErrorAction SilentlyContinue
        }
    }
    return $false
}
Start-Sleep -Seconds 1

######################################
# create the PSSession for the current step, with connection timeout of 30 seconds
try {
    if ($UseSSL) {
        $session = New-PSSession -ComputerName $RemoteComputer -Credential $Credential -ConfigurationName "SPOTConfig" -SessionOption (New-PSSessionOption -OpenTimeout 30000) -ErrorAction Stop -UseSSL
    }
    else {
        $session = New-PSSession -ComputerName $RemoteComputer -Credential $Credential -ConfigurationName "SPOTConfig" -SessionOption (New-PSSessionOption -OpenTimeout 30000) -ErrorAction Stop
    }
}
catch {
    Write-SPOTLog ">>> ERROR while creating the PSSession to the ""$RemoteComputer"" remote computer: $_."
    # cleanup in case of error
    if ($CleanupSPOTConfig) {
        if ($UseSSL) {
            Invoke-Command -ComputerName $RemoteComputer -Credential $Credential -ScriptBlock {
                Get-PSSessionConfiguration -ErrorAction SilentlyContinue | Where {$_.Name -eq "SPOTConfig"} | Unregister-PSSessionConfiguration -Force -ErrorAction SilentlyContinue
            } -UseSSL
        }
        else {
            Invoke-Command -ComputerName $RemoteComputer -Credential $Credential -ScriptBlock {
                Get-PSSessionConfiguration -ErrorAction SilentlyContinue | Where {$_.Name -eq "SPOTConfig"} | Unregister-PSSessionConfiguration -Force -ErrorAction SilentlyContinue
            }
        }
    }
    return $false
}

######################################
if ($CommandParameters) {
    # there are command parameters defined; checking for $RFI or $RFO (file variables) and managing the file/folder transfer to the target computer
    try {
        $CmdParametersRF = Process-SPOTCommandParamsRF -CommandParameters $CommandParameters -PSSession $session
    }
    catch {
        Write-SPOTLog ">>> T.ERROR while processing Referenced Files/Folders on the ""$RemoteComputer"" remote computer: $_."
        # cleanup in case of error
        Remove-PSSession -Session $session -Confirm:$false -ErrorAction SilentlyContinue
        if ($CleanupSPOTConfig) {
            if ($UseSSL) {
                Invoke-Command -ComputerName $RemoteComputer -Credential $Credential -ScriptBlock {
                    Get-PSSessionConfiguration -ErrorAction SilentlyContinue | Where {$_.Name -eq "SPOTConfig"} | Unregister-PSSessionConfiguration -Force -ErrorAction SilentlyContinue
                } -UseSSL
            }
            else {
                Invoke-Command -ComputerName $RemoteComputer -Credential $Credential -ScriptBlock {
                    Get-PSSessionConfiguration -ErrorAction SilentlyContinue | Where {$_.Name -eq "SPOTConfig"} | Unregister-PSSessionConfiguration -Force -ErrorAction SilentlyContinue
                }
            }
        }
        return $false
    }
    $RemoteTempFiles   = $CmdParametersRF.RemoteTempFiles
    $RemoteTempFolders = $CmdParametersRF.RemoteTempFolders
    $CommandParameters = $CmdParametersRF.CommandParameters
}

######################################
# prepare the objects needed remote in a hashtable
$RemoteObjects = @{
    CommandName       = $CommandName
    CommandParameters = $CommandParameters
    OrchVars          = $OrchVars
    ExecPath          = $ExecPath
    SPOTFunctions     = Get-Command | Where {$_.Name -in $_spot_FunctionNames}
    _spot_VTPs        = $_spot_VTPs
}

######################################
# prepare the PSSession before step execution
try {
    Invoke-Command -Session $session -ScriptBlock {
        ###################
        # make the OrchVars available
        $OrchVars = $args[0].OrchVars
        ###################
        # set the execution path
        if ($args[0].ExecPath) {
            if (Test-Path -Path $args[0].ExecPath -PathType Container -ErrorAction SilentlyContinue) {
                Write-Output " ############# ORCHESTRATOR LOGGING: The configured execution path was found. Setting it now. #############"
                Push-Location -Path $args[0].ExecPath -ErrorAction SilentlyContinue
            }
            else {
                Write-Output " ############# ORCHESTRATOR LOGGING: WARNING: The configured execution path was not found. Continuing execution as is. #############"
            }
        }
        ###################
        # inject SPOT Functions
        foreach ($_spot_cmd in $args[0].SPOTFunctions) {
            Set-Item "Function:$($_spot_cmd.Name)" $_spot_cmd.ScriptBlock 
            # stamp the SPOT functions also remotely
            (Get-Command -Name $_spot_cmd.Name -CommandType Function -ErrorAction Stop).Description = "#SPOT"
        }
        ###################
        # overwrite the SPOT Host functions
        $_spot_HostFunctions = [scriptblock]::Create([System.Text.Encoding]::UTF8.GetString([convert]::FromBase64String($OrchVars._SPOTHostFunctions)))
        . $_spot_HostFunctions
        ###################
        # make the VTP objects available
        $_spot_VTPs = $args[0]._spot_VTPs
        ###################
        # make the CommandName and CommandParameters available
        $_spot_Cmd = $args[0].CommandName
        $_spot_CmdP = $args[0].CommandParameters
        ###################
        # prepare the step function to intercept exit statements
        Set-Item "Function:$_spot_Cmd" "$(Replace-SPOTExitInCode -code (Get-Command -Name $_spot_Cmd | Select-Object -ExpandProperty Definition))"

    } -ArgumentList $RemoteObjects
}
catch {
    Write-SPOTLog ">>> T.ERROR while preparing the PSSession to the ""$RemoteComputer"" remote computer: $_."
    # cleanup in case of error
    Remove-PSSession -Session $session -Confirm:$false -ErrorAction SilentlyContinue
    if ($CleanupSPOTConfig) {
        if ($UseSSL) {
            Invoke-Command -ComputerName $RemoteComputer -Credential $Credential -ScriptBlock {
                Get-PSSessionConfiguration -ErrorAction SilentlyContinue | Where {$_.Name -eq "SPOTConfig"} | Unregister-PSSessionConfiguration -Force -ErrorAction SilentlyContinue
            } -UseSSL
        }
        else {
            Invoke-Command -ComputerName $RemoteComputer -Credential $Credential -ScriptBlock {
                Get-PSSessionConfiguration -ErrorAction SilentlyContinue | Where {$_.Name -eq "SPOTConfig"} | Unregister-PSSessionConfiguration -Force -ErrorAction SilentlyContinue
            }
        }
    }
    return $false
}

######################
$PCROutput = Invoke-Command -Session $session -ScriptBlock {
    $_spot_TWOE = $true
    $_spot_Output = @()
    try {
        $_spot_Output += . $_spot_Cmd @_spot_CmdP *>&1 | Out-String -Stream -OutVariable _spot_SO
    }
    catch {
        $_spot_SO = @($_spot_SO)
        $_spot_SO += "############# ORCHESTRATOR LOGGING: TERMINATING ERROR while trying to execute the command ""$_spot_Cmd"" remotely. #############"
        # error handling depending on where the error was caught
        if (($_.ScriptStackTrace -split "`n").Count -eq 1) {
            # error encountered inside the SPOT tool (this case should not appear since the try is for the step function only)
            $_spot_SO += " >>>>>> ERROR encountered inside the SPOT tool function ""PowershellCommandRemote""."
        }
        elseif (($_.ScriptStackTrace -split "`n").Count -eq 2) {
            $_spot_SO += " >>>>>> ERROR encountered inside the step function ""$_spot_Cmd""."
        }
        else {
            $_spot_SO += " >>>>>> ERROR encountered inside a script/function called in the step function ""$_spot_Cmd""."
            $_spot_SO += " >>>>>> ERROR ScriptStackTrace from the step function inward:"
            $_spot_SO += ($_.ScriptStackTrace -split "`n")[0..(($_.ScriptStackTrace -split "`n").Count-2)]
            # get the number of the line from the step function where the error occured
            $_spot_ln = (($_.ScriptStackTrace -split "`n")[($_.ScriptStackTrace -split "`n").Count-2] -split "line")[1].Trim()
            # use the line number from above to show the actual step function line
            $_spot_SO += " >>>>>> ERROR Line in the step function:"
            $_spot_SO += "$(((Get-Command -Name $_spot_Cmd | Select-Object -ExpandProperty Definition | Out-String -Width 250) -split '\r?\n')[$_spot_ln-1])"
        }
        # common error details
        $_spot_SO += " >>>>>> ERROR Exception:"
        $_spot_SO += "$($_.Exception)"
        $_spot_SO += " >>>>>> ERROR Exception Type:"
        $_spot_SO += "$($_.Exception.GetType().FullName)"
        $_spot_SO += " >>>>>> ERROR InvocationInfo.Line:"
        $_spot_SO += "$($_.InvocationInfo.Line)"
        $_spot_SO += " >>>>>> ERROR InvocationInfo.PositionMessage:"
        $_spot_SO += "$($_.InvocationInfo.PositionMessage)"
        # in case of exception, the normal output is empty, so we use the stream output in its place
        $_spot_Output = $_spot_SO
        $_spot_TWOE = $false
    }

    ######################################
    if ($_spot_TWOE) {
        # signal the execution as successful unless there was a terminating error
        $_spot_Output += $true
    }
    else {
        # signal the execution as failed because there was a terminating error
        $_spot_Output += $false
    }

    # return the results
    $_spot_Output
}

######################
if (!$PCROutput) {
    Write-SPOTLog " ############# ORCHESTRATOR LOGGING: ERROR: no output from ""$RemoteComputer""! PSSession state: $($session.State). Continuing with cleanup. #############"
    $PCROutput = $false
}

######################################
# capturing now the variables declared for publish, if they are available
if ($_spot_VTPs) {
    # capture remotely the variable values remotely; place them in the $_spot_VTPs array; make them available locally with overwrite
    $_spot_VTPs = Invoke-Command -Session $session -ErrorAction SilentlyContinue -ScriptBlock {
        foreach ($_spot_i in $_spot_VTPs) {
            $_spot_i.VarValue = Get-Variable -Name $_spot_i.VarName -ErrorAction SilentlyContinue -ValueOnly
        }
        $_spot_VTPs
    }
    # publish all captured variables locally
    foreach ($_spot_i in $_spot_VTPs) {
        $_spot_PublishedData.($_spot_i.VarNewName) = $_spot_i.VarValue
    }
}

######################################
# cleanup at the end
foreach ($rf in $RemoteTempFiles) {
    Invoke-Command -Session $session -ScriptBlock {
        Set-Content -Path $args[0] -Value "0000" -Confirm:$false -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $args[0] -Confirm:$false -Force -ErrorAction SilentlyContinue
    } -ArgumentList $rf
}
foreach ($rf in $RemoteTempFolders) {
    Invoke-Command -Session $session -ScriptBlock {
        Remove-Item -Path $args[0] -Recurse -Confirm:$false -Force -ErrorAction SilentlyContinue
    } -ArgumentList $rf
}
Remove-PSSession -Session $session -Confirm:$false
if ($CleanupSPOTConfig) {
    if ($UseSSL) {
        Invoke-Command -ComputerName $RemoteComputer -Credential $Credential -ScriptBlock {
            Get-PSSessionConfiguration -ErrorAction SilentlyContinue | Where {$_.Name -eq "SPOTConfig"} | Unregister-PSSessionConfiguration -Force -ErrorAction SilentlyContinue
        } -UseSSL
    }
    else {
        Invoke-Command -ComputerName $RemoteComputer -Credential $Credential -ScriptBlock {
            Get-PSSessionConfiguration -ErrorAction SilentlyContinue | Where {$_.Name -eq "SPOTConfig"} | Unregister-PSSessionConfiguration -Force -ErrorAction SilentlyContinue
        }
    }
}

######################################
Write-SPOTLog " ############# ORCHESTRATOR LOGGING: Finished step function ""$CommandName"" on remote computer ""$RemoteComputer"". Command output below. #############"
$PCROutput
} @innerParams
# cleanup of used parameters
$RemoteComputer      = $null
$Credential          = $null
$CommandName         = $null
$_spot_VTPs          = $null
$CommandParameters   = $null
$ExecPath            = $null
$UseSSL              = $null
$_spot_PublishedData = $null
$innerParams         = $null
$Error.Clear()
}).AddParameters($ParamList) | Out-Null
    
    # start the runspace objects
    $handle = $powershell.BeginInvoke()
    $return = @{}
    $return.Target = $null
    $return.GUID = $null
    $return.Name = $null
    $return.Type = $null
    $return.Processed = $null

    $return.handle = $handle
    $return.powershell = $powershell
    $returnObject = [pscustomobject]$return

    # return the Job object (runspace objects + some metadata)
    return $returnObject

} # end of PowershellCommandRemote function

######################################################################################################################
function PowershellCommandLocal {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the payload script/function name to be executed locally inside a runspace (without extension for scripts)
        $CommandName, 
        [Parameter(Mandatory=$false)]
        [hashtable]
        # the hashtable with the parameters to the payload script/function to be executed locally inside a runspace
        $CommandParameters,  
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the execution path for the payload script/function
        $ExecPath, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string[]]
        # the array of variable names to publish, from inside the payload script/function
        $VariablesToPublish 
        )
        
    ######################################
    # create the powershell object; for local steps this is alwats an individual runspace, to avoid bleeding of variables between pool pipelines
    if ($CommandName -eq "Execute-SPOTRunbook") {
        # create an individual Runspace with all functions and variables required for Runbook executions
        $runspace = Create-SPOTRunbookRunspace
        # include the MainWorkerPool object only for local runbook executions; for remote runbook execution the pool needs to be created from scratch
        $runspace.SessionStateProxy.SetVariable('_spot_MainWorkerPool',$_spot_MainWorkerPool)
        $powershell = [powershell]::Create()
        $powershell.Runspace = $runspace
    }
    else {
        # create an individual Runspace with all functions and variables required for RunbookStep executions
        $runspace = Create-SPOTRunbookStepRunspace
        $powershell = [powershell]::Create()
	    $powershell.Runspace = $runspace
    }

    ######################################
    # prepare the pipeline parameters
    $ParamList = @{
        _spot_CommandName        = $CommandName
        _spot_VTPs               = Get-SPOTVTPObjects -VariablesToPublish $VariablesToPublish
        _spot_CmdP               = $CommandParameters
        _spot_ExecPath           = $ExecPath
        _spot_PublishedData      = $PublishedData
    }

    #############################################################################################
    $powershell.AddScript({
        Param (
        [string]$_spot_CommandName,
        [hashtable]$_spot_CmdP,
        [string]$_spot_ExecPath,
        [object[]]$_spot_VTPs,
        [hashtable]$_spot_PublishedData
        )

    $_spot_innerParams = @{
            _spot_CommandName   = [string]$_spot_CommandName
            _spot_CmdP          = [hashtable]$_spot_CmdP
            _spot_ExecPath      = [string]$_spot_ExecPath
            _spot_VTPs          = [object[]]$_spot_VTPs
            _spot_PublishedData = [hashtable]$_spot_PublishedData
        }
# child scope against cross bleeding of variables inside the runspacepool
& {
    Param (
    [string]$_spot_CommandName,
    [hashtable]$_spot_CmdP,
    [string]$_spot_ExecPath,
    [object[]]$_spot_VTPs,
    [hashtable]$_spot_PublishedData
    )
######################################
Write-SPOTLog " ############# ORCHESTRATOR LOGGING: Launching step function ""$_spot_CommandName"" on local computer. #############"

######################################
# stamp all SPOT related frunctions inside the runspace
foreach ($_spot_cmd in $_spot_FunctionNames) {
    (Get-Command -Name $_spot_cmd -CommandType Function -ErrorAction Stop).Description = "#SPOT"
}

######################################
# try to use the ExecPath, if defined
if ($_spot_ExecPath) {
    if (Test-Path -Path $_spot_ExecPath -PathType Container -ErrorAction SilentlyContinue) {
        Write-SPOTLog " ############# ORCHESTRATOR LOGGING: The configured execution path was found. Setting it now. #############"
        Push-Location -Path $_spot_ExecPath -ErrorAction SilentlyContinue
    }
    else {
        Write-SPOTLog " ############# ORCHESTRATOR LOGGING: WARNING: The configured execution path was not found. Continuing execution as is. #############"
    }
}

######################################
# overwrite the Host related functions
$_spot_HostFunctions = [scriptblock]::Create([System.Text.Encoding]::UTF8.GetString([convert]::FromBase64String($OrchVars._SPOTHostFunctions)))
. $_spot_HostFunctions

######################################
# manage $RFI and $RFO parameters, if any
if ($_spot_CmdP) {
    # there are command parameters defined; checking for $RFI or $RFO (file variables) and managing the file/folder local path
    try {
        Process-SPOTCommandParamsLocalRF -CommandParameters $_spot_CmdP
    }
    catch {
        Write-SPOTLog ">>> T.ERROR while processing Referenced Files/Folders locally: $_."
        return $false
    }
}

######################################
# execute the payload
$_spot_TWOE = $true
$_spot_Output = @()
Set-Item "Function:$_spot_CommandName" "$(Replace-SPOTExitInCode -code (Get-Command -Name $_spot_CommandName | Select-Object -ExpandProperty Definition))"
try {
    # calling the function with dot source, to be able to get variables from inside the function
    $_spot_Output += . $_spot_CommandName @_spot_CmdP *>&1 | Out-String -Stream -OutVariable _spot_SO    
}
catch {
    $_spot_SO = @($_spot_SO)
    $_spot_SO += "############# ORCHESTRATOR LOGGING: TERMINATING ERROR while trying to execute the step function ""$_spot_CommandName"" locally. #############"
    # error handling depending on where the error was caught
    if (($_.ScriptStackTrace -split "`n").Count -le 2) {
        # error encountered inside the SPOT tool (this case should not appear since the try is for the step function only)
        $_spot_SO += " >>>>>> ERROR encountered inside the SPOT tool function ""PowershellCommandLocal""."
    }
    elseif (($_.ScriptStackTrace -split "`n").Count -eq 3) {
        $_spot_SO += " >>>>>> ERROR encountered inside the step function ""$_spot_CommandName""."
    }
    else {
        $_spot_SO += " >>>>>> ERROR encountered inside a script/function called in the step function ""$_spot_CommandName""."
        $_spot_SO += " >>>>>> ERROR ScriptStackTrace from the step function inward:"
        $_spot_SO += ($_.ScriptStackTrace -split "`n")[0..(($_.ScriptStackTrace -split "`n").Count-3)]
        # get the number of the line from the step function where the error occured
        $_spot_ln = (($_.ScriptStackTrace -split "`n")[($_.ScriptStackTrace -split "`n").Count-3] -split "line")[1].Trim()
        # use the line number from above to show the actual step function line
        $_spot_SO += " >>>>>> ERROR Line in the step function:"
        $_spot_SO += "$(((Get-Command -Name $_spot_CommandName | Select-Object -ExpandProperty Definition | Out-String -Width 250) -split '\r?\n')[$_spot_ln-1])"
    }
    # common error details
    $_spot_SO += " >>>>>> ERROR Exception:"
    $_spot_SO += "$($_.Exception)"
    $_spot_SO += " >>>>>> ERROR Exception Type:"
    $_spot_SO += "$($_.Exception.GetType().FullName)"
    $_spot_SO += " >>>>>> ERROR InvocationInfo.Line:"
    $_spot_SO += "$($_.InvocationInfo.Line)"
    $_spot_SO += " >>>>>> ERROR InvocationInfo.PositionMessage:"
    $_spot_SO += "$($_.InvocationInfo.PositionMessage)"
    # in case of exception, the normal output is empty, so we use the stream output in its place
    $_spot_Output = $_spot_SO
    $_spot_TWOE = $false
}

######################################
if ($_spot_TWOE) {
    # signal the execution as successful unless there was a terminating error
    $_spot_Output += $true
}
else {
    # signal the execution as failed because there was a terminating error
    $_spot_Output += $false
}

######################################
# capturing/publishing now the variables declared for publish
if ($_spot_VTPs) {
    foreach ($_spot_i in $_spot_VTPs) {
        $_spot_PublishedData.($_spot_i.VarNewName) = Get-Variable -Name $_spot_i.VarName -ErrorAction SilentlyContinue -ValueOnly
    }
}

######################################
Write-SPOTLog " ############# ORCHESTRATOR LOGGING: Finished step function ""$_spot_CommandName"" on local computer. Command output below. #############"
$_spot_Output
} @_spot_innerParams
# cleanup of used parameters
$_spot_CommandName   = $null
$_spot_CmdP          = $null
$_spot_ExecPath      = $null
$_spot_VTPs          = $null
$_spot_PublishedData = $null
$_spot_innerParams   = $null
$Error.Clear()

}).AddParameters($ParamList) | Out-Null
    
    # start the runspace objects
    $handle = $powershell.BeginInvoke()
    $return = @{}
    $return.GUID = $null
    $return.Name = $null
    $return.Type = $null
    $return.Processed = $null

    $return.handle = $handle
    $return.powershell = $powershell
    $returnObject = [pscustomobject]$return

    # return the Job object (runspace objects + some metadata)
    return $returnObject

} # end of PowershellCommandLocal function

######################################################################################################################
function PowershellCommandRemoteSJ {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the payload script/function name to be executed remotely (without extension for scripts)
        $CommandName, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [hashtable]
        # the hashtable with the parameters to the payload script/function to be executed remotely
        $CommandParameters, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the remote computer where to execute the payload script/function
        $RemoteComputer, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [PSCredential]
        # the credential to connect to the remote computer
        $Credential, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the execution path for the payload script/function
        $ExecPath, 
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [PSCredential]
        # specify if the payload script/function is to be executed as another user on the target computer
        $AsUser, 
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [bool]
        # specify if the payload script/function is to be executed as local system on the target computer
        $AsSystem = $false,
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [bool]
        # specify if the WinRM session should be created with SSL
        $UseSSL = $false,
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string[]]
        # the array of variable names to publish, from inside the payload script/function
        $VariablesToPublish 
        )
    
    # execution option for cases when the pure WinRM (PSRemoting/PSSession) method has issues; it uses only the WinRM port
    # running as the local system is possible
    # running as different user than the one used for the remote connection is possible
    # async method

    ######################################
    # create the powershell object
    if ($CommandName -eq "Execute-SPOTRunbook") {
        # create an individual Runspace with all functions and variables required for Runbook executions
        $runspace = Create-SPOTRunbookRunspace
        $powershell = [powershell]::Create()
        $powershell.Runspace = $runspace
    }
    else {
        # create the pipeline inside the MainWorkerPool with all functions and variables required for RunbookStep executions
        $powershell = [powershell]::Create()
	    $powershell.RunspacePool = $_spot_MainWorkerPool
    }

    ######################################
    # define random CompKey for secrets handling
    # e.g. C:\Users\%username%\AppData\Local\Microsoft\Windows\PowerShell\ScheduledJobs
    # it is generated now as it is needed to prepare the objects with the variables, functions and parameters
    $CompKey = "$(-join (((48..57)+(97..122)) * 80 | Get-Random -Count 32 |%{[char]$_}))"

    ##########################################################
    # prepare the parameters object for passing to the Execute-SPOTScheduledJob function inside the remote session
    $ArgumentList = @{
        OrchVars           = Decompose-SPOTHashTableVariable -InputVariable $OrchVars -Key $CompKey
        Command            = $CommandName
        CommandParameters  = Decompose-SPOTHashTableVariable -InputVariable $CommandParameters -Key $CompKey
        ExecPath           = $ExecPath
        _spot_VTPs         = Get-SPOTVTPObjects -VariablesToPublish $VariablesToPublish
    }
    
    # prepare the scriptblock
    $ScriptBlock = {
        ######################################
        # initialize the ScriptBlock output variable
        $_spot_SBO = @()

        ######################################
        # inject functions
        $_spot_SBO += ">>> $(Get-Date) Injecting functions."
        foreach ($_spot_cmd in $args.Functions) {
            Set-Item "Function:$($_spot_cmd.Name)" $_spot_cmd.ScriptBlock
            (Get-Command -Name $_spot_cmd.Name -CommandType Function -ErrorAction Stop).Description = "#SPOT"
        }

        ######################################
        # get the key from the environment variables
        $_spot_SBO += ">>> $(Get-Date) Getting the CompKey."
        $_spot_CmpK = [System.Environment]::GetEnvironmentVariable('SPOTCompKey','Machine')
        if (!$_spot_CmpK) {
            $_spot_SBO += ">>>  $(Get-Date) ERROR: CompKey not aquired from Environment Variable. Cannot continue."
            $_spot_SBO += $false
            $_spot_OutH = @{
                Output = $_spot_SBO
                PublishedVariables = ""
            }
            return [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([management.automation.psserializer]::Serialize($_spot_OutH)))
        }

        ######################################
        # recompose orchvars and others
        $OrchVars = Recompose-SPOTHashTableVariable -InputVariable $args.OrchVars -Key $_spot_CmpK
        # recompose parameters, if any
        if ($args.CommandParameters) {
            $_spot_cmdP = Recompose-SPOTHashTableVariable -InputVariable $args.CommandParameters -Key $_spot_CmpK
        }

        ######################################
        # try to use the ExecPath, if defined
        if ($args.ExecPath) {
            if (Test-Path -Path $args.ExecPath -PathType Container -ErrorAction SilentlyContinue) {
                $_spot_SBO += ">>> $(Get-Date) The configured execution path was found. Setting it now."
                Push-Location -Path $args.ExecPath -ErrorAction SilentlyContinue
            }
            else {
                $_spot_SBO += ">>> $(Get-Date) WARNING: The configured execution path was not found. Continuing execution as is."
            }
        }

        ######################################
        # overwrite the Host related functions
        $_spot_HostFunctions = [scriptblock]::Create([System.Text.Encoding]::UTF8.GetString([convert]::FromBase64String($OrchVars._SPOTHostFunctions)))
        . $_spot_HostFunctions

        ######################################
        # execute the desired command
        $_spot_SBO += ">>> $(Get-Date) Executing target function."
        $_spot_VTPs = $args._spot_VTPs
        $_spot_TWOE = $true
        $_spot_Output = @()
        Set-Item "Function:$($args.Command)" "$(Replace-SPOTExitInCode -code (Get-Command -Name $args.Command | Select-Object -ExpandProperty Definition))"
        try {
            $_spot_Output += . $args.Command @_spot_cmdP *>&1 | Out-String -Stream -OutVariable _spot_SO 
        }
        catch {
            $_spot_SO = @($_spot_SO)
            $_spot_SO += "############# ORCHESTRATOR LOGGING: TERMINATING ERROR while trying to execute the step function ""$($args.Command)"" using ScheduledJob. #############"
            # error handling depending on where the error was caught
            if (($_.ScriptStackTrace -split "`n").Count -le 2) {
                # error encountered inside the SPOT tool (this case should not appear since the try is for the step function only)
                $_spot_SO += " >>>>>> ERROR encountered inside the SPOT tool function ""PowershellCommandRemoteSJ""."
            }
            elseif (($_.ScriptStackTrace -split "`n").Count -eq 3) {
                $_spot_SO += " >>>>>> ERROR encountered inside the step function ""$($args.Command)""."
            }
            else {
                $_spot_SO += " >>>>>> ERROR encountered inside a script/function called in the step function ""$($args.Command)""."
                $_spot_SO += " >>>>>> ERROR ScriptStackTrace from the step function inward:"
                $_spot_SO += ($_.ScriptStackTrace -split "`n")[0..(($_.ScriptStackTrace -split "`n").Count-3)]
                # get the number of the line from the step function where the error occured
                $_spot_ln = (($_.ScriptStackTrace -split "`n")[($_.ScriptStackTrace -split "`n").Count-3] -split "line")[1].Trim()
                # use the line number from above to show the actual step function line
                $_spot_SO += " >>>>>> ERROR Line in the step function:"
                $_spot_SO += "$(((Get-Command -Name $args.Command | Select-Object -ExpandProperty Definition | Out-String -Width 250) -split '\r?\n')[$_spot_ln-1])"
            }
            # common error details
            $_spot_SO += " >>>>>> ERROR Exception:"
            $_spot_SO += "$($_.Exception)"
            $_spot_SO += " >>>>>> ERROR Exception Type:"
            $_spot_SO += "$($_.Exception.GetType().FullName)"
            $_spot_SO += " >>>>>> ERROR InvocationInfo.Line:"
            $_spot_SO += "$($_.InvocationInfo.Line)"
            $_spot_SO += " >>>>>> ERROR InvocationInfo.PositionMessage:"
            $_spot_SO += "$($_.InvocationInfo.PositionMessage)"
            # in case of exception, the normal output is empty, so we use the stream output in its place
            $_spot_Output = $_spot_SO
            $_spot_TWOE = $false
        }

        ######################################
        if ($_spot_TWOE) {
            # signal the execution as successful unless there was a terminating error
            $_spot_Output += $true
        }
        else {
            # signal the execution as failed because there was a terminating error
            $_spot_Output += $false
        }

        ######################################
        # capturing now the variables declared for publish
        if ($_spot_VTPs) {
            $_spot_PVs = @{}
            foreach ($_spot_i in $_spot_VTPs) {
                $_spot_PVs.($_spot_i.VarNewName) = Get-Variable -Name $_spot_i.VarName -ErrorAction SilentlyContinue -ValueOnly
            }
        }

        ######################################
        # prepare the output object
        $_spot_SBO += ">>> $(Get-Date) Payload was executed. Payload output below.`n####################################################"
        # include the SBOutput before the payload output
        $_spot_SBO += $_spot_Output
        $_spot_OutH = @{
            Output = $_spot_SBO
            PublishedVariables = $_spot_PVs
        }
        # return the serialized output and published variables
        [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([management.automation.psserializer]::Serialize($_spot_OutH)))
    }

    $STParameters = @{
        ScriptBlock = $ScriptBlock
        ArgumentList = $ArgumentList
    }
    if ($AsSystem) {
        $STParameters += @{
            AsSystem = $true
        }
    }
    if ($AsUser) {
        $STParameters += @{
            AsUser = $AsUser
        }
    }

    # preparing the ParamList to be passed to the runspace and then to the remote PSSession
    $ParamList = @{
        RemoteComputer      = $RemoteComputer
        UseSSL              = $UseSSL
        Credential          = $Credential
        CompKey             = $CompKey
        STParameters        = $STParameters
        _spot_PublishedData = $null
    }
    ######
    if ($VariablesToPublish -or ($CommandName -in ("Execute-SSHScript","Execute-TelnetScript"))) {
        # add the PublishedData variable only if needed to publish something or for commands that need it (otherwise it is a waste of resources)
        $ParamList._spot_PublishedData = $PublishedData
    }

    #############################################################################################
    # start to define what happens inside runspace
    $powershell.AddScript({
        Param (
        [string]$RemoteComputer,
        [System.Management.Automation.PSCredential]$Credential,
        [hashtable]$STParameters,
        [string]$CompKey,
        [bool]$UseSSL,
        [hashtable]$_spot_PublishedData
        )

        $innerParams = @{
            RemoteComputer      = [string]$RemoteComputer
            Credential          = [System.Management.Automation.PSCredential]$Credential
            STParameters        = [hashtable]$STParameters
            CompKey             = [string]$CompKey
            UseSSL              = [bool]$UseSSL
            _spot_PublishedData = [hashtable]$_spot_PublishedData
        }
# child scope against cross bleeding of variables inside the runspacepool
& {
    Param (
    [string]$RemoteComputer,
    [System.Management.Automation.PSCredential]$Credential,
    [hashtable]$STParameters,
    [string]$CompKey,
    [bool]$UseSSL,
    [hashtable]$_spot_PublishedData
    )

######################################
Write-SPOTLog " ############# ORCHESTRATOR LOGGING: Launching step function ""$($STParameters.ArgumentList.Command)"" with credential ""$($Credential.UserName)"" on remote computer ""$RemoteComputer"" using ScheduledJob. #############"

######################################
# stamp all SPOT related frunctions inside the runspace
foreach ($funcName in $_spot_FunctionNames) {
    (Get-Command -Name $funcName -CommandType Function -ErrorAction Stop).Description = "#SPOT"
}

######################################
# set the target port depending on the UseSSL parameter
if ($UseSSL) {
    $Port = 5986
}
else {
    $Port = 5985
}

######################################
# testing the availability of the remote execution TCP port on the remote computer
$TCPTestResult = Test-SPOTTCPPort -TargetIP $RemoteComputer -TCPPort $Port
if (!($TCPTestResult.TcpTestSucceeded)) {
    Write-SPOTLog " ############# ORCHESTRATOR LOGGING: ERROR: Connecting to the WinRM port ""$Port"" on remote computer ""$RemoteComputer"" failed! Ping test result was: $($TCPTestResult.PingSucceeded). #############"
    return $false
}

######################################
# open the normal PSSession, with a connection timeout of 30 seconds
try {
    if ($UseSSL) {
        $session = New-PSSession -ComputerName $RemoteComputer -Credential $Credential -SessionOption (New-PSSessionOption -OpenTimeout 30000) -ErrorAction Stop -UseSSL
    }
    else {
        $session = New-PSSession -ComputerName $RemoteComputer -Credential $Credential -SessionOption (New-PSSessionOption -OpenTimeout 30000) -ErrorAction Stop
    }
}
catch {
    Write-SPOTLog " >>> T.ERROR while creating PSSession to the ""$RemoteComputer"" remote computer: $_."
    return $false
}

######################################
# inject the needed functions in the pssession (the step function and its dependencies go directly into the ScheduledJos as a parameter)
try {
    Invoke-Command -Session $session -ScriptBlock {
        foreach ($command in $args) {
            $ssb = $command | Select-Object -ExpandProperty ScriptBlock 
            $sb = [ScriptBlock]::Create($ssb)
            Set-Item "Function:$($command.Name)" $sb 
            (Get-Command -Name $command.Name -CommandType Function -ErrorAction Stop).Description = "#SPOT"
        }
    } -ArgumentList (Get-Command | Where {$_.Name -in ("Execute-SPOTScheduledJob","Write-SPOTLog")})
}
catch {
    Write-SPOTLog ">>> T.ERROR while loading PSSession functions to the ""$RemoteComputer"" remote computer: $_."
    # cleanup
    Remove-PSSession -Session $session -Confirm:$false
    return $false
}

######################################
# prestage inside the remote computer the ComKey used for Recomposition of the variables and parameters
# use the machine store as the user executing the step function may be different than the one connecting remotely
Invoke-Command -Session $session -ScriptBlock {[System.Environment]::SetEnvironmentVariable('SPOTCompKey',$args,'Machine')} -ArgumentList $CompKey

######################################
# check if referenced file paths are present inside the command parameters
if ($STParameters.ArgumentList.CommandParameters) {
    # there are command parameters defined; checking for $RFI or $RFO (file variables) and managing the file/folder transfer to the target computer
    try {
        $CmdParametersRF = Process-SPOTCommandParamsRF -CommandParameters $STParameters.ArgumentList.CommandParameters -PSSession $session
    }
    catch {
        Write-SPOTLog ">>> T.ERROR while processing Referenced Files/Folders on the ""$RemoteComputer"" remote computer: $_."
        # cleanup
        Remove-PSSession -Session $session -Confirm:$false
        return $false
    }
    $RemoteTempFiles   = $CmdParametersRF.RemoteTempFiles
    $RemoteTempFolders = $CmdParametersRF.RemoteTempFolders
    $STParameters.ArgumentList.CommandParameters = $CmdParametersRF.CommandParameters
}

######################################
# inject the SPOT functions in the remote ScheduledJob
$STParameters.ArgumentList.Functions = Get-Command | Where {$_.Name -in $_spot_FunctionNames}

######################################
# make the OrchVars hashtable available remotely using a copy
Invoke-Command -Session $session -ScriptBlock {
    $OrchVars = $args[0]
} -ArgumentList $OrchVars

######################################
# launch the ScheduledJob in the PSSession
try {
    Invoke-Command -Session $session -ArgumentList $STParameters -ScriptBlock { 
        # set as parameters the first object from the argumentlist; it should only be one hashtable
        $IST = $args[0]
        # convert back to ScriptBlock part to Scriptblock, after it has been deserialized to string by the scheduled task/job processing
        $IST.ScriptBlock = [ScriptBlock]::Create($IST.ScriptBlock)
        # call the function to use Scheduled Job
        . Execute-SPOTScheduledJob @IST
    }
}
catch {
    Write-SPOTLog ">>> T.ERROR while executing SPOTScheduledJob on the ""$RemoteComputer"" remote computer: $_."
    return $false
}

######################################
# extract the ScheduledJob output from the remote session as an encoded string
$SJOutput = Invoke-Command -Session $session -ScriptBlock {$_spot_SJOutput}

##############################
# process the output hashtable from the ScheduledJob output 
$returnOutput = $null

if ($SJOutput) {
    ##############################
    # decode OutputHash 
    try {
        $OH = [System.Management.Automation.PSSerializer]::Deserialize([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($SJOutput)))
    }
    catch {
        Write-SPOTLog "ERROR while trying to deserialize the OutputHash: $_."
    }
    ######################################
    # handling the Published Variables
    if ($STParameters.ArgumentList._spot_VTPs) {
        foreach ($entry in $OH.PublishedVariables.GetEnumerator()) {
            $_spot_PublishedData.($entry.Name) = $entry.Value
        }
    }
    $returnOutput = $OH.Output
}
else {
    Write-SPOTLog " ############# ORCHESTRATOR LOGGING: ERROR: no output from ""$RemoteComputer""! PSSession state: $($session.State). Continuing with cleanup. #############"
    $returnOutput = $false
}

######################################
# delete the temporary environment variable
Invoke-Command -Session $session -ScriptBlock {[System.Environment]::SetEnvironmentVariable('SPOTCompKey',$null, 'Machine')}

######################################
# cleanup at the end
foreach ($rf in $RemoteTempFiles) {
    Invoke-Command -Session $session -ScriptBlock {
        Set-Content -Path $args[0] -Value "0000" -Confirm:$false -Force
        Remove-Item -Path $args[0] -Confirm:$false -Force
    } -ArgumentList $rf
}
foreach ($rf in $RemoteTempFolders) {
    Invoke-Command -Session $session -ScriptBlock {
        Remove-Item -Path $args[0] -Recurse -Confirm:$false -Force
    } -ArgumentList $rf
}
Remove-PSSession -Session $session -Confirm:$false

######################################
# logging the remote output from the runspace
Write-SPOTLog " ############# ORCHESTRATOR LOGGING: Finished step function ""$($STParameters.ArgumentList.Command)"" on remote computer ""$RemoteComputer"" using ScheduledJob. Function output below. #############"
$returnOutput

} @innerParams
# cleanup of used parameters
$RemoteComputer      = $null
$Credential          = $null
$STParameters        = $null
$CompKey             = $null
$UseSSL              = $null
$_spot_PublishedData = $null
$innerParams         = $null
$Error.Clear()

}).AddParameters($ParamList) | Out-Null
    
    # start the runspace objects
    $handle = $powershell.BeginInvoke()
    $return = @{}
    $return.Target = $null
    $return.GUID = $null
    $return.Name = $null
    $return.Type = $null
    $return.Processed = $null

    $return.handle = $handle
    $return.powershell = $powershell
    $returnObject = [pscustomobject]$return

    # return the Job object (runspace objects + some metadata)
    return $returnObject

} # end of PowershellCommandRemoteSJ function

######################################################################################################################
function PowershellCommandRemoteWMI {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the payload script/function name to be executed remotely (without extension for scripts)
        $CommandName, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [hashtable]
        # the hashtable with the parameters to the payload script/function to be executed remotely
        $CommandParameters, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the remote computer where to execute the payload script/function
        $RemoteComputer, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [PSCredential]
        # the credential to connect to the remote computer
        $Credential, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the execution path for the payload script/function
        $ExecPath, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string[]]
        # the array of variable names to publish, from inside the payload script/function
        $VariablesToPublish 
        )
    
    # execution option for cases when the WinRM is disabled but the WMI and the SMB ports are open; inspired from:
    # https://www.randomizedharmony.com/blog/2018/10/8/remote-powershell-commands-with-winrm-disabled-and-windows-powershell
    # async method
    # main known limitation is that there is no access to the credential store (the cmdkey) on the remote computer, 
    # but as always, credentials from the SPOT secret vault can be assigned as parameters to the step function

    ######################################
    # create the powershell object
    if ($CommandName -eq "Execute-SPOTRunbook") {
        # create an individual Runspace with all functions and variables required for Runbook executions
        $runspace = Create-SPOTRunbookRunspace
        $powershell = [powershell]::Create()
        $powershell.Runspace = $runspace
    }
    else {
        # create the pipeline inside the MainWorkerPool with all functions and variables required for RunbookStep executions
        $powershell = [powershell]::Create()
	    $powershell.RunspacePool = $_spot_MainWorkerPool
    }

    ######################################
    # define random CompKey for secrets handling
    # it is generated now as it is needed to prepare the objects with the variables, functions and parameters
    $CompKey = "$(-join (((48..57)+(97..122)) * 80 | Get-Random -Count 32 |%{[char]$_}))"

    ##########################################################
    # prepare the parameters object for passing to the WMI execution inside the runspace
    $ArgumentList = @{
        OrchVars           = Decompose-SPOTHashTableVariable -InputVariable $OrchVars -Key $CompKey
        Command            = $CommandName
        CommandParameters  = Decompose-SPOTHashTableVariable -InputVariable $CommandParameters -Key $CompKey
        ExecPath           = $ExecPath
        _spot_VTPs         = Get-SPOTVTPObjects -VariablesToPublish $VariablesToPublish
    }

    ##########################################################
    # prepare the scriptblock for WMI
    $ScriptBlock = {
        $_spot_CmpK = $args[0]
        $_spot_SBO = @()

        $_spot_SecDes = New-Object System.IO.Pipes.PipeSecurity
	    $_spot_everyone = New-Object System.Security.Principal.SecurityIdentifier "S-1-1-0"
	    $_spot_accRule = New-Object System.IO.Pipes.PipeAccessRule($_spot_everyone, "FullControl", "Allow")
	    $_spot_SecDes.AddAccessRule($_spot_accRule)

        $_spot_SBO += " >>> $(Get-Date) Opening Pipe1."
        $_spot_P1 = New-Object System.IO.Pipes.NamedPipeServerStream("Pipe1", [System.IO.Pipes.PipeDirection]::In, 1, 'Byte', 'None', 0, 0, $_spot_SecDes)
        $_spot_P1.WaitForConnection()
        $_spot_SBO += " >>> $(Get-Date) Client connected to Pipe1."
        $_spot_sr1 = New-Object System.IO.StreamReader $_spot_P1
        $_spot_Pt1 = 120
        $_spot_St1 = Get-Date
	    while (($null -ne ($_spot_dat = $_spot_sr1.ReadLine())) -and ([math]::floor(((Get-Date) - $_spot_St1).TotalSeconds) -lt $_spot_Pt1))
	    {
		    $_spot_tmpData = $_spot_dat
	    }
	    $_spot_sr1.dispose()
        $_spot_P1.dispose()

        $_spot_AH = [System.Management.Automation.PSSerializer]::Deserialize([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_spot_tmpData)))

        foreach ($_spot_cmd in $_spot_AH.Functions) { 
            Set-Item "Function:$($_spot_cmd.Name)" $_spot_cmd.ScriptBlock
            (Get-Command -Name $_spot_cmd.Name -CommandType Function -ErrorAction Stop).Description = "#SPOT"
        }

        $_spot_SBO += " >>> $(Get-Date) Functions got loaded."

        $OrchVars = Recompose-SPOTHashTableVariable -InputVariable $_spot_AH.OrchVars -Key $_spot_CmpK

        $_spot_P2 = New-Object System.IO.Pipes.NamedPipeServerStream("Pipe2", [System.IO.Pipes.PipeDirection]::Out, 1, 'Byte', 'None', 0, 0, $_spot_SecDes)
        $_spot_P2.WaitForConnection()
        $_spot_SBO += " >>> $(Get-Date) Client connected to Pipe2."

        $_spot_cnt = $true
        if ($_spot_AH.CommandParameters) {
            $_spot_cmdP = Recompose-SPOTHashTableVariable -InputVariable $_spot_AH.CommandParameters -Key $_spot_CmpK

            foreach ($_spot_cpRFI in $_spot_AH.CommandParametersRFI) {
                $_spot_TFP1 = [System.IO.Path]::GetTempFileName()
                $_spot_TF1 = Get-Item -Path $_spot_TFP1 -Force
                if ($_spot_TF1) {
                    [System.IO.File]::WriteAllBytes($_spot_TF1.FullName,$_spot_cmdP.$_spot_cpRFI)
                    $_spot_cmdP.$_spot_cpRFI = $_spot_TF1.FullName
                }
                else {
                    $_spot_SBO += " >>> $(Get-Date) ERROR: Temp file could not be created for parameter $_spot_cpRFI. Cannot continue."
                    $_spot_cnt = $false
                }
            }

            foreach ($_spot_cpRFO in $($_spot_AH.CommandParametersRFO.Keys)) {
                $_spot_uID = ($_spot_AH.CommandParametersRFO.$_spot_cpRFO -split ":")[1]
                $_spot_RFN = $OrchVars._RFOMap.$_spot_uID.ReferencedFileName
                $_spot_TFP2 = [System.IO.Path]::GetTempFileName()
                $_spot_TF2 = Get-Item -Path $_spot_TFP2 -Force
                if ($_spot_TF2) {
                    [System.IO.File]::WriteAllBytes($_spot_TF2.FullName,$_spot_cmdP.$_spot_cpRFO)
                    Extract-SPOTArchive -ZipPath $_spot_TFP2 -TargetFolder "$($_spot_TF2.Directory)\$($_spot_TF2.BaseName)"
                    Remove-Item -Path $_spot_TFP2 -Confirm:$false -Force -ErrorAction SilentlyContinue
                    $_spot_cmdP.$_spot_cpRFO = "$($_spot_TF2.Directory)\$($_spot_TF2.BaseName)\$_spot_RFN"
                }
                else {
                    $_spot_SBO += " >>> $(Get-Date) ERROR: Temp archive file could not be created for parameter $_spot_cpRFO. Cannot continue."
                    $_spot_cnt = $false
                }
            }
        }

        if ($_spot_cnt) {
            if ($_spot_AH.ExecPath) {
                if (Test-Path -Path $_spot_AH.ExecPath -PathType Container -ErrorAction SilentlyContinue) {
                    $_spot_SBO += " >>> $(Get-Date) The configured execution path was found. Setting it now."
                    Push-Location -Path $_spot_AH.ExecPath -ErrorAction SilentlyContinue
                }
                else {
                    $_spot_SBO += " >>> $(Get-Date) WARNING: The configured execution path was not found. Continuing execution as is."
                }
            }

            $_spot_HostFunctions = [scriptblock]::Create([System.Text.Encoding]::UTF8.GetString([convert]::FromBase64String($OrchVars._SPOTHostFunctions)))
            . $_spot_HostFunctions

            $_spot_SBO += " >>> $(Get-Date) Preparing to execute the actual paylod."
            $_spot_VTPs = $_spot_AH._spot_VTPs
            $_spot_TWOE = $true
            $_spot_Output = @()
            Set-Item "Function:$($_spot_AH.Command)" "$(Replace-SPOTExitInCode -code (Get-Command -Name $_spot_AH.Command | Select-Object -ExpandProperty Definition))"
            try {
                $_spot_Output += . $_spot_AH.Command @_spot_cmdP *>&1 | Out-String -Stream -OutVariable _spot_SO
            }
            catch {
                $_spot_SO = @($_spot_SO)
                $_spot_SO += "############# ORCHESTRATOR LOGGING: TERMINATING ERROR while trying to execute the step function ""$($_spot_AH.Command)"" over WMI. #############"
                if (($_.ScriptStackTrace -split "`n").Count -eq 1) {
                    $_spot_SO += " >>>>>> ERROR encountered inside the SPOT tool function ""PowershellCommandRemoteWMI""."
                }
                elseif (($_.ScriptStackTrace -split "`n").Count -eq 2) {
                    $_spot_SO += " >>>>>> ERROR encountered inside the step function ""$($_spot_AH.Command)""."
                }
                else {
                    $_spot_SO += " >>>>>> ERROR encountered inside a script/function called in the step function ""$($_spot_AH.Command)""."
                    $_spot_SO += " >>>>>> ERROR ScriptStackTrace from the step function inward:"
                    $_spot_SO += ($_.ScriptStackTrace -split "`n")[0..(($_.ScriptStackTrace -split "`n").Count-2)]
                    $_spot_ln = (($_.ScriptStackTrace -split "`n")[($_.ScriptStackTrace -split "`n").Count-2] -split "line")[1].Trim()
                    $_spot_SO += " >>>>>> ERROR Line in the step function:"
                    $_spot_SO += "$(((Get-Command -Name $_spot_AH.Command | Select-Object -ExpandProperty Definition | Out-String -Width 250) -split '\r?\n')[$_spot_ln-1])"
                }
                $_spot_SO += " >>>>>> ERROR Exception:"
                $_spot_SO += "$($_.Exception)"
                $_spot_SO += " >>>>>> ERROR Exception Type:"
                $_spot_SO += "$($_.Exception.GetType().FullName)"
                $_spot_SO += " >>>>>> ERROR InvocationInfo.Line:"
                $_spot_SO += "$($_.InvocationInfo.Line)"
                $_spot_SO += " >>>>>> ERROR InvocationInfo.PositionMessage:"
                $_spot_SO += "$($_.InvocationInfo.PositionMessage)"
                $_spot_Output = $_spot_SO
                $_spot_TWOE = $false
            }

            if ($_spot_TWOE) {
                $_spot_Output += $true
            }
            else {
                $_spot_Output += $false
            }
            
            $_spot_PVs = @{}
            foreach ($_spot_i in $_spot_VTPs) {
                $_spot_PVs.($_spot_i.VarNewName) = Get-Variable -Name $_spot_i.VarName -ErrorAction SilentlyContinue -ValueOnly
            }

            foreach ($_spot_cpRFI in $_spot_AH.CommandParametersRFI) {
                Set-Content -Path $_spot_cmdP.$_spot_cpRFI -Value "0000" -Confirm:$false -Force -ErrorAction SilentlyContinue
                Remove-Item -Path $_spot_cmdP.$_spot_cpRFI -Confirm:$false -Force -ErrorAction SilentlyContinue
            }
            foreach ($_spot_cpRFO in $($_spot_AH.CommandParametersRFO.Keys)) {
                Remove-Item -Path (Split-Path -Path $_spot_cmdP.$_spot_cpRFO -Parent) -Recurse -Confirm:$false -Force -ErrorAction SilentlyContinue
            }

            if ($Error) {
                $_spot_SBO += " >>> $(Get-Date) ERRORs encountered: $Error."
            }

            $_spot_SBO += " >>> $(Get-Date) Payload was executed. Payload output below.`n####################################################"
            $_spot_SBO += $_spot_Output
        }
        else {
            $_spot_SBO += " >>> $(Get-Date) ERROR: At least one temp file failed to create."
            $_spot_SBO += $false
        }

        $_spot_OutH = @{
            Output = $_spot_SBO
            PublishedVariables = $_spot_PVs
        }

	    $_spot_b64SOH = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([management.automation.psserializer]::Serialize($_spot_OutH)))
        $_spot_sw = New-Object System.IO.StreamWriter $_spot_P2
	    $_spot_sw.AutoFlush = $true
	    $_spot_sw.WriteLine($_spot_b64SOH)
	    $_spot_sw.dispose()
        $_spot_P2.dispose()
    }

    $WMIParameters = @{
        ScriptBlock  = $ScriptBlock
        ArgumentList = $ArgumentList
    }

    ######################################
    # preparing the ParamList to be passed to the runspace
    $ParamList = @{
        RemoteComputer      = $RemoteComputer
        Credential          = $Credential
        CompKey             = $CompKey
        WMIParameters       = $WMIParameters
        _spot_PublishedData = $null
    }
    ######
    if ($VariablesToPublish -or ($CommandName -in ("Execute-SSHScript","Execute-TelnetScript"))) {
        # add the PublishedData variable only if needed to publish something or for commands that need it (otherwise it is a waste of resources)
        $ParamList._spot_PublishedData = $PublishedData
    }

    #############################################################################################
    # start to define what happens inside runspace
    $powershell.AddScript({
        Param (
        [string]$RemoteComputer,
        [System.Management.Automation.PSCredential]$Credential,
        [hashtable]$WMIParameters,
        [string]$CompKey,
        [hashtable]$_spot_PublishedData
        )

        $innerParams = @{
            RemoteComputer      = [string]$RemoteComputer
            Credential          = [System.Management.Automation.PSCredential]$Credential
            WMIParameters       = [hashtable]$WMIParameters
            CompKey             = [string]$CompKey
            _spot_PublishedData = [hashtable]$_spot_PublishedData
        }
# child scope against cross bleeding of variables inside the runspacepool
& {
    Param (
    [string]$RemoteComputer,
    [System.Management.Automation.PSCredential]$Credential,
    [hashtable]$WMIParameters,
    [string]$CompKey,
    [hashtable]$_spot_PublishedData
    )

######################################
Write-SPOTLog " ############# ORCHESTRATOR LOGGING: Launching step function ""$($WMIParameters.ArgumentList.Command)"" with credential ""$($Credential.UserName)"" on remote computer ""$RemoteComputer"" over WMI with Timeout ""$($OrchVars._StepTimeout)"" seconds. #############"

######################################
# stamp all SPOT related functions inside the runspace
foreach ($funcName in $_spot_FunctionNames) {
    (Get-Command -Name $funcName -CommandType Function -ErrorAction Stop).Description = "#SPOT"
}

######################################
# testing the availability of the remote execution TCP ports on the remote computer
$TCPTestResult1 = Test-SPOTTCPPort -TargetIP $RemoteComputer -TCPPort "445"
if (!($TCPTestResult1.TcpTestSucceeded)) {
    Write-SPOTLog " ############# ORCHESTRATOR LOGGING: ERROR: Connecting to the SMB port on remote computer ""$RemoteComputer"" failed! Ping test result was: $($TCPTestResult1.PingSucceeded). #############"
    return $false
}
$TCPTestResult2 = Test-SPOTTCPPort -TargetIP $RemoteComputer -TCPPort "135"
if (!($TCPTestResult2.TcpTestSucceeded)) {
    Write-SPOTLog " ############# ORCHESTRATOR LOGGING: ERROR: Connecting to the WMI (RPC Endpoint Mapper) port on remote computer ""$RemoteComputer"" failed! Ping test result was: $($TCPTestResult2.PingSucceeded). #############"
    return $false
}

######################################
# establish SMB session authentication to be used by the NamedPipes
if ($Credential.GetNetworkCredential().Domain -eq '.') {
    # "net use" does not work well with the "." domain but other sessions could
    $nc = net use \\$RemoteComputer\IPC$ /user:$($Credential.GetNetworkCredential().UserName) $Credential.GetNetworkCredential().Password /persistent:no *>&1
}
else {
    $nc = net use \\$RemoteComputer\IPC$ /user:$($Credential.UserName) $Credential.GetNetworkCredential().Password /persistent:no *>&1
}
####
if ($nc -notlike "*command completed successfully*") {
    Write-SPOTLog  " ############# ORCHESTRATOR LOGGING: ERROR: while connecting to the remote IPC share: $nc"
    return $false
}

######################################
# prepare the encoded command
$WMIParameters.ScriptBlock = [ScriptBlock]::Create($WMIParameters.ScriptBlock)
$encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($WMIParameters.ScriptBlock))

# prepare the encoded arguments
$arguments = [System.Collections.ArrayList]::new()
$arguments.Add($CompKey) | Out-Null
$encodedArguments = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes([System.Management.Automation.PSSerializer]::Serialize($arguments)))

######################################
# inject the SPOT functions in the WMI arguments
$WMIParameters.ArgumentList.Functions = Get-Command | Where {$_.Name -in $_spot_FunctionNames}

######################################
# inject the needed Referenced Files/Folders in the WMI arguments
if ($WMIParameters.ArgumentList.CommandParameters) {
    # there are command parameters defined; checking for $RFI or $RFO (file variables) and managing the file/folder transfer to the target computer
    try {
        $CmdParametersRF = Process-SPOTCommandParamsRF -CommandParameters $WMIParameters.ArgumentList.CommandParameters
    }
    catch {
        Write-SPOTLog ">>> T.ERROR while processing Referenced Files/Folders on the ""$RemoteComputer"" remote computer for the ""$($WMIParameters.ArgumentList.Command)"" command: $_."
        return $false
    }
    $WMIParameters.ArgumentList.CommandParameters    = $CmdParametersRF.CommandParameters
    $WMIParameters.ArgumentList.CommandParametersRFI = $CmdParametersRF.CommandParametersRFI
    $WMIParameters.ArgumentList.CommandParametersRFO = $CmdParametersRF.CommandParametersRFO
}

######################################
# prepare the actual arguments object for sending over pipe
$encodedArgumentList = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([System.Management.Automation.PSSerializer]::Serialize($WMIParameters.ArgumentList)))

######################################
# launch the command over WMI/Dcom after all preparations have been done
try {
    $CimSession = New-CimSession -ComputerName $RemoteComputer -Credential $Credential -SessionOption (New-CimSessionOption -Protocol Dcom)
    $holderData = Invoke-CimMethod -CimSession $CimSession -ClassName Win32_Process -MethodName Create `
        -Arguments @{ CommandLine = "powershell.exe -WindowStyle Hidden -encodedCommand $encodedCommand -encodedArguments $encodedArguments" }
}
catch {
    Write-SPOTLog  " ############# ORCHESTRATOR LOGGING: ERROR while invoking the WMI Method on the ""$RemoteComputer"" remote computer: $_"
    return $false
}

# cleanup CIM Session
Remove-CimSession -CimSession $CimSession -ErrorAction SilentlyContinue

######################################
# sanity check of the returned data to the WMI call
if ($holderData.ReturnValue -eq "0") {
    Write-SPOTLog  " ############# ORCHESTRATOR LOGGING: The remote WMI execution seems to be launched successfully. #############" -DBG $true
}
else {
    Write-SPOTLog  " ############# ORCHESTRATOR LOGGING: WARNING: The remote WMI execution does not seem to be launched successfully. ReturnValue was: $($holderData.ReturnValue)  #############" -DBG $true
}

######################################
# start the Data Transfer handling between the local computer and the remote computer
try {
    . Transfer-SPOTDataOverPipe -encodedArgumentList $encodedArgumentList -RemoteComputer $RemoteComputer
}
catch {
    Write-SPOTLog  " ############# ORCHESTRATOR LOGGING: ERROR: while transferring data to/from ""$RemoteComputer"" remote computer: $_. #############"
    return $false
}

######################################
# disconnect from remote IPC Share
net use \\$RemoteComputer\IPC$ /delete | Out-Null

######################################
# decode OutputHash 
try {
    $OH = [System.Management.Automation.PSSerializer]::Deserialize([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($tempData)))
}
catch {
    Write-SPOTLog "ERROR: while trying to deserialize the OutputHash: $_."
}

######################################
# handling the Published Variables
if ($WMIParameters.ArgumentList._spot_VTPs) {
    foreach ($entry in $OH.PublishedVariables.GetEnumerator()) {
        $_spot_PublishedData.($entry.Name) = $entry.Value
    }
}

######################################
# logging the remote output from the runspace
Write-SPOTLog " ############# ORCHESTRATOR LOGGING: Finished step function ""$($WMIParameters.ArgumentList.Command)"" on remote computer ""$RemoteComputer"" over WMI. Full session output below. #############"
$OH.Output

} @innerParams
# cleanup of used parameters
$RemoteComputer      = $null
$Credential          = $null
$WMIParameters       = $null
$CompKey             = $null
$_spot_PublishedData = $null
$innerParams         = $null
$Error.Clear()

}).AddParameters($ParamList) | Out-Null
    
    # start the runspace objects
    $handle = $powershell.BeginInvoke()
    $return = @{}
    $return.Target = $null
    $return.GUID = $null
    $return.Name = $null
    $return.Type = $null
    $return.Processed = $null

    $return.handle = $handle
    $return.powershell = $powershell
    $returnObject = [pscustomobject]$return

    # return the Job object (runspace objects + some metadata)
    return $returnObject

} # end of PowershellCommandRemoteWMI function

######################################################################################################################
function PowershellCommandRemotePsExec {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the payload script/function name to be executed remotely (without extension for scripts)
        $CommandName, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [hashtable]
        # the hashtable with the parameters to the payload script/function to be executed remotely
        $CommandParameters, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the remote computer where to execute the payload script/function
        $RemoteComputer, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [PSCredential]
        # the credential to connect to the remote computer
        $Credential, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the execution path for the payload script/function
        $ExecPath, 
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]
        # specify if the payload script/function is to be executed as local system on the target computer
        $AsSystem = $false, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string[]]
        # the array of variable names to publish, from inside the payload script/function
        $VariablesToPublish 
        )
    
    # execution option for cases when both the WinRM (PSRemoting/PSSession) and WMI/Dcom are disabled; it uses only the SMB port
    # running as the local system is possible
    # async method
    # the local credential store (cmdkey) is accessible on the more computer with this method

    ######################################
    # get the PsExec tool file item first, as nothing can be done without it
    $PsExec = Get-Item -Path $Orchvars._PsExecPath -Force 
    if (!$PsExec) {
        Write-SPOTLog " ############# ORCHESTRATOR LOGGING: ERROR: The PsExec tool was not found in the _PsExecPath. Cannot continue. #############"
        return $false
    }

    ######################################
    # create the powershell object
    if ($CommandName -eq "Execute-SPOTRunbook") {
        # create an individual Runspace with all functions and variables required for Runbook executions
        $runspace = Create-SPOTRunbookRunspace
        $powershell = [powershell]::Create()
        $powershell.Runspace = $runspace
    }
    else {
        # create the pipeline inside the MainWorkerPool with all functions and variables required for RunbookStep executions
        $powershell = [powershell]::Create()
	    $powershell.RunspacePool = $_spot_MainWorkerPool
    }

    ######################################
    # generate random key for De/Recompose the OrchVars potentially containing secrets
    # it is generated now as it is needed to prepare the objects with the variables, functions and parameters
    $CompKey = "$(-join (((48..57)+(97..122)) * 80 | Get-Random -Count 32 |%{[char]$_}))"

    ##########################################################
    # prepare the parameters object for passing to the WMI execution inside the runspace
    $ArgumentList = @{
        OrchVars           = Decompose-SPOTHashTableVariable -InputVariable $OrchVars -Key $CompKey
        Command            = $CommandName
        CommandParameters  = Decompose-SPOTHashTableVariable -InputVariable $CommandParameters -Key $CompKey
        ExecPath           = $ExecPath
        _spot_VTPs         = Get-SPOTVTPObjects -VariablesToPublish $VariablesToPublish
    }

    ######################################
    # prepare the scriptblock for psexec
    $ScriptBlock = {

        $_spot_CmpK = $args[0]
        $_spot_SBO = @()

        # prepare Pipe Security
        $_spot_SecDes = New-Object System.IO.Pipes.PipeSecurity
	    $_spot_everyone = New-Object System.Security.Principal.SecurityIdentifier "S-1-1-0"
	    $_spot_accRule = New-Object System.IO.Pipes.PipeAccessRule($_spot_everyone, "FullControl", "Allow")
	    $_spot_SecDes.AddAccessRule($_spot_accRule)
        
        $_spot_SBO += " >>> $(Get-Date) Opening Pipe1."
        # get the encoded arguments from the first named pipe
        $_spot_P1 = New-Object System.IO.Pipes.NamedPipeServerStream("Pipe1", [System.IO.Pipes.PipeDirection]::In, 1, 'Byte', 'None', 0, 0, $_spot_SecDes)
        $_spot_P1.WaitForConnection()
        $_spot_SBO += " >>> $(Get-Date) Client connected to Pipe1."
        $_spot_sr1 = New-Object System.IO.StreamReader $_spot_P1
        $_spot_Pt = 120
        $_spot_St = Get-Date
	    while (($null -ne ($_spot_dat = $_spot_sr1.ReadLine())) -and ([math]::floor(((Get-Date) - $_spot_St).TotalSeconds) -lt $_spot_Pt)){
		    $_spot_tmpData = $_spot_dat
	    }
	    $_spot_sr1.dispose()
        $_spot_P1.dispose()

        # process the encoded arguments
        $_spot_AH = [System.Management.Automation.PSSerializer]::Deserialize([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_spot_tmpData)))
        foreach ($_spot_cmd in $_spot_AH.Functions) {
            Set-Item "Function:$($_spot_cmd.Name)" $_spot_cmd.ScriptBlock
            (Get-Command -Name $_spot_cmd.Name -CommandType Function -ErrorAction Stop).Description = "#SPOT"
        }
        $_spot_SBO += " >>> $(Get-Date) Functions got loaded."
        #####
        # open the second name pipe now
        $_spot_P2 = New-Object System.IO.Pipes.NamedPipeServerStream("Pipe2", [System.IO.Pipes.PipeDirection]::Out, 1, 'Byte', 'None', 0, 0, $_spot_SecDes)
        $_spot_P2.WaitForConnection()
        $_spot_SBO += " >>> $(Get-Date) Client connected to Pipe2."

        #####
        $_spot_cnt = $true
        $OrchVars = Recompose-SPOTHashTableVariable -InputVariable $_spot_AH.OrchVars -Key $_spot_CmpK
        if ($_spot_AH.CommandParameters) {
            $_spot_CmdP = Recompose-SPOTHashTableVariable -InputVariable $_spot_AH.CommandParameters -Key $_spot_CmpK
            # create local temp files for all RFI parameters
            foreach ($_spot_cpRFI in $_spot_AH.CommandParametersRFI) {
                $_spot_TFP1 = [System.IO.Path]::GetTempFileName()
                $_spot_TF1 = Get-Item -Path $_spot_TFP1 -Force
                if ($_spot_TF1) {
                    [System.IO.File]::WriteAllBytes($_spot_TF1.FullName,$_spot_CmdP.$_spot_cpRFI)
                    $_spot_CmdP.$_spot_cpRFI = $_spot_TF1.FullName
                }
                else {
                    $_spot_SBO += " >>> $(Get-Date) ERROR: Temp file could not be created for parameter $_spot_cpRFI. Cannot continue."
                    $_spot_cnt = $false
                }
            }
            # create local temp archive files and extract them for all RFO parameters
            foreach ($_spot_cpRFO in $($_spot_AH.CommandParametersRFO.Keys)) {
                $_spot_uID = ($_spot_AH.CommandParametersRFO.$_spot_cpRFO -split ":")[1]
                $_spot_RFN = $OrchVars._RFOMap.$_spot_uID.ReferencedFileName
                $_spot_TFP2 = [System.IO.Path]::GetTempFileName()
                $_spot_TF2 = Get-Item -Path $_spot_TFP2 -Force
                if ($_spot_TF2) {
                    [System.IO.File]::WriteAllBytes($_spot_TF2.FullName,$_spot_CmdP.$_spot_cpRFO)
                    Extract-SPOTArchive -ZipPath $_spot_TFP2 -TargetFolder "$($_spot_TF2.Directory)\$($_spot_TF2.BaseName)"
                    # the archive file can be cleaned up right now
                    Remove-Item -Path $_spot_TFP2 -Confirm:$false -Force -ErrorAction SilentlyContinue
                    # change the command parameter back to a path
                    $_spot_CmdP.$_spot_cpRFO = "$($_spot_TF2.Directory)\$($_spot_TF2.BaseName)\$_spot_RFN"
                }
                else {
                    $_spot_SBO += " >>> $(Get-Date) ERROR: Temp archive file could not be created for parameter $_spot_cpRFO. Cannot continue."
                    $_spot_cnt = $false
                }
            }
        }

        #####
        if ($_spot_cnt) {
            if ($_spot_AH.ExecPath) {
                if (Test-Path -Path $_spot_AH.ExecPath -PathType Container -ErrorAction SilentlyContinue) {
                    $_spot_SBO += " >>> $(Get-Date) The configured execution path was found. Setting it now."
                    Push-Location -Path $_spot_AH.ExecPath -ErrorAction SilentlyContinue
                }
                else {
                    $_spot_SBO += " >>> $(Get-Date) WARNING: The configured execution path was not found. Continuing execution as is."
                }
            }

            $_spot_HostFunctions = [scriptblock]::Create([System.Text.Encoding]::UTF8.GetString([convert]::FromBase64String($OrchVars._SPOTHostFunctions)))
            . $_spot_HostFunctions

            $_spot_SBO += " >>> $(Get-Date) Preparing to execute the actual paylod."
            $_spot_VTPs = $_spot_AH._spot_VTPs
            $_spot_TWOE = $true
            $_spot_Output = @()
            Set-Item "Function:$($_spot_AH.Command)" "$(Replace-SPOTExitInCode -code (Get-Command -Name $_spot_AH.Command | Select-Object -ExpandProperty Definition))"
            try {
                $_spot_Output += . $_spot_AH.Command @_spot_CmdP *>&1 | Out-String -Stream -OutVariable _spot_SO
            }
            catch {
                $_spot_SO = @($_spot_SO)
                $_spot_SO += "############# ORCHESTRATOR LOGGING: TERMINATING ERROR while trying to execute the step function ""$($_spot_AH.Command)"" over PsExec. #############"
                if (($_.ScriptStackTrace -split "`n").Count -le 1) {
                    $_spot_SO += " >>>>>> ERROR encountered inside the SPOT tool function ""PowershellCommandRemotePsExec""."
                }
                elseif (($_.ScriptStackTrace -split "`n").Count -eq 2) {
                    $_spot_SO += " >>>>>> ERROR encountered inside the step function ""$($_spot_AH.Command)""."
                }
                else {
                    $_spot_SO += " >>>>>> ERROR encountered inside a script/function called in the step function ""$($_spot_AH.Command)""."
                    $_spot_SO += " >>>>>> ERROR ScriptStackTrace from the step function inward:"
                    $_spot_SO += ($_.ScriptStackTrace -split "`n")[0..(($_.ScriptStackTrace -split "`n").Count-2)]
                    $_spot_ln = (($_.ScriptStackTrace -split "`n")[($_.ScriptStackTrace -split "`n").Count-2] -split "line")[1].Trim()
                    $_spot_SO += " >>>>>> ERROR Line in the step function:"
                    $_spot_SO += "$(((Get-Command -Name $_spot_AH.Command | Select-Object -ExpandProperty Definition | Out-String -Width 250) -split '\r?\n')[$_spot_ln-1])"
                }
                $_spot_SO += " >>>>>> ERROR Exception:"
                $_spot_SO += "$($_.Exception)"
                $_spot_SO += " >>>>>> ERROR Exception Type:"
                $_spot_SO += "$($_.Exception.GetType().FullName)"
                $_spot_SO += " >>>>>> ERROR InvocationInfo.Line:"
                $_spot_SO += "$($_.InvocationInfo.Line)"
                $_spot_SO += " >>>>>> ERROR InvocationInfo.PositionMessage:"
                $_spot_SO += "$($_.InvocationInfo.PositionMessage)"
                $_spot_Output = $_spot_SO
                $_spot_TWOE = $false
            }

            ##########################
            if ($_spot_TWOE) {
                $_spot_Output += $true
            }
            else {
                $_spot_Output += $false
            }

            $_spot_PVs = @{}
            foreach ($_spot_i in $_spot_VTPs) {
                $_spot_PVs.($_spot_i.VarNewName) = Get-Variable -Name $_spot_i.VarName -ea 0 -ValueOnly
            }
            
            # cleanup temp files
            foreach ($_spot_cpRFI in $_spot_AH.CommandParametersRFI) {
                Set-Content -Path $_spot_CmdP.$_spot_cpRFI -Value "0000" -Confirm:$false -Force -ErrorAction SilentlyContinue
                Remove-Item -Path $_spot_CmdP.$_spot_cpRFI -Confirm:$false -Force -ErrorAction SilentlyContinue
            }
            foreach ($_spot_cpRFO in $($_spot_AH.CommandParametersRFO.Keys)) {
                Remove-Item -Path (Split-Path -Path $_spot_CmdP.$_spot_cpRFO -Parent) -Recurse -Confirm:$false -Force -ErrorAction SilentlyContinue
            }
            
            # include any errors
            if ($Error) {
                $_spot_SBO += " >>> $(Get-Date) ERRORs encountered: $Error."
            }

            # include the SBOutput before the payload output
            $_spot_SBO += " >>> $(Get-Date) Payload was executed. Payload output below.`n####################################################"
            $_spot_SBO += $_spot_Output
        }
        else {
            # prepare error output
            $_spot_SBO += " >>> $(Get-Date) ERROR: At least one temp file failed to create."
            $_spot_SBO += $false
        }

        # prepare output object
        $_spot_OutH = @{
            Output = $_spot_SBO
            PublishedVariables = $_spot_PVs
        }
        $_spot_b64SOH = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([management.automation.psserializer]::Serialize($_spot_OutH)))

        $_spot_sw = New-Object System.IO.StreamWriter $_spot_P2
	    $_spot_sw.AutoFlush = $true
	    $_spot_sw.WriteLine($_spot_b64SOH)
	    $_spot_sw.dispose()
        $_spot_P2.dispose()
    }

    $PsExecParameters = @{
        ScriptBlock  = $ScriptBlock
        ArgumentList = $ArgumentList
        AsSystem     = $AsSystem
    }

    # preparing the ParamList to be passed to the runspace and then to the remote PSSession
    $ParamList = @{
        RemoteComputer      = $RemoteComputer
        Credential          = $Credential
        CompKey             = $CompKey
        PsExecParameters    = $PsExecParameters
        _spot_PublishedData = $null
    }
    ######
    if ($VariablesToPublish -or ($CommandName -in ("Execute-SSHScript","Execute-TelnetScript"))) {
        # add the PublishedData variable only if needed to publish something or for commands that need it (otherwise it is a waste of resources)
        $ParamList._spot_PublishedData = $PublishedData
    }

    #############################################################################################
    # start to define what happens inside runspace
    $powershell.AddScript({
        Param (
        [string]$RemoteComputer,
        [System.Management.Automation.PSCredential]$Credential,
        [hashtable]$PsExecParameters,
        [string]$CompKey,
        [hashtable]$_spot_PublishedData
        )

        $innerParams = @{
            RemoteComputer      = [string]$RemoteComputer
            Credential          = [System.Management.Automation.PSCredential]$Credential
            PsExecParameters    = [hashtable]$PsExecParameters
            CompKey             = [string]$CompKey
            _spot_PublishedData = [hashtable]$_spot_PublishedData
        }
# child scope against cross bleeding of variables inside the runspacepool
& {
    Param (
    [string]$RemoteComputer,
    [System.Management.Automation.PSCredential]$Credential,
    [hashtable]$PsExecParameters,
    [string]$CompKey,
    [hashtable]$_spot_PublishedData
    )

######################################
Write-SPOTLog " ############# ORCHESTRATOR LOGGING: Launching step function ""$($PsExecParameters.ArgumentList.Command)"" with credential ""$($Credential.UserName)"" on remote computer ""$RemoteComputer"" over PsExec with Timeout ""$($OrchVars._StepTimeout)"" seconds. #############"

######################################
# stamp all SPOT related frunctions inside the runspace
foreach ($funcName in $_spot_FunctionNames) {
    (Get-Command -Name $funcName -CommandType Function -ErrorAction Stop).Description = "#SPOT"
}

######################################
# testing the availability of the remote execution TCP port on the remote computer
$TCPTestResult = Test-SPOTTCPPort -TargetIP $RemoteComputer -TCPPort "445"
if (!($TCPTestResult.TcpTestSucceeded)) {
    Write-SPOTLog " ############# ORCHESTRATOR LOGGING: ERROR: Connecting to the PsExec/SMB port on remote computer ""$RemoteComputer"" failed! Ping test result was: $($TCPTestResult.PingSucceeded). Cannot continue. #############"
    return $false
}

######################################
# establish SMB session authentication to be used by PsExec and the NamedPipes
if ($Credential.GetNetworkCredential().Domain -eq '.') {
    # "net use" does not work well with the "." domain but other sessions could
    $nc = net use \\$RemoteComputer\IPC$ /user:$($Credential.GetNetworkCredential().UserName) $Credential.GetNetworkCredential().Password /persistent:no *>&1
}
else {
    $nc = net use \\$RemoteComputer\IPC$ /user:$($Credential.UserName) $Credential.GetNetworkCredential().Password /persistent:no *>&1
}
#####
if ($nc -notlike "*command completed successfully*") {
    Write-SPOTLog  " ############# ORCHESTRATOR LOGGING: ERROR: while connecting to the remote IPC share: $nc"
    return $false
}

##############################
# prepare the encoded command
$PsExecParameters.ScriptBlock = [ScriptBlock]::Create($PsExecParameters.ScriptBlock)
$command_bytes = [System.Text.Encoding]::Unicode.GetBytes($PsExecParameters.ScriptBlock)
$encodedCommand = [Convert]::ToBase64String($command_bytes)

# prepare the encoded arguments
$arguments = [System.Collections.ArrayList]::new()
$arguments.Add($CompKey) | Out-Null
$SerializedArguments = [System.Management.Automation.PSSerializer]::Serialize($arguments)
$encodedArguments = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($SerializedArguments))

######################################
# inject the SPOT functions in the PsExec arguments
$PsExecParameters.ArgumentList.Functions = Get-Command | Where {$_.Name -in $_spot_FunctionNames}

######################################
# inject the needed Referenced Files/Folders in the PsExec arguments
if ($PsExecParameters.ArgumentList.CommandParameters) {
    # there are command parameters defined; checking for $RFI or $RFO (file variables) and managing the file/folder transfer to the target computer
    try {
        $CmdParametersRF = Process-SPOTCommandParamsRF -CommandParameters $PsExecParameters.ArgumentList.CommandParameters
    }
    catch {
        Write-SPOTLog ">>> T.ERROR while processing Referenced Files/Folders on the ""$RemoteComputer"" remote computer for the ""$($PsExecParameters.ArgumentList.Command)"" command: $_."
        return $false
    }
    $PsExecParameters.ArgumentList.CommandParameters    = $CmdParametersRF.CommandParameters
    $PsExecParameters.ArgumentList.CommandParametersRFI = $CmdParametersRF.CommandParametersRFI
    $PsExecParameters.ArgumentList.CommandParametersRFO = $CmdParametersRF.CommandParametersRFO
}

##############################
# prepare the actual arguments object for sending over pipe
$encodedArgumentList = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([System.Management.Automation.PSSerializer]::Serialize($PsExecParameters.ArgumentList)))

##############################
# execute the command over PsExec
Write-SPOTLog " ############# ORCHESTRATOR LOGGING: Start psexec64 execution for the ""$RemoteComputer"" remote computer. #############" -DBG $true

$PsExec = Get-Item -Path $Orchvars._PsExecPath -Force 
$pinfo = New-Object System.Diagnostics.ProcessStartInfo
$pinfo.FileName = $PsExec.FullName
$pinfo.RedirectStandardError = $true
$pinfo.RedirectStandardOutput = $true
$pinfo.UseShellExecute = $false
$pinfo.CreateNoWindow = $true

# use -i to avoid the need for special logon as a batch job or as a service rights
# use -d to detach after launching the command (avoid hanging in some cases)
# use -h to run in elevated mode
if ($PsExecParameters.AsSystem -eq $true) {
    $pinfo.Arguments = " -accepteula -nobanner -i -d -h -s -u `"$($Credential.Username)`" -p `"$($Credential.GetNetworkCredential().Password)`" `"\\$RemoteComputer`" powershell -encodedCommand $encodedCommand -encodedArguments $encodedArguments"
}
else {
    $pinfo.Arguments = " -accepteula -nobanner -i -d -h -u `"$($Credential.Username)`" -p `"$($Credential.GetNetworkCredential().Password)`" `"\\$RemoteComputer`" powershell -encodedCommand $encodedCommand -encodedArguments $encodedArguments"
}

##############################
# start the PsExec process
$p = New-Object System.Diagnostics.Process
$p.StartInfo = $pinfo
$p.Start() | Out-Null 
$p.WaitForExit()
$exeOutput = $p.StandardOutput.ReadToEnd()
$errOutput = $p.StandardError.ReadToEnd()

# handling the psexec err output
if ($errOutput.Contains("powershell started on")) {
    # the remote command launched successfully
    Write-SPOTLog  " ############# ORCHESTRATOR LOGGING: The remote PsExec execution seems to be launched successfully. #############" -DBG $true
}
else {
    # the remote command not launched successfully
    Write-SPOTLog  " ############# ORCHESTRATOR LOGGING: ERROR while launching PsExec on the ""$RemoteComputer"" remote computer. PsExec errOutput was: $errOutput."
    return $false
}

######################################
# start the Data Transfer handling between the local computer and the remote computer
try {
    . Transfer-SPOTDataOverPipe -encodedArgumentList $encodedArgumentList -RemoteComputer $RemoteComputer
}
catch {
    Write-SPOTLog  " ############# ORCHESTRATOR LOGGING: ERROR: while transferring data to/from ""$RemoteComputer"" remote computer: $_. #############"
    return $false
}

##############################
# disconnect from remote IPC Share
net use \\$RemoteComputer\IPC$ /delete | Out-Null

##############################
# decode OutputHas
try {
    $OH = [System.Management.Automation.PSSerializer]::Deserialize([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($tempData)))
}
catch {
    Write-SPOTLog "ERROR: while trying to deserialize the OutputHash: $_."
}

##############################
# handling the Published Variables
if ($PsExecParameters.ArgumentList._spot_VTPs) {
    foreach ($entry in $OH.PublishedVariables.GetEnumerator()) {
        $_spot_PublishedData.($entry.Name) = $entry.Value
    }
}

# logging the remote output from the runspace
Write-SPOTLog " ############# ORCHESTRATOR LOGGING: Finished step function ""$($PsExecParameters.ArgumentList.Command)"" on remote computer ""$RemoteComputer"" over PsExec. Full session output below. #############"
$OH.Output

} @innerParams
# cleanup of used parameters
$RemoteComputer      = $null
$Credential          = $null
$PsExecParameters    = $null
$CompKey             = $null
$_spot_PublishedData = $null
$innerParams         = $null
$Error.Clear()

}).AddParameters($ParamList) | Out-Null
    
    # start the runspace objects
    $handle = $powershell.BeginInvoke()
    $return = @{}
    $return.Target = $null
    $return.GUID = $null
    $return.Name = $null
    $return.Type = $null
    $return.Processed = $null

    $return.handle = $handle
    $return.powershell = $powershell
    $returnObject = [pscustomobject]$return

    # return the Job object (runspace objects + some metadata)
    return $returnObject

} # end of PowershellCommandRemotePsExec function

######################################################################################################################
function PowershellCommandRemoteOWMI {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the payload script/function name to be executed remotely (without extension for scripts)
        $CommandName, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [hashtable]
        # the hashtable with the parameters to the payload script/function to be executed remotely
        $CommandParameters, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the remote computer where to execute the payload script/function
        $RemoteComputer, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [PSCredential]
        # the credential to connect to the remote computer
        $Credential, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the execution path for the payload script/function
        $ExecPath, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string[]]
        # the array of variable names to publish, from inside the payload script/function
        $VariablesToPublish 
        )
    
    # execution option for cases when both the WinRM and SMB are disabled; this one uses port 135 and a dynamic port from the RPC port range 
    # main known disadvantage in comparison to the normal WMI method is the performance penalty due to the more complex data transfer
    # async method
    # main known limitation is that there is no access to the credential store (the cmdkey) on the remote computer, 
    # but as always, credentials from the SPOT secret vault can be assigned as parameters to the step function

    ######################################
    # create the powershell object
    if ($CommandName -eq "Execute-SPOTRunbook") {
        # create an individual Runspace with all functions and variables required for Runbook executions
        $runspace = Create-SPOTRunbookRunspace
        $powershell = [powershell]::Create()
        $powershell.Runspace = $runspace
    }
    else {
        # create the pipeline inside the MainWorkerPool with all functions and variables required for RunbookStep executions
        $powershell = [powershell]::Create()
	    $powershell.RunspacePool = $_spot_MainWorkerPool
    }

    ######################################
    # define random CompKey for secrets handling
    # it is generated now as it is needed to prepare the objects with the variables, functions and parameters
    $CompKey = "$(-join (((48..57)+(97..122)) * 80 | Get-Random -Count 32 |%{[char]$_}))"

    ##########################################################
    # prepare the parameters object for passing to the WMI execution inside the runspace
    $ArgumentList = @{
        OrchVars           = Decompose-SPOTHashTableVariable -InputVariable $OrchVars -Key $CompKey
        Command            = $CommandName
        CommandParameters  = Decompose-SPOTHashTableVariable -InputVariable $CommandParameters -Key $CompKey
        ExecPath           = $ExecPath
        _spot_VTPs         = Get-SPOTVTPObjects -VariablesToPublish $VariablesToPublish
    }

    ##########################################################
    # prepare the scriptblock for WMI
    $ScriptBlock = {
        $_spot_CmpK = $args[0]
        $_spot_SBO = @()

        ncim -Namespace root -ClassName __Namespace -Property @{Name = "SPOT_TD"} -ea 0 | Out-Null
        if (Get-CimClass -Namespace "root\SPOT_TD" -ClassName "SPOT_CC" -ea 0) {
            gcim -Namespace "root\SPOT_TD" -ClassName "SPOT_CC" | rcim
        }
        else {
            $_spot_Cls = New-Object System.Management.ManagementClass("root\SPOT_TD", [String]::Empty, $null)
            $_spot_Cls["__CLASS"] = "SPOT_CC"
            $_spot_Cls.Properties.Add("ID", [System.Management.CimType]::Uint32, $false)
            $_spot_Cls.Properties["ID"].Qualifiers.Add("key", $true)
            $_spot_Cls.Properties.Add("Data", [System.Management.CimType]::String, $false)
            $_spot_Cls.Put()
        }
        $Error.Clear()
        ncim -Namespace "root\SPOT_TD" -ClassName "SPOT_CC" -Property @{ ID = [uint32]1; Data = "rtrData"} | Out-Null

        $_spot_T = 120
        $_spot_St1 = Get-Date
	    while ([math]::floor(((Get-Date) - $_spot_St1).TotalSeconds) -lt $_spot_T){
		    if ((gcim -Namespace "root\SPOT_TD" -ClassName "SPOT_CC" -Filter "ID = 1").Data -eq "DataSent") {
                $_spot_SBO += " >>> $(Get-Date) Reading WMI Data."
                $_spot_rd = @(gcim -Namespace "root\SPOT_TD" -ClassName "SPOT_CC" -Filter "ID != 1")
                $_spot_r64 = ""
                foreach ($_spot_ID in ($_spot_rd.ID | Sort-Object)) {
                    $_spot_r64 += ($_spot_rd.Where{($_.ID -eq $_spot_ID)}).Data
                }
                break
            }
            Start-Sleep -Milliseconds 50
	    }

        $_spot_SBO += " >>> $(Get-Date) Cleaning WMI Repo."
        gcim -Namespace "root\SPOT_TD" -ClassName "SPOT_CC" -Filter "ID != 1" | rcim
        gcim -Namespace "root\SPOT_TD" -ClassName "SPOT_CC" -Filter "ID = 1" | scim -Property @{Data="DataRead"}
        
        $_spot_SBO += " >>> $(Get-Date) Processing WMI Data."
        $_spot_AH = [System.Management.Automation.PSSerializer]::Deserialize([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_spot_r64)))

        foreach ($_spot_cmd in $_spot_AH.Functions) {
            Set-Item "Function:$($_spot_cmd.Name)" $_spot_cmd.ScriptBlock
            (Get-Command -Name $_spot_cmd.Name -CommandType Function -ErrorAction Stop).Description = "#SPOT"
        }
        $_spot_SBO += " >>> $(Get-Date) Functions got loaded."

        $OrchVars = Recompose-SPOTHashTableVariable -InputVariable $_spot_AH.OrchVars -Key $_spot_CmpK

        $_spot_cnt = $true
        if ($_spot_AH.CommandParameters) {
            $_spot_cmdP = Recompose-SPOTHashTableVariable -InputVariable $_spot_AH.CommandParameters -Key $_spot_CmpK

            foreach ($_spot_cpRFI in $_spot_AH.CommandParametersRFI) {
                $_spot_TFP1 = [System.IO.Path]::GetTempFileName()
                $_spot_TF1 = Get-Item -Path $_spot_TFP1 -Force
                if ($_spot_TF1) {
                    [System.IO.File]::WriteAllBytes($_spot_TF1.FullName,$_spot_cmdP.$_spot_cpRFI)
                    $_spot_cmdP.$_spot_cpRFI = $_spot_TF1.FullName
                }
                else {
                    $_spot_SBO += " >>> $(Get-Date) ERROR: Temp file could not be created for parameter $_spot_cpRFI. Cannot continue."
                    $_spot_cnt = $false
                }
            }

            foreach ($_spot_cpRFO in $($_spot_AH.CommandParametersRFO.Keys)) {
                $_spot_uID = ($_spot_AH.CommandParametersRFO.$_spot_cpRFO -split ":")[1]
                $_spot_RFN = $OrchVars._RFOMap.$_spot_uID.ReferencedFileName
                $_spot_TFP2 = [System.IO.Path]::GetTempFileName()
                $_spot_TF2 = Get-Item -Path $_spot_TFP2 -Force
                if ($_spot_TF2) {
                    [System.IO.File]::WriteAllBytes($_spot_TF2.FullName,$_spot_cmdP.$_spot_cpRFO)
                    Extract-SPOTArchive -ZipPath $_spot_TFP2 -TargetFolder "$($_spot_TF2.Directory)\$($_spot_TF2.BaseName)"
                    Remove-Item -Path $_spot_TFP2 -Confirm:$false -Force -ea 0
                    $_spot_cmdP.$_spot_cpRFO = "$($_spot_TF2.Directory)\$($_spot_TF2.BaseName)\$_spot_RFN"
                }
                else {
                    $_spot_SBO += " >>> $(Get-Date) ERROR: Temp archive file could not be created for parameter $_spot_cpRFO. Cannot continue."
                    $_spot_cnt = $false
                }
            }
        }

        if ($_spot_cnt) {
            if ($_spot_AH.ExecPath) {
                if (Test-Path -Path $_spot_AH.ExecPath -PathType Container -ea 0) {
                    $_spot_SBO += " >>> $(Get-Date) The configured execution path was found. Setting it now."
                    Push-Location -Path $_spot_AH.ExecPath -ea 0
                }
                else {
                    $_spot_SBO += " >>> $(Get-Date) WARNING: The configured execution path was not found. Continuing execution as is."
                }
            }

            $_spot_HF = [scriptblock]::Create([System.Text.Encoding]::UTF8.GetString([convert]::FromBase64String($OrchVars._SPOTHostFunctions)))
            . $_spot_HF

            $_spot_SBO += " >>> $(Get-Date) Preparing to execute the paylod."
            $_spot_VTPs = $_spot_AH._spot_VTPs
            $_spot_TWOE = $true
            $_spot_Output = @()
            Set-Item "Function:$($_spot_AH.Command)" "$(Replace-SPOTExitInCode -code (Get-Command -Name $_spot_AH.Command | Select-Object -ExpandProperty Definition))"
            try {
                $_spot_Output += . $_spot_AH.Command @_spot_cmdP *>&1 | Out-String -Stream -OutVariable _spot_SO
            }
            catch {
                $_spot_SO = @($_spot_SO)
                $_spot_SO += "############# ORCHESTRATOR LOGGING: TERMINATING ERROR while trying to execute the step function ""$($_spot_AH.Command)"" over OWMI. #############"
                if (($_.ScriptStackTrace -split "`n").Count -eq 1) {
                    $_spot_SO += " >>>>>> ERROR encountered inside the SPOT tool function ""PowershellCommandRemoteOWMI""."
                }
                elseif (($_.ScriptStackTrace -split "`n").Count -eq 2) {
                    $_spot_SO += " >>>>>> ERROR encountered inside the step function ""$($_spot_AH.Command)""."
                }
                else {
                    $_spot_SO += " >>>>>> ERROR encountered inside a script/function called in the step function ""$($_spot_AH.Command)""."
                    $_spot_SO += " >>>>>> ERROR ScriptStackTrace from the step function inward:"
                    $_spot_SO += ($_.ScriptStackTrace -split "`n")[0..(($_.ScriptStackTrace -split "`n").Count-2)]
                    $_spot_ln = (($_.ScriptStackTrace -split "`n")[($_.ScriptStackTrace -split "`n").Count-2] -split "line")[1].Trim()
                    $_spot_SO += " >>>>>> ERROR Line in the step function:"
                    $_spot_SO += "$((((Get-Command -Name $_spot_AH.Command).Definition | Out-String -Width 250) -split '\r?\n')[$_spot_ln-1])"
                }
                $_spot_SO += " >>>>>> ERROR Exception:"
                $_spot_SO += "$($_.Exception)"
                $_spot_SO += " >>>>>> ERROR Exception Type:"
                $_spot_SO += "$($_.Exception.GetType().FullName)"
                $_spot_SO += " >>>>>> ERROR InvocationInfo.Line:"
                $_spot_SO += "$($_.InvocationInfo.Line)"
                $_spot_SO += " >>>>>> ERROR InvocationInfo.PositionMessage:"
                $_spot_SO += "$($_.InvocationInfo.PositionMessage)"
                $_spot_Output = $_spot_SO
                $_spot_TWOE = $false
            }

            if ($_spot_TWOE) {
                $_spot_Output += $true
            }
            else {
                $_spot_Output += $false
            }
            
            $_spot_PVs = @{}
            foreach ($_spot_i in $_spot_VTPs) {
                $_spot_PVs.($_spot_i.VarNewName) = Get-Variable -Name $_spot_i.VarName -ea 0 -ValueOnly
            }

            foreach ($_spot_cpRFI in $_spot_AH.CommandParametersRFI) {
                Set-Content -Path $_spot_cmdP.$_spot_cpRFI -Value "0000" -Confirm:$false -Force -ea 0
                Remove-Item -Path $_spot_cmdP.$_spot_cpRFI -Confirm:$false -Force -ea 0
            }
            foreach ($_spot_cpRFO in $($_spot_AH.CommandParametersRFO.Keys)) {
                Remove-Item -Path (Split-Path -Path $_spot_cmdP.$_spot_cpRFO -Parent) -Recurse -Confirm:$false -Force -ea 0
            }

            if ($Error) {
                $_spot_SBO += " >>> $(Get-Date) ERRORs encountered: $Error."
            }

            $_spot_SBO += " >>> $(Get-Date) Payload executed. Output below.`n####################################################"
            $_spot_SBO += $_spot_Output
        }
        else {
            $_spot_SBO += " >>> $(Get-Date) ERROR: At least one temp file failed to create."
            $_spot_SBO += $false
        }

        $_spot_OutH = @{
            Output = $_spot_SBO
            PublishedVariables = $_spot_PVs
        }

	    $_spot_o64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([management.automation.psserializer]::Serialize($_spot_OutH)))
        
        gcim -Namespace "root\SPOT_TD" -ClassName "SPOT_CC" -Filter "ID = 1" | scim -Property @{Data="WrittingOutData"}
        $_spot_ID = 2
        for ($_spot_i = 0; $_spot_i -lt $_spot_o64.Length; $_spot_i += 32760) {
            ncim -Namespace "root\SPOT_TD" -ClassName "SPOT_CC" -Property @{ ID = [uint32]$_spot_ID; Data = $_spot_o64.Substring($_spot_i, [Math]::Min(32760, $_spot_o64.Length - $_spot_i))} | Out-Null
            $_spot_ID++
        }
        gcim -Namespace "root\SPOT_TD" -ClassName "SPOT_CC" -Filter "ID = 1" | scim -Property @{Data="OutDataSent"}

        $_spot_St2 = Get-Date
	    while ([math]::floor(((Get-Date) - $_spot_St2).TotalSeconds) -lt $_spot_T){
		    if ((gcim -Namespace "root\SPOT_TD" -ClassName "SPOT_CC" -Filter "ID = 1" -ea 0).Data -eq "OutDataRead") {
                break
            }
            Start-Sleep -Milliseconds 50
	    }

        gcim -Namespace "root\SPOT_TD" -ClassName "SPOT_CC" -ea 0 | rcim
        $_spot_Wsc = New-Object System.Management.ManagementScope("\\.\root\SPOT_TD")
        $_spot_Wsc.Connect()
        $_spot_Wpa = New-Object System.Management.ManagementPath("SPOT_CC")
        $_spot_Wmc = New-Object System.Management.ManagementClass($_spot_Wsc,$_spot_Wpa,$null)
        $_spot_Wmc.Delete()
        gcim -Namespace "root" -ClassName __Namespace -Filter "Name='SPOT_TD'" | rcim
    }

    $WMIParameters = @{
        ScriptBlock  = $ScriptBlock
        ArgumentList = $ArgumentList
    }

    ######################################
    # preparing the ParamList to be passed to the runspace
    $ParamList = @{
        RemoteComputer      = $RemoteComputer
        Credential          = $Credential
        CompKey             = $CompKey
        WMIParameters       = $WMIParameters
        _spot_PublishedData = $null
    }
    ######
    if ($VariablesToPublish -or ($CommandName -in ("Execute-SSHScript","Execute-TelnetScript"))) {
        # add the PublishedData variable only if needed to publish something or for commands that need it (otherwise it is a waste of resources)
        $ParamList._spot_PublishedData = $PublishedData
    }

    #############################################################################################
    # start to define what happens inside runspace
    $powershell.AddScript({
        Param (
        [string]$RemoteComputer,
        [System.Management.Automation.PSCredential]$Credential,
        [hashtable]$WMIParameters,
        [string]$CompKey,
        [hashtable]$_spot_PublishedData
        )

        $innerParams = @{
            RemoteComputer      = [string]$RemoteComputer
            Credential          = [System.Management.Automation.PSCredential]$Credential
            WMIParameters       = [hashtable]$WMIParameters
            CompKey             = [string]$CompKey
            _spot_PublishedData = [hashtable]$_spot_PublishedData
        }
# child scope against cross bleeding of variables inside the runspacepool
& {
    Param (
    [string]$RemoteComputer,
    [System.Management.Automation.PSCredential]$Credential,
    [hashtable]$WMIParameters,
    [string]$CompKey,
    [hashtable]$_spot_PublishedData
    )

######################################
Write-SPOTLog " ############# ORCHESTRATOR LOGGING: Launching step function ""$($WMIParameters.ArgumentList.Command)"" with credential ""$($Credential.UserName)"" on remote computer ""$RemoteComputer"" over OWMI with Timeout ""$($OrchVars._StepTimeout)"" seconds. #############"

######################################
# stamp all SPOT related functions inside the runspace
foreach ($funcName in $_spot_FunctionNames) {
    (Get-Command -Name $funcName -CommandType Function -ErrorAction Stop).Description = "#SPOT"
}

######################################
# testing the availability of the remote execution TCP port on the remote computer
$TCPTestResult = Test-SPOTTCPPort -TargetIP $RemoteComputer -TCPPort "135"
if (!($TCPTestResult.TcpTestSucceeded)) {
    Write-SPOTLog " ############# ORCHESTRATOR LOGGING: ERROR: Connecting to the WMI (RPC Endpoint Mapper) port on remote computer ""$RemoteComputer"" failed! Ping test result was: $($TCPTestResult.PingSucceeded). #############"
    return $false
}

######################################
# prepare the encoded command
$WMIParameters.ScriptBlock = [ScriptBlock]::Create($WMIParameters.ScriptBlock)
$encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($WMIParameters.ScriptBlock))

# prepare the encoded arguments
$arguments = [System.Collections.ArrayList]::new()
$arguments.Add($CompKey) | Out-Null
$encodedArguments = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes([System.Management.Automation.PSSerializer]::Serialize($arguments)))

######################################
# inject the SPOT functions in the WMI arguments
$WMIParameters.ArgumentList.Functions = Get-Command | Where {$_.Name -in $_spot_FunctionNames}

######################################
# inject the needed Referenced Files/Folders in the WMI arguments
if ($WMIParameters.ArgumentList.CommandParameters) {
    # there are command parameters defined; checking for $RFI or $RFO (file variables) and managing the file/folder transfer to the target computer
    try {
        $CmdParametersRF = Process-SPOTCommandParamsRF -CommandParameters $WMIParameters.ArgumentList.CommandParameters
    }
    catch {
        Write-SPOTLog ">>> T.ERROR while processing Referenced Files/Folders on the ""$RemoteComputer"" remote computer for the ""$($WMIParameters.ArgumentList.Command)"" command: $_."
        return $false
    }
    $WMIParameters.ArgumentList.CommandParameters    = $CmdParametersRF.CommandParameters
    $WMIParameters.ArgumentList.CommandParametersRFI = $CmdParametersRF.CommandParametersRFI
    $WMIParameters.ArgumentList.CommandParametersRFO = $CmdParametersRF.CommandParametersRFO
}

######################################
# prepare the actual arguments object for sending over pipe
$encodedArgumentList = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([System.Management.Automation.PSSerializer]::Serialize($WMIParameters.ArgumentList)))

######################################
# launch the command over WMI/Dcom after all preparations have been done
try {
    $CimSession = New-CimSession -ComputerName $RemoteComputer -Credential $Credential -SessionOption (New-CimSessionOption -Protocol Dcom)
    Get-CimInstance -CimSession $CimSession -Namespace "root\SPOT_TD" -ClassName "SPOT_CC" -Filter "ID = 1" -ErrorAction SilentlyContinue | Set-CimInstance -Property @{Data="StatusCleared"}
    $holderData = Invoke-CimMethod -CimSession $CimSession -ClassName Win32_Process -MethodName Create `
        -Arguments @{ CommandLine = "powershell.exe -WindowStyle Hidden -encodedCommand $encodedCommand -encodedArguments $encodedArguments" }
}
catch {
    Write-SPOTLog  " ############# ORCHESTRATOR LOGGING: ERROR while invoking the WMI Method on the ""$RemoteComputer"" remote computer: $_"
    return $false
}

######################################
# sanity check of the returned data to the WMI call
if ($holderData.ReturnValue -eq "0") {
    Write-SPOTLog  " ############# ORCHESTRATOR LOGGING: The remote WMI execution seems to be launched successfully. #############" -DBG $true
}
else {
    Write-SPOTLog  " ############# ORCHESTRATOR LOGGING: WARNING: The remote WMI execution does not seem to be launched successfully. ReturnValue was: $($holderData.ReturnValue)  #############" -DBG $true
}

######################################
# start the Data Transfer handling between the local computer and the remote computer
$_spot_DataSent = $false
$_spot_T = 120
$_spot_St1 = Get-Date
while ([math]::floor(((Get-Date) - $_spot_St1).TotalSeconds) -lt $_spot_T){
    if ((Get-CimInstance -CimSession $CimSession -Namespace "root\SPOT_TD" -ClassName "SPOT_CC" -Filter "ID = 1" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Data) -eq "rtrData") {
        # the remote computer is ready; sending the data
        Write-SPOTLog  " ############# ORCHESTRATOR LOGGING: The remote computer is ready to receive the SPOT Data. Sending it now. #############" -DBG $true
        Get-CimInstance -CimSession $CimSession -Namespace "root\SPOT_TD" -ClassName "SPOT_CC" -Filter "ID = 1" | Set-CimInstance -Property @{Data="SendingData"}
        $_spot_ID = 2
        for ($_spot_i = 0; $_spot_i -lt $encodedArgumentList.Length; $_spot_i += 32760) {
            New-CimInstance -CimSession $CimSession -Namespace "root\SPOT_TD" -ClassName "SPOT_CC" -Property @{ ID = [uint32]$_spot_ID; Data = $encodedArgumentList.Substring($_spot_i, [Math]::Min(32760, $encodedArgumentList.Length - $_spot_i))} | Out-Null
            $_spot_ID++
        }
        # marking the data as sent
        Get-CimInstance -CimSession $CimSession -Namespace "root\SPOT_TD" -ClassName "SPOT_CC" -Filter "ID = 1" | Set-CimInstance -Property @{Data="DataSent"}
        $_spot_DataSent = $true
        break
    }
    Start-Sleep -Milliseconds 50
}

######################################
if (!$_spot_DataSent) {
    Write-SPOTLog  " ############# ORCHESTRATOR LOGGING: ERROR: The remote computer was not ready for receiving data in the allowed timeout. Cannot continue. #############"
    # cleanup CIM Session
    Remove-CimSession -CimSession $CimSession -ErrorAction SilentlyContinue
    return $false
}

######################################
# waiting for the output data
Write-SPOTLog  " ############# ORCHESTRATOR LOGGING: Waiting for the remote computer to write the output data to WMI. #############" -DBG $true
$StepTimeout = $OrchVars._StepTimeout
$_spot_St2 = Get-Date
while ([math]::floor(((Get-Date) - $_spot_St2).TotalSeconds) -lt $StepTimeout){
    if ((Get-CimInstance -CimSession $CimSession -Namespace "root\SPOT_TD" -ClassName "SPOT_CC" -Filter "ID = 1" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Data) -eq "OutDataSent") {
        Write-SPOTLog  " ############# ORCHESTRATOR LOGGING: Reading WMI output data from the remote computer. #############" -DBG $true
        $_spot_WMIData = @(Get-CimInstance -CimSession $CimSession -Namespace "root\SPOT_TD" -ClassName "SPOT_CC" -Filter "ID != 1")
        $_spot_RB64 = ""
        foreach ($_spot_ID in ($_spot_WMIData.ID | Sort-Object)) {
            $_spot_RB64 += ($_spot_WMIData.Where{($_.ID -eq $_spot_ID)}).Data
        }
        # marking the data as received
        Get-CimInstance -CimSession $CimSession -Namespace "root\SPOT_TD" -ClassName "SPOT_CC" -Filter "ID = 1" | Set-CimInstance -Property @{Data="OutDataRead"}
        break
    }
    Start-Sleep -Seconds 2
}

######################################
# cleanup CIM Session at this point no matter what
Remove-CimSession -CimSession $CimSession -ErrorAction SilentlyContinue

######################################
if (!$_spot_RB64) {
    Write-SPOTLog  " ############# ORCHESTRATOR LOGGING: ERROR: The WMI Output Data could not be read from the remote computer. Cannot continue. #############"
    return $false
}

######################################
# decode OutputHash 
try {
    $OH = [System.Management.Automation.PSSerializer]::Deserialize([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_spot_RB64)))
}
catch {
    Write-SPOTLog "ERROR: while trying to deserialize the OutputHash: $_."
}

######################################
# handling the Published Variables
if ($WMIParameters.ArgumentList._spot_VTPs) {
    foreach ($entry in $OH.PublishedVariables.GetEnumerator()) {
        $_spot_PublishedData.($entry.Name) = $entry.Value
    }
}

######################################
# logging the remote output from the runspace
Write-SPOTLog " ############# ORCHESTRATOR LOGGING: Finished step function ""$($WMIParameters.ArgumentList.Command)"" on remote computer ""$RemoteComputer"" over OWMI. Full session output below. #############"
$OH.Output

} @innerParams
# cleanup of used parameters
$RemoteComputer      = $null
$Credential          = $null
$WMIParameters       = $null
$CompKey             = $null
$_spot_PublishedData = $null
$innerParams         = $null
$Error.Clear()

}).AddParameters($ParamList) | Out-Null
    
    # start the runspace objects
    $handle = $powershell.BeginInvoke()
    $return = @{}
    $return.Target = $null
    $return.GUID = $null
    $return.Name = $null
    $return.Type = $null
    $return.Processed = $null

    $return.handle = $handle
    $return.powershell = $powershell
    $returnObject = [pscustomobject]$return

    # return the Job object (runspace objects + some metadata)
    return $returnObject

} # end of PowershellCommandRemoteOWMI function


######################################################################################################################
# Runbook Internal Functions
######################################################################################################################
function Execute-SPOTRunbook {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the GUID of the runbook to execute
        $GUID, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [bool]
        # if true, the runbook steps will execute only the steps that are not already in state Completed
        $Resume = $false, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [bool]
        # if true, the current runbook is executed in a separate remote and temporary environment
        $Remote = $false, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [hashtable]
        # the hashtable with all needed SPOT variables (for remote execution)
        $RemoteSPOTVariables, 
        [Parameter(Mandatory=$false)]
        [AllowNull()]
        [string]
        # the SPOT path for the SSHNet dll file (for remote execution)
        $SshNetPath, 
        [Parameter(Mandatory=$false)]
        [AllowNull()]
        [string]
        # the SPOT path for the PsExec exe file (for remote execution)
        $PsExecPath, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the SPOT project path (for remote execution)
        $ProjectPath 
    )
    
    # handle the remote execution case
    if ($Remote) {
        Write-SPOTLog "__##__Detected remote execution for Runbook. Processing remote variables.__##__" -DBG $true
        # the Orchvars hashtable should be already defined, but not synchronized in the new environment; making it synchronized
        $OrchVars      = Get-SPOTDeepCloneSynchronized -InputObject $OrchVars
        $PublishedData = Get-SPOTDeepCloneSynchronized -InputObject $RemoteSPOTVariables.PublishedData
        $SVars         = Get-SPOTDeepCloneSynchronized -InputObject $RemoteSPOTVariables.SVars

        # define SPOT Classes
        $SPOTClasses = [scriptblock]::Create([System.Text.Encoding]::UTF8.GetString([convert]::FromBase64String($OrchVars._SPOTClassDef)))
        . $SPOTClasses

        # initialize the AllRunbooks and AllRunbookSteps hashtables
        $global:AllRunbooks = [hashtable]::Synchronized(@{})
        $global:AllRunbookSteps = [hashtable]::Synchronized(@{})

        # get the composition key
        $RunbookCompKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($RemoteSPOTVariables.RunbookCompKey))

        # recompose the runbook using the composition key above
        $DRunbook = [System.Management.Automation.PSSerializer]::Deserialize([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($RemoteSPOTVariables.Runbook)))
        $Runbook = Recompose-SPOTRunbook -DRunbook $DRunbook -Key $RunbookCompKey -ErrorAction Stop

        # overwrite specific values
        if ($OrchVars._SshNetPath) {
            Write-SPOTLog "__##__Setting SshNetPath to ""$SshNetPath"".__##__" -DBG $true
            $OrchVars._SshNetPath = $SshNetPath
        }
        if ($OrchVars._PsExecPath) {
            Write-SPOTLog "__##__Setting PsExecPath to ""$PsExecPath"".__##__" -DBG $true
            $OrchVars._PsExecPath = $PsExecPath
        }
        $InitialProjectPath = $OrchVars._ProjectPath
        $ProjectFolder = Get-Item -Path $ProjectPath -ErrorAction SilentlyContinue
        if ($ProjectFolder) {
            Write-SPOTLog "__##__Detected temporary remote execution project folder ""$($ProjectFolder.FullName)"".__##__" -DBG $true 
        }
        else {
            Write-SPOTLog "__##__Temporary remote execution project folder not properly detected. Path used ""$ProjectPath"". Cannot continue.__##__" -DBG $true
            throw "Execute-SPOTRunbook: remote project folder not detected!"
        }
        
        $OrchVars._ProjectPath = $ProjectFolder.FullName
        $OrchVars._SPOTPath = $null

        # at the beginning of the initialization of the main Runbook Job, start also the SPOT RunspacePool in this new remote environment
        $global:_spot_MainWorkerPool = Create-SPOTRsPool -MaxNumber $OrchVars._SPOTRsPoolMax

    }
    else {
        $Runbook = $AllRunbooks.$GUID
    }
    
    # manage the execution of a runbook, with the steps in the desired order
    Write-SPOTLog "__##__Starting execution for Runbook ""$($Runbook.Name)"".__##__" -DBG $true

    if ($Remote) {
        # initialize the SPOT environment with temporary Firewall Rule, TrustedHosts

        ###############
        Write-SPOTLog ">>> Get the initial PSRemoting trust value." -DBG $true 
        # Enable-PSRemoting -Force -SkipNetworkProfileCheck
        ########
        try {
            $InitialTHValue = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Client" -Name "trusted_hosts" -ErrorAction Stop).trusted_hosts
        }
        catch {
            Write-SPOTLog "__##__Could not get the initial WinRM TrustedHosts value: $_.__##__" -DBG $true
            throw "Execute-SPOTRunbook: the TrustedHosts initial value could not be determined!"
        }
        
        ###############
        if ($InitialTHValue -ne '*') {
            Write-SPOTLog ">>> Set the PSRemoting trust value to trust all (*)." -DBG $true 
            try {
                New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Client" -Name "trusted_hosts" -PropertyType String -Value '*' -Force -Confirm:$false -ErrorAction Stop
            }
            catch {
                Write-SPOTLog "__##__ERROR while setting the PSRemoting trust value: $_.__##__" -DBG $true
                throw "Execute-SPOTRunbook: failed to set PSRemoting trust value!"
            }
        }
        
        ###############
        Write-SPOTLog ">>> Get initial and set the AcceptEULA for PsExec temporarily for the remote usage." -DBG $true
        try {
            $InitialSysinternalsReg = Test-Path -Path "HKCU:\Software\Sysinternals\PsExec" -PathType Container
            if ($InitialSysinternalsReg) {
                Write-SPOTLog ">>>> Initial PsExec registry key found." -DBG $true
                $InitialSysinternalsEula = (Get-ItemProperty -Path "HKCU:\Software\Sysinternals\PsExec" -ErrorAction SilentlyContinue).EulaAccepted
                Write-SPOTLog ">>>> Initial SysinternalsEula for PsExec registry entry: $InitialSysinternalsEula." -DBG $true
            }
            else {
                Write-SPOTLog ">>>> Initial PsExec registry key not found. Creating it now." -DBG $true
                New-Item -Path "HKCU:\Software\Sysinternals\PsExec" -Confirm:$false -Force | Out-Null
            }
            Write-SPOTLog ">>>> Setting SysinternalsEula for PsExec registry entry now." -DBG $true
            Set-ItemProperty -Path "HKCU:\Software\Sysinternals\PsExec" -Name "EulaAccepted" -Value 1 -Confirm:$false -Force
        }
        catch {
            Write-SPOTLog "__##__ERROR while handling the PsExec AcceptEULA value: $_.__##__" -DBG $true
            throw "Execute-SPOTRunbook: error handling the PsExec AcceptEULA value!"
        }
        
        ###############
        $ToRemoveSPOTFWRule = $false
        if (!(Get-NetFirewallRule | Where {$_.DisplayName -eq "Allow TCP 5985/445/22/23 Outbound"})) {
            Write-SPOTLog ">>> The Firewall rule for TCP 5985/445/22/23 outbound access was not detected. Creating it now." -DBG $true 
            $ToRemoveSPOTFWRule = $true
            New-NetFirewallRule -DisplayName "Allow TCP 5985/445/22/23 Outbound" -Direction Outbound -Profile Any -Protocol TCP -RemotePort 5985,445,22,23 -Action Allow -Group SPOT | Out-Null
        }
        else {
            Write-SPOTLog ">>> The Firewall rule for TCP 5985/445/22/23 outbound access was detected." -DBG $true 
        }

        ###############
        Write-SPOTLog ">>> Adapt the ArtefactsPath to the new environment." -DBG $true 
        Replace-SPOTArtefactsPath -Runbook $Runbook -MatchString $InitialProjectPath -ReplaceString $OrchVars._ProjectPath
        Write-SPOTLog ">>> Main runbook ""$($Runbook.Name)"" has now artefacts path ""$($Runbook.ArtefactsPath)""." -DBG $true 
    }

    # create an array clone to avoid access issues to the same synced variable
    $RunbookSteps = $Runbook.RunbookSteps | ForEach-Object {$_}
    # get the sequences and execute the runbook steps based on their sequence numbers
    $Sequences = $RunbookSteps.Seq | Select-Object -Unique

    ####
    if ($Resume) {
        Write-SPOTLog "__##__Resuming Runbook ""$($Runbook.Name)"".__##__" -DBG $true
    }
    
    foreach ($Seq in $Sequences) {

        if ($OrchVars._StopFlag) {
            # the stop flag is evaluated at the beginning of each Seq, even if it is triggered while the previous Seq is running
            # this way, the Runbook will naturally stop without any step remaining in an executing status (local or remote)
            Write-SPOTLog "__##__STOP COMMAND DETECTED! SIGNALLING THE ENTIRE RUNBOOK TO STOP.__##__"
            $Runbook.StopFlag = $true
            if ($Remote) {
                try {
                    . Finalize-SPOTRemoteExecution -Runbook $Runbook -InitialTHValue $InitialTHValue -ToRemoveSPOTFWRule $ToRemoveSPOTFWRule -InitialSysinternalsReg $InitialSysinternalsReg -InitialSysinternalsEula $InitialSysinternalsEula
                }
                catch {
                    Write-SPOTLog "__##__ERROR: while finalizing the remote runbook execution: $_.__##__"
                    throw "Execute-SPOTRunbook: finalizing remote runbook execution failure!"
                }
            }
            return $true
        }

        $CurrentSteps = $null
        $CurrentJbs = $null
        $ReplaceResult = $null

        # get all steps with the current sequence number
        $CurrentSteps = $RunbookSteps.Where({$_.Seq -eq $Seq})
        # initialize execution jobs array for all current steps
        $CurrentJbs = @()
        $CurrentActiveSteps = @()
        # trigger execution for all active steps with the current sequence number
        foreach ($Step in $CurrentSteps) {
            #####
            # first, check if the current step is disabled
            if ($Step.Disabled -eq $true) {
                Write-SPOTLog "__##__Current Step with name ""$($Step.Name)"" is marked as Disabled. Skipping it.__##__" -DBG $true
                continue
            }
            #####
            # replace the remaining references (mainly PVs)
            if ($Step.GetType().Name -eq "Runbook") {
                Write-SPOTLog "__##__Replacing remaining SPOT Vars for Runbook ""$($Step.Name)"" with GUID ""$($Step.GUID)"".__##__" -DBG $true
                Replace-SPOTVarsInRunbookJIT -Runbook $Step
                Write-SPOTLog "__##__Checking conditions for Runbook ""$($Step.Name)"" with GUID ""$($Step.GUID)"".__##__" -DBG $true
            }
            else {
                Write-SPOTLog "__##__Replacing remaining SPOT Vars for RunbookStep ""$($Step.Name)"" with GUID ""$($Step.GUID)"".__##__" -DBG $true
                Replace-SPOTVarsInRunbookStepJIT -RunbookStep $Step -RbParameters $Runbook.RunbookParameters
                Write-SPOTLog "__##__Checking conditions for RunbookStep ""$($Step.Name)"" with GUID ""$($Step.GUID)"".__##__" -DBG $true
            }
            #####
            # check the conditions to see if we execute the step
            foreach ($condition in $Step.Conditions) {
                if ($condition -in ("$false","",$null)) {
                    Write-SPOTLog "__##__Current condition ""$condition"" evaluated to $false. Skipping the curent step.__##__" -DBG $true
                    $Step.Status = "Skipped"
                    break
                }
                else {
                    Write-SPOTLog "__##__Current condition ""$condition"" evaluated to $true.__##__" -DBG $true
                }
            }
            if ($Step.Status -eq "Skipped") {
                continue
            }
            #####
            # launch the step (unless this is a resume and this step was already successful)
            if ($Resume) {
                if ($Step.Status -in ("Initial","Error","Paused")) {
                    Write-SPOTLog "__##__RunbookStep ""$($Step.Name)"" detected with status ""$($Step.Status)"".__##__" -DBG $true
                    if ($Step.GetType().Name -eq "Runbook") {
                        # split based on remote or not
                        if ($Step.RemoteParameters.RemoteComputer) {
                            # this is a remote runbook execution
                            Write-SPOTLog "__##__Resuming remote Runbook ""$($Step.Name)"" execution with GUID ""$($Step.GUID)"".__##__" -DBG $true
                            $CurrentJbs += Start-SPOTRunbookJobRemote -GUID $Step.GUID -Resume $true
                        }
                        else {
                            Write-SPOTLog "__##__Resuming local Runbook ""$($Step.Name)"" execution with GUID ""$($Step.GUID)"".__##__" -DBG $true
                            $CurrentJbs += Start-SPOTRunbookJob -GUID $Step.GUID -Resume $true
                        }
                    }
                    else {
                        Write-SPOTLog "__##__Resuming RunbookStep ""$($Step.Name)"" execution with GUID ""$($Step.GUID)"".__##__" -DBG $true
                        # reinitialize the LastExecutionTimes for resuming execution of steps
                        $Step.LastExecutionTime = [datetime]::MinValue
                        $Step.MultiLastExecutionTime = @{}
                        # start the step again
                        $CurrentJbs += Start-SPOTRunbookStepJob -GUID $Step.GUID
                    }
                }
                else {
                    Write-SPOTLog "__##__RunbookStep ""$($Step.Name)"" detected with status ""$($Step.Status)"". Skipping it during resume.__##__" -DBG $true
                    continue
                }
            }
            else {
                if ($Step.GetType().Name -eq "Runbook") {
                    # case for local or remote runbook job, as there are two distinct functions for these
                    if ($Step.RemoteParameters.RemoteComputer) {
                        # this was a remote runbook execution
                        Write-SPOTLog "__##__Starting remote Runbook ""$($Step.Name)"" execution with GUID ""$($Step.GUID)"".__##__" -DBG $true
                        $CurrentJbs += Start-SPOTRunbookJobRemote -GUID $Step.GUID
                    }
                    else {
                        Write-SPOTLog "__##__Starting local Runbook ""$($Step.Name)"" execution with GUID ""$($Step.GUID)"".__##__" -DBG $true
                        $CurrentJbs += Start-SPOTRunbookJob -GUID $Step.GUID
                    }
                }
                else {
                    Write-SPOTLog "__##__Staring RunbookStep ""$($Step.Name)"" execution with GUID ""$($Step.GUID)"".__##__" -DBG $true
                    $StartedRSJobs = Start-SPOTRunbookStepJob -GUID $Step.GUID
                    if ($StartedRSJobs -eq $false) { Write-SPOTLog "WARNING: The job(s) from the step ""$($Step.Name)"" were not started." }
                    else { $CurrentJbs += $StartedRSJobs }
                }
            }

            # if we reach here in this iteration, it means the current Step is active and should be checked for execution status later
            Write-SPOTLog "__##__Adding Step ""$($Step.Name)"" to the CurrentActiveSteps array.__##__" -DBG $true
            $CurrentActiveSteps += $Step
            
        }
        Start-Sleep -Seconds 1
        # check that the CurrentJobs array is not empty (due to disabled, skipped or already completed steps)
        if (!$CurrentJbs) {
            Write-SPOTLog "__##__For sequence ""$Seq"" in Runbook ""$($Runbook.Name)"" there are no active jobs. Skipping it.__##__" -DBG $true
            continue
        }

        # check all steps with the current sequence number until they are all processes (finished one way or another)
        Write-SPOTLog "__##__Current Jobs in sequence $Seq : $($CurrentJbs.Name) and count: $($CurrentJbs.Count).__##__" -DBG $true
        while ($false -in $CurrentJbs.Processed) {
            $Jb = $null
            Start-Sleep -Seconds 4
            foreach ($Jb in $CurrentJbs) {
                if ($Jb.handle.IsCompleted -and !$Jb.Processed) {
                    if ($Jb.Type -eq "Runbook") {
                        Write-SPOTLog "__##__Getting Runbook ""$($Jb.Name)"" results.__##__" -DBG $true
                        Get-SPOTRunbookJobResult -RunbookJob $Jb
                    }
                    else {
                        Write-SPOTLog "__##__Getting RunbookStep ""$($Jb.Name)"" results.__##__" -DBG $true
                        Get-SPOTRunbookStepJobResult -RunbookStepJob $Jb
                    }
                }
            }
        }
        # check if all active steps were successful, before going to the next sequence (with the exception of jobs from steps marked with ContinueOnError flag)
        $CurrentActiveStepsWithoutCOE = $CurrentActiveSteps | Where {$_.ContinueOnError -eq $false}
        if ($CurrentActiveStepsWithoutCOE) {
            if ([string]($CurrentActiveStepsWithoutCOE.ExitValue | Select-Object -Unique) -ne $true) {
                Write-SPOTLog "__##__ERROR: Some steps in the current sequence without the flag ContinueOnError returned failure. Stopping the entire runbook.__##__"
                if ($Remote) {
                    # populate the RunbookArtefacts and RunbookSummary variables to be published and available to the calling environment
                    try {
                        . Finalize-SPOTRemoteExecution -Runbook $Runbook -InitialTHValue $InitialTHValue -ToRemoveSPOTFWRule $ToRemoveSPOTFWRule -InitialSysinternalsReg $InitialSysinternalsReg -InitialSysinternalsEula $InitialSysinternalsEula
                    }
                    catch {
                        Write-SPOTLog "__##__ERROR: while finalizing the remote runbook execution: $_.__##__"
                        throw "Execute-SPOTRunbook: finalizing remote runbook execution failure!"
                    }
                }
                throw "Execute-SPOTRunbook: step failure!"
            }
        }
    }

    # archive the output logs from the target Runbook and load the content into a variable, to be published and made available back in the calling SPOT enviroment
    if ($Remote) {
        # prepare the data for the parent runbook
        try {
            . Finalize-SPOTRemoteExecution -Runbook $Runbook -InitialTHValue $InitialTHValue -ToRemoveSPOTFWRule $ToRemoveSPOTFWRule -InitialSysinternalsReg $InitialSysinternalsReg -InitialSysinternalsEula $InitialSysinternalsEula
        }
        catch {
            Write-SPOTLog "__##__ERROR: while finalizing the remote runbook execution: $_.__##__"
            throw "Execute-SPOTRunbook: finalizing remote runbook execution failure!"
        }
        
        # close and dispose the main worker pool from this main remote runbook execution environment
        $_spot_MainWorkerPool.Dispose()
    }

    # if we reach here, it means success
    Write-SPOTLog "__##__Runbook ""$($Runbook.Name)"" executed successfully.__##__" -DBG $true
    
} # enf of Execute-SPOTRunbook function

######################################################################################################################
function Start-SPOTRunbookJob {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the GUID of the runbook to execute
        $GUID, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [bool]
        # if true, the runbook steps will execute only the steps that are not already in state Completed
        $Resume = $false 
    )

    ########
    $Runbook = $AllRunbooks.$GUID
    Write-SPOTLog "__###__Starting job for Runbook ""$($Runbook.Name)"".__###__" -Output $false -DBG $true

    ########
    # first thing, make sure the StopFlag is set to false to be able to execute and initialize the StartTime
    $Runbook.StopFlag = $false
    $Runbook.StartTime = Get-date

    ########
    Write-SPOTLog "__###__Preparing parameters for Runbook ""$($Runbook.Name)"".__###__" -Output $false -DBG $true

    $FunctionParameters = @{
        GUID = $GUID
    }
    if ($Resume) {
        $FunctionParameters += @{
            Resume = $true
        }
    }
    $FunctionParams = @{
        CommandName = "Execute-SPOTRunbook"
        CommandParameters = $FunctionParameters
    }

    ########
    Write-SPOTLog "__###__Launching job for Runbook ""$($Runbook.Name)"".__###__" -Output $false -DBG $true
    $RunbookJob           =  & PowershellCommandLocal @FunctionParams
    $RunbookJob.GUID      = $GUID
    $RunbookJob.Name      = $Runbook.Name
    $RunbookJob.Type      = "Runbook"
    $RunbookJob.Processed = $false

    ########
    if ($RunbookJob.handle.GetType().Name -eq "PowerShellAsyncResult") {
        # process seems to be launched successfully
        Write-SPOTLog "__###__Handle type detected successfully for Runbook ""$($Runbook.Name)"".__###__" -Output $false -DBG $true
        $Runbook.Status = "Executing"
    }
    else {
        Write-SPOTLog "__###__ERROR: Starting job for runbook ""$($Runbook.Name)"" failed. Orchestration error as the Runspace object was not returned as expected!__###__" -Output $false
        $Runbook.Status = "Error"
    }

    ########
    return $RunbookJob

} # enf of Start-SPOTRunbookJob function

######################################################################################################################
function Start-SPOTRunbookJobRemote {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the GUID of the runbook to execute
        $GUID, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [bool]
        # if true, the runbook steps will execute only the steps that are not already in state Completed
        $Resume = $false
    )

    ########
    $Runbook = $AllRunbooks.$GUID
    Write-SPOTLog "__###__Starting job for remote Runbook ""$($Runbook.Name)"" with function ""$($Runbook.RemoteParameters.ExecFunction)"" and credential ""$($Runbook.RemoteParameters.Credential.UserName)"" on remote computer ""$($Runbook.RemoteParameters.RemoteComputer)"".__###__" -Output $false -DBG $true

    ########
    # first thing, we make sure the StopFlag is set to false to be able to execute and initialize the StartTime
    $Runbook.StopFlag = $false
    $Runbook.StartTime = Get-date

    ########
    Write-SPOTLog "__###__Preparing parameters for remote Runbook ""$($Runbook.Name)"".__###__" -Output $false -DBG $true
    # define the composition key for the main runbook; it will be transported to the destination as a securestring
    $RunbookCompKey = "$(-join (((48..57)+(97..122)) * 80 | Get-Random -Count 32 |%{[char]$_}))"

    # do the runbook serialization now
    $CloneRunbook = Decompose-SPOTRunbook -InputRunbook $Runbook -Key $RunbookCompKey
    $b64Serialized = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([management.automation.psserializer]::Serialize($CloneRunbook, 10)))

    ########
    $FunctionParameters = @{
        GUID = $GUID
        Remote = $true
        ProjectPath = '$RFO:.'
        RemoteSPOTVariables = @{
            # include the composition key as a securestring, to be handled securely by the remote function
            RunbookCompKey = ConvertTo-SecureString -String $RunbookCompKey -AsPlainText -Force
            # include the main runbook object of interest, to be executed remotely, decomposed
            Runbook = $b64Serialized
            PublishedData = $PublishedData
            SVars = $SVars
        }
        Resume = $Resume
    }
    if ($OrchVars._PsExecPath) {
        $FunctionParameters += @{
            PsExecPath = '$RFO:PSEXEC'
        }
    }
    if ($OrchVars._SshNetPath) {
        $FunctionParameters += @{
            SshNetPath = '$RFO:SSHNET'
        }
    }

    ########
    # the published variables have the GUID as suffix for the case there are separate child runbooks executed in parallel on different computers (not implied parallel)
    $FunctionParams = @{
        CommandName        = "Execute-SPOTRunbook"
        CommandParameters  = $FunctionParameters
        RemoteComputer     = $Runbook.RemoteParameters.RemoteComputer
        Credential         = $Runbook.RemoteParameters.Credential
        VariablesToPublish = ("RunbookSummary=RunbookSummary_$GUID","PublishedData=PublishedData_$GUID","RunbookArtefacts=RunbookArtefacts_$GUID")
    }
    if ($Runbook.RemoteParameters.AsSystem) {
        $FunctionParams += @{
            AsSystem = $true
        }
    }
    if ($Runbook.RemoteParameters.UseSSL) {
        $FunctionParams += @{
            UseSSL = $true
        }
    }

    ########
    foreach ($cpar in $($FunctionParams.CommandParameters.Keys)) {
        if ($FunctionParams.CommandParameters.$cpar.GetType().Name -ne "String") {
            continue
        }
        if ($FunctionParams.CommandParameters.$cpar.StartsWith('$RFO:')) {
            # get the local file path
            if (($FunctionParams.CommandParameters.$cpar -split ":")[1] -eq "SSHNET") {
                $LocalItemPath = $OrchVars._SshNetPath
            }
            elseif (($FunctionParams.CommandParameters.$cpar -split ":")[1] -eq "PSEXEC") {
                $LocalItemPath = $OrchVars._PsExecPath
            }
            else {
                $LocalItemPath = "$($OrchVars._ProjectPath)\$(($FunctionParams.CommandParameters.$cpar -split ":")[1])"
            }
            # get the local item
            $LocalItem = Get-Item -Path $LocalItemPath -ErrorAction SilentlyContinue
            if (!($LocalItem)) {
                Write-SPOTLog "ERROR: while loading the local RFO item, for the parameter ""$cpar"". Marking the entire current runbook ""$($Runbook.Name)"" as failed." -Output $false
                $Runbook.Status = "Error"
                $RunbookStep.ExitValue = $false
                return $false
            }
            # manage the archive of its entire parent folder
            Write-SPOTLog "__#__The referenced item for parameter $cpar and value ""$($FunctionParams.CommandParameters.$cpar)"" was detected as ""$($LocalItem.FullName)"". Managing the local folder archiving.__#__" -Output $false -DBG $true
            if ($LocalItem.Attributes -eq "Directory") {
                # there is no file referenced, just the folder, so use it as is
                $LocalFolder = $LocalItem
                $ReferencedFileName = "."
            }
            else {
                # there is a file referenced, so use the parent folder
                $LocalFolder = Get-Item -Path (Split-Path -Path $LocalItem.FullName -Parent) -ErrorAction SilentlyContinue
                $ReferencedFileName = $LocalItem.Name
            }
            $UniqueID = $([guid]::NewGuid().ToString())
            $TLFP = [System.IO.Path]::GetTempFileName()
            Remove-Item -Path $TLFP -Confirm:$false -Force -ErrorAction SilentlyContinue
            # create the archive and for the project folder, exclude the sensitive and not needed subfolders
            if ($LocalFolder.FullName -eq ($OrchVars._ProjectPath).TrimEnd('\')) {
                Create-SPOTProjectArchive -TargetFolder $LocalFolder.FullName -ZipPath $TLFP
            }
            else {
                Create-SPOTArchive -TargetFolder $LocalFolder.FullName -ZipPath $TLFP
            }
            # add the RFOMap entry now
            $OrchVars._RFOMap.$UniqueID = @{
                LocalArchivePath = $TLFP
                ReferencedFileName = $ReferencedFileName
            }
            # leave the same UniqueID inside the original command parameter
            $FunctionParams.CommandParameters.$cpar = '$RFO:'+$UniqueID
        }
    }
    
    ########
    Write-SPOTLog "__###__Launching remote job for Runbook ""$($Runbook.Name)"".__###__" -Output $false -DBG $true
    $RunbookJob           = & $Runbook.RemoteParameters.ExecFunction @FunctionParams
    $RunbookJob.Target    = $Runbook.RemoteParameters.RemoteComputer
    $RunbookJob.GUID      = $GUID
    $RunbookJob.Name      = $Runbook.Name
    $RunbookJob.Type      = "Runbook"
    $RunbookJob.Processed = $false

    ########
    if ($RunbookJob.handle.GetType().Name -eq "PowerShellAsyncResult") {
        # process seems to be launched successfully
        Write-SPOTLog "__###__Handle type detected successfully for Runbook ""$($Runbook.Name)"".__###__" -Output $false -DBG $true
        $Runbook.Status = "Executing"
    }
    else {
        Write-SPOTLog "__###__ERROR: Starting job for runbook ""$($Runbook.Name)"" failed. Orchestration error as the Runspace object was not returned as expected!__###__" -Output $false
        $Runbook.Status = "Error"
    }

    ########
    return $RunbookJob

} # enf of Start-SPOTRunbookJobRemote function

######################################################################################################################
function Start-SPOTRunbookStepJob {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the GUID of the runbook step to execute
        $GUID 
    )

    ########
    $RunbookStep = $AllRunbookSteps.$GUID
    Write-SPOTLog "__#__Starting job for RunbookStep ""$($RunbookStep.Name)"".__#__" -Output $false -DBG $true

    ########
    # set the StartTime
    $RunbookStep.StartTime = Get-date

    ########
    Write-SPOTLog "__#__Launching job for runbookstep ""$($RunbookStep.Name)"".__#__" -Output $false -DBG $true
    $fParams = $RunbookStep.StepParameters

    ########
    # try to detect if this is a parallel execution (potential parallel parameter is "RemoteComputer")
    $Targets = @()

    if ($fParams.GetEnumerator().Name -contains "RemoteComputer") {
        Write-SPOTLog "__#__Checking for parallel implied steps in RunbookStep ""$($RunbookStep.Name)"".__#__" -Output $false -DBG $true
        if ($fParams.RemoteComputer.GetType().Name -in ('List`1','Object[]')) {
            Write-SPOTLog "__#__Parallel Jobs detected due to ""RemoteComputer"" being a list in RunbookStep ""$($RunbookStep.Name)"".__#__" -Output $false -DBG $true
            foreach ($i in $fParams.RemoteComputer) {
                $Targets += $i
            }
        }
        elseif ($fParams.RemoteComputer -like "*,*") {
            Write-SPOTLog "__#__Parallel Jobs detected due to ""RemoteComputer"" containing the character "","" in RunbookStep ""$($RunbookStep.Name)"".__#__" -Output $false -DBG $true
            foreach ($i in ($fParams.RemoteComputer -split ',')) {
                $Targets += $i.Trim()
            }
        }
    }

    ########
    # remove duplicates, if any
    $Targets = $Targets | Select-Object -Unique

    ########
    if ($RunbookStep.Type -like "*Remote*") {
        # for remotely executed functions, we might have RFO references; managing here the archive creation and propagation to all step jobs (single or multiple)
        foreach ($cpar in $($RunbookStep.StepParameters.CommandParameters.Keys)) {
            if ($RunbookStep.StepParameters.CommandParameters.$cpar) {
                if ($RunbookStep.StepParameters.CommandParameters.$cpar.GetType().Name -eq "String") {
                    if ($RunbookStep.StepParameters.CommandParameters.$cpar.StartsWith('$RFO:')) {
                        # get the local item path
                        if (($RunbookStep.StepParameters.CommandParameters.$cpar -split ":")[1] -eq "SSHNET") {
                            $LocalFilePath = $OrchVars._SshNetPath
                        }
                        elseif (($RunbookStep.StepParameters.CommandParameters.$cpar -split ":")[1] -eq "PSEXEC") {
                            $LocalFilePath = $OrchVars._PsExecPath
                        }
                        else {
                            $LocalFilePath = "$($OrchVars._ProjectPath)\$(($RunbookStep.StepParameters.CommandParameters.$cpar -split ":")[1])"
                        }
                        # get the local item
                        $LocalItem = Get-Item -Path $LocalFilePath -ErrorAction SilentlyContinue
                        if (!($LocalItem)) {
                            Write-SPOTLog "ERROR: a local RFO referenced item, for the parameter ""$cpar"", was not found. Skipping RFO folder management for this step. The current step ""$($RunbookStep.Name)"" will fail." -Output $false
                            continue
                        }
                        # manage the archive of the folder
                        Write-SPOTLog "__#__The referenced item for parameter $cpar and value ""$($RunbookStep.StepParameters.CommandParameters.$cpar)"" was detected as ""$($LocalItem.FullName)"". Managing the local folder archiving.__#__" -Output $false -DBG $true
                        if ($LocalItem.Attributes -eq "Directory") {
                            # there is no file referenced, just the folder, so use it as is
                            $LocalFolder = $LocalItem
                            $ReferencedFileName = "."
                        }
                        else {
                            # there is a file referenced, so use the parent folder
                            $LocalFolder = Get-Item -Path (Split-Path -Path $LocalItem.FullName -Parent) -ErrorAction SilentlyContinue
                            $ReferencedFileName = $LocalItem.Name
                        }
                        $UniqueID = $([guid]::NewGuid().ToString())
                        $TLFP = [System.IO.Path]::GetTempFileName()
                        Remove-Item -Path $TLFP -Confirm:$false -Force -ErrorAction SilentlyContinue
                        Create-SPOTArchive -TargetFolder $LocalFolder.FullName -ZipPath $TLFP
                        # add the RFOMap entry now
                        $OrchVars._RFOMap.$UniqueID = @{
                            LocalArchivePath = $TLFP
                            ReferencedFileName = $ReferencedFileName
                        }
                        # leave the same UniqueID inside the original command parameter
                        $RunbookStep.StepParameters.CommandParameters.$cpar = '$RFO:'+$UniqueID
                    }
                }
            }
        }
    }

    $RunbookStepJobs = @()
    if ($Targets) {
        # this is an implied parallel execution
        foreach ($Target in $Targets) {
            $RunbookStepJob = $null
            $fParams = Get-SPOTDeepClone -InputObject $RunbookStep.StepParameters
            Write-SPOTLog "__#__Starting StepJob for RunbookStep ""$($RunbookStep.Name)"" on target ""$Target"".__#__" -Output $false -DBG $true
            # modify the target parameter to apply to single targets, as we have parallel execution here
            $fParams.RemoteComputer = $Target
            # modify any potential VariablesToPublish with a suffix of the Target, to be able to keep all variables from all parallel executions under modified name
            # this ( - character is not allowed as part of a variable name) will also signal to the execution inside the step that the actual variable value is the one without the target name
            if ($fParams.VariablesToPublish) {
                Write-SPOTLog "__#__Adding the -$Target suffix to all VariablesToPublish.__#__" -Output $false -DBG $true
                $fParams.VariablesToPublish = $fParams.VariablesToPublish | % {$_+"-$Target"}
            }
            $RunbookStepJob           = & $RunbookStep.Type @fParams
            $RunbookStepJob.Target    = $Target
            $RunbookStepJob.GUID      = $GUID
            $RunbookStepJob.Name      = $RunbookStep.Name
            $RunbookStepJob.Type      = "RunbookStep"
            $RunbookStepJob.Processed = $false
            $RunbookStepJobs += $RunbookStepJob
        }
    }
    else {
        # this is a normal/single execution
        $fParams = Get-SPOTDeepClone -InputObject $RunbookStep.StepParameters
        Write-SPOTLog "__#__Starting StepJob for RunbookStep ""$($RunbookStep.Name)"" on a single target.__#__" -Output $false -DBG $true
        $RunbookStepJob           = & $RunbookStep.Type @fParams
        $RunbookStepJob.GUID      = $GUID
        $RunbookStepJob.Name      = $RunbookStep.Name
        $RunbookStepJob.Type      = "RunbookStep"
        $RunbookStepJob.Processed = $false
        $RunbookStepJobs += $RunbookStepJob
    }
    
    ########
    # The RunbookStep is considered "Executing" if at least one parallel target is launched succesfully 
    # The RunbookStep is considered "Error" if all parallel target are failed to launch succesfully
    $Status = "Error"
    foreach ($Job in $RunbookStepJobs) {
        if ($Job.handle.GetType().Name -eq "PowerShellAsyncResult") {
            # process seems to be launched successfully
            if ($Targets) {
                Write-SPOTLog "__#__Handle type detected successfully in runbookstep ""$($RunbookStep.Name)"" and target ""$($Job.Target)"".__#__" -Output $false -DBG $true
                $RunbookStep.MultiStatus.($Job.Target) = "Executing"
                $RunbookStep.MultiRetryCount.($Job.Target) = $RunbookStep.RetryCount
            }
            else {
                Write-SPOTLog "__#__Handle type detected successfully in runbookstep ""$($RunbookStep.Name)"".__#__" -Output $false -DBG $true
                # for single executions, the RetryCount parameter remains as defined
            }
            # the normal/main Status property is set to Executing if at least one parallel target is launched succesfully 
            $Status = "Executing"
        }
        else {
            if ($Targets) {
                Write-SPOTLog "__#__ERROR: Starting job for runbookstep ""$($RunbookStep.Name)"" and target ""$($Job.Target)"" failed. Orchestration error as the Runspace object was not returned as expected!__#__" -Output $false
                $RunbookStep.MultiStatus.($Job.Target) = "Error"
                # for failed execution, if there is an issue with the launching of a runspace, most likely trying the same thing twice will also not work
                $RunbookStep.MultiRetryCount.($Job.Target) = 0
            }
            else {
                Write-SPOTLog "__#__ERROR: Starting job for runbookstep ""$($RunbookStep.Name)"" failed. Orchestration error as the Runspace object was not returned as expected!__#__" -Output $false
                # for single executions, modify the normal/single RetryCount to 0 since there is a problem with the runspace execution (and not with the runspace output)
                $RunbookStep.RetryCount = 0
            }
        }
    }
    $RunbookStep.Status = $Status
    
    ########
    return $RunbookStepJobs

} # enf of Start-SPOTRunbookStepJob function

######################################################################################################################
function Get-SPOTRunbookJobResult {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [Object]
        # the runbook job to check
        $RunbookJob 
    )

    ########
    Write-SPOTLog "__###__Getting Job Result for Runbook ""$($RunbookJob.Name)"".__###__" -DBG $true
    $result = @{}
    
    if ($RunbookJob.handle.IsCompleted -eq $true) {
        
        ########
        Write-SPOTLog "__###__For Runbook ""$($RunbookJob.Name)"" the handle was found Completed.__###__" -DBG $true
        try {
            $PureOutput = $RunbookJob.powershell.EndInvoke($RunbookJob.handle)
        }
        catch {
            # process the output
            Write-SPOTLog "__###__ERROR while trying to get the Runbook ""$($RunbookJob.Name)"" output: $_.__###__"
            $PureOutput = "Error encountered getting the runbook job output: $_."
            
            # cleanup the job
            $RunbookJob.powershell.runspace.Close()
            $RunbookJob.powershell.Dispose()
        }
        ########
        # process the output
        if ($PureOutput.Count -ge 2) {
            Write-SPOTLog "__###__For Runbook ""$($RunbookJob.Name)"" the PureOutput was detected properly!__###__" -DBG $true
            $result.ActionOutput = $PureOutput[0..($PureOutput.Count-2)]
            $result.ExitValue = $PureOutput[$PureOutput.Count-1]  
                
        }
        else {
            Write-SPOTLog "__###__For Runbook ""$($RunbookJob.Name)"" the PureOutput was not detected properly!__###__" -DBG $true
            $result.ActionOutput = $PureOutput
            $result.ExitValue = $false
        }

        # write the exit value, True of False or otherwise in the log
        Write-SPOTLog "__###__For Runbook ""$($RunbookJob.Name)"" the exit value was: $($result.ExitValue).__###__" -DBG $true

        # cleanup the job
        $RunbookJob.powershell.runspace.Close()
        $RunbookJob.powershell.Dispose()

        ################################
        # process the results in case of success

        # get the runbook
        $Runbook = $AllRunbooks.($RunbookJob.GUID)

        # set a flag for remote execution
        $Remote = $false
        if ($Runbook.RemoteParameters.RemoteComputer) {
            $Remote = $true
        }

        # get the runbook status for remote executions (for local executions they should be already updated)
        if ($Remote) {
            if ($PublishedData["RunbookSummary_$($Runbook.GUID)"]) {
                if ($PublishedData["RunbookSummary_$($Runbook.GUID)"].ToString() -ne "") {
                    Write-SPOTLog "__###__For Runbook ""$($Runbook.Name)"" the status for the remote execution was received and is updated now.__###__"
                    Set-SPOTRunbookStatus -Runbook $Runbook -RunbookSummary $PublishedData["RunbookSummary_$($Runbook.GUID)"]
                }
                else {
                    Write-SPOTLog "WARNING: No RunbookSummary data published for remote executed runbook ""$($Runbook.Name)""! Status will rely on the job exit value alone (it may not be accurate)."
                }
            }
            else {
                Write-SPOTLog "WARNING: No RunbookSummary data published for remote executed runbook ""$($Runbook.Name)""! Status will rely on the job exit value alone (it may not be accurate)."
            }
        }

        # set the main runbook execution time
        $Runbook.LastExecutionTime = Get-date

        # get the main runbook status
        $Runbook.ExitValue = $result.ExitValue
        if (($result.ExitValue -eq $true) -and ($Runbook.RunbookSteps.Status -contains "Initial")) {
            # runbook was stopped/paused and is unfinished
            $Runbook.Status = "Paused"
        }
        elseif ($result.ExitValue -eq $true) {
            # runbook is actually Completed
            $Runbook.Status = "Completed"
        }
        else {
            # runbook is actually Completed
            $Runbook.Status = "Error"
        }
        
        # log the action output to file
        if ($Remote) {
            # this was a remote runbook execution, get the artefacts zip from PublishedData
            $TFP = [System.IO.Path]::GetTempFileName()
            $TempFile = Get-Item -Path $TFP -Force
            if ($TempFile) {
                if ($PublishedData["RunbookArtefacts_$($Runbook.GUID)"]) {
                    if ($PublishedData["RunbookArtefacts_$($Runbook.GUID)"].ToString() -ne "") {
                        [System.IO.File]::WriteAllBytes($TempFile.FullName,$PublishedData["RunbookArtefacts_$($Runbook.GUID)"])
                        Extract-SPOTArchive -ZipPath $TempFile.FullName -TargetFolder $Runbook.ArtefactsPath
                    }
                    else {
                        Write-SPOTLog "WARNING: No value published for RunbookArtefacts!!"
                    }
                }
                else {
                    Write-SPOTLog "WARNING: No value published for RunbookArtefacts!!"
                }
                # the archive file can be cleaned up right now
                Remove-Item -Path $TFP -Confirm:$false -Force -ErrorAction SilentlyContinue
            }
            else {
                Write-SPOTLog "WARNING: The temp file could not be created for processing the remote execution artefacts."
            }
            # log also the main remote function output
            if (!(Test-Path -Path "$($Runbook.ArtefactsPath)\$($Runbook.GUID)__ORCHESTRATION_REMOTE_$($Runbook.Name).log" -PathType Leaf)) {
                New-Item -Path "$($Runbook.ArtefactsPath)\$($Runbook.GUID)__ORCHESTRATION_REMOTE_$($Runbook.Name).log" -ItemType File -Force -Confirm:$false | Out-Null
            }
            $result.ActionOutput | Out-File -FilePath "$($Runbook.ArtefactsPath)\$($Runbook.GUID)__ORCHESTRATION_REMOTE_$($Runbook.Name).log" -Encoding ascii -Append

            ########################################
            # merge the Published data from the remote runbook back into the local environment, by inserting only the missing entries
            foreach ($PDEntry in $PublishedData["PublishedData_$($Runbook.GUID)"].Keys) {
                if (!($PublishedData.$PDEntry)) {
                    $PublishedData.$PDEntry = $PublishedData["PublishedData_$($Runbook.GUID)"].$PDEntry
                }
            }
            
            # discard the remote published data 
            $PublishedData.Remove("RunbookArtefacts_$($Runbook.GUID)")
            $PublishedData.Remove("PublishedData_$($Runbook.GUID)")
            $PublishedData.Remove("RunbookSummary_$($Runbook.GUID)")
            
        }
        else {
            # THIS IS FOR THE NORMAL/LOCAL EXECUTION
            if (!(Test-Path -Path "$($Runbook.ArtefactsPath)\$($Runbook.GUID)__ORCHESTRATION_$($Runbook.Name).log" -PathType Leaf)) {
                New-Item -Path "$($Runbook.ArtefactsPath)\$($Runbook.GUID)__ORCHESTRATION_$($Runbook.Name).log" -ItemType File -Force -Confirm:$false | Out-Null
            }
            $result.ActionOutput | Out-File -FilePath "$($Runbook.ArtefactsPath)\$($Runbook.GUID)__ORCHESTRATION_$($Runbook.Name).log" -Encoding ascii -Append
        }

        # mark this job as processed
        $RunbookJob.Processed = $true

        # returning true as the step cannot be rechecked after this
        return $true
    }
    elseif ($RunbookJob.handle.IsCompleted -eq $false) {
        ########
        # the execution did not reach a finished status, return false to recheck it next time
        return $false
    }
    else {
        Write-SPOTLog "__###__ERROR: The handle object for Runbook ""$($RunbookJob.Name)"" not recognized.__###__"

        # process the situation as is for the Runbook object
        $Runbook = $AllRunbooks.($RunbookJob.GUID)

        $Runbook.ExitValue = $false
        $Runbook.Status = "Error"

        # log the action output to file regardless if the execution ended with exitvalue true or false
        if (!(Test-Path -Path "$($Runbook.ArtefactsPath)\$($Runbook.GUID)__ORCHESTRATION_$($Runbook.Name).log" -PathType Leaf)) {
            New-Item -Path "$($Runbook.ArtefactsPath)\$($Runbook.GUID)__ORCHESTRATION_$($Runbook.Name).log" -ItemType File -Force -Confirm:$false | Out-Null
        }
        "ERROR: For the runbook $($RunbookJob.Name) the handle object was not recognized. Marked the runbook with ""Error"" status." | `
        Out-File -FilePath "$($Runbook.ArtefactsPath)\$($Runbook.GUID)__ORCHESTRATION_$($Runbook.Name).log" -Encoding ascii -Append

        # mark this job as processed
        $RunbookJob.Processed = $true
    }

} # enf of Get-SPOTRunbookJobResult function

######################################################################################################################
function Get-SPOTRunbookStepJobResult {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [Object]
        # the runbook step job to check
        $RunbookStepJob 
    )

    ########
    # get the main/parent RunbookStep to have access to all (multi) properties in there, in case they are needed
    $RunbookStep = $AllRunbookSteps.($RunbookStepJob.GUID)

    ########
    # set parallel runbookStep behavior
    # AnyFailFail => If any job from a parallel runbookStep (a single step that executes on several targets) fails, it means that the runbookStep failed.
    # AllFailFail => Only if all jobs from a parallel runbookStep fail, it means that the runbookStep failed (default behavior)
    if ($OrchVars._AnyFailFail -eq $true) {
        $AnyFailFail = $true
    }
    else {
        $AnyFailFail = $false
    }
    
    ########
    if ($RunbookStepJob.Target) {
        # this is a parallel job
        Write-SPOTLog "__#__Getting Job Result for RunbookStep ""$($RunbookStepJob.Name)"" and target ""$($RunbookStepJob.Target)"".__#__" -DBG $true
    }
    else {
        Write-SPOTLog "__#__Getting Job Result for RunbookStep ""$($RunbookStepJob.Name)"".__#__" -DBG $true
    }
    $result = @{}
    
    if ($RunbookStepJob.handle.IsCompleted -eq $true) {
        
        ########
        $CheckExecutionResult = $false
        if ($RunbookStepJob.Target) {
            if (!$RunbookStep.MultiLastExecutionTime.($RunbookStepJob.Target)) {
                $CheckExecutionResult = $true
                Write-SPOTLog "__#__For RunbookStep ""$($RunbookStepJob.Name)"" and target ""$($RunbookStepJob.Target)"" the handle was found Completed.__#__" -DBG $true
                # update the last execution time only if it is empty (this parameter is set to empty on every retry trigger) 
                $RunbookStep.MultiLastExecutionTime.($RunbookStepJob.Target) = Get-Date
            }
        }
        else {
            if ($RunbookStep.LastExecutionTime -eq [datetime]::MinValue) {
                $CheckExecutionResult = $true
                Write-SPOTLog "__#__For RunbookStep ""$($RunbookStepJob.Name)"" the handle was found Completed.__#__" -DBG $true
                # update the last execution time only if it is minvalue (this parameter is set to minvalue on every retry trigger) 
                $RunbookStep.LastExecutionTime = Get-Date
            }
        }
        
        if ($CheckExecutionResult) {
            try {
                $PureOutput = $RunbookStepJob.powershell.EndInvoke($RunbookStepJob.handle)
            }
            catch {
                # process the output
                if ($RunbookStepJob.Target) {
                    Write-SPOTLog "__#__ERROR while trying to get the RunbookStep ""$($RunbookStepJob.Name)"" and target ""$($RunbookStepJob.Target)"" output: $_.__#__"
                    # set RetryCount to 0 since there was an error with the runspace
                    $RunbookStep.MultiRetryCount.($RunbookStepJob.Target) = 0
                }
                else {
                    Write-SPOTLog "__#__ERROR while trying to get the RunbookStep ""$($RunbookStepJob.Name)"" output: $_.__#__"
                    # set RetryCount to 0 since there was an error with the runspace
                    $RunbookStep.RetryCount = 0
                }
                $PureOutput = "Error encountered getting the runbook step job output: $_."
            
                # cleanup the job, since there is an issue with the runspace and no retryies are to be attempted after this
                if ($RunbookStepJob.powershell.runspace) {
                    $RunbookStepJob.powershell.runspace.Close()
                }
                $RunbookStepJob.powershell.Dispose()
            }

            ########
            # process the output
            if ($PureOutput.Count -ge 2) {
                # proper output detection
                if ($RunbookStepJob.Target) {
                    Write-SPOTLog "__#__For RunbookStep ""$($RunbookStepJob.Name)"" and target ""$($RunbookStepJob.Target)"" the PureOutput was detected properly!__#__" -DBG $true
                }
                else {
                    Write-SPOTLog "__#__For RunbookStep ""$($RunbookStepJob.Name)"" the PureOutput was detected properly!__#__" -DBG $true
                    #Write-SPOTLog "__#__DEBUG: PureOutput was $PureOutput __#__" -DBG $true
                }
                $result.ActionOutput = $PureOutput
                $index = $PureOutput.Count-1
                while ($index -ge 0) {
                    if ("$($PureOutput[$index])".Trim() -ne "") {
                        $result.ExitValue = $PureOutput[$index]
                        break
                    }
                    $index--
                }
                if ($result.ExitValue -eq $true) {
                    $result.Status = "Completed"
                    # execution was successfull, so no retries are needed
                    if ($RunbookStepJob.Target) {
                        $RunbookStep.MultiRetryCount.($RunbookStepJob.Target) = 0
                    }
                    else {
                        $RunbookStep.RetryCount = 0
                    }
                }
                else {
                    $result.Status = "Error"
                    # execution was not successfull, so retries could be launched, if configured and enough remained

                }
            }
            else {
                # improper output detection
                if ($RunbookStepJob.Target) {
                    Write-SPOTLog "__#__ERROR: For RunbookStep ""$($RunbookStepJob.Name)"" and target ""$($RunbookStepJob.Target)"" the PureOutput was not detected properly!__#__"
                }
                else {
                    Write-SPOTLog "__#__ERROR: For RunbookStep ""$($RunbookStepJob.Name)"" the PureOutput was not detected properly!__#__"
                }
                $result.ActionOutput = $PureOutput
                $result.ExitValue = $false
                $result.Status = "Error"
                # execution was not successfull, so retries could be launched, if configured and enough remained
            }

            # write the exit value, True of False or otherwise in the log
            if ($RunbookStepJob.Target) {
                Write-SPOTLog "__#__For RunbookStep ""$($RunbookStepJob.Name)"" and target ""$($RunbookStepJob.Target)"" the latest exit value was: $($result.ExitValue).__#__" -DBG $true
            }
            else {
                Write-SPOTLog "__#__For RunbookStep ""$($RunbookStepJob.Name)"" the latest exit value was: $($result.ExitValue).__#__" -DBG $true
            }

            #####################################
            # handling the job output now
            if ($RunbookStepJob.Target) {
                $fName = Split-Path -Path $RunbookStep.ArtefactsPath -Leaf
                $NewFileName = "$($fName.Substring(0,$fName.LastIndexOf(".")))-$($RunbookStepJob.Target)$($fName.Substring($fName.LastIndexOf(".")))"
                $aPath = "$(Split-Path -Path $RunbookStep.ArtefactsPath -Parent)\$NewFileName"
            }
            else {
                $aPath = $RunbookStep.ArtefactsPath
            }
        
            # log the action output to file regardless if the execution ended with exitvalue true or false
            if (!(Test-Path -Path $aPath)) {
                New-Item -Path $aPath -ItemType File -Force -Confirm:$false | Out-Null
            }
            $result.ActionOutput | Out-File -FilePath $aPath -Encoding ascii -Append

            ####################################
            # 
            if ($RunbookStepJob.Target) {
                # implied parallel execution case
                #####################################
                # process the results in case of success or in case of last retry attempted (multi case)
                if (($result.Status -eq "Completed") -or $RunbookStep.MultiRetryCount.($RunbookStepJob.Target) -eq 0) {
                    if (!$RunbookStep.ExitValue) {
                        # this is the first parallel job processed for this step; marking as if it is the single one
                        $RunbookStep.ExitValue = $result.ExitValue
                        $RunbookStep.MultiStatus.($RunbookStepJob.Target) = $result.Status
                    }
                    else {
                        # this is not the first parallel job processed; marking the status and exit value depending on the AnyFailFail preference
                        if ($AnyFailFail -eq $true) {
                            # we only care to impose a single fail, if it exists; if the first job was true and now if it also true, there is no need to change that value in the RunbookStep
                            if ($result.ExitValue -eq $false) {$RunbookStep.ExitValue = $false}
                            if ($result.Status -eq "Error") {$RunbookStep.MultiStatus.($RunbookStepJob.Target) = "Error"}
                        }
                        else {
                            # we only care to impose a single success, if it exists; if the first job was failed and now if it also failed, there is no need to change that value in the RunbookStep
                            if ($result.ExitValue -eq $true) {$RunbookStep.ExitValue = $true}
                            $RunbookStep.MultiStatus.($RunbookStepJob.Target) = $result.Status
                        }
                    }
                    # if this is the last parallel job from the current Step,
                    $LastParallelJob = $true
                    foreach ($tgt in $RunbookStep.MultiStatus.GetEnumerator().Name) {
                        if ($RunbookStep.MultiStatus.$tgt -eq "Executing") {
                                $LastParallelJob = $false
                                break
                            }
                    }
                    if ($LastParallelJob -eq $true) {
                        # set also the main "Status" and "LastExecutionTime" parameters
                        if ($AnyFailFail -eq $true) {
                            $MainStatus = "Completed"
                            foreach ($tg in $RunbookStep.MultiStatus.GetEnumerator().Name) {
                                if ($RunbookStep.MultiStatus.$tg -eq "Error") {
                                    $MainStatus = "Error"
                                    break
                                }
                            }
                        }
                        else {
                            $MainStatus = "Error"
                            foreach ($tg in $RunbookStep.MultiStatus.GetEnumerator().Name) {
                                if ($RunbookStep.MultiStatus.$tg -eq "Completed") {
                                    $MainStatus = "Completed"
                                    break
                                }
                            }
                        }
                        # set the main Status now and do any potential cleanup
                        Write-SPOTLog "__#__For RunbookStep ""$($RunbookStepJob.Name)"" the main status is ""$MainStatus"" and it is set now in the master step object.__#__" -DBG $true
                        $RunbookStep.Status = $MainStatus

                        # delete any potential RFO archives locally
                        if ($RunbookStep.Type -like "*Remote*") {
                            # for remotely executed functions, we might have RFO references; if yes, cleaning them up
                            foreach ($cpar in $($RunbookStep.StepParameters.CommandParameters.Keys)) {
                                if ($RunbookStep.StepParameters.CommandParameters.$cpar.GetType().Name -ne "String") {
                                    continue
                                }
                                if ($RunbookStep.StepParameters.CommandParameters.$cpar.StartsWith('$RFO:')) {
                                    Write-SPOTLog "__#__For RunbookStep ""$($RunbookStep.Name)"" the command parameter ""$cpar"" has a RFO reference. Cleaning up.__#__" -DBG $true
                                    $UniqueID = ($RunbookStep.StepParameters.CommandParameters.$cpar -split ":")[1]
                                    $LocalArchivePath = $OrchVars._RFOMap.$UniqueID.LocalArchivePath
                                    if ($LocalArchivePath) {
                                        Remove-Item -Path $LocalArchivePath -Confirm:$false -Force -ErrorAction SilentlyContinue
                                    }
                                }
                            }
                        }
                    }
                    # NOW do the cleanup
                    if ($RunbookStepJob.powershell.runspace) {
                        $RunbookStepJob.powershell.runspace.Close()
                    }
                    $RunbookStepJob.powershell.Dispose()

                    # mark this job as processed
                    $RunbookStepJob.Processed = $true

                    # returning true as the step cannot be rechecked after this
                    return $true
                }
            }
            else {
                #####################################
                # process the results in case of success or in case of last retry attempted (single case)
                if (($result.Status -eq "Completed") -or $RunbookStep.RetryCount -eq 0) {
                    # single execution case
                    $RunbookStep.ExitValue = $result.ExitValue
                    $RunbookStep.Status = $result.Status

                    # delete any potential RFO archives locally
                    if ($RunbookStep.Type -like "*Remote*") {
                        # for remotely executed functions, we might have RFO references; if yes, cleaning them up
                        foreach ($cpar in $($RunbookStep.StepParameters.CommandParameters.Keys)) {
                            if ($RunbookStep.StepParameters.CommandParameters.$cpar) {
                                if ($RunbookStep.StepParameters.CommandParameters.$cpar.GetType().Name -eq "String") {
                                    if ($RunbookStep.StepParameters.CommandParameters.$cpar.StartsWith('$RFO:')) {
                                        Write-SPOTLog "__#__For RunbookStep ""$($RunbookStep.Name)"" the command parameter ""$cpar"" has a RFO reference. Cleaning up.__#__" -DBG $true
                                        $UniqueID = ($RunbookStep.StepParameters.CommandParameters.$cpar -split ":")[1]
                                        $LocalArchivePath = $OrchVars._RFOMap.$UniqueID.LocalArchivePath
                                        if ($LocalArchivePath) {
                                            Remove-Item -Path $LocalArchivePath -Confirm:$false -Force -ErrorAction SilentlyContinue
                                        }
                                    }
                                }
                            }
                        }
                    }

                    # NOW do the cleanup
                    if ($RunbookStepJob.powershell.runspace) {
                        $RunbookStepJob.powershell.runspace.Close()
                    }
                    $RunbookStepJob.powershell.Dispose()

                    # mark this job as processed
                    $RunbookStepJob.Processed = $true

                    # returning true as the step cannot be rechecked after this
                    return $true
                }
            }
        }
        
        else {
            #####################################
            # here we are only if the previous execution was found Completed but not Successful (Error status)
            if ($RunbookStepJob.Target) {
                # retry possible, checking for retry delay
                if ([math]::floor(((Get-Date) - $RunbookStep.MultiLastExecutionTime.($RunbookStepJob.Target)).TotalSeconds) -lt $RunbookStep.RetryDelay) {
                    Write-SPOTLog "__#__For RunbookStep ""$($RunbookStepJob.Name)"" and target ""$($RunbookStepJob.Target)"" the job is waiting the RetryDelay before restarting. RetryCount remaining ""$($RunbookStep.MultiRetryCount.($RunbookStepJob.Target))"".__#__" -DBG $true
                    # the execution did not reach a finished status, return false to recheck it next time
                    return $false
                }
                else {
                    # -> restarting the job
                    Write-SPOTLog "__#__For RunbookStep ""$($RunbookStepJob.Name)"" and target ""$($RunbookStepJob.Target)"" the job is restarting.__#__" -DBG $true
                    # decrement the RetryCount
                    $RunbookStep.MultiRetryCount.($RunbookStepJob.Target) -= 1
                    # set LastExecutionTime to null
                    $RunbookStep.MultiLastExecutionTime.($RunbookStepJob.Target) = $null
                    # retry
                    $RunbookStepJob.handle = $RunbookStepJob.powershell.BeginInvoke()
                    # the execution did not reach a finished status, return false to recheck it next time
                    return $false
                }
            }
            else {
                # retry possible, checking for retry delay
                if ([math]::floor(((Get-Date) - $RunbookStep.LastExecutionTime).TotalSeconds) -lt $RunbookStep.RetryDelay) {
                    Write-SPOTLog "__#__For RunbookStep ""$($RunbookStepJob.Name)"" the job is waiting the RetryDelay before restarting. RetryCount remaining ""$($RunbookStep.RetryCount)"".__#__" -DBG $true
                    # the execution did not reach a finished status, return false to recheck it next time
                    return $false
                }
                else {
                    #-> restarting the job
                    Write-SPOTLog "__#__For RunbookStep ""$($RunbookStepJob.Name)"" the job is restarting.__#__" -DBG $true
                    # decrement the RetryCount
                    $RunbookStep.RetryCount -= 1
                    # set LastExecutionTime to null
                    $RunbookStep.LastExecutionTime = [datetime]::MinValue
                    # retry
                    $RunbookStepJob.handle = $RunbookStepJob.powershell.BeginInvoke()
                    # the execution did not reach a finished status, return false to recheck it next time
                    return $false
                }
            }
        }
    }
    else {
        ########
        # the execution did not reach a finished status, return false to recheck it next time
        return $false
    }

} # enf of Get-SPOTRunbookStepJobResult function

######################################################################################################################
function Finalize-SPOTRemoteExecution {
    Param (
        [Parameter(Mandatory=$true)]
        [object]
        # the main runbook object
        $Runbook, 
        [Parameter(Mandatory=$true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]
        # the initial TrustedHosts value
        $InitialTHValue, 
        [Parameter(Mandatory=$true)]
        [bool]
        # the flag for the SPOT firewall rule removal
        $ToRemoveSPOTFWRule, 
        [Parameter(Mandatory=$true)]
        [bool]
        # the flag for the initial existence of the PsExec reg key
        $InitialSysinternalsReg, 
        [Parameter(Mandatory=$true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]
        # the initial value of the PsExec eula
        $InitialSysinternalsEula 
    )

    ###############
    Write-SPOTLog "===== Starting function Finalize-SPOTRemoteExecution. ====="
    
    ###############
    # populate the RunbookArtefacts variable to be published and available to the calling environment
    if (Test-Path -Path $Runbook.ArtefactsPath) {
        Create-SPOTArchive -TargetFolder $Runbook.ArtefactsPath -ZipPath "$($Runbook.ArtefactsPath).zip"
        $RunbookArtefacts = [System.IO.File]::ReadAllBytes("$($Runbook.ArtefactsPath).zip")
    }
    else {
        Write-SPOTLog "WARNING: The Artefacts path ""$($Runbook.ArtefactsPath)"" was not detected. PublishedVariables will not contain the logs!!"
    }

    # get the main runbook summary
    Write-SPOTLog ">>> Prepare the RunbookSummary." -DBG $true
    $RunbookSummary = Get-SPOTRunbookSummary -InputRunbook $Runbook

    ###############
    # undo the SPOT environment changes
    Write-SPOTLog ">>> Revert the initial PSRemoting trust value." -DBG $true
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Client" -Name "trusted_hosts" -PropertyType String -Value $InitialTHValue -Force -Confirm:$false

    ###############
    if ($ToRemoveSPOTFWRule) {
        if (Get-NetFirewallRule | Where {$_.DisplayName -eq "Allow TCP 5985/445/22/23 Outbound"}) {
            Write-SPOTLog ">>> Removing the Firewall rule for TCP 5985/445/22/23 outbound access." -DBG $true
            Remove-NetFirewallRule -DisplayName "Allow TCP 5985/445/22/23 Outbound" -Confirm:$false
        }
    }
    ###############
    Write-SPOTLog ">>> Revert the initial AcceptEULA state for Sysinternals." -DBG $true
    if ($InitialSysinternalsReg) {
        if (!$InitialSysinternalsEula) {
            # remove the eula
            Remove-ItemProperty -Path "HKCU:\Software\Sysinternals\PsExec" -Name "EulaAccepted" -Confirm:$false -Force -ErrorAction SilentlyContinue
        }
        else {
            Set-ItemProperty -Path "HKCU:\Software\Sysinternals\PsExec" -Name "EulaAccepted" -Value $InitialSysinternalsEula -Confirm:$false -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        # remove the reg key
        Remove-Item -Path "HKCU:\Software\Sysinternals\PsExec" -Confirm:$false -Force -ErrorAction SilentlyContinue
    }

    ###############
    Write-SPOTLog "===== Finished function Finalize-SPOTRemoteExecution. ====="

} # enf of Finalize-SPOTRemoteExecution function

######################################################################################################################
function Replace-SPOTVarsInRunbookStepJIT {
Param (
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [Object]
    # the runbookstep to process
    $RunbookStep,
    [Parameter(Mandatory=$true)]
    [AllowNull()]
    [hashtable]
    # the runbook parameters hashtable to be used for RP references
    $RbParameters
    )

    # targeting PV references, mixed string references involving all reference types and all applicable "." references
    #####
    Write-SPOTLog "Starting function Replace-SPOTVarsInRunbookStepJIT for RunbookStep ""$($RunbookStep.Name)""." -Output $false -DBG $true

    # conditions
    if ($RunbookStep.Conditions) {
        $RunbookStep.Conditions = $RunbookStep.Conditions | foreach {
            if ($_) {
                if ($_.GetType().Name -eq "String") {
                    if ($_.StartsWith("`$PV:")) {
                        Write-SPOTLog " > Evaluating the RunbookStep ""$($RunbookStep.Name)"" Condition ""$_"" >>>" -Output $false -DBG $true
                        try {
                            $_ = Invoke-Expression -Command "`$PublishedData.$(($_ -split ":")[1].Trim())"
                        }
                        catch {
                            Write-SPOTLog " >> ERROR: while replacing PV in Condition: $_." -Output $false
                            throw "Replace-SPOTVarsInRunbookStepJIT: error processing condition!"
                        }
                        Write-SPOTLog " >> INFO: Condition value evaluated to ""$_""." -Output $false -DBG $true
                    }
                    $_
                }
                else {
                    Write-SPOTLog " >> INFO: Current Condition ""$_"" for the RunbookStep ""$($RunbookStep.Name)"" is not of type string! Leaving it unchanged." -Output $false
                    $_
                }
            }
            else {
                # return the empty value as this is important for conditions
                $_
            }
        }
    }

    # step parameters
    foreach ($i in $($RunbookStep.StepParameters.Keys)) {
        $Splitted = $null
        if ($RunbookStep.StepParameters.$i) { 
            if (($RunbookStep.StepParameters.$i).GetType().Name -eq "String") {
                $Splitted = ($RunbookStep.StepParameters.$i).Trim() -split ":"
                if ($Splitted.Count -eq 2) {
                    # a single reference is present
                    if ($Splitted[0] -eq "`$PV") {
                        Write-SPOTLog " > Current step parameter ""$i"" detected as single `$PV reference." -Output $false -DBG $true
                        try {
                            $RunbookStep.StepParameters.$i = Invoke-Expression -Command "`$PublishedData.$($Splitted[1])"
                        }
                        catch {
                            Write-SPOTLog " >> ERROR: while replacing PV in step parameter: $_." -Output $false
                            throw "Replace-SPOTVarsInRunbookStepJIT: error processing step parameter!"
                        }
                        Write-SPOTLog " >> INFO: Changed the step parameter ""$i"" into ""$($RunbookStep.StepParameters.$i)""." -Output $false -DBG $true
                    }
                }
                # if mixed string reference is present, process it
                if ($RunbookStep.StepParameters.$i) {
                    if (($RunbookStep.StepParameters.$i).GetType().Name -eq "String") {
                        if (($RunbookStep.StepParameters.$i).Contains("`$RP:") -or `
                            ($RunbookStep.StepParameters.$i).Contains("`$OV:") -or `
                            ($RunbookStep.StepParameters.$i).Contains("`$SV:") -or `
                            ($RunbookStep.StepParameters.$i).Contains("`$PV:")) {
                            Write-SPOTLog " > Processing the RunbookStep ""$($RunbookStep.Name)"" step parameter ""$i"" as string line >>>" -Output $false -DBG $true
                            $RunbookStep.StepParameters.$i = Replace-SPOTLineVars -line $RunbookStep.StepParameters.$i -SVars $SVars -PVars $PublishedData -RPars $RbParameters
                            Write-SPOTLog " >> Into: ""$($RunbookStep.StepParameters.$i)""." -Output $false -DBG $true
                        }
                    }
                }
            }
        }
    }

    # VariablesToPublish
    if ($RunbookStep.StepParameters.VariablesToPublish) {
        $RunbookStep.StepParameters.VariablesToPublish = $RunbookStep.StepParameters.VariablesToPublish | foreach {
            if ($_) {
                if ($_.GetType().Name -eq "String") {
                    Write-SPOTLog " > Evaluating the RunbookStep ""$($RunbookStep.Name)"" VariablesToPublish entry ""$_"" >>>" -Output $false -DBG $true
                    if (($_ -split ":").Count -eq 2) {
                        ###############################
                        # only single referenced PV expected at this point
                        if ($_.StartsWith("`$PV:")) {
                            try {
                                $_ = Invoke-Expression -Command "`$PublishedData.$(($_ -split ":")[1].Trim())"
                            }
                            catch {
                                Write-SPOTLog " >> ERROR: while replacing PV in VariablesToPublish entry: $_." -Output $false
                                throw "Replace-SPOTVarsInRunbookStep: error replacing PV reference!"
                            }
                            Write-SPOTLog " >> INFO: VariablesToPublish entry value evaluated to ""$_""." -Output $false -DBG $true
                        }
                    }
                    ###############################
                    # if mixed string reference is present, process it
                    if ($_) {
                        if ($_.GetType().Name -eq "String") {
                            if ($_.Contains("`$RP:") -or `
                                $_.Contains("`$OV:") -or `
                                $_.Contains("`$SV:") -or `
                                $_.Contains("`$PV:")) {
                                Write-SPOTLog " > Processing the RunbookStep ""$($RunbookStep.Name)"" VariablesToPublish entry ""$_"" as string line >>>" -Output $false -DBG $true
                                $_ = Replace-SPOTLineVars -line $_ -SVars $SVars -PVars $PublishedData -RPars $RbParameters
                                Write-SPOTLog " >> Into: ""$_""." -Output $false -DBG $true
                            }
                        }
                        $_
                    }
                }
                else {
                    Write-SPOTLog " >> WARNING: Current VariablesToPublish entry ""$_"" for the RunbookStep ""$($RunbookStep.Name)"" is not of type string! Leaving it out." -Output $false
                }
            }
        }
    }

    # command parameters (for runbookSteps)
    foreach ($i in $($RunbookStep.StepParameters.CommandParameters.Keys)) {
        $Splitted = $null
        if ($RunbookStep.StepParameters.CommandParameters.$i) { 
            if (($RunbookStep.StepParameters.CommandParameters.$i).GetType().Name -eq "String") {
                $Splitted = ($RunbookStep.StepParameters.CommandParameters.$i).Trim() -split ":"
                if ($Splitted.Count -eq 2) {
                    # a single reference is present
                    switch ($Splitted[0]) {
                        #########################################
                        "`$RP" {
                            # single reference to RP (only the '.' reference expected)
                            Write-SPOTLog " > Current command parameter ""$i"" detected as single `$RP reference." -Output $false -DBG $true
                            if ($Splitted[1] -eq '.') {
                                Write-SPOTLog " >> INFO: The current RP reference is for the full RP, as expected at this point. Replacing it now." -Output $false -DBG $true
                                $RunbookStep.StepParameters.CommandParameters.$i = $RbParameters
                            }
                            else {
                                Write-SPOTLog " >> ERROR: The current RP reference is not ""."", as expected at this point, but rather ""$($RunbookStep.StepParameters.CommandParameters.$i)"". Something went wrong. Cannot continue." -Output $false
                                throw "Replace-SPOTVarsInRunbookStepJIT: error processing command parameter!"
                            }
                        }
                        #########################################
                        "`$SV" {
                            # single reference to SV (only the '.' reference expected)
                            Write-SPOTLog " > Current command parameter ""$i"" detected as single `$SV reference." -Output $false -DBG $true
                            if ($Splitted[1] -eq '.') {
                                Write-SPOTLog " >> INFO: The current SV reference is for the full SV, as expected at this point. Replacing it now." -Output $false -DBG $true
                                $RunbookStep.StepParameters.CommandParameters.$i = $SVars
                            }
                            else {
                                Write-SPOTLog " >> ERROR: The current SV reference is not ""."", as expected at this point, but rather ""$($RunbookStep.StepParameters.CommandParameters.$i)"". Something went wrong. Cannot continue." -Output $false
                                throw "Replace-SPOTVarsInRunbookStepJIT: error processing command parameter!"
                            }
                        }
                        #########################################
                        "`$PV" {
                            # single reference to PV
                            Write-SPOTLog " > Current command parameter ""$i"" detected as single `$PV reference." -Output $false -DBG $true
                            if ($Splitted[1] -eq '.') {
                                Write-SPOTLog " >> INFO: The current PV reference is for the full PV. Replacing it now." -Output $false -DBG $true
                                $RunbookStep.StepParameters.CommandParameters.$i = $PublishedData
                            }
                            else {
                                try {
                                    $RunbookStep.StepParameters.CommandParameters.$i = Invoke-Expression -Command "`$PublishedData.$($Splitted[1])"
                                }
                                catch {
                                    Write-SPOTLog " >> ERROR: while replacing PV in command parameter: $_." -Output $false
                                    throw "Replace-SPOTVarsInRunbookStepJIT: error processing command parameter!"
                                }
                                Write-SPOTLog " >> INFO: Changed the command parameter ""$i"" into ""$($RunbookStep.StepParameters.CommandParameters.$i)""." -Output $false -DBG $true
                            }
                        }
                    }
                }
                # if mixed string reference is present, process it
                if ($RunbookStep.StepParameters.CommandParameters.$i) {
                    if (($RunbookStep.StepParameters.CommandParameters.$i).GetType().Name -eq "String") {
                        if (($RunbookStep.StepParameters.CommandParameters.$i).Contains("`$RP:") -or `
                            ($RunbookStep.StepParameters.CommandParameters.$i).Contains("`$OV:") -or `
                            ($RunbookStep.StepParameters.CommandParameters.$i).Contains("`$SV:") -or `
                            ($RunbookStep.StepParameters.CommandParameters.$i).Contains("`$PV:")) {
                            Write-SPOTLog " > Processing the RunbookStep ""$($RunbookStep.Name)"" command parameter ""$i"" as string line >>>" -Output $false -DBG $true
                            $RunbookStep.StepParameters.CommandParameters.$i = Replace-SPOTLineVars -line $RunbookStep.StepParameters.CommandParameters.$i -SVars $SVars -PVars $PublishedData -RPars $RbParameters
                            Write-SPOTLog " >> Into: ""$($RunbookStep.StepParameters.CommandParameters.$i)""." -Output $false -DBG $true
                        }
                    }
                }
            }
        }
    }

    #####
    Write-SPOTLog "Finished function Replace-SPOTVarsInRunbookStepJIT for RunbookStep ""$($RunbookStep.Name)""." -Output $false -DBG $true

} # end of Replace-SPOTVarsInRunbookStepJIT function

######################################################################################################################
function Replace-SPOTVarsInRunbookJIT {
Param (
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [Object]
    # the runbook object to process
    $Runbook 
    )

    #####
    Write-SPOTLog "Starting function Replace-SPOTVarsInRunbookJIT for Runbook ""$($Runbook.Name)""." -Output $false -DBG $true

    # conditions (no RP references should be here at this point so starting with conditions)
    if ($Runbook.Conditions) {
        $Runbook.Conditions = $Runbook.Conditions | foreach {
            if ($_) {
                if ($_.GetType().Name -eq "String") {
                    if ($_.StartsWith("`$PV:")) {
                        Write-SPOTLog " > Evaluating the Runbook ""$($Runbook.Name)"" Condition ""$_"" >>>" -Output $false -DBG $true
                        try {
                            $_ = Invoke-Expression -Command "`$PublishedData.$(($_ -split ":")[1].Trim())"
                        }
                        catch {
                            Write-SPOTLog " >> ERROR: while replacing PV in Condition: $_." -Output $false
                            throw "Replace-SPOTVarsInRunbookJIT: error processing condition!"
                        }
                        Write-SPOTLog " >> INFO: Condition value evaluated to ""$_""." -Output $false -DBG $true
                    }
                    $_
                }
                else {
                    Write-SPOTLog " >> INFO: Current Condition ""$_"" for the Runbook ""$($Runbook.Name)"" is not of type string! Leaving it unchanged." -Output $false
                    $_
                }
            }
            else {
                # return the empty value as this is important for conditions
                $_
            }
        }
    }

    # runbook parameters
    if ($Runbook.RunbookParameters) {
        foreach ($i in $($Runbook.RunbookParameters.Keys)) {
            $Splitted = $null
            if ($Runbook.RunbookParameters.$i) { 
                if (($Runbook.RunbookParameters.$i).GetType().Name -eq "String") {
                    $Splitted = ($Runbook.RunbookParameters.$i).Trim() -split ":"
                    if ($Splitted.Count -eq 2) {
                        # a single reference is present
                        if ($Splitted[0] -eq "`$PV") {
                            Write-SPOTLog " > Current runbook parameter ""$i"" detected as single `$PV reference." -Output $false -DBG $true
                            try {
                                $Runbook.RunbookParameters.$i = Invoke-Expression -Command "`$PublishedData.$($Splitted[1])"
                            }
                            catch {
                                Write-SPOTLog " >> ERROR: while replacing PV in runbook parameter: $_." -Output $false
                                throw "Replace-SPOTVarsInRunbookJIT: error processing runbook parameter!"
                            }
                            Write-SPOTLog " >> INFO: Changed the runbook parameter ""$i"" into ""$($Runbook.RunbookParameters.$i)""." -Output $false -DBG $true
                        }
                    }
                }
            }
        }
    }

    # remote parameters
    if ($Runbook.RemoteParameters) {
        foreach ($i in $($Runbook.RemoteParameters.Keys)) {
            $Splitted = $null
            if ($Runbook.RemoteParameters.$i) { 
                if (($Runbook.RemoteParameters.$i).GetType().Name -eq "String") {
                    $Splitted = ($Runbook.RemoteParameters.$i).Trim() -split ":"
                    if ($Splitted.Count -eq 2) {
                        # a single reference is present
                        if ($Splitted[0] -eq "`$PV") {
                            Write-SPOTLog " > Current remote parameter ""$i"" detected as single `$PV reference." -Output $false -DBG $true
                            try {
                                $Runbook.RemoteParameters.$i = Invoke-Expression -Command "`$PublishedData.$($Splitted[1])"
                            }
                            catch {
                                Write-SPOTLog " >> ERROR: while replacing PV in remote parameter: $_." -Output $false
                                throw "Replace-SPOTVarsInRunbookJIT: error processing remote parameter!"
                            }
                            Write-SPOTLog " >> INFO: Changed the remote parameter ""$i"" into ""$($Runbook.RemoteParameters.$i)""." -Output $false -DBG $true
                            
                        }
                    }
                }
            }
        }
    }

    #####
    Write-SPOTLog "Finished function Replace-SPOTVarsInRunbookJIT for Runbook ""$($Runbook.Name)""." -Output $false -DBG $true

} # end of Replace-SPOTVarsInRunbookJIT function

######################################################################################################################
function Replace-SPOTLineVars {
    Param (
    [Parameter(Mandatory=$true)]
    [string]
    # the string to parse and replace with any variables (Published Variables, Secrets or Orch Variables; no credential objects to be referenced as this is a string replace)
    $line,
    [Parameter(Mandatory=$false)]
    [AllowNull()]
    [hashtable]
    # the secret variables to be used for replacing the references
    $SVars,
    [Parameter(Mandatory=$false)]
    [AllowNull()]
    [hashtable]
    # the published variables to be used for replacing the references
    $PVars,
    [Parameter(Mandatory=$false)]
    [AllowNull()]
    [hashtable]
    # the runbook parameters to be used for replacing RP references
    $RPars
    )

    #####
    Write-SPOTLog "Starting function Replace-SPOTLineVars for line ""$line""." -Output $false -DBG $true

    if ($line.Contains('$PV:') -or $line.Contains('$SV:') -or $line.Contains('$OV:') -or $line.Contains('$RP:')) {
        Write-SPOTLog "INFO: Current line ""$line"" detected with a Variable keyword." -Output $false -DBG $true
        $NewLine = @()
        foreach ($word in ($line -split '\s+')) {
            if ($word.Contains("`$PV:") -or $word.Contains('$SV:') -or $word.Contains('$OV:') -or $word.Contains('$RP:')) {
                ###################################################
                # set array of occurences
                $occurences = @()
                $SortedOccurences = @()
                # start at position 0, for RP
                $offset = 0
                while (($pos = $word.IndexOf('$RP:',$offset)) -ne -1) {
                    $occurences += New-Object -TypeName psobject -Property @{Pos=$pos; Type="RP"}
                    $offset = $pos + 4
                }
                # start at position 0, for PV
                $offset = 0
                while (($pos = $word.IndexOf('$PV:',$offset)) -ne -1) {
                    $occurences += New-Object -TypeName psobject -Property @{Pos=$pos; Type="PV"}
                    $offset = $pos + 4
                }
                # start at position 0, for SV
                $offset = 0
                while (($pos = $word.IndexOf('$SV:',$offset)) -ne -1) {
                    $occurences += New-Object -TypeName psobject -Property @{Pos=$pos; Type="SV"}
                    $offset = $pos + 4
                }
                # start at position 0, for OV
                $offset = 0
                while (($pos = $word.IndexOf('$OV:',$offset)) -ne -1) {
                    $occurences += New-Object -TypeName psobject -Property @{Pos=$pos; Type="OV"}
                    $offset = $pos + 4
                }
                # sort ascending based on positions order
                $SortedOccurences = @($occurences | Sort-Object -Property Pos)

                ###################################################
                # detect all details about Vars to replace
                $i = 0
                while ($i -lt $SortedOccurences.Count) {
                    $VarName = $null
                    $LastPosition = $null
                    # get the end of the current string section, until the next starting delimiter or until the end of the entire word
                    if ($i -eq ($SortedOccurences.Count-1)) {
                        $EndPos = $word.Length-1
                    }
                    else {
                        $EndPos = $SortedOccurences[$i+1].Pos-1
                    }
                    # get the ending delimiter index, if it exists
                    switch ($SortedOccurences[$i].Type) {
                        "RP" { $LastPos = $word.Substring($SortedOccurences[$i].Pos,$EndPos-$SortedOccurences[$i].Pos+1).IndexOf(':$RP') }
                        "PV" { $LastPos = $word.Substring($SortedOccurences[$i].Pos,$EndPos-$SortedOccurences[$i].Pos+1).IndexOf(':$PV') }
                        "SV" { $LastPos = $word.Substring($SortedOccurences[$i].Pos,$EndPos-$SortedOccurences[$i].Pos+1).IndexOf(':$SV') }
                        "OV" { $LastPos = $word.Substring($SortedOccurences[$i].Pos,$EndPos-$SortedOccurences[$i].Pos+1).IndexOf(':$OV') }
                    }
        
                    if ($LastPos -ne -1) {
                        # the ending delimiter has been used
                        $VarName = $word.Substring($SortedOccurences[$i].Pos+4,$LastPos-4)
                        $LastPosition = $SortedOccurences[$i].Pos+$LastPos+3
                    }
                    else {
                        # the ending delimiter has not been used, considering the entire section as the variable name
                        $VarName = $word.Substring($SortedOccurences[$i].Pos+4,$EndPos-$SortedOccurences[$i].Pos-3)
                        $LastPosition = $EndPos
                    }
                    # adding new properties to the Occurences objects
                    $SortedOccurences[$i] | Add-Member -Name "VarName" -Type NoteProperty -Value $VarName
                    $SortedOccurences[$i] | Add-Member -Name "LastPosition" -Type NoteProperty -Value $LastPosition
                    $i++
                }

                # reverse the order, so that processing the replacement from end to beginning will not mess up the position numbers inside the original string
                $SortedOccurences = @($SortedOccurences | Sort-Object -Property Pos -Descending)

                ###################################################
                # do the actual replace in the string
                foreach ($var in $SortedOccurences) {
                    $ReplaceString = $null
                    switch ($var.Type) {
                        "RP" { 
                            if (!$RPars) {
                                Write-SPOTLog "ERROR: a Runbook Parameter reference was detected, ""$($var.VarName)"", but no Runbook Parameters were made available. Cannot continue." -Output $false
                                throw "Replace-SPOTLineVars: error replacing RP!"
                            }
                            Write-SPOTLog "INFO: Trying to replace RP: ""$($var.VarName)""." -Output $false -DBG $true
                            try {
                                $ReplaceString = Invoke-Expression -Command "`$RPars.$($var.VarName)"
                            }
                            catch {
                                Write-SPOTLog "ERROR: while trying to replace the Runbook Parameter ""$($var.VarName)"": $_." -Output $false
                                throw "Replace-SPOTLineVars: error replacing RP!"
                            }
                            if ($ReplaceString.GetType().Name -ne "String") {
                                Write-SPOTLog "ERROR: the referenced Runbook Parameter ""$($var.VarName)"" is not a String. Only String objects are supported in this function." -Output $false
                                throw "Replace-SPOTLineVars: error replacing RP!"
                            }
                            $word = $word.Remove($var.Pos, ($var.LastPosition-$var.Pos+1)).Insert($var.Pos,$ReplaceString)
                        }
                        "PV" { 
                            if (!$PVars) {
                                Write-SPOTLog "ERROR: a Published Variable reference was detected, ""$($var.VarName)"", but no Published Variables were made available. Cannot continue." -Output $false
                                throw "Replace-SPOTLineVars: error replacing PV!"
                            }
                            Write-SPOTLog "INFO: Trying to replace PV: ""$($var.VarName)""." -Output $false -DBG $true
                            try {
                                $ReplaceString = Invoke-Expression -Command "`$PVars.$($var.VarName)"
                            }
                            catch {
                                Write-SPOTLog "ERROR: while trying to replace the Published Variable ""$($var.VarName)"": $_." -Output $false
                                throw "Replace-SPOTLineVars: error replacing PV!"
                            }
                            if ($ReplaceString.GetType().Name -ne "String") {
                                Write-SPOTLog "ERROR: the referenced Published Variable ""$($var.VarName)"" is not a String. Only String objects are supported in this function." -Output $false
                                throw "Replace-SPOTLineVars: error replacing PV!"
                            }
                            $word = $word.Remove($var.Pos, ($var.LastPosition-$var.Pos+1)).Insert($var.Pos,$ReplaceString)
                        }
                        "SV" {
                            if (!$SVars) {
                                Write-SPOTLog "ERROR: a Secret Variable reference was detected, ""$($var.VarName)"", but no Secret Variables were made available. Cannot continue." -Output $false
                                throw "Replace-SPOTLineVars: error replacing SV!"
                            }
                            Write-SPOTLog "INFO: Trying to replace SV: ""$($var.VarName)""." -Output $false -DBG $true
                            if ($SVars[$var.VarName]) {
                                if ($SVars[$var.VarName].GetType().Name -ne "SecureString") {
                                    Write-SPOTLog "ERROR: the referenced secret ""$($var.VarName)"" is not a SecureString. Only SecureString objects are supported in this function." -Output $false
                                    throw "Replace-SPOTLineVars: error replacing SV!"
                                }
                                else {
                                    $ReplaceString = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($SVars[$var.VarName]))
                                }
                            }
                            else {
                                Write-SPOTLog "ERROR: the referenced secret ""$($var.VarName)"" does not exist in the SVars." -Output $false
                                throw "Replace-SPOTLineVars: error replacing SV!"
                            }
                            if (!$ReplaceString) {
                                Write-SPOTLog "ERROR: the secret has a null value." -Output $false
                                throw "Replace-SPOTLineVars: error replacing SV!"
                            }
                            else {
                                $word = $word.Remove($var.Pos, ($var.LastPosition-$var.Pos+1)).Insert($var.Pos,$ReplaceString)
                            }
                        }
                        "OV" { 
                            Write-SPOTLog "INFO: Trying to replace OV: ""$($var.VarName)""." -Output $false -DBG $true
                            try {
                                $ReplaceString = Invoke-Expression -Command "`$OrchVars.$($var.VarName)"
                            }
                            catch {
                                Write-SPOTLog "ERROR: while trying to replace the Orch Variable ""$($var.VarName)"": $_." -Output $false
                                throw "Replace-SPOTLineVars: error replacing OV!"
                            }
                            if ($ReplaceString.GetType().Name -ne "String") {
                                Write-SPOTLog "ERROR: the referenced OrchVar ""$($var.VarName)"" is not a String. Only String objects are supported in this function." -Output $false
                                throw "Replace-SPOTLineVars: error replacing OV!"
                            }
                            $word = $word.Remove($var.Pos, ($var.LastPosition-$var.Pos+1)).Insert($var.Pos,$ReplaceString)
                        }
                    }
                }
            }
            $NewLine += $word
        }
        $line = $NewLine -join " "
        Write-SPOTLog "INFO: Current line changed to: ""$line""." -Output $false -DBG $true
    }
    
    #####
    Write-SPOTLog "Finished function Replace-SPOTLineVars." -Output $false -DBG $true

    return $line
} # end of Replace-SPOTLineVars function

######################################################################################################################
function Replace-SPOTLineCred {
    Param (
    [Parameter(Mandatory=$true)]
    [string]
    # the string to parse and replace with Credential parts
    $line, 
    [Parameter(Mandatory=$true)]
    [System.Management.Automation.PSCredential]
    # the Credential to be used for replacement
    $Credential 
    )

    #####
    Write-SPOTLog "Starting function Replace-SPOTLineCred for line ""$line""." -Output $false -DBG $true

    if ($line.Contains("`$Cred")) {
        # this means we must have had a Credential parameter defined
        $NewLine = @()
        foreach ($word in ($line -split '\s+')) {
            if ($word -like "*`$Cred:Username*") {
                $NewLine += $word.Replace('$Cred:Username',$Credential.UserName)
            }
            elseif ($word -like "*`$Cred:Password*") {
                $NewLine += $word.Replace('$Cred:Password',$Credential.GetNetworkCredential().Password)
            }
            else {
                $NewLine += $word
            }
        }
        $line = $NewLine -join " "
    }

    #####
    Write-SPOTLog "Finished function Replace-SPOTLineCred." -Output $false -DBG $true

    return $line
} # end of Replace-SPOTLineCred function

######################################################################################################################
function Decompose-SPOTHashTableVariable {
    Param (
        [Parameter(Mandatory=$true)]
        [AllowNull()]
        #[hashtable]
        # the hash table variable containing secure strings and PSCredentials
        $InputVariable, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the key to be used to temporary encrypt the secrets
        $Key  
    )

    $Variable = Get-SPOTDeepClone -InputObject $InputVariable
    if ($Variable -is [hashtable]) {
        foreach ($i in $($Variable.Keys)) {
            if (!$Variable[$i]) {
                continue
            }
            elseif ($Variable[$i].GetType().Name -eq "Hashtable") {
                if ($Variable[$i].Count -ne 0) {
                    $Variable[$i] = Decompose-SPOTHashTableVariable -InputVariable $Variable[$i] -Key $key
                }
            }
            elseif ($Variable[$i].GetType().Name -eq "SecureString") {
                $Variable[$i] = @{
                    SecType = "SecureString"
                    eStringValue = Get-SPOTSecStringToEncrypted -SecString $Variable[$i] -Key $key
                }
            }
            elseif ($Variable[$i].GetType().Name -eq "PSCredential") {
                $Variable[$i] = @{
                    SecType = "PSCredential"
                    eUsername = $Variable[$i].UserName
                    ePassword = Get-SPOTSecStringToEncrypted -SecString $Variable[$i].Password -Key $key
                }
            }
        }
    }
    
    return $Variable
} # end of Decompose-SPOTHashTableVariable function

######################################################################################################################
function Recompose-SPOTHashTableVariable {
    Param (
        [Parameter(Mandatory=$true)]
        [AllowNull()]
        # [hashtable]
        # the hash table variable containing CT values to be converted back to secure strings and PSCredentials
        $InputVariable, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the key to be used to decrypt the temporary encrypted secrets 
        $Key 
    )

    $Variable = Get-SPOTDeepClone -InputObject $InputVariable
    if ($Variable -is [hashtable]) {
        foreach ($i in $($Variable.Keys)) {
            if (!$Variable[$i]) {
                continue
            }
            # PublishedData was kept out and remains out
            elseif ($Variable[$i].GetType().Name -eq "Hashtable" -and $Variable[$i].SecType -eq "SecureString") {
                $Variable[$i] = Get-SPOTEncryptedToSecString -EncString $Variable[$i].eStringValue -Key $key
            }
            elseif ($Variable[$i].GetType().Name -eq "Hashtable" -and $Variable[$i].SecType -eq "PSCredential") {
                $Variable[$i] = New-Object System.Management.Automation.PSCredential ($Variable[$i].eUsername, (Get-SPOTEncryptedToSecString -EncString $Variable[$i].ePassword -Key $key))
            }
            elseif ($Variable[$i].GetType().Name -eq "Hashtable") {
                if ($Variable[$i].Count -ne 0) {
                    $Variable[$i] = Recompose-SPOTHashTableVariable -InputVariable $Variable[$i] -Key $key
                }
            }
        }
    }
    return $Variable
} # end of Recompose-SPOTHashTableVariable function

######################################################################################################################
function Decompose-SPOTRunbook {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [runbook]
        # the runbook object, potentially containing secure strings and PSCredentials
        $InputRunbook, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the key to be used to temporary encrypt the secrets
        $Key  
    )

    # create a clone of a runbook (with runbookStep clones) that has any potential secrets (secured strings and credentials) decomposed into hashtables with key based encrypted strings
    # this is to be used for the remote execution of specific runbooks
    # on the remote target, they will be recomposed and attached to the AllRunbooks and AllRunbookSteps synchronized hashtables
    
    ##########################
    $CloneRunbookSteps = @()
    foreach ($Step in $InputRunbook.RunbookSteps) {
        $CloneStep = $null
        $FunctionParams = $null
        if ($Step.GetType().Name -eq "RunbookStep") {
            # FunctionParams may contain secrets, so decompose these hashtables
            $FunctionParams = Decompose-SPOTHashTableVariable -InputVariable $Step.StepParameters -Key $Key

            # initialize a new RunbookStep object with the same parameters
            $CloneStep = [RunbookStep]::new($Step.Name, $Step.Seq, $Step.Type, $FunctionParams)
            $CloneStep.GUID                   = $Step.GUID
            $CloneStep.Conditions             = $Step.Conditions
            $CloneStep.Description            = $Step.Description
            $CloneStep.Status                 = $Step.Status
            $CloneStep.MultiStatus            = Get-SPOTDeepClone -InputObject $Step.MultiStatus
            $CloneStep.StartTime              = $Step.StartTime
            $CloneStep.LastExecutionTime      = $Step.LastExecutionTime
            $CloneStep.MultiLastExecutionTime = Get-SPOTDeepClone -InputObject $Step.MultiLastExecutionTime
            $CloneStep.ExitValue              = $Step.ExitValue
            $CloneStep.RetryCount             = $Step.RetryCount
            $CloneStep.MultiRetryCount        = Get-SPOTDeepClone -InputObject $Step.MultiRetryCount
            $CloneStep.RetryDelay             = $Step.RetryDelay
            $CloneStep.Disabled               = $Step.Disabled
            $CloneStep.ContinueOnError        = $Step.ContinueOnError
            $CloneStep.ArtefactsPath          = $Step.ArtefactsPath

            # add this cloned step to the cloned runbooksteps array
            $CloneRunbookSteps += $CloneStep
        }
        elseif ($Step.GetType().Name -eq "Runbook") {
            $CloneStep = Decompose-SPOTRunbook -InputRunbook $Step -Key $Key
            $CloneRunbookSteps += $CloneStep
        }
    }

    ##########################
    # at the end, initialize a new Runbook object with the same parameters
    # RemoteParameters may contain secrets, so decompose these hashtables

    # initialize a new Runbook object with the same parameters
    $CloneRunbook = [Runbook]::new($InputRunbook.Name, $InputRunbook.Seq)
    $CloneRunbook.GUID              = $InputRunbook.GUID
    $CloneRunbook.Conditions        = $InputRunbook.Conditions
    $CloneRunbook.Description       = $InputRunbook.Description
    $CloneRunbook.Status            = $InputRunbook.Status
    $CloneRunbook.MultiStatus       = Get-SPOTDeepClone -InputObject $InputRunbook.MultiStatus
    $CloneRunbook.StartTime         = $InputRunbook.StartTime
    $CloneRunbook.LastExecutionTime = $InputRunbook.LastExecutionTime
    $CloneRunbook.ExitValue         = $InputRunbook.ExitValue 
    $CloneRunbook.Disabled          = $InputRunbook.Disabled
    $CloneRunbook.ContinueOnError   = $InputRunbook.ContinueOnError
    $CloneRunbook.ArtefactsPath     = $InputRunbook.ArtefactsPath
    $CloneRunbook.RunbookParameters = Decompose-SPOTHashTableVariable -InputVariable $InputRunbook.RunbookParameters -Key $Key
    $CloneRunbook.RemoteParameters  = Decompose-SPOTHashTableVariable -InputVariable $InputRunbook.RemoteParameters -Key $Key
    $CloneRunbook.RunbookSteps     += $CloneRunbookSteps

    # force stop flag to false
    $CloneRunbook.StopFlag = $false

    ##########################
    return $CloneRunbook

} # end of Decompose-SPOTRunbook function

######################################################################################################################
function Recompose-SPOTRunbook {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [object]
        # the deserialized runbook object, potentially containing CT values to be converted back to secure strings and PSCredentials
        $DRunbook, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the key to be used to decrypt the temporary encrypted secrets
        $Key  
    )

    # reconstruct a runbook object based on its deserialized/decomposed object, recreating locally any secret objects contained

    ##########################
    $RunbookSteps = @()
    foreach ($DStep in $DRunbook.RunbookSteps) {
        $Step = $null
        $FunctionParams = $null
        
        if (($DStep | gm | Select -Property TypeName -First 1).TypeName -eq "Deserialized.RunbookStep") {
            # FunctionParams may contain secrets, so recompose these hashtables
            $FunctionParams = Recompose-SPOTHashTableVariable -InputVariable $DStep.StepParameters -Key $Key

            # initialize a new RunbookStep object with the same parameters
            $Step = [RunbookStep]::new($DStep.Name, $DStep.Seq, $DStep.Type, $FunctionParams)
            $Step.GUID                   = $DStep.GUID
            $Step.Conditions             = $DStep.Conditions
            $Step.Description            = $DStep.Description
            $Step.Status                 = $DStep.Status
            $Step.MultiStatus            = Get-SPOTDeepClone -InputObject $DStep.MultiStatus
            $Step.StartTime              = $DStep.StartTime
            $Step.LastExecutionTime      = $DStep.LastExecutionTime
            $Step.MultiLastExecutionTime = Get-SPOTDeepClone -InputObject $DStep.MultiLastExecutionTime
            $Step.ExitValue              = $DStep.ExitValue
            $Step.RetryCount             = $DStep.RetryCount
            $Step.MultiRetryCount        = Get-SPOTDeepClone -InputObject $DStep.MultiRetryCount
            $Step.RetryDelay             = $DStep.RetryDelay
            $Step.Disabled               = $DStep.Disabled
            $Step.ContinueOnError        = $DStep.ContinueOnError
            $Step.ArtefactsPath          = $DStep.ArtefactsPath

            # add this new step to the runbooksteps array
            $RunbookSteps += $Step

            # add the current runbookstep object to the AllRunbookSteps hashtable
            $AllRunbookSteps.$($Step.GUID) = $Step
        }
        elseif (($DStep | gm | Select -Property TypeName -First 1).TypeName -eq "Deserialized.Runbook") {
            $Step = Recompose-SPOTRunbook -DRunbook $DStep -Key $Key
            $RunbookSteps += $Step
        }
    }

    ##########################
    # at the end, initialize a new Runbook object with the same parameters
    # RemoteParameters may contain secrets, so recompose these hashtables

    # initialize a new Runbook object with the same parameters
    $Runbook = [Runbook]::new($DRunbook.Name, $DRunbook.Seq)
    $Runbook.GUID              = $DRunbook.GUID
    $Runbook.Conditions        = $DRunbook.Conditions
    $Runbook.Description       = $DRunbook.Description
    $Runbook.Status            = $DRunbook.Status
    $Runbook.MultiStatus       = Get-SPOTDeepClone -InputObject $DRunbook.MultiStatus
    $Runbook.StartTime         = $DRunbook.StartTime
    $Runbook.LastExecutionTime = $DRunbook.LastExecutionTime
    $Runbook.ExitValue         = $DRunbook.ExitValue 
    $Runbook.Disabled          = $DRunbook.Disabled
    $Runbook.ContinueOnError   = $DRunbook.ContinueOnError
    $Runbook.ArtefactsPath     = $DRunbook.ArtefactsPath
    $Runbook.RemoteParameters  = Recompose-SPOTHashTableVariable -InputVariable $DRunbook.RemoteParameters -Key $Key
    $Runbook.RunbookParameters = Recompose-SPOTHashTableVariable -InputVariable $DRunbook.RunbookParameters -Key $Key
    $Runbook.RunbookSteps     += $RunbookSteps

    # force stop flag to false
    $Runbook.StopFlag          = $false

    # add the current runbook object to the AllRunbooks hashtable
    $AllRunbooks.$($Runbook.GUID) = $Runbook

    ##########################
    return $Runbook

} # end of Recompose-SPOTRunbook function

######################################################################################################################
function Get-SPOTDeepClone {
    # clones a multi level hash table
    [cmdletbinding()]
    param(
        [Parameter(Position = 0,Mandatory=$true)]
        [AllowNull()]
        $InputObject,
        [Parameter(Mandatory=$false)]
        [AllowNull()]
        [string[]]
        # they keys to be excluded from the top level only
        $ExcludeKeys
    )
    process
    {
        if ($InputObject -is [hashtable]) {
            $clone = @{}
            foreach($key in $InputObject.keys){
                if ($key -notin $ExcludeKeys) {
                    $clone[$key] = Get-SPOTDeepClone $InputObject[$key]
                }
            }
            return $clone
        } else {
            return $InputObject
        }
    }
} # end of Get-SPOTDeepClone function

######################################################################################################################
function Get-SPOTDeepCloneSynchronized {
    # clones a multi level hash table
    [cmdletbinding()]
    param(
        [AllowNull()]
        $InputObject
    )
    process
    {
        if ($InputObject -is [hashtable]) {
            $clone = [hashtable]::Synchronized(@{})
            foreach($key in $InputObject.keys) {
                $clone[$key] = Get-SPOTDeepClone $InputObject[$key]
            }
            return $clone
        }
        else {
            return $InputObject
        }
    }
} # end of Get-SPOTDeepCloneSynchronized function

######################################################################################################################
function Get-SPOTRunbookSummary {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [runbook]
        # the runbook object to be summarized
        $InputRunbook 
    )

    # create a summary hashtable for a runbook, containing all status related information, that is relevant to establish the overall status 
    # of the main runbook and of the steps included 
    
    ##########################
    $SummarySteps = @()
    foreach ($Step in $InputRunbook.RunbookSteps) {
        $SummaryStep = $null
        if ($Step.GetType().Name -eq "RunbookStep") {
            $SummaryStep = @{
                Name                   = $Step.Name
                GUID                   = $Step.GUID
                Status                 = $Step.Status
                MultiStatus            = Get-SPOTDeepClone -InputObject $Step.MultiStatus
                StartTime              = $Step.StartTime
                LastExecutionTime      = $Step.LastExecutionTime
                MultiLastExecutionTime = Get-SPOTDeepClone -InputObject $Step.MultiLastExecutionTime
                ExitValue              = $Step.ExitValue
            }
            $SummarySteps += $SummaryStep
        }
        elseif ($Step.GetType().Name -eq "Runbook") {
            $SummaryStep = Get-SPOTRunbookSummary -InputRunbook $Step
            $SummarySteps += $SummaryStep
        }
    }

    ##########################
    # at the end, include the details of the main runbook 
    $Summary = @{
        Name              = $InputRunbook.Name
        GUID              = $InputRunbook.GUID
        Status            = $InputRunbook.Status
        MultiStatus       = Get-SPOTDeepClone -InputObject $InputRunbook.MultiStatus
        StartTime         = $InputRunbook.StartTime
        LastExecutionTime = $InputRunbook.LastExecutionTime
        ExitValue         = $InputRunbook.ExitValue
        RunbookSteps      = $SummarySteps
    }

    ##########################
    return $Summary

} # end of Get-SPOTRunbookSummary function

######################################################################################################################
function Set-SPOTRunbookStatus {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [runbook]
        # the runbook object to have its status updated
        $Runbook, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [hashtable]
        # the runbook summary object with the status data for the update
        $RunbookSummary 
    )

    # this is for remote runbook executions, where all step status is captured remotely and made available all at once
    # to the local environment with the use of a RunbookSummary hashtable object that is sent back via PublishedData
    
    Write-SPOTLog ">>> Staring function Set-SPOTRunbookStatus on runbook ""$($Runbook.Name)""." -Output $false -DBG $true
    ##########################
    
    if ($Runbook.Name -eq $RunbookSummary.Name -and $Runbook.GUID -eq $RunbookSummary.GUID) {
        foreach ($Step in $Runbook.RunbookSteps) {
            $SummaryStep = $null
            $SummaryStep = $RunbookSummary.RunbookSteps | Where {$_.Name -eq $Step.Name -and $_.GUID -eq $Step.GUID}
            if ($Step.GetType().Name -eq "RunbookStep") {
                if ($SummaryStep) {
                    $Step.Status                 = $SummaryStep.Status
                    $Step.MultiStatus            = Get-SPOTDeepClone -InputObject $SummaryStep.MultiStatus
                    $Step.StartTime              = $SummaryStep.StartTime
                    $Step.LastExecutionTime      = $SummaryStep.LastExecutionTime
                    $Step.MultiLastExecutionTime = Get-SPOTDeepClone -InputObject $SummaryStep.MultiLastExecutionTime
                    $Step.ExitValue              = $SummaryStep.ExitValue
                }
                else {
                    Write-SPOTLog ">>> WARNING: For RunbookStep ""$($Step.Name)"" there was no summary data found. Skipping it." -Output $false
                }
            }
            elseif ($Step.GetType().Name -eq "Runbook") {
                if ($SummaryStep) {
                    Set-SPOTRunbookStatus -Runbook $Step -RunbookSummary $SummaryStep
                }
                else {
                    Write-SPOTLog ">>> WARNING: For Runbook ""$($Step.Name)"" there was no summary data found. Skipping it." -Output $false
                }
            }
        }

        ##########################
        # at the end, update the details of the main runbook 
        $Runbook.Status            = $RunbookSummary.Status
        $Runbook.MultiStatus       = Get-SPOTDeepClone -InputObject $RunbookSummary.MultiStatus
        $Runbook.StartTime         = $RunbookSummary.StartTime
        $Runbook.LastExecutionTime = $RunbookSummary.LastExecutionTime
        $Runbook.ExitValue         = $RunbookSummary.ExitValue
        $Runbook.Status            = $RunbookSummary.Status
    }
    else {
        Write-SPOTLog ">>> ERROR: The RunbookSummary ""$($RunbookSummary.Name)"" with GUID ""$($RunbookSummary.GUID)"" does not match with the input runbook ""$($Runbook.Name)"" with GUID ""$($Runbook.GUID)""." -Output $false
    }
    
    ##########################
    Write-SPOTLog ">>> Finished function Set-SPOTRunbookStatus on runbook ""$($Runbook.Name)""." -Output $false -DBG $true
    
} # end of Set-SPOTRunbookStatus function

######################################################################################################################
function Replace-SPOTArtefactsPath {
    Param (
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [object]
    # the target runbook
    $Runbook, 
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]
    # the string to be replaced
    $MatchString, 
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]
    # the replace string
    $ReplaceString 
    )

    $Runbook.ArtefactsPath = $Runbook.ArtefactsPath.Replace($MatchString,$ReplaceString)
    foreach ($RSstep in $Runbook.RunbookSteps) {
        if ($RSstep.GetType().Name -eq "RunbookStep") {
            $RSstep.ArtefactsPath = $RSstep.ArtefactsPath.Replace($MatchString,$ReplaceString)
        }
        else {
            Replace-SPOTArtefactsPath -Runbook $RSstep -MatchString $MatchString -ReplaceString $ReplaceString
        }
    }
    # no return necessary, the object is updated in place

} # end of Replace-SPOTArtefactsPath function 

######################################################################################################################
function Execute-SPOTScheduledJob {
    Param(
        [Parameter(Mandatory = $true)]
        [ScriptBlock]
        # the ScriptBlock to the executed inside the Scheduled Job
        $ScriptBlock,
        [Parameter(Mandatory = $false)]
        [Object[]]
        # the arguments to be used by the ScriptBlock
        $ArgumentList,
        [Parameter(Mandatory = $false)]
        [PSCredential]
        # the credential object for the potential RunAs another user option
        $AsUser,
        [Parameter(Mandatory = $false)]
        [bool]
        # the flag used to set the execution as Local System or  not
        $AsSystem=$false
    )

    ###########################################
    Write-SPOTLog "===== Starting function Execute-SPOTScheduledJob ====="

    ###########################################
    # define variables
    $JobName = ([guid]::NewGuid()).Guid
    $StepTimeout = $OrchVars._StepTimeout

    try {
        ###########################################
        # check prerequisites for SJ step type
        $TSService = Get-Service -Name Schedule -ErrorAction Stop
        if ($TSService.Status -ne "Running") {
            Write-SPOTLog ">>> ScheduledJob: ERROR: The Task Scheduler service is required for this step type but not running."
            throw "Execute-SPOTScheduledJob: Task Scheduler service not running!"
        }
        
        ###########################################
        # prepare and register the Scheduled Job
        $JobParams = @{
            Name = $JobName
            ScheduledJobOption = New-ScheduledJobOption -RunElevated -StartIfOnBattery -ContinueIfGoingOnBattery
        }
        $JobArgs = @{
            ScriptBlock = $ScriptBlock
            ArgumentList = $ArgumentList
        }

        $JobSB = [ScriptBlock]::Create({
            Param($_spot_JSBParams)
            $_spot_JobParams = @{
                ScriptBlock = [ScriptBlock]::Create($_spot_JSBParams.ScriptBlock)
                ArgumentList = $_spot_JSBParams.ArgumentList
            }
            Invoke-Command @_spot_JobParams
        })
        Write-SPOTLog ">>> ScheduledJob: Register ""$JobName""." -DBG $true
        $SJ = Register-ScheduledJob  @JobParams -ScriptBlock $JobSB -ArgumentList $JobArgs -ErrorAction Stop

        ###########################################
        # get and modify the associated Scheduled Task
        Write-SPOTLog ">>> ScheduledJob: Customize ""$JobName""." -DBG $true
        $ST = Get-ScheduledTask -TaskName $JobName -ErrorAction Stop
        $TaskParams = @{
            TaskName = $ST.TaskName
            TaskPath = $ST.TaskPath
            Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Priority 2 -ExecutionTimeLimit (New-TimeSpan -Seconds $StepTimeout)
        }

        # do specific modifications for System or for other user
        if ($AsSystem) {
            Write-SPOTLog ">>> ScheduledJob: AsSystem detected for ""$JobName""." -DBG $true
            $TaskParams += @{
                Principal = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel 'Highest'
            }
        } 
        elseif ($AsUser) {
            Write-SPOTLog ">>> ScheduledJob: AsUser detected for ""$JobName""." -DBG $true
            # avoid the "." domain name
            if ($AsUser.GetNetworkCredential().Domain -eq ".") {
                $UserString = $AsUser.GetNetworkCredential().UserName
            }
            else {
                $UserString = $AsUser.UserName
            }
            $TaskParams += @{
                User = $UserString
                Password = $AsUser.GetNetworkCredential().Password
            }
        }
    
        # apply the new task configuration
        Set-ScheduledTask @TaskParams -ErrorAction Stop | Out-Null

        ###########################################
        # execute the Scheduled Task
        Write-SPOTLog ">>> ScheduledJob: Start ""$JobName""." -DBG $true
        $STJob = $ST | Start-ScheduledTask -AsJob -ErrorAction Stop
        $STJob | Wait-Job | Remove-Job -Force -Confirm:$False
    
        ###########################################
        # wait the Scheduled Task
        Write-SPOTLog ">>> ScheduledJob: Wait for ""$JobName"" with timeout ""$StepTimeout"" seconds." -DBG $true
        $StartTime = Get-Date
        while ([math]::floor(((Get-Date) - $StartTime).TotalSeconds) -lt ($StepTimeout + 1)){
            $STI = $null
            $STI = $ST | Get-ScheduledTaskInfo
            if ($STI.LastTaskResult -ne 267009) {
                break
            }
            Start-Sleep -Milliseconds 500
        }

        ###########################################
        # check the Scheduled Task
        $STI = $ST | Get-ScheduledTaskInfo
        if ($STI.LastRunTime.Year -ne $StartTime.Year) { 
            Write-SPOTLog ">>> ERROR: Unable to execute task." -DBG $true
            throw "Execute-SPOTScheduledJob: job timeout or failed to execute!"
        }

        ###########################################
        # process the output after completion
        Write-SPOTLog ">>> ScheduledJob: Receive ""$JobName""." -DBG $true
        $Job = Get-Job -Name $JobName -ErrorAction SilentlyContinue
        If ($Job) { 
            # receive the job and the output that will be returned
            $_spot_SJOutput = $Job | Wait-Job | Receive-Job -Wait -AutoRemoveJob 
        }
    }
    catch {
        "############# TERMINATING ERROR while trying to execute the Execute-SPOTScheduledJob function. #############"
        " >>>>>> ERROR Exception:"
        "$($_.Exception)"
        " >>>>>> ERROR Exception Type:"
        "$($_.Exception.GetType().FullName)"
        " >>>>>> ERROR InvocationInfo.Line:"
        "$($_.InvocationInfo.Line)"
        " >>>>>> ERROR InvocationInfo.PositionMessage:"
        "$($_.InvocationInfo.PositionMessage)"
    }

    ###########################################
    # cleanup the Scheduled Task/Job
    Write-SPOTLog ">>> ScheduledJob: Unregister ""$JobName"" job." -DBG $true
    Get-ScheduledJob -Name $JobName -ErrorAction SilentlyContinue | Unregister-ScheduledJob -Force -Confirm:$false | Out-Null
    
    ###########################################
    Write-SPOTLog "===== Finished function Invoke-ScheduledJob ====="

} # enf of Execute-SPOTScheduledJob function

######################################################################################################################
Function Get-SPOTSecStringToEncrypted {

    param(
         [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][SecureString]$SecString,
         [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][String]$Key
    )
    
    # generate bytes
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($key)

    # convert
    $return = ConvertFrom-SecureString $SecString -Key $bytes

    # return
    $return

} # end of Get-SPOTSecStringToEncrypted function

######################################################################################################################
Function Get-SPOTEncryptedToSecString {

    param(
         [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][String]$EncString,
         [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][String]$Key
    )

    # generate salt
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($key)

    #convert 
    $SecString = ConvertTo-SecureString -String $EncString -Key $bytes

    #return
    return $SecString

} # end of Get-SPOTEncryptedToSecString function

######################################################################################################################
function Create-SPOTArchive {
Param (
    [Parameter(Mandatory=$true)]
    [String]
    # The folder which will be archived
    $TargetFolder, 
    [Parameter(Mandatory=$true)]
    [String]
    # The path to the Zip archive
    $ZipPath 
    )

    # create the archive
    Add-Type -Assembly "system.io.compression.filesystem"
    [io.compression.zipfile]::CreateFromDirectory($TargetFolder,$ZipPath)

} # end of Create-SPOTArchive function

######################################################################################################################
function Create-SPOTProjectArchive {
Param (
    [Parameter(Mandatory=$true)]
    [String]
    # The SPOT project folder which will be archived
    $TargetFolder, 
    [Parameter(Mandatory=$true)]
    [String]
    # The path to the SPOT Project Zip archive
    $ZipPath 
    )

    # create the archive
    Add-Type -Assembly "system.io.compression.filesystem"

    $zip = [System.IO.Compression.ZipFile]::Open($ZipPath, 'Create')

    Get-ChildItem $TargetFolder -Recurse -File | Where-Object {
        #$_.Name -notin @("secret.txt", "config.json") -and
        $_.FullName -notmatch "\\(__SPOT_Config|__SPOT_Runbooks|__SPOT_Artefacts|_HelperFunctions)\\"
    } | ForEach-Object {
        $relativePath = $_.FullName.Substring($TargetFolder.Length + 1)
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip,
            $_.FullName,
            $relativePath
        ) | Out-Null
    }

    $zip.Dispose()

} # end of Create-SPOTProjectArchive function

######################################################################################################################
function Extract-SPOTArchive {
Param (
    [Parameter(Mandatory=$true)]
    [String]
    # The folder which will be archived
    $TargetFolder, 
    [Parameter(Mandatory=$true)]
    [String]
    # The path to the Zip archive
    $ZipPath 
    )

    # extract the archive
    Add-Type -Assembly "system.io.compression.filesystem"
    [io.compression.zipfile]::ExtractToDirectory($ZipPath,$TargetFolder)

} # end of Extract-SPOTArchive function

######################################################################################################################
function Ping-SPOTHostWMI {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [String]
        # the target ip address or hostname
        $ip 
        )

    # execute the ping
    $status = Get-WmiObject -Class Win32_PingStatus -Filter "Address='$ip'" 
    # get the result           
    if( $status.statuscode -eq 0) {            
        return $true            
    }
    else {            
        return $false           
    } 
} # end of Ping-SPOTHostWMI function

######################################################################################################################
function Test-SPOTTCPPort {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the IP address or hostname on which to test the TCP port
        $TargetIP, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the TCP port to be tested
        $TCPPort 
        )

    # create the return hashtable
    $return = @{
        PingSucceeded = $false
        TcpTestSucceeded = $false
    }

    trap {return $return}
    # handle the potential errors
    $ErrorActionPreference = “silentlycontinue”

    # test first the ping availability
    $PingSucceeded = Ping-SPOTHostWMI -ip $TargetIP
    $return.PingSucceeded = [bool]$PingSucceeded

    # test also the TCP Port availability
    $tcpConnection = New-Object System.Net.Sockets.TcpClient
    $tcpConnection.Connect($TargetIP, $TCPPort)
    $TcpTestSucceeded = $tcpConnection.Connected
    $tcpConnection.Dispose()
    $return.TcpTestSucceeded = [bool]$TcpTestSucceeded

    # return the results as a hashtable
    return $return
} # end of Test-SPOTTCPPort function

######################################################################################################################
function New-SPOTSFTPSession {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the target IP Address or hostname on which to create the SFTP Session
        $TargetIP,
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int]
        # the port to be used, in case it is different from the default
        $Port = 22,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.Management.Automation.PSCredential]
        # the SSH credentials to be used for remote authentication
        $Credential,
        [Parameter(Mandatory=$false)]
        [AllowNull()]
        [string]
        # the path to the TrustedHosts file
        $TrustedHostsFilePath,
        [Parameter(Mandatory=$false)]
        [string]
        # the local path to the Renci.SSHNet.dll file
        $SshNetPath 
        )
    
    #################################
    Write-SPOTLog "===== Starting function New-SPOTSFTPSession for the target ""$TargetIP"" and port ""$Port"" =====" -Output $false -DBG $true

    #################################
    # test/detect the local Renci.SSHNet.dll file
    try {
        $SshNetPath = Get-SPOTSshNetPath -SshNetPath $SshNetPath -ErrorAction Stop
    }
    catch {
        Write-SPOTLog "T.ERROR: The SshNetPath was not provided/determined/detected: $_." -Output $false
        throw "New-SPOTSFTPSession: SshNetPath not detected!"
    }

    #########################
    # load Renci SSH dll file
    if ($PSVersionTable.PSVersion.Major -eq 5) {
        Add-Type -Path $SshNetPath
    }
    else {
        Write-SPOTLog "ERROR: The detected PowerShell version is too low. Cannot continue." -Output $false
        throw "New-SPOTSFTPSession: PowerShell version is too low!"
    }

    #########################
    # check if .NET 4.7.1 or higher is available
    try {
        $NetVersion = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop | Select-Object Release -ExpandProperty Release -ErrorAction Stop
        $NetInstallPath = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' | Select-Object InstallPath -ExpandProperty InstallPath
    }
    catch {
        Write-SPOTLog "ERROR: while detecting .NET Framework version: $_." -Output $false
        throw "New-SPOTSFTPSession: error detecting .NET version!"
    }
    if ($NetVersion -lt 461308) {
        Write-SPOTLog "ERROR: the .NET Framework version is not 4.7.1 or greater. Cannot continue." -Output $false
        throw "New-SPOTSFTPSession: .NET version too low!"
    }
    if (!$NetInstallPath) {
        Write-SPOTLog "ERROR: the .NET Framework install path could not be determined. Cannot continue." -Output $false
        throw "New-SPOTSFTPSession: error detecting .NET path!"
    }

    #########################
    # default behavior is not to validate the SSH key unless there is a usable TrustedHosts file provided
    $ValidateSSHKey = $false

    #########################
    # validate the file exists and can be used (fit for purpose)
    if ($TrustedHostsFilePath) {
        if (Test-Path -Path $TrustedHostsFilePath -PathType Leaf) {
            $TrustedHostsFilePath = (Get-Item -Path $TrustedHostsFilePath -ErrorAction Stop).FullName
            Write-SPOTLog "TrustedHosts file path provided and detected. Checking it." -DBG $true -Output $false
            try {
                $TrustedHostKeys = @(Import-Csv -Path $TrustedHostsFilePath -Delimiter ";" -Encoding UTF8 -ErrorAction Stop)
            }
            catch {
                Write-SPOTLog "ERROR: while loading the objects inside the TrustedHosts file in the provided path ""$TrustedHostsFilePath"": $_." -Output $false
                throw "New-SPOTSFTPSession: error loading Trusted Hosts!"
            }
            if ($TrustedHostKeys) {
                $RequiredProperties = @("TargetHost","Port","KeyType","Fingerprint")
                $MissingObjectProperties = $RequiredProperties | Where-Object { $_ -notin $TrustedHostKeys[0].PSObject.Properties.Name }
                if ($MissingObjectProperties) {
                    Write-SPOTLog "ERROR: at least the first TrustedHosts object is missing some required properties: $($MissingObjectProperties -join ","). Cannot continue." -Output $false
                    throw "New-SPOTSFTPSession: error loading Trusted Hosts!"
                }
            }
            else {
                # no objects found; file cannot be used
                Write-SPOTLog "ERROR: the provided TrustedHosts file has no usable data. Cannot continue." -Output $false
                throw "New-SPOTSFTPSession: error loading Trusted Hosts!"
            }
            # using the TrustedHosts file; if the received key fingeprint does not match in the TrustedHosts file abort the connection
            $ValidateSSHKey = $true
        }
        else {
            # TrustedHosts file path provided but not detected; abort the connection
            Write-SPOTLog "ERROR: the TrustedHosts file path was provided but the file was not found. Cannot continue." -Output $false
            throw "New-SPOTSFTPSession: error loading Trusted Hosts!"
        }
    }

    #########################
    # define and create the host key handler object (verification and logging / only logging)
    if (!("HostKeyHandler" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using Renci.SshNet;
using Renci.SshNet.Common;

public class HostKeyHandler
{
    // Configuration from PowerShell
    public bool EnforceValidation = false;

    // host -> port -> keyType -> fingerprint
    public Dictionary<string, Dictionary<int, Dictionary<string,string>>> TrustedHosts;

    public List<string> Logs = new List<string>();

    public string ComputeSha256(byte[] data)
    {
        using (var sha256 = SHA256.Create())
        {
            return Convert.ToBase64String(sha256.ComputeHash(data));
        }
    }

    public void Handle(object sender, HostKeyEventArgs e)
    {
        var baseClient = sender as Renci.SshNet.BaseClient;
        var host = baseClient.ConnectionInfo.Host;
        var port = baseClient.ConnectionInfo.Port;

        var keyType = e.HostKeyName;
        var fp = ComputeSha256(e.HostKey);

        // Always log
        var logLine = string.Format(
            "Host=>{0},Port=>{1},Type=>{2},SHA256Fingerprint=>{3}",
            host, port, keyType, fp
        );
        lock (Logs)
        {
            Logs.Add(logLine);
        }

        // Conditional validation
        if (!EnforceValidation)
        {
            e.CanTrust = true;
            return;
        }

        if (TrustedHosts != null &&
            TrustedHosts.ContainsKey(host) &&
            TrustedHosts[host].ContainsKey(port) &&
            TrustedHosts[host][port].ContainsKey(keyType) &&
            TrustedHosts[host][port][keyType] == fp)
        {
            e.CanTrust = true;
        }
        else
        {
            e.CanTrust = false;
        }
    }
}
'@ -ReferencedAssemblies @($SshNetPath,"$NetInstallPath\netstandard.dll")
    }

    $handlerObj = New-Object HostKeyHandler
    
    #########################
    # prepare the host key handler object for use depending on the context
    if ($ValidateSSHKey) {
        #########################
        Write-SPOTLog "INFO: SSH Key validation is enabled." -DBG $true -Output $false
        # convert the TrustedHosts array to a suitable dictionary
        $trustedDict = New-Object "System.Collections.Generic.Dictionary[string, System.Collections.Generic.Dictionary[int, System.Collections.Generic.Dictionary[string,string]]]"
        foreach ($i in $TrustedHostKeys) {
            # Ensure host level
            if (!$trustedDict.ContainsKey($i.TargetHost)) {
                $trustedDict[$i.TargetHost] = New-Object "System.Collections.Generic.Dictionary[int, System.Collections.Generic.Dictionary[string,string]]"
            }
            # Ensure port level
            if (!$trustedDict[$i.TargetHost].ContainsKey($i.Port)) {
                $trustedDict[$i.TargetHost][$i.Port] = New-Object "System.Collections.Generic.Dictionary[string,string]"
            }
            # Add key type
            $trustedDict[$i.TargetHost][$i.Port][$i.KeyType] = $i.Fingerprint
        }
        # use the handler class to validate and log
        $handlerObj.EnforceValidation = $true
        $handlerObj.TrustedHosts = $trustedDict
    }
    else {
        #########################
        # use the handler class only to log
        Write-SPOTLog "INFO: SSH Key validation is disabled." -DBG $true -Output $false
        $handlerObj.EnforceValidation = $false
    }
    
    #########################
    # prepare SSHNet connection objects
    # Set up the authentication method
    $authMethod = New-Object Renci.SshNet.PasswordAuthenticationMethod($Credential.UserName, $Credential.GetNetworkCredential().Password)
    $connectionInfo = New-Object Renci.SshNet.ConnectionInfo($TargetIP, $Port, $Credential.UserName, $authMethod)
    $sftp = New-Object Renci.SshNet.SftpClient($connectionInfo)

    #########################
    # insert the handler into the SSH client object
    $eventInfo = $sftp.GetType().GetEvent("HostKeyReceived")
    $handler = [System.Delegate]::CreateDelegate($eventInfo.EventHandlerType, $handlerObj, $handlerObj.GetType().GetMethod("Handle"))
    $sftp.add_HostKeyReceived($handler)

    #########################
    # try to connect
    try {
        $sftp.Connect()
    }
    catch {
        Write-SPOTLog "ERROR: while trying to connect to the target IP: $_." -Output $false
        Write-SPOTLog "INFO: SSH server key details: $($handlerObj.Logs)." -Output $false
        throw "New-SPOTSFTPSession: error connecting to target!"
    }

    #########################
    # log the current server key
    Write-SPOTLog "INFO: SSH server key details: $($handlerObj.Logs)." -Output $false

    #########################
    # put the SSH key details into a variable into the parent scope
    New-Variable -Name _spot_SSH_Key -Scope 1 -Force -Confirm:$false -Value @{
        TargetHost  = (($handlerObj.Logs -split ',')[0] -split '=>')[1]
        Port        = (($handlerObj.Logs -split ',')[1] -split '=>')[1]
        KeyType     = (($handlerObj.Logs -split ',')[2] -split '=>')[1]
        Fingerprint = (($handlerObj.Logs -split ',')[3] -split '=>')[1]
    }

    #########################
    if ($sftp.GetType().Name -eq "SftpClient" -and $sftp.IsConnected -eq $true) {
        #########################
        # return the session object
        Write-SPOTLog "===== Function New-SPOTSFTPSession for the target ""$TargetIP"" successfull and returning the session object =====" -Output $false -DBG $true
        return $sftp
    }
    else {
        Write-SPOTLog "===== Function New-SPOTSFTPSession for the target ""$TargetIP"" NOT successfull and throwing error =====" -Output $false -DBG $true
        throw "New-SPOTSFTPSession: error connecting to target!"
    }
} # end of New-SPOTSFTPSession function

######################################################################################################################
function New-SPOTSSHSession {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the target IP Address or hostname on which to create the SSH Session
        $TargetIP,
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int]
        # the port to be used, in case it is different from the default
        $Port = 22, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.Management.Automation.PSCredential]
        # the SSH credentials to be used for remote authentication
        $Credential,
        [Parameter(Mandatory=$false)]
        [AllowNull()]
        [string]
        # the path to the TrustedHosts file
        $TrustedHostsFilePath,
        [Parameter(Mandatory=$false)]
        [string]
        # the local path to the Renci.SSHNet.dll file
        $SshNetPath 
        )
    
    #################################
    Write-SPOTLog "===== Starting function New-SPOTSSHSession for the target ""$TargetIP"" and port ""$Port"" =====" -Output $false -DBG $true

    #################################
    # test/detect the local Renci.SSHNet.dll file
    try {
        $SshNetPath = Get-SPOTSshNetPath -SshNetPath $SshNetPath -ErrorAction Stop
    }
    catch {
        Write-SPOTLog "T.ERROR: The SshNetPath was not provided/determined/detected: $_." -Output $false
        throw "New-SPOTSSHSession: SshNetPath not detected!"
    }

    #########################
    # load Renci SSH dll file
    if ($PSVersionTable.PSVersion.Major -eq 5) {
        Add-Type -Path $SshNetPath
    }
    else {
        Write-SPOTLog "ERROR: The detected PowerShell version is too low. Cannot continue." -Output $false
        throw "New-SPOTSSHSession: PowerShell version is too low!"
    }

    #########################
    # check if .NET 4.7.1 or higher is available
    try {
        $NetVersion = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop | Select-Object Release -ExpandProperty Release -ErrorAction Stop
        $NetInstallPath = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' | Select-Object InstallPath -ExpandProperty InstallPath
    }
    catch {
        Write-SPOTLog "ERROR: while detecting .NET Framework version: $_." -Output $false
        throw "New-SPOTSSHSession: error detecting .NET version!"
    }
    if ($NetVersion -lt 461308) {
        Write-SPOTLog "ERROR: the .NET Framework version is not 4.7.1 or greater. Cannot continue." -Output $false
        throw "New-SPOTSSHSession: .NET version too low!"
    }
    if (!$NetInstallPath) {
        Write-SPOTLog "ERROR: the .NET Framework install path could not be determined. Cannot continue." -Output $false
        throw "New-SPOTSSHSession: error detecting .NET path!"
    }
    
    #########################
    # default behavior is not to validate the SSH key unless there is a usable TrustedHosts file provided
    $ValidateSSHKey = $false

    #########################
    # validate the file exists and can be used (fit for purpose)
    if ($TrustedHostsFilePath) {
        if (Test-Path -Path $TrustedHostsFilePath -PathType Leaf) {
            $TrustedHostsFilePath = (Get-Item -Path $TrustedHostsFilePath -ErrorAction Stop).FullName
            Write-SPOTLog "TrustedHosts file path provided and detected. Checking it." -DBG $true -Output $false
            try {
                $TrustedHostKeys = @(Import-Csv -Path $TrustedHostsFilePath -Delimiter ";" -Encoding UTF8 -ErrorAction Stop)
            }
            catch {
                Write-SPOTLog "ERROR: while loading the objects inside the TrustedHosts file in the provided path ""$TrustedHostsFilePath"": $_." -Output $false
                throw "New-SPOTSSHSession: error loading Trusted Hosts!"
            }
            if ($TrustedHostKeys) {
                $RequiredProperties = @("TargetHost","Port","KeyType","Fingerprint")
                $MissingObjectProperties = $RequiredProperties | Where-Object { $_ -notin $TrustedHostKeys[0].PSObject.Properties.Name }
                if ($MissingObjectProperties) {
                    Write-SPOTLog "ERROR: at least the first TrustedHosts object is missing some required properties: $($MissingObjectProperties -join ","). Cannot continue." -Output $false
                    throw "New-SPOTSSHSession: error loading Trusted Hosts!"
                }
            }
            else {
                # no objects found; file cannot be used
                Write-SPOTLog "ERROR: the TrustedHosts file has no usable data. Cannot continue." -Output $false
                throw "New-SPOTSSHSession: error loading Trusted Hosts!"
            }
            # using the TrustedHosts file; if the received key fingeprint does not match in the TrustedHosts file abort the connection
            $ValidateSSHKey = $true
        }
        else {
            # TrustedHosts file path provided but not detected; abort the connection
            Write-SPOTLog "ERROR: the TrustedHosts file path was provided but the file was not found. Cannot continue." -Output $false
            throw "New-SPOTSSHSession: error loading Trusted Hosts!"
        }
    }

    #########################
    # define and create the host key handler object (verification and logging / only logging)
    if (!("HostKeyHandler" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using Renci.SshNet;
using Renci.SshNet.Common;

public class HostKeyHandler
{
    // Configuration from PowerShell
    public bool EnforceValidation = false;

    // host -> port -> keyType -> fingerprint
    public Dictionary<string, Dictionary<int, Dictionary<string,string>>> TrustedHosts;

    public List<string> Logs = new List<string>();

    public string ComputeSha256(byte[] data)
    {
        using (var sha256 = SHA256.Create())
        {
            return Convert.ToBase64String(sha256.ComputeHash(data));
        }
    }

    public void Handle(object sender, HostKeyEventArgs e)
    {
        var baseClient = sender as Renci.SshNet.BaseClient;
        var host = baseClient.ConnectionInfo.Host;
        var port = baseClient.ConnectionInfo.Port;

        var keyType = e.HostKeyName;
        var fp = ComputeSha256(e.HostKey);

        // Always log
        var logLine = string.Format(
            "Host=>{0},Port=>{1},Type=>{2},SHA256Fingerprint=>{3}",
            host, port, keyType, fp
        );
        lock (Logs)
        {
            Logs.Add(logLine);
        }

        // Conditional validation
        if (!EnforceValidation)
        {
            e.CanTrust = true;
            return;
        }

        if (TrustedHosts != null &&
            TrustedHosts.ContainsKey(host) &&
            TrustedHosts[host].ContainsKey(port) &&
            TrustedHosts[host][port].ContainsKey(keyType) &&
            TrustedHosts[host][port][keyType] == fp)
        {
            e.CanTrust = true;
        }
        else
        {
            e.CanTrust = false;
        }
    }
}
'@ -ReferencedAssemblies @($SshNetPath,"$NetInstallPath\netstandard.dll")
    }

    $handlerObj = New-Object HostKeyHandler

    #########################
    # prepare the host key handler object for use depending on the context
    if ($ValidateSSHKey) {
        #########################
        Write-SPOTLog "INFO: SSH Key validation is enabled." -DBG $true -Output $false
        # convert the TrustedHosts array to a suitable dictionary
        $trustedDict = New-Object "System.Collections.Generic.Dictionary[string, System.Collections.Generic.Dictionary[int, System.Collections.Generic.Dictionary[string,string]]]"
        foreach ($i in $TrustedHostKeys) {
            # Ensure host level
            if (!$trustedDict.ContainsKey($i.TargetHost)) {
                $trustedDict[$i.TargetHost] = New-Object "System.Collections.Generic.Dictionary[int, System.Collections.Generic.Dictionary[string,string]]"
            }
            # Ensure port level
            if (!$trustedDict[$i.TargetHost].ContainsKey($i.Port)) {
                $trustedDict[$i.TargetHost][$i.Port] = New-Object "System.Collections.Generic.Dictionary[string,string]"
            }
            # Add key type
            $trustedDict[$i.TargetHost][$i.Port][$i.KeyType] = $i.Fingerprint
        }
        # use the handler class to validate and log
        $handlerObj.EnforceValidation = $true
        $handlerObj.TrustedHosts = $trustedDict
    }
    else {
        #########################
        # use the handler class to log
        Write-SPOTLog "INFO: SSH Key validation is disabled." -DBG $true -Output $false
        $handlerObj.EnforceValidation = $false
    }
    
    #########################
    # prepare connection objects
    # Set up the authentication method
    $authMethod = New-Object Renci.SshNet.PasswordAuthenticationMethod($Credential.UserName, $Credential.GetNetworkCredential().Password)
    # Define connection info with host key callback
    $connectionInfo = New-Object Renci.SshNet.ConnectionInfo($TargetIP, $Port, $Credential.UserName, $authMethod)
    # define the ssh session object
    $sshClient = New-Object Renci.SshNet.SshClient($connectionInfo)

    #########################
    # insert the handler into the SSH client object
    $eventInfo = $sshClient.GetType().GetEvent("HostKeyReceived")
    $handler = [System.Delegate]::CreateDelegate($eventInfo.EventHandlerType, $handlerObj, $handlerObj.GetType().GetMethod("Handle"))
    $sshClient.add_HostKeyReceived($handler)

    #########################
    # try to connect
    try {
        $sshClient.Connect()
    }
    catch {
        Write-SPOTLog "ERROR: while trying to connect to the target IP: $_." -Output $false
        Write-SPOTLog "INFO: SSH server key details: $($handlerObj.Logs)." -Output $false
        throw "New-SPOTSSHSession: error connecting to target!"
    }

    #########################
    # log the current server key
    Write-SPOTLog "INFO: SSH server key details: $($handlerObj.Logs)." -Output $false

    #########################
    # put the SSH key details into a variable into the parent scope
    New-Variable -Name _spot_SSH_Key -Scope 1 -Force -Confirm:$false -Value @{
        TargetHost  = (($handlerObj.Logs -split ',')[0] -split '=>')[1]
        Port        = (($handlerObj.Logs -split ',')[1] -split '=>')[1]
        KeyType     = (($handlerObj.Logs -split ',')[2] -split '=>')[1]
        Fingerprint = (($handlerObj.Logs -split ',')[3] -split '=>')[1]
    }

    #########################
    if ($sshClient.GetType().Name -eq "SshClient" -and $sshClient.IsConnected -eq $true) {
        #########################
        # return the session object
        Write-SPOTLog "===== Function New-SPOTSSHSession for the target ""$TargetIP"" successfull and returning the session object =====" -Output $false -DBG $true
        return $sshClient
    }
    else {
        Write-SPOTLog "===== Function New-SPOTSSHSession for the target ""$TargetIP"" NOT successfull and and throwing error =====" -Output $false -DBG $true
        throw "New-SPOTSSHSession: error connecting to target!"
    }
} # end of New-SPOTSSHSession function

######################################################################################################################
function Get-SPOTSshNetPath {
    Param (
        [Parameter(Mandatory=$false)]
        [AllowNull()]
        [string]
        # the local path to the Renci.SSHNet.dll file
        $SshNetPath 
        )
    
    if ($SshNetPath) {
        if (Test-Path -Path $SshNetPath -PathType Leaf) {
            Write-SPOTLog "The SshNetPath was provided as parameter and detected." -Output $false -DBG $true
            return $SshNetPath
        }
        else {
            Write-SPOTLog "WARNING: The SshNetPath was provided but not detected. Fallback to trying to load Posh-SSH module locally." -Output $false
            Import-Module -Name Posh-SSH -ErrorAction SilentlyContinue | Out-Null
            $module = Get-Module | Where {$_.Name -eq "Posh-SSH" -and [System.Version]$_.Version -ge [System.Version]"3.2.4"}
            if ($module) {
                $SshNetPath = "$($module.ModuleBase)\Assembly\Renci.SshNet.dll"
                Write-SPOTLog "The SshNetPath was retrieved from a local Posh-SSH module." -Output $false
                return $SshNetPath
            }
            else {
                Write-SPOTLog "ERROR: No Posh-SSH module detected after trying to load it, or version too low." -Output $false
                throw "Get-SPOTSshNetPath: Posh-SSH module (fallback) not found!"
            }
        }
    }
    else {
        # path not defined; trying to get it from OrchVars
        if ($OrchVars._SshNetPath) {
            if (Test-Path -Path $OrchVars._SshNetPath -PathType Leaf) {
                Write-SPOTLog "The SshNetPath was retrieved from OrchVars and detected." -Output $false -DBG $true
                return $OrchVars._SshNetPath
            }
            else {
                Write-SPOTLog "WARNING: The SshNetPath was not provided and not available from OrchVars. Fallback to trying to load Posh-SSH module locally." -Output $false
                Import-Module -Name Posh-SSH -ErrorAction SilentlyContinue | Out-Null
                $module = Get-Module | Where {$_.Name -eq "Posh-SSH" -and [System.Version]$_.Version -ge [System.Version]"3.2.4"}
                if ($module) {
                    $SshNetPath = "$($module.ModuleBase)\Assembly\Renci.SshNet.dll"
                    Write-SPOTLog "The SshNetPath was retrieved from a local Posh-SSH module." -Output $false
                    return $SshNetPath
                }
                else {
                    Write-SPOTLog "ERROR: No Posh-SSH module detected after trying to load it, or version too low." -Output $false
                    throw "Get-SPOTSshNetPath: Posh-SSH module (fallback) not found!"
                }
            }
        }
    }
} # end of Get-SPOTSshNetPath function

######################################################################################################################
function New-SPOTTelnetSession {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the target IP Address or hostname on which to create the Telnet Session
        $TargetIP, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [int]
        # the port to be used, in case it is different from the default
        $Port = 23
    )

    ###############################
    Write-SPOTLog "===== Starting New-SPOTTelnetSession function for TargetIP ""$TargetIP"" and Port ""$Port"" =====" -Output $false -DBG $true

    ###############################
    # define the telnet client object
    [System.Net.Sockets.TcpClient]$telnet = New-Object "System.Net.Sockets.TcpClient"
    ###############################
    # try to connect
    try {
        $telnet.Connect($TargetIP, $Port)
        if ($telnet.Connected) {
            # extend the telnet client object when connected
            $telnet | Add-Member -MemberType "NoteProperty" -Name "ReadBufferSize" -Value $([int]1024)
            $telnet | Add-Member -MemberType "ScriptMethod" -Name "WriteLine"      -Value ({
                param([string]$cmdLine)
                if ($this.Connected) {
                    # Write-SPOTLog "INFO: writing commandLine $cmdLine." -Output $false -DBG $true
                    $line = $cmdLine + "`r`n"
                    $bytes = [System.Text.Encoding]::ASCII.GetBytes($line)
                    $this.GetStream().Write($bytes, 0, $bytes.Length)
                }
                else {
                    Write-SPOTLog "ERROR: cannot write command while the telnet client is no longer connected. Cannot continue." -Output $false
                    $this.RemoveSession()
                }
            })
            $telnet | Add-Member -MemberType "ScriptMethod" -Name "ReadOutput"     -Value ({
                #####################################
                # special bytes
                $IAC  = 255
                $DO   = 253
                $DONT = 254
                $WILL = 251
                $WONT = 252
                $SB   = 250
                $SE   = 240
                # Telnet options
                $TTYPE = 24
                # Subnegotiation commands
                $SEND = 1
                $IS   = 0
                #####################################
                # assign the stream object
                $Stream = $this.GetStream()
                # define the buffer
                $buffer = New-Object System.Collections.Generic.List[byte]
                #####################################
                # enter the reading loop
                while ($buffer.Count -lt $this.ReadBufferSize -and $Stream.DataAvailable) {
                    $b = $Stream.ReadByte()
                    if ($b -eq -1) { 
                        # enf of stream
                        break
                    }
                    if ($b -eq $IAC) {
                        #################
                        # take care of IAC - get command
                        # Write-SPOTLog "IAC received. Taking care of it." -Output $false
                        $command = $Stream.ReadByte()
                        if ($command -eq -1) { 
                            return 
                        }
                        if ($command -eq $IAC) {
                            return
                        }
                        if ($command -eq $SB) {
                            #################
                            # SkipNegotiation
                            #Write-SPOTLog "SB received. Consume everything until IAC SE." -Output $false
                            # Consume everything until IAC SE
                            while ($true) {
                                $c = $Stream.ReadByte()
                                if ($c -eq -1) { 
                                    break 
                                }
                                if ($c -eq $IAC) {
                                    $next = $Stream.ReadByte()
                                    if ($next -eq $SE) { 
                                        break 
                                    }
                                    elseif ($next -eq $IAC) { 
                                        continue 
                                    }
                                }
                            }
                            #################
                            return
                        }
                        #################
                        # take care of IAC - get option
                        $option = $Stream.ReadByte()
                        if ($option -eq -1) {
                            return
                        }
                        #################
                        switch ($command) {
                            $DO {
                                #Write-SPOTLog "DO received. Sending WONT back." -Output $false
                                $bytes = [byte[]]($IAC, [byte]$WONT, [byte]$Option)
                            }
                            $DONT { 
                                #Write-SPOTLog "DONT received. Sending WONT back." -Output $false
                                $bytes = [byte[]]($IAC, [byte]$WONT, [byte]$Option)
                            }
                            $WILL { 
                                #Write-SPOTLog "WILL received. Sending DONT back." -Output $false
                                $bytes = [byte[]]($IAC, [byte]$DONT, [byte]$Option)
                            }
                            $WONT { 
                                #Write-SPOTLog "WONT received. Sending DONT back." -Output $false
                                $bytes = [byte[]]($IAC, [byte]$DONT, [byte]$Option)
                            }
                        }
                        $Stream.Write($bytes, 0, $bytes.Length)
                        continue
                    }
                    #################
                    # add the current byte to the buffer
                    $buffer.Add([byte]$b)
                }
                
                #####################################
                if ($buffer.Count -gt 0) {
                    $text = [System.Text.Encoding]::ASCII.GetString($buffer)
                }
                #Write-SPOTLog "Returning read text: $text." -Output $false
                return $text
            })
            $telnet | Add-Member -MemberType "ScriptMethod" -Name "RemoveSession"  -Value ({
                # if the current object is connected, close the session
                if ($this.Connected) {
                    $this.GetStream().Close()
                    $this.Close()
                }
                # dispose of the object in any case
                $this.Dispose()
            })
        }
        else{
            Write-SPOTLog "ERROR: the telnet connection to ""$TargetIP"" on port ""$Port"" is not established. Cannot continue." -Output $false
            $telnet.RemoveSession()
            throw "New-TelnetSession: connection fail!"
        }
    } 
    catch {
        Write-SPOTLog "ERROR: while trying to connect over telnet to ""$TargetIP"" on port ""$Port"" : $_." -Output $false
        $telnet.RemoveSession()
        throw "New-TelnetSession: telnet session not established!"
    }

    Write-SPOTLog "===== Finished New-SPOTTelnetSession function =====" -Output $false -DBG $true
    # return the telnet object
    return $telnet

} # enf of New-SPOTTelnetSession function

######################################################################################################################
function Create-SPOTRsPool {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [int]
        # the maximum number of runspaces in the pool
        $MaxNumber
    )

    ######################################
    Write-SPOTLog "###> Starting execution of Create-SPOTRsPool function." -Output $false -DBG $true

    ######################################
    # prepare the functions to be injected in the RunspacePool InitialSessionState
    $RSPoolFunctions = Get-Command | Where {$_.Name -in $OrchVars._StepFunctions}

    ######################################
    # Create the initial session state
    $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($f in $RSPoolFunctions) {
        $sessionState.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($f.Name, $f.Definition))
    }
    $sessionState.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new("_spot_FunctionNames", $RSPoolFunctions.Name, "Injected Step Functions"))
    $sessionState.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new("OrchVars", $OrchVars, "SPOT Orchestration Variables"))

    ######################################
    # create runspace pool and open
    $pool = [runspacefactory]::CreateRunspacePool($sessionState)
    $pool.SetMaxRunspaces($MaxNumber) | Out-Null
    $pool.SetMinRunspaces(3) | Out-Null
    $pool.CleanupInterval = New-TimeSpan -Minutes 5
    $pool.Open()

    ######################################
    Write-SPOTLog "###> Finished execution of Create-SPOTRsPool function." -Output $false -DBG $true

    ######################################
    # return the runspace pool object
    return $pool

} # end of Create-SPOTRsPool function

######################################################################################################################
function Create-SPOTRunbookRunspace {
    
    ######################################
    Write-SPOTLog "###> Starting execution of Create-SPOTRunbookRunspace function." -Output $false -DBG $true
    
    ######################################
    # prepare the functions to be injected in the Runspace InitialSessionState
    $RunspaceFunctions = Get-Command | Where {$_.Name -in $OrchVars._RunbookFunctions}
    ######################################
    # Create initial session state
    $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($f in $RunspaceFunctions) {
        $sessionState.Commands.Add(
            [System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($f.Name, $f.Definition)
        )
    }
    $sessionState.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new("_spot_FunctionNames", $RunspaceFunctions.Name, "Injected Runbook Functions"))
    $sessionState.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new("OrchVars", $OrchVars, "SPOT Orchestration Variables"))
    $sessionState.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new("SVars", $SVars, "SPOT Secret Variables"))
    $sessionState.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new("PublishedData", $PublishedData, "SPOT Published Variables"))
    $sessionState.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new("AllRunbooks", $AllRunbooks, "All SPOT Runbook objects"))
    $sessionState.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new("AllRunbookSteps", $AllRunbookSteps, "All SPOT RunbookStep objects"))

    ######################################
    # create runspace and open
    $runspace = [runspacefactory]::CreateRunspace($sessionState)
    $runspace.Open()
    
    ######################################
    Write-SPOTLog "###> Finished execution of Create-SPOTRunbookRunspace function." -Output $false -DBG $true

    ######################################
    # return the runspace object
    return $runspace

} #end of Create-SPOTRunbookRunspace function

######################################################################################################################
function Create-SPOTRunbookStepRunspace {
    
    ######################################
    Write-SPOTLog "###> Starting execution of Create-SPOTRunbookStepRunspace function." -Output $false -DBG $true
    
    ######################################
    # prepare the functions to be injected in the Runspace InitialSessionState
    $RunspaceFunctions = Get-Command | Where {$_.Name -in $OrchVars._StepFunctions}
    
    ######################################
    # Create initial session state
    $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($f in $RunspaceFunctions) {
        $sessionState.Commands.Add(
            [System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($f.Name, $f.Definition)
        )
    }
    $sessionState.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new("_spot_FunctionNames", $RunspaceFunctions.Name, "Injected Step Functions"))
    $sessionState.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new("OrchVars", $OrchVars, "SPOT Orchestration Variables"))

    ######################################
    # create runspace and open
    $runspace = [runspacefactory]::CreateRunspace($sessionState)
    $runspace.Open()
    
    ######################################
    Write-SPOTLog "###> Finished execution of Create-SPOTRunbookStepRunspace function." -Output $false -DBG $true

    ######################################
    # return the runspace object
    return $runspace

} #end of Create-SPOTRunbookStepRunspace function

######################################################################################################################
function Process-SPOTCommandParamsRF {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [hashtable]
        # the set of command parameters to be processed
        $CommandParameters, 
        [Parameter(Mandatory=$false)]
        [System.Management.Automation.Runspaces.PSSession]
        # the pssession object to be used to transfer files/folder archives
        $PSSession
    )

    # if the pssession parameter is not provided, the function will process the references by placing the content inside the command parameters themselves
    #######################################
    $ReturnHashtable = @{
        CommandParameters = $CommandParameters
    }

    if (!$PSSession) {
        #######################################
        # add the needed extra elements
        $ReturnHashtable += @{
            CommandParametersRFI = @()
            CommandParametersRFO = @{}
        }
        # check for $RFI or $RFO (file variables) and manage the file/folder transfer to the target computer over the command parameters themselves
        foreach ($cpar in $($ReturnHashtable.CommandParameters.Keys)) {
            if ($ReturnHashtable.CommandParameters.$cpar) {
                if ($ReturnHashtable.CommandParameters.$cpar.GetType().Name -ne "String") {
                    continue
                }
                if ($ReturnHashtable.CommandParameters.$cpar.StartsWith('$RFI:')) {
                    # reference to a local file detected
                    $LocalFile = $null
                    # get the local file
                    $LocalFile = Get-Item -Path "$($OrchVars._ProjectPath)\$(($ReturnHashtable.CommandParameters.$cpar -split ":")[1])" -ErrorAction SilentlyContinue
                    if ($LocalFile) {
                        Write-SPOTLog ">>> The RFI for parameter ""$cpar"" and value ""$($ReturnHashtable.CommandParameters.$cpar)"" was detected as ""$($LocalFile.FullName)"". Managing the transfer to the remote computer inside the step command parameteres." -Output $false -DBG $true
                        # add this parameter name to the list of parameters to be transformed into files on the remote computer
                        $ReturnHashtable.CommandParametersRFI += $cpar
                        # add the file content as the parameter value
                        $ReturnHashtable.CommandParameters.$cpar = [System.IO.File]::ReadAllBytes($LocalFile.FullName)
                    }
                    else {
                        Write-SPOTLog ">>> ERROR: The RFI for parameter ""$cpar"" and value ""$($CommandParameters.$cpar)"" was not detected. Cannot continue." -Output $false
                        throw "Process-SPOTCommandParamsRF: RFI not detected!"
                    }
                }
                elseif ($ReturnHashtable.CommandParameters.$cpar.StartsWith('$RFO:')) {
                    # reference to a local folder detected
                    $UniqueID = ($ReturnHashtable.CommandParameters.$cpar -split ":")[1]
                    $LocalArchivePath = $OrchVars._RFOMap.$UniqueID.LocalArchivePath
                    # get the local archive file, as indicated by the UniqueID from this parameter 
                    # local archive file created before this point in time, so that it can be reused in case of implied parallel executions
                    $LocalArchiveFile = Get-Item -Path $LocalArchivePath -ErrorAction SilentlyContinue
                    if (!$LocalArchiveFile) {
                        Write-SPOTLog ">>> ERROR: The RFO archive file for parameter ""$cpar"" and value ""$($ReturnHashtable.CommandParameters.$cpar)"" was not detected. Path is ""$LocalArchivePath"". Cannot continue." -Output $false
                        throw "Process-SPOTCommandParamsRF: RFO not detected!"
                    }
                    else {
                        # the referenced local archive file is found, managing the transfer
                        Write-SPOTLog ">>> The RFO archive file for parameter ""$cpar"" and value ""$($ReturnHashtable.CommandParameters.$cpar)"" was detected as ""$LocalArchivePath"". Managing the transfer to the remote computer inside the step command parameteres." -Output $false -DBG $true
                        $ReturnHashtable.CommandParametersRFO.$cpar = $ReturnHashtable.CommandParameters.$cpar
                        # add the file content as the parameter value
                        $ReturnHashtable.CommandParameters.$cpar = [System.IO.File]::ReadAllBytes($LocalArchiveFile.FullName)
                    }
                }
            }
        }
    }
    elseif ($PSSession.State -eq "Opened") {
        #######################################
        # add the needed extra elements
        $ReturnHashtable += @{
            RemoteTempFiles   = @()
            RemoteTempFolders = @()
        }
        # check for $RFI or $RFO (file variables) and manage the file/folder transfer to the target computer over the PSSession
        foreach ($cpar in $($ReturnHashtable.CommandParameters.Keys)) {
            if ($ReturnHashtable.CommandParameters.$cpar) {
                if ($ReturnHashtable.CommandParameters.$cpar.GetType().Name -ne "String") {
                    continue
                }
                if ($ReturnHashtable.CommandParameters.$cpar.StartsWith('$RFI:')) {
                    # reference to a local file detected
                    $LocalFile = $null
                    $RemoteTempFile = $null
                    # get the local file
                    $LocalFile = Get-Item -Path "$($OrchVars._ProjectPath)\$(($ReturnHashtable.CommandParameters.$cpar -split ":")[1])" -ErrorAction SilentlyContinue
                    if ($LocalFile) {
                        Write-SPOTLog ">>> The RFI for parameter ""$cpar"" and value ""$($ReturnHashtable.CommandParameters.$cpar)"" was detected as ""$($LocalFile.FullName)"". Managing the file transfer to the remote computer over PSSession." -Output $false -DBG $true
                        $RemoteTempFile = Invoke-Command -Session $PSSession -ScriptBlock {
                            $_spot_TFP = [System.IO.Path]::GetTempFileName(); Get-Item -Path $_spot_TFP -Force
                        }
                        if ($RemoteTempFile.FullName) {
                            # try to copy the file to the remote computer
                            try {
                                Copy-Item -Path $LocalFile.FullName -Destination $RemoteTempFile.FullName -ToSession $PSSession -Force -Confirm:$false
                            }
                            catch {
                                Write-SPOTLog ">>> ERROR: While trying to copy the local file ""$($LocalFile.FullName)"" to the remote computer: $_." -Output $false
                                throw "Process-SPOTCommandParamsRF: RFI copy error!"
                            }
                            # change the parameter to the remote temp file path
                            $ReturnHashtable.CommandParameters.$cpar = $RemoteTempFile.FullName
                            # add the remote file path to the list of files to be deleted at the end of the execution
                            $ReturnHashtable.RemoteTempFiles += $RemoteTempFile.FullName
                            Write-SPOTLog ">>> The RFI for parameter ""$cpar"" was transfered to the remote computer and the value changed to ""$($RemoteTempFile.FullName)""." -Output $false -DBG $true
                        }
                        else {
                            Write-SPOTLog ">>> ERROR: The remote temporary file failed to create on the remote computer. Cannot continue." -Output $false
                            throw "Process-SPOTCommandParamsRF: RFI temp file error!"
                        }
                    }
                    else {
                        Write-SPOTLog ">>> ERROR: The RFI for parameter ""$cpar"" and value ""$($ReturnHashtable.CommandParameters.$cpar)"" was not detected in the project folder. Cannot continue." -Output $false
                        throw "Process-SPOTCommandParamsRF: RFI not detected!"
                    }
                } 
                elseif ($ReturnHashtable.CommandParameters.$cpar.StartsWith('$RFO:')) {
                    # reference to a local folder detected
                    $UniqueID = ($ReturnHashtable.CommandParameters.$cpar -split ":")[1]
                    $ReferencedFileName = $OrchVars._RFOMap.$UniqueID.ReferencedFileName
                    $LocalArchivePath = $OrchVars._RFOMap.$UniqueID.LocalArchivePath
                    # get the local archive file, as indicated by the UniqueID from this parameter
                    $LocalArchiveFile = Get-Item -Path $LocalArchivePath -ErrorAction SilentlyContinue
                    if (!$LocalArchiveFile) {
                        Write-SPOTLog ">>> ERROR: The RFO archive file for parameter ""$cpar"" and value ""$($ReturnHashtable.CommandParameters.$cpar)"" was not detected. Path is ""$LocalArchivePath"". Cannot continue." -Output $false
                        throw "Process-SPOTCommandParamsRF: RFO not detected!"
                    }
                    else {
                        # the referenced local archive file is found, managing the transfer
                        Write-SPOTLog ">>> The RFO archive file for parameter ""$cpar"" and value ""$($ReturnHashtable.CommandParameters.$cpar)"" was detected as ""$LocalArchivePath"". Managing the transfer to the remote computer over PSSession." -Output $false -DBG $true
                        # create a temp remote file
                        $RemoteTempFile = Invoke-Command -Session $PSSession -ScriptBlock {
                            $_spot_TFP = [System.IO.Path]::GetTempFileName(); Get-Item -Path $_spot_TFP -Force
                        }
                        if (!($RemoteTempFile.FullName)) {
                            Write-SPOTLog ">>> ERROR: The remote temporary file failed to create on the remote computer. Cannot continue." -Output $false
                            throw "Process-SPOTCommandParamsRF: RFO temp file error!"
                        }
                        else {
                            # try to copy the folder archive to the remote computer
                            try {
                                Copy-Item -Path $LocalArchivePath -Destination $RemoteTempFile.FullName -ToSession $PSSession -Force -Confirm:$false
                            }
                            catch {
                                Write-SPOTLog ">>> ERROR: While trying to copy the local folder archive ""$LocalArchivePath"" to the remote computer: $_." -Output $false
                                throw "Process-SPOTCommandParamsRF: RFO copy file error!"
                            }
                            # extract the archive remotely
                            Invoke-Command -Session $PSSession -ScriptBlock {
                                $_spot_Item = Get-Item -Path $_spot_TFP -Force
                                Add-Type -Assembly "system.io.compression.filesystem"
                                [io.compression.zipfile]::ExtractToDirectory($_spot_TFP,"$($_spot_Item.Directory)\$($_spot_Item.BaseName)")
                                # the archive file can be cleaned up right now
                                Remove-Item -Path $_spot_TFP -Confirm:$false -Force -ErrorAction SilentlyContinue
                            }
                            # change the parameter to the remote temp file in folder path
                            $ReturnHashtable.CommandParameters.$cpar = "$($RemoteTempFile.Directory)\$($RemoteTempFile.BaseName)\$ReferencedFileName"
                            # add the remote folder path to the list of items to be deleted at the end of the execution
                            $ReturnHashtable.RemoteTempFolders += "$($RemoteTempFile.Directory)\$($RemoteTempFile.BaseName)"
                            Write-SPOTLog ">>> The RFO for parameter ""$cpar"" was transfered to the remote computer and value changed to ""$($ReturnHashtable.CommandParameters.$cpar)""." -Output $false -DBG $true
                        }
                    }
                }
            }
        }
    }
    else {
        #######################################
        Write-SPOTLog "ERROR: the provided PSSession is not opened. Cannot continue." -Output $false
        throw "Process-SPOTCommandParamsRF: PSSession not opened!"
    }

    #######################################
    return $ReturnHashtable

} #end of Process-SPOTCommandParamsRF function

######################################################################################################################
function Process-SPOTCommandParamsLocalRF {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [hashtable]
        # the set of command parameters to be processed
        $CommandParameters
    )

    ######################################
    # manage local $RFI and $RFO parameters
    foreach ($_spot_cp in $($CommandParameters.Keys)) {
        $_spot_LocalItem = $null
        if ($CommandParameters.$_spot_cp.GetType().Name -ne "String") {
            continue
        }
        if ($CommandParameters.$_spot_cp.StartsWith('$RFI:')) {
            # reference to a local file detected, get the local item
            $_spot_LocalItem = Get-Item -Path "$($OrchVars._ProjectPath)\$(($CommandParameters.$_spot_cp -split ":")[1])" -ErrorAction SilentlyContinue
            if ($_spot_LocalItem) {
                Write-SPOTLog ">>> The RFI for parameter ""$_spot_cp"" and value ""$($CommandParameters.$_spot_cp)"" was detected as ""$($_spot_LocalItem.FullName)"", a file. Managing the local path." -DBG $true
                # change the parameter to the local item full path
                $CommandParameters.$_spot_cp = $_spot_LocalItem.FullName
            }
            else {
                Write-SPOTLog ">>> ERROR: The RFI for parameter ""$_spot_cp"" and value ""$($CommandParameters.$_spot_cp)"" was not detected in the project folder. Cannot continue."
                throw "Process-SPOTCommandParamsLocalRF: local referenced item not found!"
            }
        }
        elseif ($CommandParameters.$_spot_cp.StartsWith('$RFO:')) {
            # reference to a local folder detected, get the local item
            if (($CommandParameters.$_spot_cp -split ":")[1] -eq "SSHNET") {
                $_spot_LocalItem = Get-Item -Path $OrchVars._SshNetPath -ErrorAction SilentlyContinue
            }
            elseif (($CommandParameters.$_spot_cp -split ":")[1] -eq "PSEXEC") {
                $_spot_LocalItem = Get-Item -Path $OrchVars._PsExecPath -ErrorAction SilentlyContinue
            }
            else {
                $_spot_LocalItem = Get-Item -Path "$($OrchVars._ProjectPath)\$(($CommandParameters.$_spot_cp -split ":")[1])" -ErrorAction SilentlyContinue
            }
            if ($_spot_LocalItem) {
                if ($_spot_LocalItem.PSIsContainer) {
                    Write-SPOTLog ">>> The RFO for parameter ""$_spot_cp"" and value ""$($CommandParameters.$_spot_cp)"" was detected as ""$($_spot_LocalItem.FullName)"", a folder. Managing the local path." -DBG $true
                }
                else {
                    Write-SPOTLog ">>> The RFO for parameter ""$_spot_cp"" and value ""$($CommandParameters.$_spot_cp)"" was detected as ""$($_spot_LocalItem.FullName)"", a file. Managing the local path." -DBG $true
                }
                # change the parameter to the local item full path
                $CommandParameters.$_spot_cp = $_spot_LocalItem.FullName
            }
            else {
                Write-SPOTLog ">>> ERROR: The RFO for parameter ""$_spot_cp"" and value ""$($CommandParameters.$_spot_cp)"" was not detected in the project folder. Cannot continue."
                throw "Process-SPOTCommandParamsLocalRF: local referenced item not found!"
            }
        }
    }

} #end of Process-SPOTCommandParamsLocalRF function

######################################################################################################################
function Transfer-SPOTDataOverPipe {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the encoded SPOT data to be sent out
        $encodedArgumentList, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the target remote computer
        $RemoteComputer
    )

######################################
# send the actual arguments using the first pipe (timeout 2 minutes for connecting)
Write-SPOTLog " ############# ORCHESTRATOR LOGGING: Starting the PipeClient to Pipe1 on remote computer ""$RemoteComputer"". #############" -DBG $true
$PipeObjectLocal1 = New-Object System.IO.Pipes.NamedPipeClientStream($RemoteComputer, "Pipe1", [System.IO.Pipes.PipeDirection]::Out, [System.IO.Pipes.PipeOptions]::None, [System.Security.Principal.TokenImpersonationLevel]::Impersonation)
[int32]$timeout = 120000
try {
    $PipeObjectLocal1.connect($timeout)
}
catch {
    Write-SPOTLog  " ############# ORCHESTRATOR LOGGING: ERROR: while connecting to Pipe1 on ""$RemoteComputer"" remote computer: $_ #############"
    throw "Transfer-SPOTDataOverPipe: error connecting to pipe!"
}

if ($PipeObjectLocal1.IsConnected -eq $false) {
    Write-SPOTLog  " ############# ORCHESTRATOR LOGGING: ERROR: the client connection to Pipe1 on ""$RemoteComputer"" remote computer is not established after the timeout. #############"
    $PipeObjectLocal1.dispose()
    throw "Transfer-SPOTDataOverPipe: error connecting to pipe!"
}

Write-SPOTLog " ############# ORCHESTRATOR LOGGING: Starting to send the data over Pipe1 on ""$RemoteComputer"" remote computer. #############" -DBG $true
$streamWriter = New-Object System.IO.StreamWriter $PipeObjectLocal1
$streamWriter.AutoFlush = $true
$streamWriter.WriteLine($encodedArgumentList)
$streamWriter.dispose()
$PipeObjectLocal1.dispose()
Write-SPOTLog " ############# ORCHESTRATOR LOGGING: Finished sending the data over Pipe1. #############" -DBG $true

######################################
# read the output hashtable using the second pipe
Write-SPOTLog " ############# ORCHESTRATOR LOGGING: Starting the PipeClient to Pipe2 on remote computer ""$RemoteComputer"". #############" -DBG $true
$PipeObjectLocal2 = New-Object System.IO.Pipes.NamedPipeClientStream($RemoteComputer, "Pipe2", [System.IO.Pipes.PipeDirection]::In, [System.IO.Pipes.PipeOptions]::None, [System.Security.Principal.TokenImpersonationLevel]::Impersonation)
# set timeout of 2 minutes as the remote computer connects fast, then it waits for the completion to send data
[int32]$timeout = 120000
# wait the connection from the remote computer 
try {
    $PipeObjectLocal2.connect($timeout)
}
catch {
    Write-SPOTLog  " ############# ORCHESTRATOR LOGGING: ERROR: while connecting to Pipe2 on ""$RemoteComputer"" remote computer: $_ #############"
    throw "Transfer-SPOTDataOverPipe: error connecting to pipe!"
}
# check the connection from the remote computer
if ($PipeObjectLocal2.IsConnected -eq $false) {
    Write-SPOTLog  " ############# ORCHESTRATOR LOGGING: ERROR: the client connection to Pipe2 on ""$RemoteComputer"" remote computer is not established after the timeout. #############"
    $PipeObjectLocal2.dispose()
    throw "Transfer-SPOTDataOverPipe: error connecting to pipe!"
}

Write-SPOTLog " ############# ORCHESTRATOR LOGGING: Waiting to receive the data over Pipe2 from ""$RemoteComputer"" remote computer. #############" -DBG $true
$streamReader = New-Object System.IO.StreamReader $PipeObjectLocal2
# set the timout from OrchVars (default is 1h, 3600s)
$PipeTimeout = $OrchVars._StepTimeout
$StartTime = Get-Date
while (($null -ne ($data = $streamReader.ReadLine())) -and ([math]::floor(((Get-Date) - $StartTime).TotalSeconds) -lt $PipeTimeout))
{
    $tempData = $data
    Start-Sleep -Seconds 2
}
$streamReader.dispose()
$PipeObjectLocal2.dispose()
if (!$tempData) {
    Write-SPOTLog  " ############# ORCHESTRATOR LOGGING: ERROR: Timed out waiting for the output object or object null from the ""$RemoteComputer"" remote computer over Pipe2. #############"
    throw "Transfer-SPOTDataOverPipe: error getting pipe data!"
}

####################################################
Write-SPOTLog " ############# ORCHESTRATOR LOGGING: Data received over Pipe2 from ""$RemoteComputer"" remote computer. #############" -DBG $true

} #end of Transfer-SPOTDataOverPipe function

######################################################################################################################
function Get-SPOTVTPObjects {
    Param (
        [Parameter(Mandatory=$true)]
        [AllowNull()]
        [string[]]
        # the array of variable names to publish, from inside the payload script/function
        $VariablesToPublish 
        )
    
    if (!$VariablesToPublish) {
        $_spot_VTPs = $null
    }
    else {
        $_spot_VTPs = @()
        foreach ($_spot_i in $VariablesToPublish) {
            if ($_spot_i -like "*-*") {
                # this is a parallel execution
                if (($_spot_i -split "-")[0] -like "*=*") {
                    # this is a variable set to be published by another name
                    $_spot_VTPs += [pscustomobject]@{
                        VarName = (($_spot_i -split "-")[0] -split "=")[0]
                        VarNewName = "$(($_spot_i -split "=")[1])"
                        VarValue = $null
                    }
                }
                else {
                    # this is a variable set to be published by the same name
                    $_spot_VTPs += [pscustomobject]@{
                        VarName = ($_spot_i -split "-")[0]
                        VarNewName = $_spot_i
                        VarValue = $null
                    }
                }
            }
            else {
                # this is a single execution
                if ($_spot_i -like "*=*") {
                    # this is a variable set to be published by another name
                    $_spot_VTPs += [pscustomobject]@{
                        VarName = ($_spot_i -split "=")[0]
                        VarNewName = "$(($_spot_i -split "=")[1])"
                        VarValue = $null
                    }
                }
                else {
                    # this is a variable set to be published by the same name
                    $_spot_VTPs += [pscustomobject]@{
                        VarName = $_spot_i
                        VarNewName = $_spot_i
                        VarValue = $null
                    }
                }
            }
        }
    }

    return $_spot_VTPs

} #end of Get-SPOTVTPObjects function

######################################################################################################################
function Replace-SPOTExitInCode {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the PowerShell code to be processed
        $code
        )
    
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$tokens, [ref]$errors)

$replacements = @()

$ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.ExitStatementAst]
}, $true) | ForEach-Object {

    $extent = $_.Extent
    $replacements += [PSCustomObject]@{
        Start = $extent.StartOffset
        # End   = $extent.EndOffset
        Text  = ". exit"
    }
}

# Apply replacements from end to start
$result = $code
$replacements | Sort-Object Start -Descending | ForEach-Object {
    $result = $result.Substring(0,$_.Start) + $_.Text + $result.Substring($_.Start+4)
}
# return the modified code
$result
} #end of Replace-SPOTExitInCode function

######################################################################################################################
function Write-SPOTLog {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [String]
        # The log entry to be written
        $Message, 
        [Parameter(Mandatory=$false)]
        [bool]
        # set the function to write only in the log file and not also in the console putput
        $Output = $true, 
        [Parameter(Mandatory=$false)]
        [bool]
        # set the function to execute depending on the SPOT Debug setting, if this parameter is set to true
        $DBG = $false, 
        [Parameter(Mandatory=$false)]
        [String]
        # The Path of the Log file generated by SPOT
        $LogPath = "C:\Windows\Temp\Orchestration.log" 
        )
    
    if (($DBG -and $OrchVars._Debug) -or !$DBG) {
        # when Debug is true, execute the function only if the Debug setting is true, or, when Debug is false, execute the function (default mode)
        $ErrorActionPreference = "SilentlyContinue"

        # Format Date for the log File 
        $FormattedDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        # Write log entry to $LogPath 
        # https://stackoverflow.com/questions/23999761/multiple-powershell-scripts-writing-to-same-file

        while ($true) {
            Try {
                $sw = New-Object -TypeName System.IO.StreamWriter($LogPath, $true)
                $sw.WriteLine("$FormattedDate :: $Message")
                $sw.Close()
                Break
            }
            Catch {}
        }

        if ($Output) {
            # Also write the log entry to output, to have the same logging in the Runbook as well
            Write-Output "$FormattedDate :: $Message"
        }

        # clear any errors, most likely while accessing the file
        $Error.Clear()
    }
} # end of Write-SPOTLog function
