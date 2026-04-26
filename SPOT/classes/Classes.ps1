# SPOT Classes
# v1.0 - 12.04.2026 - initial version
#
#
#
######################################################################################################################
class RunbookStep {
    # this class represents the basic building block of runbooks and can contain various types of actions
    [string]    $Name                   # self-explanatory
    [string]    $Description            # self-explanatory
    [int]       $Seq                    # the sequence number, used inside a parent runbook to execute the steps in the desired order, or in parallel 
    [string]    $GUID                   # a unique identifier for the current object; a new one is generated on every execution
    [string]    $Status                 # reflects the status of the underlying runspace; it can be: Initial, Executing, Completed, Error, Disabled
    [hashtable] $MultiStatus            # the status of all parallel Jobs implied by this Step, in case there are multiple targets; applies only to remote steps
    [string]    $Function               # the name of a predefined step function; it can be: PowershellCommandRemote, PowershellCommandLocal, PowershellCommandRemoteSJ, PowershellCommandRemoteWMI, PowershellCommandRemotePsExec, SSHScript, TelnetScript
    [hashtable] $FunctionParams         # the parameters to be passed to the step function; usually these are the function/script name to call, its parameters, target computer, credentials to use.
    [datetime]  $StartTime              # the start time of the execution (in case of retries, this value is not updated)
    [datetime]  $LastExecutionTime      # the time of the last attempt to execute the step; it is set when the runspace is found completed and the output is retrieved
    [hashtable] $MultiLastExecutionTime # the last execution time for all parallel Jobs implied by this Step, in case there are multiple targets
    [string]    $ExitValue              # the exit value of the runbook step; it is usually the last object returned by the step; if this last object is not true or false, then false is implied.
    [int]       $RetryCount             # the number of retires left for the step in case of Error status after execution; default is 0, no retries
    [hashtable] $MultiRetryCount        # the number of retires left for all parallel Jobs implied by this Step, in case there are multiple targets
    [int]       $RetryDelay             # the number seconds betwen retries, in case retries are enables with the RetryCount parameter; default is 30
    [bool]      $Disabled               # the step will be loaded and verified, but skipped during runbook execution
    [bool]      $ContinueOnError        # the Error status after the execution of this step will not determine the entire Runbook it is part of to be stopped.
    [string[]]  $Conditions             # a set of optional values which have to be all evaluated to True for the runbook/step to be executed. otherwise, the runbook/step will be skipped.
    [string]    $ArtefactsPath          # the file/folder path where the output files and other relevant files will be saved right after execution
    
    RunbookStep([string]$Name,[string[]]$Conditions,[int]$Seq,[string]$Function,[hashtable]$FunctionParams) {
        $this.ExitValue = $null
        $this.Name = $Name
        $this.Seq = $Seq
        $this.GUID = $([guid]::NewGuid().ToString())
        $this.Status = "Initial"
        $this.MultiStatus = @{}
        $this.Function = $Function
        $this.FunctionParams = $FunctionParams
        $this.RetryCount = 0
        $this.MultiRetryCount = @{}
        $this.RetryDelay = 30
        $this.MultiLastExecutionTime = @{}
        $this.Disabled = $false
        $this.ContinueOnError = $false
        $this.Conditions = $Conditions
        $this.Description = $null
    }
    RunbookStep([string]$Name,[string[]]$Conditions,[string]$Description,[int]$Seq,[string]$Function,[hashtable]$FunctionParams) {
        $this.ExitValue = $null
        $this.Name = $Name
        $this.Seq = $Seq
        $this.GUID = $([guid]::NewGuid().ToString())
        $this.Status = "Initial"
        $this.MultiStatus = @{}
        $this.Function = $Function
        $this.FunctionParams = $FunctionParams
        $this.RetryCount = 0
        $this.MultiRetryCount = @{}
        $this.RetryDelay = 30
        $this.MultiLastExecutionTime = @{}
        $this.Disabled = $false
        $this.ContinueOnError = $false
        $this.Conditions = $Conditions
        $this.Description = $Description
    }
    RunbookStep(){}
}

##########################################################################
class Runbook {
    # this class represents the runbooks and can contain one or several RunbookSteps and/or other Runbooks
    [string]   $Name              # self-explanatory
    [string]   $Description       # self-explanatory
    [Int]      $Seq               # the sequence number, used inside a parent runbook to execute the steps in the desired order, or in parallel (a runbook can be a step in another runbook)
    [string]   $GUID              # a unique identifier for the current object; a new one is generated on every execution
    [string]   $Status            # used to see if the runbook is still running or if it is completed; it can be: Initial, Executing, Completed, Error, Disabled
    [hashtable]$MultiStatus       # the status of all parallel Jobs implied by this Step, in case there are multiple targets; applies only to remote runbooks
    [hashtable]$RemoteParams      # the parameters to be passed to the step function; exec function (e.g. PowershellCommandRemote) target computer, credentials to use.
    [Object[]] $RunbookSteps      # the collection of runbook steps, to be executed in order of their sequence numbers
    [datetime] $StartTime         # the start time of the runbook execution
    [datetime] $LastExecutionTime # the time of the execution finish of the runbook job
    [string]   $ExitValue         # the exit value of the runbook step; it is similar to the step exit value
    [string]   $ArtefactsPath     # the file/folder path where the output files and other relevant files will be saved right after execution
    [bool]     $Disabled          # the step will be loaded and verified, but skipped during runbook execution
    [bool]     $ContinueOnError   # the Error status after the execution of this runbook will not determine the parent Runbook it is part of to be stopped.
    [string[]] $Conditions        # a set of optional values which have to be all evaluated to True for the runbook/step to be executed. otherwise, the runbook/step will be skipped.
    [bool]     $StopFlag          # the attribute that signals if a stop has been requested for this runbook; it can be updated during execution but it is checked only between steps
    
    Runbook([string]$Name,[string[]]$Conditions,[Int]$Seq,[Object[]]$RunbookSteps) {
        $this.Name = $Name
        $this.Seq = $Seq
        $this.GUID = $([guid]::NewGuid().ToString())
        $this.Status = "Initial"
        $this.MultiStatus = @{}
        $this.RemoteParams = @{}
        $this.RunbookSteps = $RunbookSteps
        $this.StopFlag = $false
        $this.Disabled = $false
        $this.ContinueOnError = $false
        $this.Conditions = $Conditions
    }

    Runbook([string]$Name,[string[]]$Conditions,[string]$Description,[Int]$Seq,[Object[]]$RunbookSteps) {
        $this.Name = $Name
        $this.Description = $Description
        $this.Seq = $Seq
        $this.GUID = $([guid]::NewGuid().ToString())
        $this.Status = "Initial"
        $this.MultiStatus = @{}
        $this.RemoteParams = @{}
        $this.RunbookSteps = $RunbookSteps
        $this.StopFlag = $false
        $this.Disabled = $false
        $this.ContinueOnError = $false
        $this.Conditions = $Conditions
    }

    Runbook([string]$Name,[string[]]$Conditions,[string]$Description,[Int]$Seq,[Object[]]$RunbookSteps,[hashtable]$RemoteParams) {
        $this.Name = $Name
        $this.Description = $Description
        $this.Seq = $Seq
        $this.GUID = $([guid]::NewGuid().ToString())
        $this.Status = "Initial"
        $this.MultiStatus = @{}
        $this.RemoteParams = $RemoteParams
        $this.RunbookSteps = $RunbookSteps
        $this.StopFlag = $false
        $this.Disabled = $false
        $this.ContinueOnError = $false
        $this.Conditions = $Conditions
    }
    Runbook(){}
}
