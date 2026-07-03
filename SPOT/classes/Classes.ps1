# SPOT Classes
# v1.0 - 26.04.2026 - initial version
# v1.1 - 17.05.2026 - simplified the object constructors to the 2 main use cases
# v1.2 - 28.06.2026 - simplified and changed the object constructors and the classes to mirror the yaml fields
#
#
######################################################################################################################
class RunbookStep {
    # this class represents the basic building block of runbooks and can contain various types of actions
    [string]    $Name                   # the name of the RunbookStep
    [string]    $Description            # self-explanatory
    [int]       $Seq                    # the sequence number, used inside a parent runbook to execute the steps in the desired order, or in parallel 
    [string]    $GUID                   # a unique identifier for the current object; a new one is generated on every execution
    [string]    $Status                 # reflects the status of the underlying runspace; it can be: Initial, Executing, Completed, Error, Disabled
    [hashtable] $MultiStatus            # the status of all parallel Jobs implied by this Step, in case there are multiple targets; applies only to remote steps
    [string]    $Type                   # the name of a predefined type function; it can be: PowershellCommandRemote, PowershellCommandLocal, PowershellCommandRemoteSJ, PowershellCommandRemoteWMI, PowershellCommandRemotePsExec or PowershellCommandRemoteOWMI
    [hashtable] $StepParameters         # the parameters to be passed to the step function; usually these are the function/script name to call, its parameters, target computer, credentials to use.
    [datetime]  $StartTime              # the start time of the execution (in case of retries, this value is not updated)
    [datetime]  $LastExecutionTime      # the time of the last attempt to execute the step; it is set when the runspace is found completed and the output is retrieved
    [hashtable] $MultiLastExecutionTime # the last execution time for all parallel Jobs implied by this Step, in case there are multiple targets
    [string]    $ExitValue              # the exit value of the runbook step; it is usually the last object returned by the step; if this last object is not true or false, then false is implied.
    [int]       $RetryCount             # the number of retires left for the step in case of Error status after execution; default is 0, no retries
    [hashtable] $MultiRetryCount        # the number of retires left for all parallel Jobs implied by this Step, in case there are multiple targets
    [int]       $RetryDelay             # the number seconds betwen retries, in case retries are enables with the RetryCount parameter; default is 30
    [bool]      $Disabled               # the step will be loaded and verified, but skipped during runbook execution
    [bool]      $ContinueOnError        # the Error status after the execution of this step will not determine the entire Runbook it is part of to be stopped.
    [Object[]]  $Conditions             # a set of optional values which have to be all evaluated to True for the runbook/step to be executed. otherwise, the runbook/step will be skipped.
    [string]    $ArtefactsPath          # the file/folder path where the output files and other relevant files will be saved right after execution
    
    RunbookStep([string]$Name,[int]$Seq,[string]$Type,[hashtable]$StepParameters) {
        $this.ExitValue = $null
        $this.Name = $Name
        $this.Seq = $Seq
        $this.GUID = $([guid]::NewGuid().ToString())
        $this.Status = "Initial"
        $this.MultiStatus = @{}
        $this.Type = $Type
        $this.StepParameters = $StepParameters
        $this.RetryCount = 0
        $this.MultiRetryCount = @{}
        $this.RetryDelay = 30
        $this.MultiLastExecutionTime = @{}
        $this.Disabled = $false
        $this.ContinueOnError = $false
        $this.Conditions = @()
        $this.Description = $null
    }

    RunbookStep(){}
}

##########################################################################
class Runbook {
    # this class represents the runbooks and can contain one or several RunbookSteps and/or other Runbooks
    [string]   $Name              # the base name of the runbook file
    [string]   $Description       # self-explanatory
    [Int]      $Seq               # the sequence number, used inside a parent runbook to execute the steps in the desired order, or in parallel (a runbook can be a step in another runbook)
    [string]   $GUID              # a unique identifier for the current object; a new one is generated on every execution
    [string]   $Status            # used to see if the runbook is still running or if it is completed; it can be: Initial, Executing, Completed, Error, Disabled
    [hashtable]$MultiStatus       # the status of all parallel Jobs implied by this Step, in case there are multiple targets; applies only to remote runbooks
    [hashtable]$RemoteParameters  # the parameters to be passed to the step function; exec function (e.g. PowershellCommandRemote) target computer, credentials to use.
    [hashtable]$RunbookParameters # the parameters to be used inside the runbook as variables.
    [Object[]] $RunbookSteps      # the collection of runbook steps, to be executed in order of their sequence numbers
    [datetime] $StartTime         # the start time of the runbook execution
    [datetime] $LastExecutionTime # the time of the execution finish of the runbook job
    [string]   $ExitValue         # the exit value of the runbook step; it is similar to the step exit value
    [string]   $ArtefactsPath     # the file/folder path where the output files and other relevant files will be saved right after execution
    [bool]     $Disabled          # the step will be loaded and verified, but skipped during runbook execution
    [bool]     $ContinueOnError   # the Error status after the execution of this runbook will not determine the parent Runbook it is part of to be stopped.
    [Object[]] $Conditions        # a set of optional values which have to be all evaluated to True for the runbook/step to be executed. otherwise, the runbook/step will be skipped.
    [bool]     $StopFlag          # the attribute that signals if a stop has been requested for this runbook; it can be updated during execution but it is checked only between steps
    
    Runbook([string]$Name,[Int]$Seq) {
        $this.Name = $Name
        $this.Seq = $Seq
        $this.GUID = $([guid]::NewGuid().ToString())
        $this.Status = "Initial"
        $this.MultiStatus = @{}
        $this.RemoteParameters = @{}
        $this.RunbookParameters = @{}
        $this.RunbookSteps = @()
        $this.StopFlag = $false
        $this.Disabled = $false
        $this.ContinueOnError = $false
        $this.Conditions = @()
    }

    Runbook(){}
}
