# SPOT Main Module File
# v1.0 - 26.04.2026 - initial version
# v1.1 - 17.05.2026 - fixed Load-SPOTRunbook to return only $false when encountering an error loading the yaml file
#                   - added the RunbookParameters functionality in Load-SPOTRunbook and changed Replace Vars and Validate functions
#                   - enhancements in the Start-SPOTGUI function
# v1.2 - 03.07.2026 - changed the error behavior of some internal functions to use throw; extended attributes shown as strings in the GUI
#                   - improved the GUI refresh during runbook execution; minor improvement to Load-SPOTRunbook to avoind self nesting
#                   - added several public functions for SecretStore handling: Initialize-SPOTSecretStore, Get-SPOTSecretStoreStatus,
#                     Remove-SPOTProjectSecrets and Show-SPOTProjectSecretsInfo
#                   - Improved overall GUI and non-GUI SecretStore handling in various functions; improved Validate-SPOTRunbookRemoteParameters
#                   - removed some unnecessary functions and improved Runbook loading and validations
#                   - added support for references (including mixed strings) inside VariablesToPublish entries
#
#
#
######################################################################################################################
# import the built-in SPOT Step Functions
. "$PSScriptRoot\SPOTStepFunctions.ps1"
# import the SPOT Runbook Functions
. "$PSScriptRoot\SPOTRunbookFunctions.ps1"

# SPOT Internal Functions
################################################################################################################################################################
######################################################################################################################
function Load-SPOTRunbook {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [String]
        # The name of the yaml runbook file
        $Name, 
        [Parameter(Mandatory=$false)]
        [AllowNull()]
        [hashtable]
        # The set of (parent) Runbook Parameters to be used in case child runbooks are loaded
        $RunbookParameters,
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the folder path where the output files and other relevant files will be saved right after execution
        $ArtefactsPath = "C:\Windows\temp", 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int]
        # The sequence number to use, when called from another runbook
        $Seq = 0,
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [bool]
        # The enable/disable configuration from or assigned from the parent runbook
        $Disabled = $false
        )
    
    #######
    Write-SPOTLog "#> Starting function Load-SPOTRunbook for runbook ""$Name""." -Output $false -DBG $true
    
    #########################
    # test the yaml module
    if (!(Get-Module -Name powershell-yaml -ListAvailable)) {
        Write-SPOTLog "ERROR: The powershell-yaml module is not available. Cannot continue." -Output $false
        throw "Load-SPOTRunbook: powershell-yaml module not available!"
    }

    #########################
    # load the step type definitions from yaml file
    if (!$StepTypeDefinitions) {
        try {
            $global:StepTypeDefinitions = Get-SPOTStepTypeDefinitions
        }
        catch {
            Write-SPOTLog "ERROR: The StepTypeDefinitions could not be loaded from file. Cannot continue." -Output $false
            throw "Load-SPOTRunbook: error loading StepTypeDefinitions!"
        }
    }

    #########################
    # set the maximum file length in MB for referenced files/folders
    $ReferencedFileSizeLimit = 10

    # define the runbook files path to the project path
    $RunbooksPath = "$($OrchVars._ProjectPath)\__SPOT_Runbooks"

    # handle the artefacts path
    if ($ArtefactsPath.EndsWith($Name)) {
        $CurrentArtefactsPath = $ArtefactsPath
    }
    else {
        $CurrentArtefactsPath = "$ArtefactsPath\$Name"
    }

    #########################
    # get the runbook ConfigFile
    $ConfigFile = Get-ChildItem -Path $RunbooksPath -Recurse | Where {$_.BaseName -eq $Name} | Select-Object -First 1
    # test the runbook ConfigFile existence
    if (!$ConfigFile) {
        Write-SPOTLog "ERROR: The configuration file ""$Name"" could not be detected in the default folder: ""$RunbooksPath"". Cannot continue." -Output $false
        throw "Load-SPOTRunbook: error loading runbook file!"
    }

    #########################
    # load runbook parameters from the runbook ConfigFile
    $yaml = Get-Content -Path $ConfigFile.FullName -raw
    try {
        $RunbookConfig = ConvertFrom-Yaml $yaml
    }
    catch {
        Write-SPOTLog "ERROR: while loading the yaml file ""$($ConfigFile.FullName)"": $_." -Output $false
        throw "Load-SPOTRunbook: error loading runbook file!"
    }

    ###################################################
    # determine the total number of steps for this runbook and any subordinate ones
    if (!$global:TotalStepCount) {
        $global:TotalStepCount = [int](Get-SPOTStepsCountFromRunbookName -RunbookName $Name -ProjectRunbooksPath $RunbooksPath)
        $global:75 = [math]::Floor($global:TotalStepCount/4)
        $global:50 = [math]::Floor($global:TotalStepCount/2)
        $global:25 = [math]::Floor($global:TotalStepCount*3/4)
    }
    else {
        Write-SPOTLog "For runbook ""$Name"", the TotalStepCount variable was found already defined ""$TotalStepCount"". The current runbook must be a child runbook." -Output $false -DBG $true
    }

    ###################################################
    # build the runbook first with minimal attributes and populate it with additional attributes from the current runbook yaml
    $Runbook = [Runbook]::new($Name,$Seq)
    $Runbook.Description       = $RunbookConfig.Description
    $Runbook.Conditions        = $RunbookConfig.Conditions
    $Runbook.ContinueOnError   = $RunbookConfig.ContinueOnError
    $Runbook.RemoteParameters  = $RunbookConfig.RemoteParameters
    $Runbook.RunbookParameters = $RunbookConfig.RunbookParameters
    $Runbook.ArtefactsPath     = $CurrentArtefactsPath
    if ($Disabled -or $RunbookConfig.Disabled) { $Runbook.Disabled = $true}
    
    if ($Runbook.RunbookParameters) {
        # runbook parameters were defined inside the current Runbook yaml and imported in the current runbook object
        if ($RunbookParameters) {
            # runbook parameters for this runbook are assigned also from the parent Runbook via RunbookStep attributes
            foreach ($RPar in $($Runbook.RunbookParameters.Keys)) {
                if ($RunbookParameters.$RPar) {
                    # the same parameter name is also assigned from the parent runbook; use that instead
                    $Runbook.RunbookParameters.$RPar = $RunbookParameters.$RPar
                    Write-SPOTLog "INFO: For runbook ""$Name"", the Runbook Parameter ""$RPar"" was overwritten from the calling RunbookStep runbook parameters." -Output $false -DBG $true
                }
            }
            # if there are extra RunbookParameters coming from the parent Runbook via RunbookStep attributes, they will be ignored
            foreach ($PRPar in $($RunbookParameters.Keys)){
                if ($PRPar -notin $($Runbook.RunbookParameters.Keys)) {
                    Write-SPOTLog "WARNING: For runbook ""$Name"", the Runbook Parameter ""$PRPar"" was defined in the calling RunbookStep runbook parameters but does not exist in the actual runbook. It will be ignored." -Output $false -DBG $true
                }
            }
        }
    }

    if ($Seq -eq 0) {
        # replace the the O&S&R Vars in the current runbook, if it is the main one
        Replace-SPOTVarsInRunbook -Runbook $Runbook
        
        # validate the remote parameters configured from the current runbook yaml
        if (!(Validate-SPOTRunbookRemoteParameters -Runbook $Runbook)) {
            Write-SPOTLog "ERROR: for the current Runbook ""$($Runbook.Name)"" the remote parameters are not validated. Cannot continue." -Output $false
            throw "Load-SPOTRunbook: error validating remote runbook parameters!"
        }
    }
    
    ###################################################
    # build the runbook steps
    $RunbookSteps = @()
    foreach ($RunbookStepConfig in $RunbookConfig.RunbookSteps.GetEnumerator()) {
        $RunbookStep = $null
        # generate the runbook or runbookstep object
        if ($RunbookStepConfig.Value.Type -eq "Runbook") {
            
            $RunbookGUID = $null
            $RunbookDisable = $false

            ######################
            # handle referencing Runbook Parameters by using the current runbook parameters from parent runbook parameters defined above
            # the Runbook Parameters defined in the called runbook yaml file do not contain references as they are for standalone runbook use
            # the only place to contain references to parent runbook parameters is the RunbookStep config
            foreach ($i in $($RunbookStepConfig.Value.RunbookParameters.Keys)) {
                if ($RunbookStepConfig.Value.RunbookParameters.$i) { 
                    if (($RunbookStepConfig.Value.RunbookParameters.$i).GetType().Name -eq "String") {
                        if (($RunbookStepConfig.Value.RunbookParameters.$i).StartsWith("`$RP:") -and (($RunbookStepConfig.Value.RunbookParameters.$i -split ":").Count -eq 2)) {
                            Write-SPOTLog "Value of current parameter ""$i"" from nested runbook ""$($RunbookStepConfig.Name)"" detected as single reference and starting with `$RP." -Output $false -DBG $true
                            try {
                                $RunbookStepConfig.Value.RunbookParameters.$i = Invoke-Expression -Command "`$Runbook.RunbookParameters.$(($RunbookStepConfig.Value.RunbookParameters.$i -split ":")[1])"
                            }
                            catch {
                                Write-SPOTLog ">>> ERROR while replacing RP reference in nested Runbook Parameter: $_." -Output $false
                                throw "Load-SPOTRunbook: error replacing SPOT vars!"
                            }
                            Write-SPOTLog "Changed parameter ""$i"" from nested runbook ""$($RunbookStepConfig.Name)"" into ""$($RunbookStepConfig.Value.RunbookParameters.$i)""." -Output $false -DBG $true
                        }
                        elseif (($RunbookStepConfig.Value.RunbookParameters.$i).StartsWith("`$RP:") -and (($RunbookStepConfig.Value.RunbookParameters.$i -split ":").Count -gt 2)) {
                            Write-SPOTLog "ERROR: Non-single RP reference detected for parameter ""$i"" in nested Runbook ""$($RunbookStepConfig.Name)"" with value ""$($RunbookStepConfig.Value.RunbookParameters.$i)"". Mixed string references are not allowed in Runbook Parameters. Cannot continue." -Output $false
                            throw "Load-SPOTRunbook: unexpected mixed string references!"
                        }
                    }
                }
            }

            ######################
            # load the nested runbook from its own runbook yaml file; propagate the disable state down
            if ($Runbook.Disabled -or $RunbookStepConfig.Value.Disabled) { $RunbookDisable = $true }
            if ($RunbookStepConfig.Value.Seq -and ($null -ne ($RunbookStepConfig.Value.Seq -as [int])) -and ($RunbookStepConfig.Value.Seq -ne 0)) {
                if ($RunbookStepConfig.Value.RunbookName) {
                    if ($RunbookStepConfig.Value.RunbookName -eq $Name) {
                        # trying to load a runbook inside itself as a runbook step!! no go
                        throw "Load-SPOTRunbook: a runbook cannot be present as a runbook step inside itself!"
                    }
                    else {
                        $RunbookGUID = Load-SPOTRunbook -Name $RunbookStepConfig.Value.RunbookName -RunbookParameters $RunbookStepConfig.Value.RunbookParameters -Seq $RunbookStepConfig.Value.Seq -ArtefactsPath "$CurrentArtefactsPath\$($RunbookStepConfig.Name)_#_$($RunbookStepConfig.Value.RunbookName)" -Disabled $RunbookDisable
                    }
                }
                else {
                    if ($RunbookStepConfig.Name -eq $Name) {
                        # trying to load a runbook inside itself as a runbook step!! no go
                        throw "Load-SPOTRunbook: a runbook cannot be present as a runbook step inside itself!"
                    }
                    else {
                        $RunbookGUID = Load-SPOTRunbook -Name $RunbookStepConfig.Name -RunbookParameters $RunbookStepConfig.Value.RunbookParameters -Seq $RunbookStepConfig.Value.Seq -ArtefactsPath "$CurrentArtefactsPath\$($RunbookStepConfig.Name)" -Disabled $RunbookDisable
                    }
                }
            }
            else {
                Write-SPOTLog "ERROR: For nested Runbook ""$($RunbookStepConfig.Name)"" the Seq number has an unsupported value: ""$($RunbookStepConfig.Value.Seq)"". It must be a non-zero integer. Cannot continue." -Output $false
                throw "Load-SPOTRunbook: unexpected Seq value!"
            }

            # get the object of the current step, which is a runbook, from the synched all runbooks hashtable variable
            $RunbookStep = $AllRunbooks.$($RunbookGUID)

            ######################
            # handle the propagation of attributes from current runbook/runbookStep to the child runbook processed here
            if ($RunbookStep.Disabled) { $RunbookStep.Status = "Disabled" }
            if ($Runbook.ContinueOnError -or $RunbookStepConfig.Value.ContinueOnError -or $RunbookStep.ContinueOnError) { $RunbookStep.ContinueOnError = $true }
            else { $RunbookStep.ContinueOnError = $OrchVars._ContinueOnError }
            if ($RunbookStepConfig.Value.Conditions) { $RunbookStep.Conditions = $RunbookStepConfig.Value.Conditions }
            if ($RunbookStepConfig.Value.Description) { $RunbookStep.Description = $RunbookStepConfig.Value.Description }
            if ($RunbookStepConfig.Value.RemoteParameters) { $RunbookStep.RemoteParameters = $RunbookStepConfig.Value.RemoteParameters }

            ######################
            # replace the the O&S&R Vars in the current child runbook, specially for potential new RemoteParameters and Conditions
            Replace-SPOTVarsInRunbook -Runbook $RunbookStep

            ######################
            # validate the remote parameters after replacing any references
            if (!(Validate-SPOTRunbookRemoteParameters -Runbook $RunbookStep)) {
                Write-SPOTLog "ERROR: for the current nested Runbook ""$($RunbookStep.Name)"" the remote parameters are not validated. Cannot continue." -Output $false
                throw "Load-SPOTRunbook: error validating remote runbook parameters!"
            }
        }
        else {
            # handle progress reporting
            $global:TotalStepCount--

            ######################
            # load the runbook step from the runbook yaml file
            if ($RunbookStepConfig.Value.Seq -and ($null -ne ($RunbookStepConfig.Value.Seq -as [int]))) {
                $RunbookStep = [RunbookStep]::new($RunbookStepConfig.Name, $RunbookStepConfig.Value.Seq, $RunbookStepConfig.Value.Type, $RunbookStepConfig.Value.StepParameters)
            }
            else {
                Write-SPOTLog "ERROR: For RunbookStep ""$($RunbookStepConfig.Name)"" the Seq number has an unsupported value: ""$($RunbookStepConfig.Value.Seq)"". It must be an integer. Cannot continue." -Output $false
                throw "Load-SPOTRunbook: unexpected Seq value!"
            }
            
            $RunbookStep.ArtefactsPath = "$CurrentArtefactsPath\$($Runbook.GUID)_$($RunbookStep.Name).log"
            $RunbookStep.Description   = $RunbookStepConfig.Value.Description
            $RunbookStep.Conditions    = $RunbookStepConfig.Value.Conditions

            ######################
            # handle the ContinueOnError with propagation from above
            if ($Runbook.ContinueOnError -or $RunbookStepConfig.Value.ContinueOnError) { $RunbookStep.ContinueOnError = $true }
            else { $RunbookStep.ContinueOnError = $OrchVars._ContinueOnError }

            ######################
            # handle the RetryCount
            if ($RunbookStepConfig.Value.RetryCount -and ($null -ne ($RunbookStepConfig.Value.RetryCount -as [int]))) { $RunbookStep.RetryCount = $RunbookStepConfig.Value.RetryCount }
            else { $RunbookStep.RetryCount = $OrchVars._RetryCount }

            ######################
            # handle the RetryDelay
            if ($RunbookStepConfig.Value.RetryDelay -and ($null -ne ($RunbookStepConfig.Value.RetryDelay -as [int]))) { $RunbookStep.RetryDelay = $RunbookStepConfig.Value.RetryDelay }
            else { $RunbookStep.RetryDelay = $OrchVars._RetryDelay }
            
            ######################
            # perform validation if not disabled
            if ($Disabled -or $Runbook.Disabled -or $RunbookStepConfig.Value.Disabled) { 
                Write-SPOTLog "INFO: The RunbookStep ""$($RunbookStep.Name)"" is disabled. No validation." -Output $false -DBG $true
                $RunbookStep.Disabled = $true
                $RunbookStep.Status = "Disabled"
            }
            else {
                Write-SPOTLog "INFO: The RunbookStep ""$($RunbookStep.Name)"" is not disabled. Performing validation." -Output $false -DBG $true

                #########################
                # start with replacing SPOTVars
                Replace-SPOTVarsInRunbookStep -RunbookStep $RunbookStep -RbParameters $Runbook.RunbookParameters

                ########################
                # validate parameters
                if (!(Validate-SPOTRunbookStep -RunbookStep $RunbookStep)) {
                    Write-SPOTLog "ERROR: for the current RunbookStep ""$($RunbookStep.Name)"" the parameters are not validated. Cannot continue." -Output $false
                    throw "Load-SPOTRunbook: error validating runbook step parameters!"
                }

                ########################
                # check the size of referenced Items
                if (!(Validate-SPOTReferencedItems -RunbookStep $RunbookStep -MaxSizeMB $ReferencedFileSizeLimit)) {
                    Write-SPOTLog "ERROR: for the RunbookStep ""$($RunbookStep.Name)"" the referenced file size validation failed. Cannot continue." -Output $false
                    throw "Load-SPOTRunbook: error validating referenced items!"
                }
            }

            ######################
            # add the current step to the synced all runbook steps hashtable variable
            $AllRunbookSteps.$($RunbookStep.GUID) = $RunbookStep

            ######
            # signaling progress in the GUI, but only in case the execution is in GUI environment
            if (Get-Command | Where {$_.Name -eq "Set-SPOTSmallPG"}) {
                switch ($global:TotalStepCount) {
                    $75 {Set-SPOTSmallPG -percent 75}
                    $50 {Set-SPOTSmallPG -percent 50}
                    $25 {Set-SPOTSmallPG -percent 25}
                }
            }
        }
        # add the current step to the runbook steps array
        $RunbookSteps += $RunbookStep
    }

    ########################
    # add the RunbookSteps array to the main Runbook Object
    $RunbookSteps = $RunbookSteps | Sort-Object -Property Seq 
    $Runbook.RunbookSteps = $RunbookSteps

    ########################
    # add the current runbook to the AllRunbooks synced variable
    $AllRunbooks.$($Runbook.GUID) = $Runbook

    #######
    Write-SPOTLog "#> Finished function Load-SPOTRunbook for runbook ""$Name""." -Output $false -DBG $true

    # return true
    return $Runbook.GUID

} # end of Load-SPOTRunbook function

######################################################################################################################
function Load-SPOTProject {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the path to the Project folder
        $ProjectPath, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the master password to be used, in case it is not registered
        $MasterPassword 
    )

    #######
    Write-SPOTLog "##> Starting function Load-SPOTProject for project path ""$ProjectPath""." -Output $false -DBG $true

    ###################################################
    # loads a SPOT project by loading into memory all secrets, functions and Orchvars (end-user settings and configs)
    # always use this function with dot sourcing to make available all SPOT functions in the parent/calling scope

    ###########################################
    # transform any potential relative paths into full paths after testing the given project path
    if (Test-Path -Path $ProjectPath -PathType Container) {
        $ProjectPath = (Get-Item -Path $ProjectPath).FullName
    }
    else {
        Write-SPOTLog "ERROR: The provided path was not detected as a folder. Cannot continue." -Output $false
        throw "Load-SPOTProject: project path not found!"
    }

    ###########################################
    # validate project folder
    if (!(Validate-SPOTProjectFolder -TargetPath $ProjectPath)) {
        Write-SPOTLog "ERROR: The provided path was not validated as a SPOT project path. Cannot continue." -Output $false
        throw "Load-SPOTProject: project folder not validated!"
    }

    ###########################################
    # test for Initialized status
    if ($MasterPassword) {
        $SPOTStatus = Get-SPOTStatus -MasterPassword $MasterPassword
    }
    else {
        $SPOTStatus = Get-SPOTStatus
    }
    if ($SPOTStatus -ne "Initialized") {
        Write-SPOTLog "ERROR: The SPOT tool is not initialized. Current status: $SPOTStatus. Cannot continue." -Output $false
        throw "Load-SPOTProject: SPOT not initialized!"
    }

    ###########################################
    # unlock the secrets store
    if ($MasterPassword) {
        Unlock-SPOTSecretStore -MasterPassword $MasterPassword
    }
    else {
        Unlock-SPOTSecretStore
    }
    Write-SPOTLog "The SPOT secret store was unlocked." -Output $false -DBG $true

    ###########################################
    # check for secrets file and use it if present to refresh the Vault (if the file is present, it will be used all the time; if not, not)
    if ($MasterPassword) {
        Import-SPOTProjectSecrets -ProjectPath $ProjectPath -MasterPassword $MasterPassword
    }
    else {
        Import-SPOTProjectSecrets -ProjectPath $ProjectPath
    }
    
    ###########################################
    # initialize the SPOT variables with internal and project values, as well as with the (potentially) updated secret vault available
    Initialize-SPOTVariables -ProjectPath $ProjectPath
    
    ###########################################
    # load all SPOT classes
    . "$($OrchVars._SPOTPath)\classes\Classes.ps1"

    ###########################################
    # load all project FunctionFiles
    foreach ($FunctionsFile in (Get-ChildItem -Path "$($OrchVars._ProjectPath)\_HelperFunctions" -Recurse -File -Include *.ps1)) {
        . $FunctionsFile.FullName
    }

    ###########################################
    # get all project scripts and define them as functions
    . Convert-SPOTProjectScriptsToFunctions

    ###########################################
    # stamp all internal and project function with #SPOT
    foreach ($function in (Get-SPOTAllFunctions)) {
        $function.Description = "#SPOT"
    }

    ###########################################
    # populate the list of Runbook functions (to be used to create inidividual runspaces for Runbook execution) 
    # and the list of Payload/Step functions (to be used for the Main Runspace Pool initial session state)
    $OrchVars._ProjectFunctions += (Get-SPOTProjectFunctions).Name
    $OrchVars._StepFunctions = @($OrchVars._ProjectFunctions) + ("Write-SPOTLog",
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

    #######
    Write-SPOTLog "##> Finished function Load-SPOTProject for project path ""$ProjectPath""." -Output $false -DBG $true

} # end of Load-SPOTProject function

######################################################################################################################
function Initialize-SPOTVariables {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the path to the Project folder
        $ProjectPath 
        )
    
    ####################################################################
    Write-SPOTLog "===== Starting function Initialize-SPOTVariables =====" -Output $false

    # test the yaml module
    Import-Module -Name powershell-yaml -ErrorAction SilentlyContinue
    if (!(Get-Module -Name powershell-yaml)) {
        Write-SPOTLog "ERROR: The powershell-yaml module could not be loaded. Cannot continue." -Output $false
        throw "Initialize-SPOTVariables: error loading powershell-yaml module!"
    }

    # detect SPOT Path if it was not already set (for GUI, SPOT cannot be detected from inside a runspace)
    if (!$SPOTPath) {
        $SPOTPath = Get-SPOTPath
    }
    $ProjectConfigPath = "$ProjectPath\__SPOT_Config\OrchVars.yaml"

    # testing project config file path
    if (!(Test-Path -Path $ProjectConfigPath -PathType Leaf)) {
        Write-SPOTLog "ERROR: No project config file detected at the expected location: $ProjectConfigPath. Cannot continue." -Output $false
        throw "Initialize-SPOTVariables: project path not found!"
    }

    # define the main orchestration variable set, only if it is not already initialized in a different runspace and replicated here
    ######
    if (!$OrchVars) {
        $global:OrchVars = [hashtable]::Synchronized(@{})
    }
    elseif ($OrchVars.GetType().Name -ne "SyncHashtable") {
        $global:OrchVars = [hashtable]::Synchronized(@{})
    }
    ######
    if (!$SVars) {
        $global:SVars = [hashtable]::Synchronized(@{})
    }
    elseif ($SVars.GetType().Name -ne "SyncHashtable") {
        $global:SVars = [hashtable]::Synchronized(@{})
    }
    ######
    if (!$PublishedData) {
        $global:PublishedData = [hashtable]::Synchronized(@{})
    }
    elseif ($PublishedData.GetType().Name -ne "SyncHashtable") {
        $global:PublishedData = [hashtable]::Synchronized(@{})
    }
    ######
    if (!$AllRunbooks) {
        $global:AllRunbooks = [hashtable]::Synchronized(@{})
    }
    elseif ($AllRunbooks.GetType().Name -ne "SyncHashtable") {
        $global:AllRunbooks = [hashtable]::Synchronized(@{})
    }
    ######
    if (!$AllRunbookSteps) {
        $global:AllRunbookSteps = [hashtable]::Synchronized(@{})
    }
    elseif ($AllRunbookSteps.GetType().Name -ne "SyncHashtable") {
        $global:AllRunbookSteps = [hashtable]::Synchronized(@{})
    }

    ######
    # add project specific variables from yaml config file
    $ProjectConfigsRaw = Get-Content -Path $ProjectConfigPath -raw
    try {
        $ProjectConfigs = ConvertFrom-Yaml $ProjectConfigsRaw
    }
    catch {
        Write-SPOTLog "ERROR: while loading the yaml file $ProjectConfigPath. Error details: $_."
        throw "Initialize-SPOTVariables: error loading OrchVars file!"
    }

    foreach ($Var in $($ProjectConfigs.Keys)) { 
        $global:OrchVars.$Var = $ProjectConfigs.$Var
    }

    ######
    $global:OrchVars._StopFlag = $false
    # initialize OrchVars settings (overwriting them if defined in the yaml file)
    $global:OrchVars._SPOTPath = $SPOTPath
    $global:OrchVars._ProjectPath = $ProjectPath
    $global:OrchVars._SPOTCapability = Show-SPOTCapability
    # initialize the paths to the internal tools (separate entries to be able to adapt to other environments) depending on the existing SPOTCapability value
    if ($global:OrchVars._SPOTCapability -eq "SshNet") {
        $global:OrchVars._SshNetPath = "$($OrchVars._SPOTPath)\tools\SshNet\Renci.SshNet.dll"
    }
    elseif ($global:OrchVars._SPOTCapability -eq "Extended") {
        $global:OrchVars._SshNetPath = "$($OrchVars._SPOTPath)\tools\SshNet\Renci.SshNet.dll"
        $global:OrchVars._PsExecPath = "$($OrchVars._SPOTPath)\tools\psexec\psexec64.exe"
    }
    # SPOT class definition
    $global:OrchVars._SPOTClassDef = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([System.IO.File]::ReadAllText("$SPOTPath\classes\Classes.ps1")))
    # SPOT host functions for overwriting
    $global:OrchVars._SPOTHostFunctions = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([System.IO.File]::ReadAllText("$SPOTPath\SPOTHostFunctions.ps1")))
    # hashtable with the map from referenced RFO folder archives to the actual file name targets (to avoid multiple parent folder archiving in case of implied parallel execution steps)
    $global:OrchVars._RFOMap = @{}
    # make sure the function lists are empty (they will be initialized during SPOT runbook execution)
    $global:OrchVars._ProjectFunctions = @()
    $global:OrchVars._StepFunctions = @()
    $global:OrchVars._RunbookFunctions = @()
    
    ######
    # define the default settings, if not defined in the yaml file
    if (!$global:OrchVars._Debug) {
        Write-SPOTLog "INFO: The global Debug preference was not set in the Project Config. Setting it to the default value of False." -Output $false -DBG $true
        $global:OrchVars._Debug = $false
    }
    if (!$global:OrchVars._RetryCount) {
        Write-SPOTLog "INFO: The global RetryCount preference was not set in the Project Config. Setting it to the default value of 0 retries." -Output $false -DBG $true
        $global:OrchVars._RetryCount = 0
    }
    if (!$global:OrchVars._RetryDelay) {
        Write-SPOTLog "INFO: The global RetryDelay preference was not set in the Project Config. Setting it to the default value of 30 seconds." -Output $false -DBG $true
        $global:OrchVars._RetryDelay = 30
    }
    if (!$global:OrchVars._ContinueOnError) {
        Write-SPOTLog "INFO: The global ContinueOnError preference was not set in the Project Config. Setting it to the default value of False." -Output $false -DBG $true
        $global:OrchVars._ContinueOnError = $false
    }
    if (!$global:OrchVars._StepTimeout) {
        Write-SPOTLog "INFO: The global StepTimeout preference was not set in the Project Config. Setting it to the default value of 3600 seconds." -Output $false -DBG $true
        $global:OrchVars._StepTimeout = 3600
    }
    if (!$global:OrchVars._VaultName) {
        Write-SPOTLog "INFO: The VaultName was not set in the Project Config. Setting it to the default value of project name." -Output $false -DBG $true
        $global:OrchVars._VaultName = Split-Path -Path $ProjectPath -Leaf
    }
    if (!$global:OrchVars._SPOTRsPoolMax) {
        Write-SPOTLog "INFO: The SPOTRsPoolMax was not set in the Project Config. Setting it to the default value of project name." -Output $false -DBG $true
        $global:OrchVars._SPOTRsPoolMax = 20
    }
    # AnyFailFail applies only to parallel executions for multiple targets in a single step and determines the behavior of the reported Status
    # if AnyFailFail is true, in case at least one of the parallel target executions does not report success (Status=Completed), the entire step is considered failed (Status=Error)
    # if AnyFailFail is false, in case at least one of the parallel target executions report success (Status=Completed), the entire step is considered success (Status=Completed). this is the default
    # of course, in any of the above cases, all parallel executions are waited until finished
    if (!$global:OrchVars._AnyFailFail) {
        Write-SPOTLog "INFO: The global AnyFailFail preference was not set in the Project Config. Setting it to the default value of False." -Output $false -DBG $true
        $global:OrchVars._AnyFailFail = $false
    }

    ######
    # populate the SVars hashtable
    if (Get-SPOTSecretStoreState) {
        Write-SPOTLog ">>> Access to the SecretStore seems to work. Extracting the SVars from the vault." -Output $false -DBG $true
        foreach ($s in (Get-SecretInfo | Where {$_.Name -like "$($OrchVars._VaultName)%_%*"})) {
            try {
                $SVars[($s.Name -split "%_%")[1]] = Get-Secret -Name $s.Name
            }
            catch {
                Write-SPOTLog "ERROR: while loading secret $($s.Name) from the vault: $_." -Output $false -DBG $true
                throw "Initialize-SPOTVariables: error loading secrets!"
            }
        }
    }

    ######
    # replace any secrets placed in the OrchVars, 3 levels deep, if the SecretVault is available
    Write-SPOTLog ">>> Replacing any SV references from the OrchVars." -Output $false -DBG $true
    foreach ($Var in $($OrchVars.Keys)) {
        # Level 1
        if (($OrchVars[$Var]).GetType().Name -eq "string") {
            if ($OrchVars[$Var].StartsWith("`$SV:")) {
                # trying to replace Secret inside the OrchVars
                Write-SPOTLog ">>> OrchVariable ""$Var"" detected as a SV reference. Replacing it from the SVars." -Output $false -DBG $true
                $OrchVars[$Var] = $SVars[($OrchVars[$Var] -split ":")[1]]
            }
        }
        elseif ($OrchVars[$Var].GetType().Name -eq "Hashtable") {
            # Level 2
            foreach ($VarL2 in $($OrchVars[$Var].Keys)) {
                if ($OrchVars[$Var][$VarL2].GetType().Name -eq "string") {
                    if ($OrchVars[$Var][$VarL2].StartsWith("`$SV:")) {
                        # trying to replace Secret inside the OrchVars
                        Write-SPOTLog ">>> OrchVariable ""$VarL2"" detected as a SV reference. Replacing it from the SVars." -Output $false -DBG $true
                        $OrchVars[$Var][$VarL2] = $SVars[($OrchVars[$Var][$VarL2] -split ":")[1]]
                    }
                }
                elseif (($ProjectConfigs.$Var.$VarL2).GetType().Name -eq "Hashtable") {
                    #Level 3
                    foreach ($VarL3 in $($OrchVars[$Var][$VarL2].Keys)) {
                        if ($OrchVars[$Var][$VarL2][$VarL3].GetType().Name -eq "string") {
                            if ($OrchVars[$Var][$VarL2][$VarL3].StartsWith("`$SV:")) {
                                # trying to replace Secret inside the OrchVars
                                Write-SPOTLog ">>> OrchVariable ""$VarL3"" detected as a SV reference. Replacing it from the SVars." -Output $false -DBG $true
                                $OrchVars[$Var][$VarL2][$VarL3] = $SVars[($OrchVars[$Var][$VarL2][$VarL3] -split ":")[1]]
                            }
                        }
                    }
                }
            }
        }
    }

    ####################################################################
    Write-SPOTLog "===== Finished function Initialize-SPOTVariables =====" -Output $false
    
} # end of Initialize-SPOTVariables function

######################################################################################################################
function Start-SPOTOrchestration {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [String]
        # The name of the single main/root runbook that triggers the entire desired orchestration
        $MainRunbookName, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int]
        # The number of seconds to wait between the checks for the runbook execution completion
        $CheckInterval = 10 
        )
    
    #############################
    Write-SPOTLog "__## MAIN ##__Starting function Start-SPOTOrchestration for runbook ""$MainRunbookName"".__## MAIN ##__"
    # cleanup the total numer of steps
    if ($global:TotalStepCount) {
        $global:TotalStepCount = $null
    }
    $MainRunbookGUID = Load-SPOTRunbook -Name $MainRunbookName -ArtefactsPath "$($OrchVars._ProjectPath)\__SPOT_Artefacts"
    $Runbook = $AllRunbooks.$($MainRunbookGUID)

    #############################
    # just before starting the main Runbook Job, start also the SPOT RunspacePool
    $global:_spot_MainWorkerPool = Create-SPOTRsPool -MaxNumber $OrchVars._SPOTRsPoolMax
    # launch runbook execution
    $MainJob = Start-SPOTRunbookJob -GUID $Runbook.GUID
    # wait a little for the dedicated runspace to start
    Start-Sleep -Seconds 4

    #############################
    # check the status in a loop, until the orchestration is finished
    while (!$MainJob.handle.IsCompleted) {
        Start-Sleep -Seconds 5
        # progress report
        $CurrentStatus = [math]::floor(($AllRunbookSteps.Values.Where({($_.Status -eq "Completed") -or (($_.Status -eq "Error") -and ($_.ContinueOnError -eq $true))}).Count/$AllRunbookSteps.Values.Where({$_.Disabled -eq $false}).Count)*100)
        $CurrentRunbooks = ($AllRunbooks.Values.Where({$_.Status -eq "Executing"})).Name -join ","
        $CurrentRunbookSteps = ($AllRunbookSteps.Values.Where({$_.Status -eq "Executing"})).Name -join ","
        Write-SPOTLog ">>> Progress: $CurrentStatus % >>> Current Runbooks: $CurrentRunbooks >>> Current RunbookSteps: $CurrentRunbookSteps <<<"
    } 

    #############################
    # get main runbook results
    Get-SPOTRunbookJobResult -RunbookJob $MainJob
    # close and dispose the main worker pool
    $_spot_MainWorkerPool.Dispose()

    #############################
    # log the overall execution result
    if ($Runbook.ExitValue -eq $false) {
        Write-SPOTLog "__## MAIN ##__Runbook ""$($Runbook.Name)"" execution finished and returned failure.__## MAIN ##__"
    }
    elseif ($Runbook.ExitValue -eq $true) {
        Write-SPOTLog "__## MAIN ##__Runbook ""$($Runbook.Name)"" execution finished and returned success.__## MAIN ##__"
    }
    
} # end of Start-SPOTOrchestration function 

######################################################################################################################
function Get-SPOTStepsCountFromRunbookName {
    Param (
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [String]
    # The name of the target runbook
    $RunbookName, 
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [String]
    # The path where the project runbooks are found
    $ProjectRunbooksPath 
    )

    ############################
    Write-SPOTLog "===== Starting function Get-SPOTStepsCountFromRunbookName for runbook ""$RunbookName"" and project runbooks path ""$ProjectRunbooksPath"". =====" -Output $false -DBG $true

    ############################
    $StepsNumberTotal = 0
    $Config = Get-ChildItem -Path $ProjectRunbooksPath -Recurse | Where {$_.BaseName -eq $RunbookName} | Select-Object -First 1
    if (!$Config) {
        Write-SPOTLog "ERROR: No runbook with the given name ""$RunbookName"" detected in the target runbookspath ""$ProjectRunbooksPath""." -Output $false
        throw "Get-SPOTStepsCountFromRunbookName: runbook not found!"
    }
    $yamlConfig = Get-Content -Path $Config.FullName -raw
    try {
        $RunbookCfg = ConvertFrom-Yaml $yamlConfig
    }
    catch {
        Write-SPOTLog "ERROR: while loading the yaml file ""$($Config.FullName)"". Error details: $_." -Output $false
        throw "Get-SPOTStepsCountFromRunbookName: error loading runbook file!"
    }

    ############################
    foreach ($item in $RunbookCfg.RunbookSteps.GetEnumerator()) {
        if ($item.Value.Type -ne "Runbook") {
            $StepsNumberTotal++
        }
        else {
            if ($item.Value.RunbookName) {
                [int]$StepsNumberTotal += [int](Get-SPOTStepsCountFromRunbookName $item.Value.RunbookName $ProjectRunbooksPath)
            }
            else {
                [int]$StepsNumberTotal += [int](Get-SPOTStepsCountFromRunbookName $item.Name $ProjectRunbooksPath)
            }
        }
    }

    ############################
    Write-SPOTLog "===== Finished function Get-SPOTStepsCountFromRunbookName. =====" -Output $false -DBG $true
    
    return $StepsNumberTotal

} # enf of Get-SPOTStepsCountFromRunbookName function

######################################################################################################################
function Get-SPOTRunbookByName {
    Param (
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [String]
    # The name of the target runbook
    $Name 
    )
    
    ##########################
    foreach ($rBook in $AllRunbooks.GetEnumerator().Name) {
        if ($AllRunbooks.$rBook.Name -eq $Name) {
            return $AllRunbooks.$rBook
        }
    }
} # end of Get-SPOTRunbookByName function

######################################################################################################################
function Replace-SPOTVarsInRunbook {
    Param (
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [Object]
    # the runbook to validate, parse and replace the RPs/OVs/SVs
    $Runbook
    )

    #####
    Write-SPOTLog "Starting function Replace-SPOTVarsInRunbook for Runbook ""$($Runbook.Name)""." -Output $false -DBG $true

    # Runbook Parameters first because the RP references from other elements refer to these ones
    foreach ($i in $($Runbook.RunbookParameters.Keys)) {
        $Splitted = $null
        if ($Runbook.RunbookParameters.$i) { 
            if (($Runbook.RunbookParameters.$i).GetType().Name -eq "String") {
                $Splitted = ($Runbook.RunbookParameters.$i).Trim() -split ":"
                if ($Splitted.Count -eq 2) {
                    ###############################
                    # check for unsupported cases
                    if ([string]::IsNullOrEmpty($Splitted[1])) {
                        Write-SPOTLog " >> ERROR: the current Var reference in current runbook parameter ""$i"" is null or empty. Cannot continue." -Output $false
                        throw "Replace-SPOTVarsInRunbook: empty Var reference!"
                    }
                    elseif ($Splitted[1] -eq '.') {
                        Write-SPOTLog " >> ERROR: The current Var reference in current runbook parameter ""$i"" is for the full Var set. Not needed/supported in Runbook Remote Parameters. Cannot continue." -Output $false
                        throw "Replace-SPOTVarsInRunbook: unexpected dot reference!"
                    }
                    elseif ($Splitted[1] -like '*=*') {
                        Write-SPOTLog " >> ERROR: The current Var reference in current runbook parameter ""$i"" contains ""="" character and this is not supported in a Var reference. Cannot continue." -Output $false
                        throw "Replace-SPOTVarsInRunbook: unsupported Var reference!"
                    }
                    ###############################
                    # process based on Var types
                    switch ($Splitted[0]) {
                        #########################################
                        "`$RP" {
                            # single reference to RP
                            Write-SPOTLog " > Current runbook parameter ""$i"" detected as single `$RP reference." -Output $false -DBG $true
                            Write-SPOTLog " >> ERROR: There should be no RP references in Runbook Parameters when the runbook is processed by this function!! Cannot continue." -Output $false
                            throw "Replace-SPOTVarsInRunbook: unexpected RP reference at this time!"
                        }
                        #########################################
                        "`$OV" {
                            # single reference to OV
                            Write-SPOTLog " > Current runbook parameter ""$i"" detected as single `$OV reference." -Output $false -DBG $true
                            try {
                                $Runbook.RunbookParameters.$i = Invoke-Expression -Command "`$OrchVars.$($Splitted[1])"
                            }
                            catch {
                                Write-SPOTLog " >> ERROR: while replacing OV in runbook parameter: $_." -Output $false
                                throw "Replace-SPOTVarsInRunbook: error replacing OV reference!"
                            }
                            Write-SPOTLog " >> INFO: Changed the runbook parameter ""$i"" into ""$($Runbook.RunbookParameters.$i)""." -Output $false -DBG $true
                            
                        }
                        #########################################
                        "`$SV" {
                            # single reference to SV
                            Write-SPOTLog " > Current runbook parameter ""$i"" detected as single `$SV reference." -Output $false -DBG $true
                            $Runbook.RunbookParameters.$i = $SVars[$Splitted[1]]
                            Write-SPOTLog " >> INFO: Changed the runbook parameter ""$i"" into ""$($Runbook.RunbookParameters.$i)""." -Output $false -DBG $true
                        }
                        #########################################
                        "`$PV" {
                            # single reference to PV
                            Write-SPOTLog " > Current runbook parameter ""$i"" detected as single `$PV reference." -Output $false -DBG $true
                            Write-SPOTLog " >> INFO: The current PV reference will be replaced later, just in time for execution." -Output $false -DBG $true
                        }
                        #########################################
                        default  {
                            Write-SPOTLog " >> ERROR: the "":"" split character detected in runbook parameter ""$i"" without a known prefix or in a mixed string. Cannot continue." -Output $false
                            throw "Replace-SPOTVarsInRunbook: unexpected "":"" usage in RunbookParameter!"
                        }
                    }
                }
                elseif ($Splitted.Count -gt 2) {
                    # mixed string reference is present, which is not allowed here
                    if (($Runbook.RunbookParameters.$i).Contains("`$RP:") -or `
                        ($Runbook.RunbookParameters.$i).Contains("`$OV:") -or `
                        ($Runbook.RunbookParameters.$i).Contains("`$SV:") -or `
                        ($Runbook.RunbookParameters.$i).Contains("`$PV:")) {
                        Write-SPOTLog " >> ERROR: Non-single RP, OV, SV or PV reference detected in Runbook Parameter ""$($Runbook.RunbookParameters.$i)"". Mixed string references are not allowed in Runbook Parameters. Cannot continue." -Output $false
                        throw "Replace-SPOTVarsInRunbook: unexpected mixed string reference!"
                    }
                    else {
                        Write-SPOTLog " >> ERROR: Too many "":"" chars detected in Runbook Parameter ""$($Runbook.RunbookParameters.$i)"". Only single Var references are allowed in Runbook Parameters. Cannot continue." -Output $false
                        throw "Replace-SPOTVarsInRunbook: unexpected mixed string reference!"
                    }
                }
            }
        }
    }

    # conditions
    if ($Runbook.Conditions) {
        $Runbook.Conditions = $Runbook.Conditions | foreach {
            if ($_) {
                if ($_.GetType().Name -eq "String") {
                    Write-SPOTLog " > Evaluating the Runbook ""$($Runbook.Name)"" Condition ""$_"" >>>" -Output $false -DBG $true
                    if (($_ -split ":").Count -eq 2) {
                        ###############################
                        # check for unsupported cases
                        if ([string]::IsNullOrEmpty(($_.Trim() -split ":")[1])) {
                            Write-SPOTLog " >> ERROR: the current Var reference is null or empty. Cannot continue." -Output $false
                            throw "Replace-SPOTVarsInRunbook: empty Var reference!"
                        }
                        elseif (($_.Trim() -split ":")[1] -eq '.') {
                            Write-SPOTLog " >> ERROR: The current Var reference is for a full Var set and this is not supported inside Conditions. Cannot continue." -Output $false
                            throw "Replace-SPOTVarsInRunbook: unsupported Var reference!"
                        }
                        elseif (($_.Trim() -split ":")[1] -like '*=*') {
                            Write-SPOTLog " >> ERROR: The current Var reference contains ""="" character and this is not supported in a Var reference. Cannot continue." -Output $false
                            throw "Replace-SPOTVarsInRunbook: unsupported Var reference!"
                        }
                        ###############################
                        # process based on Var types
                        if ($_.StartsWith("`$RP:")) {
                            try {
                                $_ = Invoke-Expression -Command "`$Runbook.RunbookParameters.$(($_ -split ":")[1].Trim())"
                            }
                            catch {
                                Write-SPOTLog " >> ERROR: while replacing RP in Condition: $_." -Output $false
                                throw "Replace-SPOTVarsInRunbook: error replacing RP reference!"
                            }
                            Write-SPOTLog " >> INFO: Condition value evaluated to ""$_""." -Output $false -DBG $true
                        }
                        elseif ($_.StartsWith("`$OV:")) {
                            try {
                                $_ = Invoke-Expression -Command "`$OrchVars.$(($_ -split ":")[1].Trim())"
                            }
                            catch {
                                Write-SPOTLog " >> ERROR: while replacing OV in Condition: $_." -Output $false
                                throw "Replace-SPOTVarsInRunbook: error replacing OV reference!"
                            }
                            Write-SPOTLog " >> INFO: Condition value evaluated to ""$_""." -Output $false -DBG $true
                        }
                        elseif ($_.StartsWith("`$PV:")) {
                            Write-SPOTLog " >> INFO: Condition with single PV reference. It will be replaced later, just in time for execution." -Output $false -DBG $true
                        }
                        elseif ($_.StartsWith("`$SV:")) {
                            Write-SPOTLog " >> ERROR: SV reference detected in condition ""$_"". SV references are not allowed in Conditions. Cannot continue." -Output $false
                            throw "Replace-SPOTVarsInRunbook: unexpected SV reference in condition!"
                        }
                        else {
                            Write-SPOTLog " >> ERROR: the "":"" split character detected in condition ""$_"" without a known prefix or in a mixed string. Cannot continue." -Output $false
                            throw "Replace-SPOTVarsInRunbook: unexpected "":"" usage in condition!"
                        }
                    
                    }
                    ###############################
                    # now the validations that this is not a mixed string or multi-word string
                    # multi-word is not allowed here, at the start, as it defeats the purpose of a condition - it will never become $false, $null or ""
                    elseif ((($_ -split ":").Count -gt 2) -or (($_.Trim() -split '\s+').Count -gt 1)) {
                        Write-SPOTLog " >> ERROR: mixed string reference or multi-word string detected in condition ""$_"". These are not allowed in Conditions. Cannot continue." -Output $false
                        throw "Replace-SPOTVarsInRunbook: unexpected mixed string reference!"
                    }
                    $_
                }
                else {
                    Write-SPOTLog " >> INFO: Current Condition ""$_"" for the runbook ""$($Runbook.Name)"" is not of type string! Leaving it unchanged." -Output $false -DBG $true
                    $_
                }
            }
            else {
                # return the empty value as this is important for conditions
                $_
            }
        }
    }

    # remote params 
    foreach ($i in $($Runbook.RemoteParameters.Keys)) {
        $Splitted = $null
        if ($Runbook.RemoteParameters.$i) { 
            if (($Runbook.RemoteParameters.$i).GetType().Name -eq "String") {
                $Splitted = ($Runbook.RemoteParameters.$i).Trim() -split ":"
                if ($Splitted.Count -eq 2) {
                    ###############################
                    # check for unsupported cases
                    if ([string]::IsNullOrEmpty($Splitted[1])) {
                        Write-SPOTLog " >> ERROR: the current Var reference in current remote parameter ""$i"" is null or empty. Cannot continue." -Output $false
                        throw "Replace-SPOTVarsInRunbook: empty Var reference!"
                    }
                    elseif ($Splitted[1] -eq '.') {
                        Write-SPOTLog " >> ERROR: The current Var reference in current remote parameter ""$i"" is for the full Var set. Not needed/supported in Remote Parameters. Cannot continue." -Output $false
                        throw "Replace-SPOTVarsInRunbook: unexpected dot reference!"
                    }
                    elseif ($Splitted[1] -like '*=*') {
                        Write-SPOTLog " >> ERROR: The current Var reference in current remote parameter ""$i"" contains ""="" character and this is not supported in a Var reference. Cannot continue." -Output $false
                        throw "Replace-SPOTVarsInRunbook: unsupported Var reference!"
                    }
                    ###############################
                    # process based on Var types
                    switch ($Splitted[0]) {
                        #########################################
                        "`$RP" {
                            # single reference to RP
                            Write-SPOTLog " > Current remote parameter ""$i"" detected as single `$RP reference." -Output $false -DBG $true
                            try {
                                $Runbook.RemoteParameters.$i = Invoke-Expression -Command "`$Runbook.RunbookParameters.$($Splitted[1])"
                            }
                            catch {
                                Write-SPOTLog " >> ERROR: while replacing RP in remote parameter: $_." -Output $false
                                throw "Replace-SPOTVarsInRunbook: error replacing RP reference!"
                            }
                            Write-SPOTLog " >> INFO: Changed the remote parameter ""$i"" into ""$($Runbook.RemoteParameters.$i)""." -Output $false -DBG $true 
                        }
                        #########################################
                        "`$OV" {
                            # single reference to OV
                            Write-SPOTLog " > Current remote parameter ""$i"" detected as single `$OV reference." -Output $false -DBG $true
                            try {
                                $Runbook.RemoteParameters.$i = Invoke-Expression -Command "`$OrchVars.$($Splitted[1])"
                            }
                            catch {
                                Write-SPOTLog " >> ERROR: while replacing OV in runbook parameter: $_." -Output $false
                                throw "Replace-SPOTVarsInRunbook: error replacing OV reference!"
                            }
                            Write-SPOTLog " >> INFO: Changed the runbook parameter ""$i"" into ""$($Runbook.RemoteParameters.$i)""." -Output $false -DBG $true
                        }
                        #########################################
                        "`$SV" {
                            # single reference to SV
                            Write-SPOTLog " > Current remote parameter ""$i"" detected as single `$SV reference." -Output $false -DBG $true
                            $Runbook.RemoteParameters.$i = $SVars[$Splitted[1]]
                            Write-SPOTLog " >> INFO: Changed the remote parameter ""$i"" into ""$($Runbook.RemoteParameters.$i)""." -Output $false -DBG $true
                        }
                        #########################################
                        "`$PV" {
                            # single reference to PV
                            Write-SPOTLog " > Current remote parameter ""$i"" detected as single `$PV reference." -Output $false -DBG $true
                            Write-SPOTLog " >> INFO: The current PV reference will be replaced later, just in time for execution." -Output $false -DBG $true
                        }
                        #########################################
                        default  {
                            Write-SPOTLog " >> ERROR: the "":"" split character detected in remote parameter ""$i"" without a known prefix or in a mixed string. Cannot continue." -Output $false
                            throw "Replace-SPOTVarsInRunbook: unexpected "":"" usage in RemoteParameter!"
                        }
                    }
                }
                elseif ($Splitted.Count -gt 2) {
                    # mixed string reference is present, which is not allowed here
                    if (($Runbook.RemoteParameters.$i).Contains("`$RP:") -or `
                        ($Runbook.RemoteParameters.$i).Contains("`$OV:") -or `
                        ($Runbook.RemoteParameters.$i).Contains("`$SV:") -or `
                        ($Runbook.RemoteParameters.$i).Contains("`$PV:")) {
                        Write-SPOTLog " > ERROR: Non-single RP, OV, SV or PV reference detected in Remote Parameter ""$($Runbook.RemoteParameters.$i)"". Mixed string references are not allowed in Runbook Remote Parameters. Cannot continue." -Output $false
                        throw "Replace-SPOTVarsInRunbook: unexpected mixed string reference!"
                    }
                    else {
                        Write-SPOTLog " >> ERROR: Too many "":"" chars detected in Remote Parameter ""$($Runbook.RemoteParameters.$i)"". Only single Var references are allowed in Runbook Remote Parameters. Cannot continue." -Output $false
                        throw "Replace-SPOTVarsInRunbook: unexpected mixed string reference!"
                    }
                }
            }
        }
    }

    #####
    Write-SPOTLog "Finished function Replace-SPOTVarsInRunbook for Runbook ""$($Runbook.Name)""." -Output $false -DBG $true

} # end of Replace-SPOTVarsInRunbook function

######################################################################################################################
function Replace-SPOTVarsInRunbookStep {
    Param (
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [Object]
    # the runbookstep to parse and replace the RPs/OVs/SVs
    $RunbookStep,
    [Parameter(Mandatory=$true)]
    [AllowNull()]
    [hashtable]
    # the runbook parameters hashtable to be used for RP references
    $RbParameters
    )

    #####
    Write-SPOTLog "Starting function Replace-SPOTVarsInRunbookStep for RunbookStep ""$($RunbookStep.Name)""." -Output $false -DBG $true

    # conditions
    if ($RunbookStep.Conditions) {
        $RunbookStep.Conditions = $RunbookStep.Conditions | foreach {
            if ($_) {
                if ($_.GetType().Name -eq "String") {
                    Write-SPOTLog " > Evaluating the RunbookStep ""$($RunbookStep.Name)"" Condition ""$_"" >>>" -Output $false -DBG $true
                    if (($_ -split ":").Count -eq 2) {
                        ###############################
                        # check for unsupported cases
                        if ([string]::IsNullOrEmpty(($_.Trim() -split ":")[1])) {
                            Write-SPOTLog " >> ERROR: the current Var reference is null or empty. Cannot continue." -Output $false
                            throw "Replace-SPOTVarsInRunbookStep: empty Var reference!"
                        }
                        elseif (($_.Trim() -split ":")[1] -eq '.') {
                            Write-SPOTLog " >> ERROR: The current Var reference is for a full Var set and this is not supported inside Conditions. Cannot continue." -Output $false
                            throw "Replace-SPOTVarsInRunbookStep: unsupported Var reference!"
                        }
                        elseif (($_.Trim() -split ":")[1] -like '*=*') {
                            Write-SPOTLog " >> ERROR: The current Var reference contains ""="" character and this is not supported in a Var reference. Cannot continue." -Output $false
                            throw "Replace-SPOTVarsInRunbookStep: unsupported Var reference!"
                        }
                        ###############################
                        # process based on Var types
                        if ($_.StartsWith("`$RP:")) {
                            try {
                                $_ = Invoke-Expression -Command "`$RbParameters.$(($_ -split ":")[1].Trim())"
                            }
                            catch {
                                Write-SPOTLog " >> ERROR: while replacing RP in Condition: $_." -Output $false
                                throw "Replace-SPOTVarsInRunbookStep: error replacing RP reference!"
                            }
                            Write-SPOTLog " >> INFO: Condition value evaluated to ""$_""." -Output $false -DBG $true
                        }
                        elseif ($_.StartsWith("`$OV:")) {
                                try {
                                    $_ = Invoke-Expression -Command "`$OrchVars.$(($_ -split ":")[1].Trim())"
                                }
                                catch {
                                    Write-SPOTLog " >> ERROR: while replacing OV in Condition: $_." -Output $false
                                    throw "Replace-SPOTVarsInRunbookStep: error replacing OV reference!"
                                }
                                Write-SPOTLog " >> INFO: Condition value evaluated to ""$_""." -Output $false -DBG $true
                            }
                        elseif ($_.StartsWith("`$PV:")) {
                                Write-SPOTLog " >> INFO: Condition with single PV reference. It will be replaced later, just in time for execution." -Output $false -DBG $true
                            }
                        elseif ($_.StartsWith("`$SV:")) {
                            Write-SPOTLog " >> ERROR: SV reference detected in condition ""$_"". SV references are not allowed in Conditions. Cannot continue." -Output $false
                            throw "Replace-SPOTVarsInRunbookStep: unexpected reference!"
                        }
                        else {
                            Write-SPOTLog " >> ERROR: the "":"" split character detected in condition ""$_"" without a known prefix or in a mixed string. Cannot continue." -Output $false
                            throw "Replace-SPOTVarsInRunbookStep: unexpected "":"" usage in condition!"
                        }
                    
                    }
                    ###############################
                    # now the validations that this is not a mixed string or multi-word string
                    # multi-word is not allowed here, at the start, as it defeats the purpose of a condition - it will never become $false, $null or ""
                    elseif ((($_ -split ":").Count -gt 2) -or (($_.Trim() -split '\s+').Count -gt 1)) {
                        Write-SPOTLog " >> ERROR: mixed string reference or multi-word string detected in condition ""$_"". These are not allowed in Conditions. Cannot continue." -Output $false
                        throw "Replace-SPOTVarsInRunbookStep: unexpected mixed string reference!"
                    }
                    $_
                }
                else {
                    Write-SPOTLog " >> INFO: Current Condition ""$_"" for the RunbookStep ""$($RunbookStep.Name)"" is not of type string! Leaving it unchanged." -Output $false -DBG $true
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
                    ###############################
                    # check for unsupported cases
                    if ([string]::IsNullOrEmpty($Splitted[1])) {
                        Write-SPOTLog " >> ERROR: the current Var reference in current step parameter ""$i"" is null or empty. Cannot continue." -Output $false
                        throw "Replace-SPOTVarsInRunbookStep: empty Var reference!"
                    }
                    elseif ($Splitted[1] -eq '.') {
                        Write-SPOTLog " >> ERROR: The current Var reference in current step parameter ""$i"" is for the full Var set. Not needed/supported in Step Parameters. Cannot continue." -Output $false
                        throw "Replace-SPOTVarsInRunbookStep: unexpected dot reference!"
                    }
                    elseif ($Splitted[1] -like '*=*') {
                        Write-SPOTLog " >> ERROR: The current Var reference in current step parameter ""$i"" contains ""="" character and this is not supported in a Var reference. Cannot continue." -Output $false
                        throw "Replace-SPOTVarsInRunbookStep: unsupported Var reference!"
                    }
                    ###############################
                    # process based on Var types
                    switch ($Splitted[0]) {
                        #########################################
                        "`$RP" {
                            # single reference to RP
                            Write-SPOTLog " > Current step parameter ""$i"" detected as single `$RP reference." -Output $false -DBG $true
                            try {
                                $RunbookStep.StepParameters.$i = Invoke-Expression -Command "`$RbParameters.$($Splitted[1])"
                            }
                            catch {
                                Write-SPOTLog " >> ERROR: while replacing RP in step parameter: $_." -Output $false
                                throw "Replace-SPOTVarsInRunbookStep: error replacing RP reference!"
                            }
                            Write-SPOTLog " >> INFO: Changed the step parameter ""$i"" into ""$($RunbookStep.StepParameters.$i)""." -Output $false -DBG $true
                        }
                        #########################################
                        "`$OV" {
                            # single reference to OV
                            Write-SPOTLog " > Current step parameter ""$i"" detected as single `$OV reference." -Output $false -DBG $true
                            try {
                                $RunbookStep.StepParameters.$i = Invoke-Expression -Command "`$OrchVars.$($Splitted[1])"
                            }
                            catch {
                                Write-SPOTLog " >> ERROR: while replacing OV in step parameter: $_." -Output $false
                                throw "Replace-SPOTVarsInRunbookStep: error replacing OV reference!"
                            }
                            Write-SPOTLog " >> INFO: Changed the step parameter ""$i"" into ""$($RunbookStep.StepParameters.$i)""." -Output $false -DBG $true
                        }
                        #########################################
                        "`$SV" {
                            # single reference to SV
                            Write-SPOTLog " > Current step parameter ""$i"" detected as single `$SV reference." -Output $false -DBG $true
                            $RunbookStep.StepParameters.$i = $SVars[$Splitted[1]]
                            Write-SPOTLog " >> INFO: Changed the step parameter ""$i"" into ""$($RunbookStep.StepParameters.$i)""." -Output $false -DBG $true
                        }
                        #########################################
                        "`$PV" {
                            # single reference to PV
                            Write-SPOTLog " > Current step parameter ""$i"" detected as single `$PV reference." -Output $false -DBG $true
                            Write-SPOTLog " >> INFO: The current PV reference will be replaced later, just in time for execution." -Output $false -DBG $true
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
                        # check for unsupported cases
                        if ([string]::IsNullOrEmpty(($_.Trim() -split ":")[1])) {
                            Write-SPOTLog " >> ERROR: the current Var reference is null or empty. Cannot continue." -Output $false
                            throw "Replace-SPOTVarsInRunbookStep: empty Var reference!"
                        }
                        elseif (($_.Trim() -split ":")[1] -eq '.') {
                            Write-SPOTLog " >> ERROR: The current Var reference is for a full Var set and this is not supported inside VariablesToPublish. Cannot continue." -Output $false
                            throw "Replace-SPOTVarsInRunbookStep: unsupported Var reference!"
                        }
                        elseif (($_.Trim() -split ":")[1] -like '*=*') {
                            Write-SPOTLog " >> ERROR: The current Var reference contains ""="" character and this is not supported in a Var reference. Cannot continue." -Output $false
                            throw "Replace-SPOTVarsInRunbookStep: unsupported Var reference!"
                        }
                        ###############################
                        # process based on Var types
                        if ($_.StartsWith("`$RP:")) {
                            try {
                                $_ = Invoke-Expression -Command "`$RbParameters.$(($_ -split ":")[1].Trim())"
                            }
                            catch {
                                Write-SPOTLog " >> ERROR: while replacing RP in VariablesToPublish entry: $_." -Output $false
                                throw "Replace-SPOTVarsInRunbookStep: error replacing RP reference!"
                            }
                            Write-SPOTLog " >> INFO: VariablesToPublish entry value evaluated to ""$_""." -Output $false -DBG $true
                        }
                        elseif ($_.StartsWith("`$OV:")) {
                            try {
                                $_ = Invoke-Expression -Command "`$OrchVars.$(($_ -split ":")[1].Trim())"
                            }
                            catch {
                                Write-SPOTLog " >> ERROR: while replacing OV in VariablesToPublish entry: $_." -Output $false
                                throw "Replace-SPOTVarsInRunbookStep: error replacing OV reference!"
                            }
                            Write-SPOTLog " >> INFO: VariablesToPublish entry value evaluated to ""$_""." -Output $false -DBG $true
                        }
                        elseif ($_.StartsWith("`$PV:")) {
                            Write-SPOTLog " >> INFO: VariablesToPublish entry with single PV reference. It will be replaced later, just in time for execution." -Output $false -DBG $true
                        }
                        elseif ($_.StartsWith("`$SV:")) {
                            Write-SPOTLog " >> ERROR: SV reference detected in VariablesToPublish entry ""$_"". SV references are not allowed in VariablesToPublish entries. Cannot continue." -Output $false
                            throw "Replace-SPOTVarsInRunbookStep: unexpected reference!"
                        }
                    }
                    $_
                }
                else {
                    Write-SPOTLog " >> WARNING: Current VariablesToPublish entry ""$_"" for the RunbookStep ""$($RunbookStep.Name)"" is not of type string! Leaving it out." -Output $false -DBG $true
                }
            }
        }
    }

    # command parameters
    foreach ($i in $($RunbookStep.StepParameters.CommandParameters.Keys)) {
        if ($RunbookStep.StepParameters.CommandParameters.$i) {
            if (($RunbookStep.StepParameters.CommandParameters.$i).GetType().Name -eq "String") {
                $Splitted = ($RunbookStep.StepParameters.CommandParameters.$i).Trim() -split ":"
                if ($Splitted.Count -eq 2) {
                    ###############################
                    # check for unsupported cases
                    if ([string]::IsNullOrEmpty($Splitted[1])) {
                        Write-SPOTLog " >> ERROR: the current Var reference in current command parameter ""$i"" is null or empty. Cannot continue." -Output $false
                        throw "Replace-SPOTVarsInRunbookStep: empty Var reference!"
                    }
                    elseif ($Splitted[1] -like '*=*') {
                        Write-SPOTLog " >> ERROR: The current Var reference in current command parameter ""$i"" contains ""="" character and this is not supported in a Var reference. Cannot continue." -Output $false
                        throw "Replace-SPOTVarsInRunbookStep: unsupported Var reference!"
                    }
                    ###############################
                    # process based on Var types
                    switch ($Splitted[0]) {
                        #########################################
                        "`$RP" {
                            Write-SPOTLog " > Current command parameter ""$i"" detected as single `$RP reference." -Output $false -DBG $true
                            if ($Splitted[1] -eq '.') {
                                Write-SPOTLog " >> INFO: The current RP reference is for the full RP. It will be replaced later, just in time for execution." -Output $false -DBG $true
                            }
                            else {
                                try {
                                    $RunbookStep.StepParameters.CommandParameters.$i = Invoke-Expression -Command "`$RbParameters.$($Splitted[1])"
                                }
                                catch {
                                    Write-SPOTLog " >> ERROR: while replacing RP in command parameter: $_." -Output $false
                                    throw "Replace-SPOTVarsInRunbookStep: error replacing RP reference!"
                                }
                                Write-SPOTLog " >> INFO: Changed the command parameter ""$i"" into ""$($RunbookStep.StepParameters.CommandParameters.$i)""." -Output $false -DBG $true
                            }
                        }
                        #########################################
                        "`$OV" {
                            # single reference to OV
                            Write-SPOTLog " > Current command parameter ""$i"" detected as single `$OV reference." -Output $false -DBG $true
                            if ($Splitted[1] -eq '.') {
                                Write-SPOTLog " >> ERROR: The current OV reference is for the full OV. Not needed/supported. Cannot continue." -Output $false
                                throw "Replace-SPOTVarsInRunbookStep: unexpected reference!"
                            }
                            else {
                                try {
                                    $RunbookStep.StepParameters.CommandParameters.$i = Invoke-Expression -Command "`$OrchVars.$($Splitted[1])"
                                }
                                catch {
                                    Write-SPOTLog " >> ERROR: while replacing OV in command parameter: $_." -Output $false
                                    throw "Replace-SPOTVarsInRunbookStep: error replacing OV reference!"
                                }
                                Write-SPOTLog " >> INFO: Changed the command parameter ""$i"" into ""$($RunbookStep.StepParameters.CommandParameters.$i)""." -Output $false -DBG $true
                            }
                        }
                        #########################################
                        "`$SV" {
                            # single reference to SV
                            Write-SPOTLog " > Current command parameter ""$i"" detected as single `$SV reference." -Output $false -DBG $true
                            if ($Splitted[1] -eq '.') {
                                Write-SPOTLog " >> INFO: The current SV reference is for the full SV. It will be replaced later, just in time for execution." -Output $false -DBG $true
                            }
                            else {
                                $RunbookStep.StepParameters.CommandParameters.$i = $SVars[$Splitted[1]]
                                Write-SPOTLog " >> INFO: Changed the command parameter ""$i"" into ""$($RunbookStep.StepParameters.CommandParameters.$i)""." -Output $false -DBG $true
                            }
                        }
                        #########################################
                        "`$PV" {
                            # single reference to PV
                            Write-SPOTLog " > Current command parameter ""$i"" detected as single `$PV reference." -Output $false -DBG $true
                            Write-SPOTLog " >> INFO: The current PV reference will be replaced later, just in time for execution." -Output $false -DBG $true
                        }
                    }
                }
            }
        }
    }

    #####
    Write-SPOTLog "Finished function Replace-SPOTVarsInRunbookStep for RunbookStep ""$($RunbookStep.Name)""." -Output $false -DBG $true

} # end of Replace-SPOTVarsInRunbookStep function

######################################################################################################################
function Validate-SPOTParameterSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]
        # The name of the function to validate
        $Command, 
        [Parameter(Mandatory)]
        [AllowNull()]
        [hashtable]
        # The parameters hashtable to be used for validation
        $CommandParams 
    )

    #####
    Write-SPOTLog "Starting function Validate-SPOTParameterSet for command ""$Command""." -Output $false -DBG $true

    # initialize the return value
    $retVSPS = $true

    # Get metadata
    $cmd = Get-Command $Command -ErrorAction SilentlyContinue

    # stop here if the function is not available
    if (!($cmd)) {
        Write-SPOTLog "VALIDATION ERROR: Function ""$Command"" is not available. Cannot continue." -Output $false
        return $false
    }

    # Flatten parameter names for quick lookup
    $allParameters = $cmd.Parameters.Keys

    # Validate unknown parameters first
    $unknown = $CommandParams.Keys | Where-Object { $_ -notin $allParameters }
    if ($unknown) {
        Write-SPOTLog "VALIDATION ERROR: The given parameters ""$unknown"" are not defined as parameters for the function ""$Command""." -Output $false
        $retVSPS = $false
    }

    # validate the given parameters against all function parameter sets
    $validSets = @()
    foreach ($set in $cmd.ParameterSets) {
        $setName = $set.Name
        # All parameters in this set
        $setParams = $set.Parameters.Name
        # Check if the given params are all allowed in this set
        $badInSet = $CommandParams.Keys | Where-Object { $_ -notin $setParams }
        if ($badInSet) {
            Write-SPOTLog "Bad Parameters for the set $setName => $badInSet." -Output $false -DBG $true
            continue # Cannot fit this parameter set
        }

        # Check mandatory parameters
        $missingMandatory =
            $set.Parameters |
            Where-Object { $_.IsMandatory -and $_.Name -notin $CommandParams.Keys } |
            Select-Object -ExpandProperty Name

        if ($missingMandatory) {
            Write-SPOTLog "Missing Mandatory Parameters for the set ""$setName"" => $missingMandatory." -Output $false -DBG $true
            continue # still invalid for this set due to missing mandatory
        }

        # If we reach here, this set is valid
        Write-SPOTLog "INFO: The given parameters fit the current parameter set ""$setName"" for the function ""$Command""." -Output $false -DBG $true
        $validSets += $setName
    }

    if ($validSets.Count -gt 0) {
        Write-SPOTLog "INFO: The given parameters fit one or more parameter sets for the function ""$Command""." -Output $false -DBG $true
    }
    else {
        Write-SPOTLog "VALIDATION ERROR: The given parameters do not fit (either incompatible parameters or missing mandatory parameters) any parameter sets for the function ""$Command""." -Output $false
        $retVSPS = $false
    }

    #####
    Write-SPOTLog "Finished function Validate-SPOTParameterSet for command ""$Command""." -Output $false -DBG $true

    # return the result
    return $retVSPS
} # end of Validate-SPOTParameterSet function

######################################################################################################################
function Validate-SPOTRunbookRemoteParameters {
    Param (
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [Object]
    # the runbook to check the Remote Parameters
    $Runbook 
    )

    #####
    Write-SPOTLog "Starting function Validate-SPOTRunbookRemoteParameters for Runbook ""$($Runbook.Name)""." -Output $false -DBG $true

    if ($Runbook.RemoteParameters) {
        Write-SPOTLog "INFO: The RemoteParameters are defined for Runbook ""$($Runbook.Name)"". Checking them." -Output $false -DBG $true
        # make sure all remote parameters are present (they are mandatory only if this parent parameter is present)
        if ($Runbook.RemoteParameters.ExecFunction -notin ("PowershellCommandRemote","PowershellCommandRemoteSJ","PowershellCommandRemoteWMI","PowershellCommandRemotePsExec","PowershellCommandRemoteOWMI")) {
            Write-SPOTLog "ERROR: for the Runbook ""$($Runbook.Name)"" the ExecFunction remote parameter is not defined or wrong value!" -Output $false
            return $false
        }
        if (($Runbook.RemoteParameters.ExecFunction -eq "PowershellCommandRemotePsExec") -and ($OrchVars._SPOTCapability -ne "Extended")) {
            Write-SPOTLog "ERROR: for the Runbook ""$($Runbook.Name)"" the ExecFunction remote parameter references the PsExec tool but the current SPOT Capability is not ""Extended""!" -Output $false
            return $false
        }
        if (!$Runbook.RemoteParameters.RemoteComputer) {
            Write-SPOTLog "ERROR: for the Runbook ""$($Runbook.Name)"" the RemoteComputer remote parameter is not defined!" -Output $false
            return $false
        }
        if (($Runbook.RemoteParameters.RemoteComputer.GetType().Name -in ('List`1','Object[]')) -or (($Runbook.RemoteParameters.RemoteComputer -split ",").Count -gt 1)) {
            Write-SPOTLog "ERROR: for the Runbook ""$($Runbook.Name)"" the RemoteComputer remote parameter is configured for multiple targets with the value: $($Runbook.RemoteParameters.RemoteComputer)!" -Output $false
            return $false
        }
        if (!$Runbook.RemoteParameters.Credential) {
            Write-SPOTLog "ERROR: for the Runbook ""$($Runbook.Name)"" the Credential remote parameter is not defined!" -Output $false
            return $false
        }
        if (($Runbook.RemoteParameters.AsSystem) -and ($Runbook.RemoteParameters.ExecFunction -notin ("PowershellCommandRemoteSJ","PowershellCommandRemotePsExec"))) {
            Write-SPOTLog "ERROR: for the Runbook ""$($Runbook.Name)"" the AsSystem remote parameter is defined but not applicable to the ExecFunction!" -Output $false
            return $false
        }
    }

    #####
    Write-SPOTLog "Finished function Validate-SPOTRunbookRemoteParameters for Runbook ""$($Runbook.Name)""." -Output $false -DBG $true

    return $true

} # end of Validate-SPOTRunbookRemoteParameters function

######################################################################################################################
function Validate-SPOTReferencedItems {
    Param (
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [Object]
    # the runbookstep to check for Referenced Items
    $RunbookStep,
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [int]
    # the maximum size permitted, in MB
    $MaxSizeMB
    )

    #########################
    # check any parameter file paths referenced from the project folder, to make sure the referenced files exist and its size is less than the maximum allowed
    if ($RunbookStep.StepParameters.CommandParameters) {
        foreach ($cpar in $RunbookStep.StepParameters.CommandParameters.GetEnumerator()) {
            if ($cpar.Value.GetType().Name -ne "String") {
                continue
            }
            else {
                if ($cpar.Value.StartsWith('$RFI:') -or $cpar.Value.StartsWith('$RFO:')) {
                    # reference to a local file/folder detected
                    $LocalItem = $null
                    # get the local item
                    if ($cpar.Value.StartsWith('$RFO:') -and (($cpar.Value -split ":")[1] -eq "SSHNET")) {
                        if ($OrchVars._SPOTCapability -in ("SshNet","Extended")) {
                            $LocalItem = Get-Item -Path $OrchVars._SshNetPath -ErrorAction SilentlyContinue
                        }
                        else {
                            Write-SPOTLog ">>> ERROR: For RunbookStep ""$($RunbookStep.Name)"" the parameter ""$($cpar.Name)"" references the SshNet tool but the current SPOT Capability is ""Core"". Cannot continue." -Output $false
                            return $false
                        }
                    }
                    elseif ($cpar.Value.StartsWith('$RFO:') -and (($cpar.Value -split ":")[1] -eq "PSEXEC")) {
                        if ($OrchVars._SPOTCapability -eq "Extended") {
                            $LocalItem = Get-Item -Path $OrchVars._PsExecPath -ErrorAction SilentlyContinue
                        }
                        else {
                            Write-SPOTLog ">>> ERROR: For RunbookStep ""$($RunbookStep.Name)"" the parameter ""$($cpar.Name)"" references the PsExec tool but the current SPOT Capability is not ""Extended"". Cannot continue." -Output $false
                            return $false
                        }
                    }
                    else {
                        $LocalItem = Get-Item -Path "$($OrchVars._ProjectPath)\$(($cpar.Value -split ":")[1])" -ErrorAction SilentlyContinue
                    }
                    
                    if ($LocalItem) {
                        # check that with RFI only files are referenced
                        if ($LocalItem.PSIsContainer -and $cpar.Value.StartsWith('$RFI:')) {
                            # problem; there should only be files referenced with RFI
                            Write-SPOTLog ">>> ERROR: For RunbookStep ""$($RunbookStep.Name)"" the referenced item for parameter ""$($cpar.Name)"" and value ""$($cpar.Value)"" was detected as a folder, but only files are permitted with RFI. Cannot continue." -Output $false
                            return $false
                        }
                        # check the size of the local item (if a folder item is referenced, it has a default Length of 1, so no actual check for size but it will pass)
                        if ([math]::ceiling($LocalItem.Length / 1MB) -le $MaxSizeMB) {
                            Write-SPOTLog ">>> For RunbookStep ""$($RunbookStep.Name)"" the referenced item for parameter ""$($cpar.Name)"" and value ""$($cpar.Value)"" was detected and is less than $($MaxSizeMB)MB. OK to continue." -Output $false -DBG $true
                        }
                        else {
                            Write-SPOTLog ">>> ERROR: For RunbookStep ""$($RunbookStep.Name)"" the referenced item for parameter ""$($cpar.Name)"" and value ""$($cpar.Value)"" was detected but it is bigger than $($MaxSizeMB)MB. Cannot continue." -Output $false
                            return $false
                        }
                    }
                    else {
                        Write-SPOTLog ">>> ERROR: For RunbookStep ""$($RunbookStep.Name)"" the referenced item for parameter ""$($cpar.Name)"" and value ""$($cpar.Value)"" was not detected. Cannot continue." -Output $false
                        return $false
                    }
                }
            }
        }
    }

    return $true

} # end of Validate-SPOTReferencedItems function

######################################################################################################################
function Validate-SPOTRunbookStep {
    Param (
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [Object]
    # the runbookstep to parse and validate
    $RunbookStep
    )

    #####
    Write-SPOTLog "Starting function Validate-SPOTRunbookStep for RunbookStep ""$($RunbookStep.Name)""." -Output $false -DBG $true

    #########################
    # load the step type definitions from yaml file
    if (!$StepTypeDefinitions) {
        try {
            $global:StepTypeDefinitions = Get-SPOTStepTypeDefinitions
        }
        catch {
            Write-SPOTLog "ERROR: while loading StepTypeDefinitions from file: $_." -Output $false
            return $false
        }
    }

    ######################
    # SPOT internal step attribute validation
    if ($RunbookStep.Type -notin $($StepTypeDefinitions.RunbookStepParameters.Keys)) {
        Write-SPOTLog "ERROR: For RunbookStep ""$($RunbookStep.Name)"" the step type is not defined or has an unsupported value: ""$($RunbookStep.Type)"". Cannot continue." -Output $false
        return $false
    }
    # check that PsExec type can be used only if the SPOT Capability is "Extended"
    if (($RunbookStep.Type -eq "PowerShellCommandRemotePsExec") -and ($OrchVars._SPOTCapability -ne "Extended")) {
        Write-SPOTLog "ERROR: For RunbookStep ""$($RunbookStep.Name)"" the step type depends on PsExec but the SPOT Capability is not ""Extended"". Cannot continue." -Output $false
        return $false
    }

    #########################
    # validate that the mandatory step parameters are properly defined
    foreach ($ManPar in ($StepTypeDefinitions.RunbookStepParameters.($RunbookStep.Type).GetEnumerator() | Where {$_.Value.Mandatory -eq $true}).Name) {
        if (!$RunbookStep.StepParameters.$ManPar) {
            Write-SPOTLog "ERROR: For RunbookStep ""$($RunbookStep.Name)"" the ""$ManPar"" mandatory step parameter is not defined. Cannot continue." -Output $false
            return $false
        }
    }
    
    #########################
    # if additional step parameters are defined, they will break the loading
    foreach ($par in $($RunbookStep.StepParameters.keys)) {
        if ($par -notin $($StepTypeDefinitions.RunbookStepParameters.($RunbookStep.Type).Keys)) {
            Write-SPOTLog "ERROR: Current StepParameter ""$par"" from step ""$($RunbookStep.Name)"" from Runbook ""$Name"" is not valid for the step type ""$($RunbookStep.Type)"". Cannot continue." -Output $false
            return $false
        }
    }

    #########################
    # SPOT step function validation
    if ($RunbookStep.StepParameters.CommandName -notin $OrchVars._ProjectFunctions) {
        Write-SPOTLog "ERROR: The step function from the current RunbookStep ""$($RunbookStep.Name)"", ""$($RunbookStep.StepParameters.CommandName)"", is not a valid SPOT step function." -Output $false
        return $false
    }
    
    ########################
    # validate parameters for the step function
    if (!(Validate-SPOTParameterSet -Command $RunbookStep.StepParameters.CommandName -CommandParams $RunbookStep.StepParameters.CommandParameters)) {
        Write-SPOTLog "ERROR: The step function parameters from the current RunbookStep ""$($RunbookStep.Name)"" are not valid. Cannot continue." -Output $false
        return $false
    }

    ########################
    # make sure that (correct if necessary) VariablesToPublish are valid (all spaces are removed; "=" sign is removed if there is nothing before or after it)
    if ($RunbookStep.StepParameters.VariablesToPublish) {
        $RunbookStep.StepParameters.VariablesToPublish = foreach ($i in $RunbookStep.StepParameters.VariablesToPublish) {
            if (($i.Trim() -like "*=") -or ($i.Trim() -like "=*")) {
                Write-SPOTLog "WARNING: The current item in VariablesToPublish ""$i"" has an equal sign without values on both sides of it. Removing the equal sign and continuing as is." -Output $false -DBG $true
                $i = $i -replace "=",""
            }
            $i -replace '\s',""
        }
    }
    
    #####
    Write-SPOTLog "Finished function Validate-SPOTRunbookStep for RunbookStep ""$($RunbookStep.Name)""." -Output $false -DBG $true

    return $true
         
} # end of Validate-SPOTRunbookStep function

######################################################################################################################
function Unlock-SPOTSecretStore {
    Param (
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [String]
        # The the master password in plain text, if not registered locally
        $MasterPassword 
        )
    
    ####################################################################
    Write-SPOTLog "===== Starting function Unlock-SPOTSecretStore =====" -DBG $true -Output $false
       
    # checks
    ####
    Import-Module -Name microsoft.powershell.secretstore
    if (!(Get-Module -Name microsoft.powershell.secretstore)) {
        Write-SPOTLog "ERROR: The ""microsoft.powershell.secretstore"" powershell module was not detected locally. Cannot continue." -Output $false
        throw "Unlock-SPOTSecretStore: error loading secretstore module!"
    }

    ####
    if (Get-SPOTSecretStoreState) {
        Write-SPOTLog "The secret store is already unlocked. Nothing to do." -Output $false
        return
    }

    ###################
    # get the master password secure string
    if ($MasterPassword) {
        $SSMasterPassword = ConvertTo-SecureString $MasterPassword -AsPlainText -Force 
    }
    else {
        if ('SPOTKey' -in [System.Environment]::GetEnvironmentVariables("User").Keys) {
            $SSMasterPassword = [System.Environment]::GetEnvironmentVariable('SPOTKey','User') | ConvertTo-SecureString
        }
        else {
            Write-SPOTLog "ERROR: The MasterPassword parameter was not supplied and was also not found to be registered as user environment variable. Cannot continue." -Output $false
            throw "Unlock-SPOTSecretStore: no master password provided!"
        } 
    }
    
    ###################
    # unlock the secret store for the current session
    try {
        Unlock-SecretStore -Password $SSMasterPassword
    }
    catch {
        Write-SPOTLog "ERROR: There was an error unlocking the secret store: $_." -Output $false
        throw "Unlock-SPOTSecretStore: error unlocking the secret store!"
    }

    ###################
    # test if the secret store is unlocked
    if (!(Get-SPOTSecretStoreState)) {
        Write-SPOTLog "ERROR: The access to the secret store failed: $_." -Output $false
        throw "Unlock-SPOTSecretStore: error accessing the secret store!"
    }

    ###################
    # log success and return true
    Write-SPOTLog "The secret store has been successfully unlocked." -Output $false

    ####################################################################
    Write-SPOTLog "===== Finished function Unlock-SPOTSecretStore ====="  -DBG $true -Output $false

} # end of Unlock-SPOTSecretStore function

######################################################################################################################
function Get-SPOTSecretStoreState {

    $EVar = $null
    $SInfo = Get-SecretInfo -ErrorAction SilentlyContinue -ErrorVariable EVar
    if ($EVar) {
        return $false
    }
    else {
        if ($SInfo.Count -gt 0) {
            Get-Secret -Name $SInfo[0].Name -ErrorAction SilentlyContinue -ErrorVariable EVar | Out-Null
            if ($EVar) {
                return $false
            }
            else {
                return $true
            }
        }
        else {
            return $false
        }
    }

} # end of Get-SPOTSecretStoreState function

######################################################################################################################
function Get-SPOTStepTypeDefinitions {
    
    #####################
    # get config path from $OrchVars
    $ConfigPath = "$($OrchVars._SPOTPath)\config\StepTypeDefinitions.yaml"

    #####################
    # test the yaml module
    if (!(Get-Module -Name powershell-yaml -ListAvailable)) {
        Write-SPOTLog "ERROR: The powershell-yaml module is not available. Cannot continue." -Output $false
        throw "Get-SPOTStepTypeDefinitions: powershell-yaml module not available!"
    }

    #####################
    # testing config file path
    if (!(Test-Path -Path $ConfigPath -PathType Leaf)) {
        Write-SPOTLog "ERROR: No StepTypeDefinitions file detected at the specified location $ConfigPath. Exiting." -Output $false
        throw "Get-SPOTStepTypeDefinitions: error loading StepTypeDefinitions file!"
    }

    #####################
    $yamlSTDConfigs = Get-Content -Path $ConfigPath -raw
    try {
        $StepTypeDefinitions = ConvertFrom-Yaml $yamlSTDConfigs
    }
    catch {
        Write-SPOTLog "ERROR: while loading the yaml file $ConfigPath. Error details: $_."
        throw "Get-SPOTStepTypeDefinitions: error loading StepTypeDefinitions file!"
    }

    #####################
    return $StepTypeDefinitions.StepTypeDefinitions

} # enf of Get-SPOTStepTypeDefinitions function

######################################################################################################################
function Get-SPOTAllFunctions {
    
    # get all SPOT internal and SPOT project functions
    $SPOTCommands += Get-Command | Where {($_.ScriptBlock.File -like "$($OrchVars._ProjectPath)*") -or ($_.ScriptBlock.File -like "$($OrchVars._SPOTPath)*") }
    return $SPOTCommands

} # end of Get-SPOTAllFunctions function

######################################################################################################################
function Get-SPOTInternalFunctions {
    
    # set initial value null
    $SPOTPath = $null

    ###################################
    # handle the two cases, OrchVars loaded or not
    if ($OrchVars._SPOTPath) {
        # OrchVars are loaded, the SPOT functions can be queried
        $SPOTPath = $OrchVars._SPOTPath
    }
    else {
        # OrchVars cannot be loaded, the SPOT path must be detected and used
        $SPOTPath = Get-SPOTPath
    }

    ###################################
    # function to be executed on the SPOT computer (where the module is installed)
    $SPOTCommands = @()

    # get all internal SPOT functions (excluding the SPOT step built-in functions)
    $SPOTCommands += Get-Command | Where {($_.ScriptBlock.File -like "$($SPOTPath)*") -and ($_.ScriptBlock.File -ne "$($SPOTPath)\SPOTStepFunctions.ps1")}
    return $SPOTCommands

} # end of Get-SPOTInternalFunctions function

######################################################################################################################
function Get-SPOTProjectFunctions {

    # function to be executed on the SPOT computer (where the module is installed)
    $SPOTPrjCommands = @()

    # get all project SPOT functions
    $SPOTPrjCommands += Get-Command | Where {$_.ScriptBlock.File -like "$($OrchVars._ProjectPath)*"}

    # add all SPOT step built-in functions
    $SPOTPrjCommands += Get-Command | Where {$_.ScriptBlock.File -eq "$($OrchVars._SPOTPath)\SPOTStepFunctions.ps1"}

    # return function collection
    return $SPOTPrjCommands

} # end of Get-SPOTProjectFunctions function

######################################################################################################################
function Convert-SPOTProjectScriptsToFunctions {
    
    # function to be executed on the SPOT computer (where the module is installed)
    $ProjectScriptFiles = Get-ChildItem -Path "$($OrchVars._ProjectPath)\_Scripts" -Recurse | Where-Object {$_.Extension -eq ".ps1"}
    $ProjectScripts = @()
    foreach ($PSFile in $ProjectScriptFiles) {
        $ProjectScripts += Get-Command -Name $PSFile.FullName
    }
    foreach ($i in $ProjectScripts) {
        # transform existing scripts to functions
        $ScriptName = $i.Name -replace ".ps1",""
        Set-Item "Function:$ScriptName" ($i | Select-Object -ExpandProperty ScriptBlock)
    }

} # end of Convert-SPOTProjectScriptsToFunctions function 

######################################################################################################################
function ConvertTo-SPOTHashtable {
    [CmdletBinding()]
    [OutputType('hashtable')]
    param (
        [Parameter(ValueFromPipeline)]
        $InputObject
    )

    process {
        ## Return null if the input is null. This can happen when calling the function
        ## recursively and a property is null
        if (!$InputObject) {
            return $null
        }

        ## Check if the input is an array or collection. If so, we also need to convert
        ## those types into hash tables as well. This function will convert all child
        ## objects into hash tables (if applicable)
        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            $collection = @(
                foreach ($object in $InputObject) {
                    ConvertTo-SPOTHashtable -InputObject $object
                }
            )

            ## Return the array but don't enumerate it because the object may be pretty complex
            Write-Output -NoEnumerate $collection
        } elseif ($InputObject -is [psobject]) { ## If the object has properties that need enumeration
            ## Convert it to its own hash table and return it
            $hash = @{}
            foreach ($property in $InputObject.PSObject.Properties) {
                $hash[$property.Name] = ConvertTo-SPOTHashtable -InputObject $property.Value
            }
            $hash
        } else {
            ## If the object isn't an array, collection, or other object, it's already a hash table
            ## So just return it.
            $InputObject
        }
    }
} # end of ConvertTo-SPOTHashtable function 

######################################################################################################################
function Validate-SPOTProjectFolder {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [String]
        # The path of the folder to be checked 
        $TargetPath 
        )

    $ErrorActionPreference = "SilentlyContinue"
    ###
    Write-SPOTLog "===== Starting function Validate-SPOTProjectFolder for the target folder ""$TargetPath"" =====." -Output $false -DBG $true

    $return = $true
    # Check first the existence of the target folder
    if (!(Test-Path -Path $TargetPath -PathType Container)) {
        Write-SPOTLog "ERROR: The target folder does not exist." -Output $false
        $return = $false
    }
    # Check for the critical file __SPOT_Config\OrchVars.yaml 
    if (!(Test-Path -Path "$TargetPath\__SPOT_Config\OrchVars.yaml" -PathType Leaf)) {
        Write-SPOTLog "ERROR: The critical file OrchVars.yaml does not exist in the expected location." -Output $false
        $return = $false
    }
    # Check for the needed file StepTemplates.yaml 
    if (!(Test-Path -Path "$TargetPath\StepTemplates.yaml" -PathType Leaf)) {
        Write-SPOTLog "ERROR: The needed file StepTemplates.yaml does not exist in the expected location." -Output $false
        $return = $false
    }
    # Check for the HelperFunctions folder
    if (!(Test-Path -Path "$TargetPath\_Scripts" -PathType Container)) {
        Write-SPOTLog "ERROR: The subfolder ""_Scripts"" does not exist in the expected location. No Runbooks can be created without Scripts/Functions." -Output $false
        $return = $false
    }
    # Check for the RUNBOOKS folder
    if (!(Test-Path -Path "$TargetPath\__SPOT_Runbooks" -PathType Container)) {
        Write-SPOTLog "WARNING: The subfolder ""__SPOT_Runbooks"" does not exist in the expected location. No Runbooks can be loaded." -Output $false
    }
    # Check for the HelperFunctions folder
    if (!(Test-Path -Path "$TargetPath\_HelperFunctions" -PathType Container)) {
        Write-SPOTLog "WARNING: The subfolder ""_HelperFunctions"" does not exist in the expected location." -Output $false
    }
    
    ###
    Write-SPOTLog "===== Finished function Validate-SPOTProjectFolder for the target folder ""$TargetPath"" =====." -Output $false -DBG $true
    
    # return the validation result (if at least one mandatory condition fails, return false)
    return $return
    
} # end of Validate-SPOTProjectFolder function

# Exported Functions
################################################################################################################################################################
######################################################################################################################
function Get-SPOTPath {
<#
.SYNOPSIS
Returns the path to the SPOT PowerShell module.

.DESCRIPTION
Gets and returns the SPOT Powershell module path by using the $PSScriptRoot built-in PowerShell variable.
This function only works on the SPOT computer and not on remote computers, during execution of remote runbooks or of runbook steps. 

.INPUTS
None. You can't pipe objects to Get-SPOTPath.

.OUTPUTS
System.String. Get-SPOTPath returns a folder path. 
#>

    $Path = $PSScriptRoot.TrimEnd('\')
    if ($Path) {
        return $Path
    }
    elseif ($SPOTPath) {
        # for GUI env where the $PSScriptRoot variable is not available, the $SPOTPath variable may be available thanks to the Offload-SPOTRunspace function
        return $SPOTPath
    }
    else {
        throw "Get-SPOTPath: error detecting SPOT path!"
    }
} # end of Get-SPOTPath function

######################################################################################################################
function Export-SPOTDevHelperFile {
<#
.SYNOPSIS
Exports the SPOT project functions and OrchVars required to simulate the execution inside SPOT to a single file, for development purposes.

.DESCRIPTION
Loads a project with all the functions and OrchVars, which may include referenced secrets from the Secret Vault, then it exports all project functions and OrchVars to a single file.
Due to the potential secrets included in the file, the handling of this file should be treated with care.
The secrets are encrypted in this file, but with key encryption and the key is also present in the same file.
The exported file is created in such a way to allow easy loading and development of step functions remotely, independent from SPOT, but with the key SPOT elements (functions and OrchVars) available.
After export, the file can be transported to a remote computer and loaded in the PowerShell ISE or in PowerShell by executing, with or without dot sourcing.
When loaded, all functions and OrchVars inside are declared in the global scope.

.PARAMETER ProjectPath
Specifies the path to the Project folder.

.PARAMETER MasterPassword
Specifies the password to be used for unlocking the secret store, if it is not registered.

.PARAMETER FilePath
Specifies the Path of the DevHelper.ps1 file generated by the current function.

.INPUTS
None. You can't pipe objects to Export-SPOTDevHelperFile.

.OUTPUTS
System.String. Export-SPOTDevHelperFile may return only logging output, or not. 

.EXAMPLE
PS> Export-SPOTDevHelperFile -ProjectPath "C:\test\project" -FilePath "C:\test\DevHelper.ps1" -MasterPassword "Passw0rd"
In this example the SPOT project functions and OrchVars defined for the project from "C:\test\project" are exported to the file "C:\test\DevHelper.ps1".
The MasterPassword is specified because, probably, it is not registered locally in the environment variable.

.EXAMPLE
PS> Export-SPOTDevHelperFile -ProjectPath "C:\test\project"
In this example the SPOT project functions and OrchVars defined for the project from "C:\test\project" are exported to the file "C:\temp\DevHelper.ps1" which is the default file location.
The MasterPassword is not specified because, probably, it is registered locally in the environment variable.
#>

    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the path to the Project folder
        $ProjectPath, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]
        # The password to be used for unlocking the secret store, if it is not registered
        $MasterPassword, 
        [Parameter(Mandatory=$false)]
        [String]
        # The Path of the DevHelper.ps1 file generated by the current function
        $FilePath = "C:\temp\DevHelper.ps1" 
        )
    
    #################################################
    Write-SPOTLog "===== Starting function Export-SPOTDevHelperFile. ====="

    ###########################################
    # transform any potential relative paths into full paths
    $ProjectPath = (Get-Item -Path $ProjectPath).FullName
    if (!($ProjectPath)) {
        Write-SPOTLog "ERROR: The provided SPOT Project Path not found. Cannot continue."
        throw "Export-SPOTDevHelperFile: error while loading project."
    }
    else {
        Write-SPOTLog "The provided SPOT Project Path found. Full path: $ProjectPath."
    }

    ###########################################
    # load the target project
    try {
        if (!$MasterPassword) {
            . Load-SPOTProject -ProjectPath $ProjectPath
        }
        else {
            . Load-SPOTProject -ProjectPath $ProjectPath -MasterPassword $MasterPassword
        }
    }
    catch {
        Write-SPOTLog "ERROR: There was an error while trying to load the SPOT project from ""$ProjectPath"": $_."
        throw "Export-SPOTDevHelperFile: error while loading project."
    }

    #################################################
    # select functions to export  
    $ProjectFunctions = Get-SPOTProjectFunctions
    $SPOTFunctions = Get-SPOTInternalFunctions

    $DevHelperFunctions = @()
    $DevHelperRequiredFunctionNames = @()
    $DevHelperRequiredFunctionNames += (Get-SPOTProjectFunctions).Name
    $DevHelperRequiredFunctionNames += ("Write-SPOTLog",
                                        "Get-SPOTSshNetPath",
                                        "New-SPOTSSHSession",
                                        "New-SPOTSFTPSession",
                                        "New-SPOTTelnetSession",
                                        "Extract-SPOTArchive",
                                        "Decompose-SPOTHashTableVariable",
                                        "Recompose-SPOTHashTableVariable",
                                        "Test-SPOTTCPPort",
                                        "Ping-SPOTHostWMI",
                                        "Execute-SPOTScheduledJob",
                                        "Get-SPOTDeepClone",
                                        "Get-SPOTEncryptedToSecString",
                                        "Get-SPOTSecStringToEncrypted",
                                        "Replace-SPOTLineVars",
                                        "Replace-SPOTLineCred",
                                        "ConvertTo-SPOTHashtable",
                                        "Process-SPOTCommandParamsRF",
                                        "Process-SPOTCommandParamsLocalRF",
                                        "Transfer-SPOTDataOverPipe",
                                        "Replace-SPOTExitInCode",
                                        "Add-SPOTSSHTrustedHostKey")

    foreach ($function in $SPOTFunctions) {
        if (($function.Name -in $DevHelperRequiredFunctionNames) -and ($function.Name -notin $DevHelperFunctions.Name)) {
            $DevHelperFunctions += $function
        }
    }

    # adding all filtered functions to a single array
    $DevHelperFunctions += $ProjectFunctions

    # prepare the json 
    $CompKey = $([guid]::NewGuid().ToString()).Substring(0,32)
    $Orchvars._CompKey = $CompKey
    $OrchVarsJson = Decompose-SPOTHashTableVariable -InputVariable $Orchvars -Key $Orchvars._CompKey | ConvertTo-Json -Depth 4 

    # initialize the file
    "##########################################" | Out-File -FilePath $FilePath -Encoding ascii
    "## DEVHELPER FILE FOR PROJECT: $ProjectPath." | Out-File -FilePath $FilePath -Encoding ascii -Append
    "" | Out-File -FilePath $FilePath -Encoding ascii -Append
    "##########################################" | Out-File -FilePath $FilePath -Encoding ascii -Append
    "## FUNCTIONS" | Out-File -FilePath $FilePath -Encoding ascii -Append
    "" | Out-File -FilePath $FilePath -Encoding ascii -Append
    # add the DevHelper Functions to file
    foreach ($f in $DevHelperFunctions) {
        "function global:$($f.Name) {" | Out-File -FilePath $FilePath -Encoding ascii -Append
        $f.Definition | Out-File -FilePath $FilePath -Encoding ascii -Append
        "} # enf of function $($f.Name)" | Out-File -FilePath $FilePath -Encoding ascii -Append
        "##########################################" | Out-File -FilePath $FilePath -Encoding ascii -Append
    }

    # add the OrchVars to file
    "" | Out-File -FilePath $FilePath -Encoding ascii -Append
    "" | Out-File -FilePath $FilePath -Encoding ascii -Append
    "## ORCHVARS" | Out-File -FilePath $FilePath -Encoding ascii -Append
    "##########################################" | Out-File -FilePath $FilePath -Encoding ascii -Append
    "## Orchvars definition" | Out-File -FilePath $FilePath -Encoding ascii -Append
    '$hashtable = ' + "`'$OrchVarsJson`'" + ' | ConvertFrom-Json | ConvertTo-SPOTHashtable ' | Out-File -FilePath $FilePath -Encoding ascii -Append
    "##########################################" | Out-File -FilePath $FilePath -Encoding ascii -Append
    "`$global:Orchvars = Recompose-SPOTHashTableVariable -InputVariable `$hashtable -Key `$hashtable._CompKey" | Out-File -FilePath $FilePath -Encoding ascii -Append

    ####################################################################
    Write-SPOTLog "===== Finished function Export-SPOTDevHelperFile. ====="

} # end of Export-SPOTDevHelperFile function

######################################################################################################################
function Initialize-SPOT {
<#
.SYNOPSIS
Initializes the SPOT PowerShell module on the local computer.

.DESCRIPTION
Checks first if the SPOT module is already initialized and if not, it performs the initialization by:
- enabling PSRemoting 
- recreating the default Secrets Vault (erasing any previous secrets from any local projects)
- creating the Outgoing SPOT firewall rule

.PARAMETER MasterPassword
Specifies the password to be used for unlocking the secret store.

.PARAMETER RegisterMasterPassword
Specifies if the provided MasterPassword is to be registered locally, in the environment variable.

.INPUTS
None. You can't pipe objects to Initialize-SPOT.

.OUTPUTS
System.String. Initialize-SPOT may return only logging output, or not. 

.EXAMPLE
PS> Initialize-SPOT -MasterPassword "Passw0rd" -RegisterMasterPassword $false
In this example the SPOT PowerShell module is initialized on the current computer with the master password "Passw0rd" which is not registered locally in the environment variable.

.EXAMPLE
PS> Initialize-SPOT -MasterPassword "Passw0rd"
In this example the SPOT PowerShell module is initialized on the current computer with the master password "Passw0rd" which is also registered locally in the environment variable.
#>

    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the master password for the secrets vault, in clear text
        $MasterPassword, 
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [bool]
        # flag to enable the possibility to have SPOT initialized but without the Master Password prestaged locally
        $RegisterMasterPassword = $true 
        )

    ####################################################################
    Write-SPOTLog "===== Starting function Initialize-SPOT. ====="

    ####################################################################
    # execute the function only if SPOT is not already initialized
    if ($MasterPassword) {
        $CurrentSPOTStatus = Get-SPOTStatus -MasterPassword $MasterPassword
    }
    else {
        $CurrentSPOTStatus = Get-SPOTStatus
    }
    
    if ($CurrentSPOTStatus -ne "NotInitialized") {
        Write-SPOTLog "Current SPOT status: ""$CurrentSPOTStatus"". You can initialize SPOT only from the status ""NotInitialized"". Nothing to do."
    }
    else {
        ####################################################################
        # enable the possibility to connect to any remote Windows computer (could be a vulnerability to trust all remote computers!! if this is a concern, 
        #    any set of specifically trusted IP Addresses can be used instead of the star wildcard below)
        # https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_remote_troubleshooting?view=powershell-5.1
        # >>  How to connect remotely from a workgroup-based computer
        Write-SPOTLog ">>> Enabling the PSRemoting locally with trust on all hosts."
        Enable-PSRemoting -Force -SkipNetworkProfileCheck
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value '*' -Force

        ####################################################################
        # initialize SecretStore
        if ((Get-SPOTSecretStoreStatus) -ne "Initialized") {
            try {
                if ($RegisterMasterPassword) {
                    Write-SPOTLog ">>> Register the Master Password, due to register flag."
                    Register-SPOTMasterPassword -Password $MasterPassword

                    Write-SPOTLog ">>> Initializing the SecretStore with the registered master password."
                    Initialize-SPOTSecretStore
                }
                else {
                    Write-SPOTLog ">>> Initializing the SecretStore without a registered master password."
                    Initialize-SPOTSecretStore -MasterPassword $MasterPassword
                }
            }
            catch {
                Write-SPOTLog "ERROR: while initializing the SPOT Secret Store: $_. Cannot continue."
                return
            }
        }
    
        ####################################################################
        # check and add allow all applicable outgoing ports
        if (!(Get-NetFirewallRule | Where {$_.DisplayName -eq "Allow TCP 5985/445/22/23 Outbound"})) {
            Write-SPOTLog ">>> The Firewall rule for TCP 5985/445/22/23 outbound access was not detected. Creating it now."
            New-NetFirewallRule -DisplayName "Allow TCP 5985/445/22/23 Outbound" -Direction Outbound -Profile Any -Protocol TCP -RemotePort 5985,445,22,23 -Action Allow -Group SPOT | Out-Null
        }
        else {
            Write-SPOTLog ">>> The Firewall rule for TCP 5985/445/22/23 outbound access was detected."
        }

        ####################################################################
        # check if PsExec is already present (offline installer) and manage the EULA
        $SPOTPath = Get-SPOTPath
        
        if (Test-Path -Path "$SPOTPath\tools\psexec\PsExec64.exe" -PathType Leaf) {
            # PsExec detected; check EULA acceptance
            Write-SPOTLog ">>> PsExec (Sysinternals, Microsoft) tool detected. Managing the EULA. To use PsExec from SPOT, its EULA must be accepted."
            if (Test-Path -Path "HKCU:\Software\Sysinternals\PsExec" -PathType Container) {
                $InitialSysinternalsEula = (Get-ItemProperty -Path "HKCU:\Software\Sysinternals\PsExec" -ErrorAction SilentlyContinue).EulaAccepted
            }
            if ($InitialSysinternalsEula -eq "1") {
                Write-SPOTLog ">>> PsExec EULA found already accepted. No need to trigger the pop-up window and accept it again."
            }
            else {
                # trigger PsExec EULA
                & "$ToolsPath\psexec\PsExec64.exe" cmd /c exit
                # check EULA acceptance and remove the tool if EULA not accepted
                if (Test-Path -Path "HKCU:\Software\Sysinternals\PsExec" -PathType Container) {
                    $SysinternalsEula = (Get-ItemProperty -Path "HKCU:\Software\Sysinternals\PsExec" -ErrorAction SilentlyContinue).EulaAccepted
                }
                if ($SysinternalsEula -eq "1") {
                    Write-SPOTLog ">>> PsExec EULA accepted after initialization."
                }
                else {
                    # remove the PsExec tool
                    Write-SPOTLog ">>> PsExec EULA acceptance not found in the registry after initialization! Removing the PsExec tool from SPOT."
                    Remove-Item -Path "$SPOTPath\tools\psexec\PsExec64.exe" -Confirm:$false -Force
                }
            }
        }
    }
    
    ####################################################################
    Write-SPOTLog "===== Finished function Initialize-SPOT. ====="

} # end of Initialize-SPOT function

######################################################################################################################
function Initialize-SPOTProject {
<#
.SYNOPSIS
Initializes a SPOT project on the local computer.

.DESCRIPTION
Checks for the target folder to be empty and then creates the minimum file system structure for a SPOT project inside. 
It then initializes the default Secrets Vault with the emtpy secrets file just created for this project,
to make sure there are no lingering secrets from potential previous projects with the same path.

.PARAMETER MasterPassword
Specifies the password to be used for unlocking the secret store, usually if it is not registered.

.PARAMETER ProjectPath
Specifies the path to the SPOT project to be initialized.

.INPUTS
None. You can't pipe objects to Initialize-SPOTProject.

.OUTPUTS
System.String. Initialize-SPOTProject may return only logging output, or not. 

.EXAMPLE
PS> Initialize-SPOTProject -ProjectPath "C:\temp\test" -MasterPassword "Passw0rd"
In this example a new SPOT project is created/initialized on the current computer in the folder "C:\temp\test" with the master password "Passw0rd" which is not registered locally in the environment variable.

.EXAMPLE
PS> Initialize-SPOTProject -ProjectPath "C:\temp\test"
In this example a new SPOT project is created/initialized on the current computer in the folder "C:\temp\test" with the already registered master password from the environment variable.
#>

    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the path to the SPOT folder
        $ProjectPath, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the master password to be used, in case it is not prestaged (the masterpassword is not per project, but one per system and user)
        $MasterPassword 
        )

    ####################################################################
    Write-SPOTLog "===== Starting function Initialize-SPOTProject. ====="

    ####################################################################
    # check if the provided folder path exists; create it if not; return error if it exists and it is not empty or if it is invalid
    if (Test-Path -Path $ProjectPath -PathType Container) {
        # the project folder exists, check if it is empty
        if (Get-ChildItem -Path $ProjectPath) {
            Write-SPOTLog "ERROR: the target folder ""$ProjectPath"" is not empty. Cannot continue."
            throw "Initialize-SPOTProject: target folder not empty!"
        }
        else {
            Write-SPOTLog "The target folder ""$ProjectPath"" already exists and it is empty."
        }
    }
    else {
        # the project folder does not exist; try to create it
        New-Item -ItemType Directory -Force -Path $ProjectPath -Confirm:$false -ErrorAction Stop | Out-Null
        Write-SPOTLog "The target folder ""$ProjectPath"" has been created."
    }

    ####################################################################
    # create the project file and folder structure 
    ########
    New-Item -ItemType Directory -Force -Path "$ProjectPath\_Scripts" -Confirm:$false -ErrorAction Stop | Out-Null
    Write-SPOTLog "The target folder ""$ProjectPath\_Scripts"" has been created."

    ########
    New-Item -ItemType Directory -Force -Path "$ProjectPath\_HelperFunctions" -Confirm:$false -ErrorAction Stop | Out-Null
    Write-SPOTLog "The target folder ""$ProjectPath\_HelperFunctions"" has been created."

    ########
    New-Item -ItemType Directory -Force -Path "$ProjectPath\__SPOT_Runbooks" -Confirm:$false -ErrorAction Stop | Out-Null
    Write-SPOTLog "The target folder ""$ProjectPath\__SPOT_Runbooks"" has been created."

    ########
    New-Item -ItemType Directory -Force -Path "$ProjectPath\__SPOT_Config" -Confirm:$false -ErrorAction Stop | Out-Null
    Write-SPOTLog "The target folder ""$ProjectPath\__SPOT_Config"" has been created."

    ########
    New-Item -ItemType Directory -Force -Path "$ProjectPath\__SPOT_Artefacts" -Confirm:$false -ErrorAction Stop | Out-Null
    Write-SPOTLog "The target folder ""$ProjectPath\__SPOT_Artefacts"" has been created."

    ########
    New-Item -ItemType File -Force -Path "$ProjectPath\__SPOT_Config\OrchVars.yaml" -Confirm:$false -ErrorAction Stop | Out-Null
    Write-SPOTLog "The target file ""$ProjectPath\__SPOT_Config\OrchVars.yaml"" has been created."

    ########
    New-Item -ItemType File -Force -Path "$ProjectPath\__SPOT_Config\SInputs.yaml" -Confirm:$false -ErrorAction Stop | Out-Null
    Write-SPOTLog "The target file ""$ProjectPath\__SPOT_Config\SInputs.yaml"" has been created."

    ####################################################################
    # copy the StepTemplates.yaml file
    $SPOTPath = Get-SPOTPath
    Copy-Item -Path "$SPOTPath\config\StepTemplates.yaml" -Destination "$ProjectPath" -Force -Confirm:$false -ErrorAction Stop
    Write-SPOTLog "The target file ""$SPOTPath\config\StepTemplates.yaml"" has been copied."

    ####################################################################
    # initialize the SecretStore for this project (keep this section to empty the Vault from potential secrets from a previous project with the same name)
    if ($MasterPassword) {
        Import-SPOTProjectSecrets -ProjectPath $ProjectPath -MasterPassword $MasterPassword
    }
    else {
        Import-SPOTProjectSecrets -ProjectPath $ProjectPath
    }
    
    ####################################################################
    Write-SPOTLog "===== Finished function Initialize-SPOTProject successfully. ====="

} # end of Initialize-SPOTProject function

######################################################################################################################
function Remove-SPOTProjectSecrets {
<#
.SYNOPSIS
Removes SPOT project secrets.

.DESCRIPTION
Removes all secrets defined for a target SPOT Project or in a Vault associated with a SPOT Project from the SecretStore vault.

.PARAMETER MasterPassword
Specifies the password to be used for unlocking the secret store, usually if it is not registered.

.PARAMETER ProjectPath
Specifies the path to the SPOT project for which the secrets to be removed.

.PARAMETER VaultName
Specifies the Vault Name of the SPOT project for which the secrets to be removed.
The SPOT Project may be already removed and its secrets still populating the SecretStore.

.INPUTS
None. You can't pipe objects to Remove-SPOTProjectSecrets.

.OUTPUTS
System.String. Remove-SPOTProjectSecrets returns only logging output. 

.EXAMPLE
PS> Remove-SPOTProjectSecrets -ProjectPath "C:\temp\test" -MasterPassword "Passw0rd"
In this example the secrets defined for the SPOT project from the folder "C:\temp\test" are removed. The master password "Passw0rd" is used,
which is not registered locally in the environment variable.

.EXAMPLE
PS> Remove-SPOTProjectSecrets -VaultName "test" -MasterPassword "Passw0rd"
In this example the secrets defined for the SPOT project Vault "test" are removed. The master password "Passw0rd" is used,
which is not registered locally in the environment variable.

.EXAMPLE
PS> Remove-SPOTProjectSecrets -ProjectPath "C:\temp\test"
In this example the secrets defined for the SPOT project from the folder "C:\temp\test" are removed. The master password is not specfied because
it is already registered in the environment variable.
#>
    
    [CmdletBinding(DefaultParameterSetName = 'ProjectPath')]
    param(
    # the path to the SPOT folder
    [Parameter(Mandatory, ParameterSetName = 'ProjectPath')]
    [ValidateNotNullOrEmpty()]
    [string]$ProjectPath,

    # the target Vault Name
    [Parameter(Mandatory, ParameterSetName = 'VaultName')]
    [ValidateNotNullOrEmpty()]
    [string]$VaultName,

    # Common parameter, the master password
    [Parameter(ParameterSetName = 'ProjectPath')]
    [Parameter(ParameterSetName = 'VaultName')]
    [ValidateNotNullOrEmpty()]
    [string]$MasterPassword
    )

    ###########################################
    Write-SPOTLog "===== Starting function Remove-SPOTProjectSecrets ====="

    switch ($PSCmdlet.ParameterSetName) {
        'ProjectPath' {
            ###########################################
            # load the target project
            if (!$MasterPassword) {
                . Load-SPOTProject -ProjectPath $ProjectPath
            }
            else {
                . Load-SPOTProject -ProjectPath $ProjectPath -MasterPassword $MasterPassword
            }

            ###########################################
            # set the VaultName prefix
            $VaultNamePrefix = "$($OrchVars._VaultName)%_%"
        }
        'VaultName' {
            ###########################################
            # set the VaultName prefix
            $VaultNamePrefix = "$VaultName%_%"
        }
    }
    Write-SPOTLog " > VaultName prefix: $VaultNamePrefix."

    ###########################################
    # unlock the secretstore
    if (!$MasterPassword) {
        Unlock-SPOTSecretStore
    }
    else {
        Unlock-SPOTSecretStore -MasterPassword $MasterPassword
    }

    ###########################################
    # remove the secrets defined for the current project
    $ProjectSecrets = Get-SecretInfo | Where {$_.Name -like "$VaultNamePrefix*"} 
    foreach ($i in $ProjectSecrets) {
        Write-SPOTLog " > Removing SPOT secret: $(($i.Name -split '%_%')[1])."
        Remove-Secret -Name $i.Name -Vault "SecretStore" -Confirm:$false
    }

    ###########################################
    Write-SPOTLog "===== Finished function Remove-SPOTProjectSecrets ====="

} # end of Remove-SPOTProjectSecrets function

######################################################################################################################
function Show-SPOTProjectSecretsInfo {
<#
.SYNOPSIS
Shows SPOT project secrets info.

.DESCRIPTION
Shows general info (metadata) about the stored SPOT secrets associated with an existing SPOT Project or SPOT Project Vault.

.PARAMETER MasterPassword
Specifies the password to be used for unlocking the secret store, usually if it is not registered.

.PARAMETER ProjectPath
Specifies the path to the SPOT project for which the secrets info to be shown.

.PARAMETER VaultName
Specifies the Vault Name of the SPOT project for which the secrets to be shown.
The SPOT Project may be already removed and its secrets still populating the SecretStore.

.PARAMETER All
Specifies that the info for all secrets from all projects must be listed.

.INPUTS
None. You can't pipe objects to Show-SPOTProjectSecretsInfo.

.OUTPUTS
System.String. Show-SPOTProjectSecretsInfo will return a list of existing secrets info (not the secrets themselves). 

.EXAMPLE
PS> Show-SPOTProjectSecretsInfo -ProjectPath "C:\temp\test" -MasterPassword "Passw0rd"
In this example the secrets defined for the SPOT project from the folder "C:\temp\test" are shown. The master password "Passw0rd" is used,
which is not registered locally in the environment variable.

.EXAMPLE
PS> Show-SPOTProjectSecretsInfo -VaultName "test" -MasterPassword "Passw0rd"
In this example the secrets defined for the SPOT project Vault "test" are shown. The master password "Passw0rd" is used,
which is not registered locally in the environment variable.

.EXAMPLE
PS> Show-SPOTProjectSecretsInfo -ProjectPath "C:\temp\test"
In this example the secrets defined for the SPOT project from the folder "C:\temp\test" are shown. The master password is not specfied because
it is already registered in the environment variable.
#>
    
    [CmdletBinding(DefaultParameterSetName = 'ProjectPath')]
    param(
    # the path to the SPOT folder
    [Parameter(Mandatory, ParameterSetName = 'ProjectPath')]
    [ValidateNotNullOrEmpty()]
    [string]$ProjectPath,

    # the target Vault Name
    [Parameter(Mandatory, ParameterSetName = 'VaultName')]
    [ValidateNotNullOrEmpty()]
    [string]$VaultName,

    # the target Vault Name
    [Parameter(Mandatory, ParameterSetName = 'All')]
    [switch]$All,

    # Common parameter, the master password
    [Parameter(ParameterSetName = 'ProjectPath')]
    [Parameter(ParameterSetName = 'VaultName')]
    [Parameter(ParameterSetName = 'All')]
    [ValidateNotNullOrEmpty()]
    [string]$MasterPassword
    )

    ###########################################
    Write-SPOTLog "===== Starting function Show-SPOTProjectSecretsInfo =====" -Output $false

    switch ($PSCmdlet.ParameterSetName) {
        'ProjectPath' {
            #################################################
            # get the Vault name prefix for the current project
            $ProjectConfigPath = "$ProjectPath\__SPOT_Config\OrchVars.yaml"

            # testing project config file path
            if (!(Test-Path -Path $ProjectConfigPath -PathType Leaf)) {
                Write-SPOTLog "ERROR: No project config file detected at the expected location: $ProjectConfigPath. Exiting." -Output $false
                throw "Show-SPOTProjectSecretsInfo: OrchVars file not found!"
            }

            # load the project config file
            $ProjectConfigsRaw = Get-Content -Path $ProjectConfigPath -raw
            try {
                $ProjectConfigs = ConvertFrom-Yaml $ProjectConfigsRaw
            }
            catch {
                Write-SPOTLog "ERROR: while loading the yaml file $ProjectConfigPath. Error details: $_." -Output $false
                throw "Show-SPOTProjectSecretsInfo: error loading OrchVars file!"
            }

            if (!$ProjectConfigs._VaultName) {
                Write-SPOTLog "INFO: The VaultName was not set in the Project Config. Using the default value of project name." -Output $false -DBG $true
                $VaultName = Split-Path -Path $ProjectPath -Leaf
            }
            else {
                $VaultName = $ProjectConfigs._VaultName
            }

            ###########################################
            # set the VaultName prefix
            $VaultNamePrefix = "$VaultName%_%"
        }
        'VaultName' {
            ###########################################
            # set the VaultName prefix
            $VaultNamePrefix = "$VaultName%_%"
        }
        'All' {
            $VaultNamePrefix = "*"
        }
    }
    Write-SPOTLog " > VaultName prefix: $VaultNamePrefix." -Output $false

    ###########################################
    # unlock the secretstore
    if (!$MasterPassword) {
        Unlock-SPOTSecretStore
    }
    else {
        Unlock-SPOTSecretStore -MasterPassword $MasterPassword
    }

    ###########################################
    # remove the secrets defined for the current project
    $SecretsInfo = Get-SecretInfo | Where {$_.Name -like "$VaultNamePrefix*"}
    foreach ($sInfo in $SecretsInfo) {
        if ($sInfo.Name -like '*%_%*') {
            [pscustomobject]@{
                SPOTSecretName = ($sInfo.Name -split '%_%')[1]
                SPOTVault      = ($sInfo.Name -split '%_%')[0]
                Type           = $sInfo.Type
            }
        }
    }
    
    ###########################################
    Write-SPOTLog "===== Finished function Show-SPOTProjectSecretsInfo =====" -Output $false

} # end of Show-SPOTProjectSecretsInfo function

######################################################################################################################
function Start-SPOT {
<#
.SYNOPSIS
Starts the SPOT orchestration for a specific runbook file, from the command line.

.DESCRIPTION
Loads the specified project, unlocks the Secret Store, loads the specified runbook file and then starts to execute it.

.PARAMETER ProjectPath
Specifies the path to the Project folder.

.PARAMETER MasterPassword
Specifies the password to be used for unlocking the secret store, if it is not registered.

.PARAMETER MainRunbookName
Specifies the runbook file name, without extension, to be loaded and executed.

.INPUTS
None. You can't pipe objects to Start-SPOT.

.OUTPUTS
System.String. Start-SPOT may return only logging output, or not. 

.EXAMPLE
PS> Start-SPOT -ProjectPath "C:\test\project" -MainRunbookName "ProcessDbReports" -MasterPassword "Passw0rd"
In this example, the runbook file "ProcessDbReports.yaml" from the project "C:\test\project" is loaded with the help of the master password "Passw0rd".
The MasterPassword is specified because, probably, it is not registered locally in the environment variable.
The loaded runbook is then executed.

.EXAMPLE
PS> Start-SPOT -ProjectPath "C:\test\project" -MainRunbookName "ProcessDbReports"
In this example, the runbook file "ProcessDbReports.yaml" from the project "C:\test\project" is loaded with the help of the master password registered locally.
The MasterPassword is not specified because, probably, it is registered locally in the environment variable.
The loaded runbook is then executed.
#>

    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the path to the Project folder
        $ProjectPath, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the name of the main runbook to be executed
        $MainRunbookName, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the master password to be used, in case it is not registered
        $MasterPassword 
        )
    
    ###########################################
    # remove previous logs/artefacts to start logging from scratch
    Remove-Item -Path "$ProjectPath\__SPOT_Artefacts\*" -Recurse -Confirm:$false -Force -ErrorAction SilentlyContinue
    if (Test-Path -Path C:\Windows\temp\Orchestration.log) {
        Remove-Item -Path C:\Windows\temp\Orchestration.log -Confirm:$false -Force -ErrorAction SilentlyContinue
    }

    ###########################################
    Write-SPOTLog "===== Starting function Start-SPOT ====="

    ###########################################
    # load the target project
    try {
        if ($MasterPassword) {
            . Load-SPOTProject -ProjectPath $ProjectPath -MasterPassword $MasterPassword
        }
        else {
            . Load-SPOTProject -ProjectPath $ProjectPath
        }
    }
    catch {
        Write-SPOTLog "T.ERROR: while loading the SPOT project from ""$ProjectPath"": $_."
        return
    }
    
    ###########################################
    # log user context
    Write-SPOTLog "Executing SPOT as: $(whoami)."

    ###########################################
    # start the main orchestration/runbook, after the SPOT project is loaded
    try {
        Start-SPOTOrchestration -MainRunbookName $MainRunbookName
    }
    catch {
        Write-SPOTLog "T.ERROR: while executing the SPOT orchestration: $_."
        return
    }

    ###########################################
    Write-SPOTLog "===== Finished function Start-SPOT ====="

} # end of Start-SPOT function

######################################################################################################################
function Start-SPOTGUI {
<#
.SYNOPSIS
Starts the SPOT GUI.

.DESCRIPTION
Starts the SPOT GUI that allows for loading projects, loading runbooks and execute runbooks, with stop and resume support.
The GUI is based on the Windows Presentation Foundation framework and provides mainly a good visualization of the orchestration progress.
The GUI does not provide project or runbook editing capabilities.

.INPUTS
None. You can't pipe objects to Start-SPOTGUI.

.OUTPUTS
WPF.Window. Start-SPOTGUI returns a WPF.Window. 
#>

##########################################################################
Write-SPOTLog "===== Starting function Start-SPOTGUI. ====="

####################################
# Ensure WPF assemblies are loaded
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Collections.ObjectModel;
using System.ComponentModel;

public class TreeNode : INotifyPropertyChanged
{
    private string _DisplayName;
    private string _IconPath;
    private bool _IsExpanded;
    private string _Tag;

    public TreeNode()
    {
        Children = new ObservableCollection<TreeNode>();
    }

    public string DisplayName
    {
        get { return _DisplayName; }
        set
        {
            if (_DisplayName != value)
            {
                _DisplayName = value;
                OnPropertyChanged("DisplayName");
            }
        }
    }

    public string IconPath
    {
        get { return _IconPath; }
        set
        {
            if (_IconPath != value)
            {
                _IconPath = value;
                OnPropertyChanged("IconPath");
            }
        }
    }

    public bool IsExpanded
    {
        get { return _IsExpanded; }
        set
        {
            if (_IsExpanded != value)
            {
                _IsExpanded = value;
                OnPropertyChanged("IsExpanded");
            }
        }
    }

    public string Tag
    {
        get { return _Tag; }
        set
        {
            if (_Tag != value)
            {
                _Tag = value;
                OnPropertyChanged("Tag");
            }
        }
    }

    public ObservableCollection<TreeNode> Children { get; set; }

    public event PropertyChangedEventHandler PropertyChanged;

    protected void OnPropertyChanged(string propertyName)
    {
        if (PropertyChanged != null)
        {
            PropertyChanged(
                this,
                new PropertyChangedEventArgs(propertyName)
            );
        }
    }
}
"@

# set execution policy for current session
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Confirm:$false -Force

[xml]$xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    x:Name="MainWindow"
    Title="SPOT Main Window" 
    Height="800" 
    Width="1200"  
    AllowsTransparency="True" 
    WindowStyle="None" 
    ResizeMode="CanResizeWithGrip" 
    Background="Transparent"
    MinHeight="400" 
    MinWidth="650">
    <Window.Resources>
        <!-- Define the TreeNode type using a DataTemplate -->
        <HierarchicalDataTemplate x:Key="TreeNodeTemplate" ItemsSource="{Binding Children}">
            <StackPanel Orientation="Horizontal">
                <Image Source="{Binding IconPath}" Width="15" Height="15" Margin="0,0,5,0"/>
                <TextBlock Text="{Binding DisplayName}" VerticalAlignment="Center"/>
            </StackPanel>
        </HierarchicalDataTemplate>
    </Window.Resources>
    <Border CornerRadius="5" Background="#282c38" BorderBrush="#282c38" BorderThickness="2">
        <Grid Name="BaseGrid" Background="#282c38">
		    <Grid.RowDefinitions>
			    <RowDefinition Height="31" />
			    <RowDefinition Height="*" />
			    <RowDefinition Height="10" />
		    </Grid.RowDefinitions>
            <TextBlock Name="TitleBar" Text="SPOT Main Window" FontSize="12" FontWeight="Bold" Foreground="White" Margin="8,0,0,0" Grid.Row="0" HorizontalAlignment="Left" VerticalAlignment="Center" />
            <Rectangle Name="DragArea" Grid.Row="0" Fill="Transparent" />
            <Ellipse Name="CloseButton" Fill="Red" Grid.Row="0" Grid.Column="2" Height="15" Width="15" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,8,8,0" ToolTip = "Close"/>
            <Ellipse Name="MaximizeButton" Fill="Orange" Grid.Row="0" Grid.Column="2" Height="15" Width="15" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,8,31,0" ToolTip = "Maximize"/>
            <Ellipse Name="MinimizeButton" Fill="Yellow" Grid.Row="0" Grid.Column="2" Height="15" Width="15" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,8,54,0" ToolTip = "Minimize"/>
            <Grid Name="InnerGrid" Grid.Row="1">
            <Grid.ColumnDefinitions>
			    <ColumnDefinition Width="10" />
			    <ColumnDefinition Width="*" />
			    <ColumnDefinition Width="10" />
		    </Grid.ColumnDefinitions>
                <Grid Name="WorkGrid" Grid.Column="1">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="8" />
			            <RowDefinition Height="18*" />
			            <RowDefinition Height="9*" />
			            <RowDefinition Height="3*" />
		            </Grid.RowDefinitions>
                    <Grid.ColumnDefinitions>
			            <ColumnDefinition Width="*" />
			            <ColumnDefinition Width="*" />
			            <ColumnDefinition Width="*" />
		            </Grid.ColumnDefinitions>
                
                    <ProgressBar Grid.Row="0" Grid.Column="0" Height="2" Grid.ColumnSpan="3" Margin="0,3,0,3" Name="SmallProgressBar" />
                    <TextBox Name="OutputBlock" Grid.Row="2" Grid.Column="0" Grid.ColumnSpan="2" Foreground="Black" IsReadOnly="True" TextWrapping="Wrap" Padding="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="3,3,3,3"/>
                    <ListView Grid.Row="2" Grid.Column="2" Name="PublishedData" Foreground="Black" ScrollViewer.VerticalScrollBarVisibility="Auto" ScrollViewer.HorizontalScrollBarVisibility="Auto" Margin="3,2,3,3">
                        <ListView.View>
                            <GridView>
                                <GridViewColumn Header="Name" DisplayMemberBinding="{Binding Name}"/>
                                <GridViewColumn Header="Value" DisplayMemberBinding="{Binding Value}"/>
                            </GridView>
                        </ListView.View>
                    </ListView>

                    <Grid Name="Progress" Grid.Row="3" Grid.Column="0" Grid.ColumnSpan="3">
                        <Grid.RowDefinitions>
			                <RowDefinition Height="*" />
			                <RowDefinition Height="5" />
		                </Grid.RowDefinitions>
                        <Button Grid.Row="0" Name="StartStop" Height="25" Width="150" Content='Start' HorizontalAlignment="Center" Margin="3"/>
                        <ProgressBar Grid.Row="1" Name="ProgressBar" />    
                    </Grid>
                    
                    <Grid Name="ProjectDetailsGrid" Grid.Row="1" Grid.Column="0">
                        <Grid.RowDefinitions>
			                <RowDefinition Height="31" />
			                <RowDefinition Height="*" />
		                </Grid.RowDefinitions>
                        <Button Grid.Row="0" Name="LoadProject" Height="25" Width="150" Content ='Load Project' HorizontalAlignment="Center" Margin="3"/>
                        <ListView Grid.Row="1" Name="ProjectDetails" ScrollViewer.VerticalScrollBarVisibility="Auto" ScrollViewer.HorizontalScrollBarVisibility="Auto" Margin="3">
                            <ListView.ItemContainerStyle>
                                <Style TargetType="ListViewItem">
                                    <Setter Property="Foreground" Value="Black"/>
                                </Style>
                            </ListView.ItemContainerStyle>
                            <ListView.View>
                                <GridView>
                                    <GridViewColumn Header="Name" DisplayMemberBinding="{Binding Name}" />
                                    <GridViewColumn Header="Value" DisplayMemberBinding="{Binding Value}" />
                                </GridView>
                            </ListView.View>
                            <ListView.GroupStyle>
                                <GroupStyle>
                                    <GroupStyle.HeaderTemplate>
                                        <DataTemplate>
                                            <TextBlock FontWeight="Bold" FontSize="12" Text="{Binding Name}" Foreground="Black"/>
                                        </DataTemplate>
                                    </GroupStyle.HeaderTemplate>
                                </GroupStyle>
                            </ListView.GroupStyle>
                        </ListView>
                    </Grid>

                    <Grid Name="MiddleGrid" Grid.Row="1" Grid.Column="1">
                        <Grid.RowDefinitions>
			                <RowDefinition Height="31" />
			                <RowDefinition Height="*" />
		                </Grid.RowDefinitions>
                        <Label Name="LoadedRunbook" Grid.Row="0" Height = "25" Content='Runbook:' Foreground="White" HorizontalAlignment="Center" FontWeight="Bold" Margin="3"/>
                        <TreeView Grid.Row="1" Name="MainRunbook" ItemTemplate="{StaticResource TreeNodeTemplate}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Margin="3">
                            <TreeView.ItemContainerStyle>
                                <Style TargetType="{x:Type TreeViewItem}">
                                    <Setter Property="IsExpanded" Value="{Binding IsExpanded, Mode=TwoWay}" />
                                    <Setter Property="Tag" Value="{Binding Tag, Mode=TwoWay}" />
                                </Style>
                            </TreeView.ItemContainerStyle>
                        </TreeView>
                    </Grid>

                    <Grid Name="RunbookDetailsGrid" Grid.Row="1" Grid.Column="2">
                        <Grid.RowDefinitions>
			                <RowDefinition Height="31" />
			                <RowDefinition Height="31" />
                            <RowDefinition Height="31" />
                            <RowDefinition Height="*" />
		                </Grid.RowDefinitions>
                        <Button   Grid.Row="0" Name="LoadRunbook" Height="25" Width ="150" Content ='Load Runbook' HorizontalAlignment="Center" VerticalAlignment="Top" Margin="3"/>
                        <ComboBox Grid.Row="1" Name="ComboRunbook" Height="25" Margin="3"></ComboBox>
                        <Label    Grid.Row="2" Name="LabelStep" Height = "25" Content='RunbookStep: TESTING' Foreground="White" HorizontalAlignment="Left" FontWeight="Bold" Margin="3"/>
                        <ListView Grid.Row="3" Name="RunbookStepDetails" Foreground="Black" ScrollViewer.VerticalScrollBarVisibility="Auto" ScrollViewer.HorizontalScrollBarVisibility="Auto" Margin="3">
                            <ListView.View>
                                <GridView>
                                    <GridViewColumn Header="Name" DisplayMemberBinding="{Binding Name}"/>
                                    <GridViewColumn Header="Value" DisplayMemberBinding="{Binding Value}"/>
                                </GridView>
                            </ListView.View>
                            <ListView.GroupStyle>
                                <GroupStyle>
                                    <GroupStyle.HeaderTemplate>
                                        <DataTemplate>
                                            <TextBlock FontWeight="Bold" FontSize="12" Text="{Binding Name}" Foreground="Black"/>
                                        </DataTemplate>
                                    </GroupStyle.HeaderTemplate>
                                </GroupStyle>
                            </ListView.GroupStyle>
                        </ListView>
                    </Grid>

                </Grid>
            </Grid>
        </Grid>
    </Border>
</Window>
"@

####################################
$reader = (New-Object System.Xml.XmlNodeReader $xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

####################################
# get all named controls
foreach ($Name in (            
    $xaml |             
    Select-Xml '//*/@Name' |             
    foreach { $_.Node.Value}            
    )) {
    $window | Add-Member NoteProperty -Name "Control_$Name" -Value $window.FindName($Name) -Force          
}            


####################################
# controls initialization
$window.Control_ProgressBar.Value = 0
$window.Control_SmallProgressBar.Value = 0
$window.Control_LoadProject.IsEnabled = $true
$window.Control_StartStop.IsEnabled = $false
$window.Control_LoadRunbook.IsEnabled = $false
$window.Control_ComboRunbook.IsEnabled = $false
$window.Control_LoadedRunbook.Content = 'Runbook:'
$window.Control_LabelStep.Content = 'RunbookStep:'

# variable initialization
$global:OrchVars        = [hashtable]::Synchronized(@{})
$global:SVars           = [hashtable]::Synchronized(@{})
$global:PublishedData   = [hashtable]::Synchronized(@{})
$global:AllRunbooks     = [hashtable]::Synchronized(@{})
$global:AllRunbookSteps = [hashtable]::Synchronized(@{})
$global:syncHash        = [hashtable]::Synchronized(@{})
$global:syncHash.window = $window

##############################################################

#region GUI functions

function Offload-SPOTRunspace {
    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [scriptblock]
        # the scriptblock to be executed in the runspace
        $RunspaceScriptBlock, 
        [Parameter(Mandatory=$false)]
        [AllowNull()]
        [InitialSessionState]
        # the session stateto be used for the GUI runspace
        $SessionState,
        [Parameter(Mandatory=$true)]
        [hashtable]
        # the hashtable with the parameters to the scriptblock to be executed in the runspace
        $RunspaceScriptBlockParameters 
        )
    
    ######################################
    $RunspaceScriptBlock = [scriptblock]::Create($RunspaceScriptBlock)

    if (!$SessionState) {
        ######################################
        # for GUI, load all SPOT internal functions
        $SessionFunctions = @()
        try {
            $SessionFunctions += Get-SPOTInternalFunctions
        }
        catch {
            Write-Host "Offload-SPOTRunspace: error getting SPOT Internal Functions: $_."
            return
        }
        $SessionFunctions += ("Write-SPOTConsole",
                            "Set-SPOTSmallPG",
                            "Set-SPOTMainPG",
                            "ConvertTo-SPOTTreeNodes",
                            "Update-SPOTPublishedData")

        ######################################
        # Create initial session state
        $SessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        foreach ($funcName in $SessionFunctions) {
            $func = Get-Command -Name $funcName -CommandType Function -ErrorAction Stop
            $SessionState.Commands.Add(
                [System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($func.Name, $func.Definition)
            )
        }
        $SessionState.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new("SFunctionNames", $SessionFunctions.Name, "InjectedFunctions"))
        $SessionState.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new("OrchVars", $OrchVars, "The Orchestration Variables"))
        $SessionState.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new("SVars", $SVars, "The Secret Variables"))
        $SessionState.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new("syncHash", $syncHash, "The GUI Sunchronized Hashtable"))
        $SessionState.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new("PublishedData", $PublishedData, "The SPOT Published Variables"))
        $SessionState.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new("AllRunbooks", $AllRunbooks, "All Runbook objects"))
        $SessionState.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new("AllRunbookSteps", $AllRunbookSteps, "All RunbookSteps objects"))
        $SessionState.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new("SPOTPath", (Get-SPOTPath), "The path to the SPOT module"))

        ######################################
        # create runspace
        $Runspace = [runspacefactory]::CreateRunspace($SessionState)
        $Runspace.ApartmentState = "STA"
        $Runspace.Open()
        $powershell = [powershell]::Create()
        $powershell.AddScript($RunspaceScriptBlock).AddParameters($RunspaceScriptBlockParameters) | Out-Null
        $powershell.Runspace = $Runspace

    }
    else {
        $Runspace = [runspacefactory]::CreateRunspace($SessionState)
        $Runspace.ApartmentState = "STA"
        $Runspace.Open()
        $Runspace.SessionStateProxy.SetVariable("syncHash",$syncHash)
        $Runspace.SessionStateProxy.SetVariable("OrchVars",$OrchVars)
        $Runspace.SessionStateProxy.SetVariable("SVars",$SVars)
        $Runspace.SessionStateProxy.SetVariable("PublishedData",$PublishedData)
        $Runspace.SessionStateProxy.SetVariable("AllRunbooks",$AllRunbooks)
        $Runspace.SessionStateProxy.SetVariable("AllRunbookSteps",$AllRunbookSteps)
        $powershell = [powershell]::Create()
        $powershell.AddScript($RunspaceScriptBlock).AddParameters($RunspaceScriptBlockParameters) | Out-Null
        $powershell.Runspace = $Runspace
    }
    
    # handle the automatic disposal of the runspace
    # https://stackoverflow.com/questions/59792766/the-runspace-and-its-closure
    $null = Register-ObjectEvent -InputObject $powershell -EventName InvocationStateChanged -Action {
        param([System.Management.Automation.PowerShell] $ps)
        $state = $EventArgs.InvocationStateInfo.State
        Write-Host "Invocation state: $state"
        if ($state -in 'Completed', 'Failed') {
            $ps.Runspace.Dispose()
            $ps.Dispose()
            [GC]::Collect()
            Write-Host "Runspace objects disposed."
        }      
    }

    $job = $powershell.BeginInvoke()
    Write-Host "Offload-SPOTRunspace function completed."
}

function Write-SPOTConsole {
    param([string]$text)
    # Append the new text with a newline
    $time = Get-Date
    # Append the new text with a newline
    $syncHash.window.Control_OutputBlock.Dispatcher.invoke([action]{
        $syncHash.window.Control_OutputBlock.AppendText("$time :: $text`n")
        $syncHash.window.Control_OutputBlock.ScrollToEnd()
    })   
}

function Set-SPOTSmallPG {
    param([string]$percent)
    # Set the Small Progress Bar from the GUI to a certain value
    $syncHash.window.Control_SmallProgressBar.Dispatcher.invoke([action]{$syncHash.window.Control_SmallProgressBar.Value = $percent })
}

function Set-SPOTMainPG {
    param([string]$percent)
    # Set the Main Progress Bar from the GUI to a certain value
    $syncHash.window.Control_ProgressBar.Dispatcher.invoke([action]{$syncHash.window.Control_ProgressBar.Value = $percent })
}

function ConvertTo-SPOTTreeNodes {
    Param (
        [Parameter(Mandatory=$true)]
        [Runbook]
        # the target runbook to process
        $Runbook, 
        [Parameter(Mandatory=$false)]
        [AllowNull()]
        [bool]
        # the flag to set the current runbook as the main
        $Main
        )
    
    # main runbook case
    if ($Main) {
        $Mcollection = [System.Collections.ObjectModel.ObservableCollection[TreeNode]]::new()
        $MainNode = New-Object TreeNode -Property @{
            DisplayName = "$($Runbook.Seq)_$($Runbook.Name)_$($Runbook.Description)"
            IconPath = "$SPOTPath\res\$($Runbook.Status).png"
            IsExpanded = $true
            Tag = $Runbook.GUID
        }
        $MainNode.Children = ConvertTo-SPOTTreeNodes -Runbook $Runbook
        $Mcollection.Add($MainNode)
        return $Mcollection
    }
    else {
        $collection = [System.Collections.ObjectModel.ObservableCollection[TreeNode]]::new()
        foreach ($RunbookStep in $Runbook.RunbookSteps) {
            $treeNode = New-Object TreeNode -Property @{
                DisplayName = "$($RunbookStep.Seq)_$($RunbookStep.Name)_$($RunbookStep.Description)"
                IconPath = "$SPOTPath\res\$($RunbookStep.Status).png"
                IsExpanded = $true
                Tag = $RunbookStep.GUID
            }
            if ($RunbookStep.GetType().Name -eq "Runbook") {
                $treeNode.Children = ConvertTo-SPOTTreeNodes -Runbook $RunbookStep
            }
            if ($RunbookStep.Disabled -eq $true) {
                $treeNode.IconPath = "$SPOTPath\res\disabled.png"
            }
            $collection.Add($treeNode)
        }
        return $collection
    }
}

function Update-SPOTPublishedData {
    #############################################
    # prepare the new published data objects
    $NewGuiData = @()
    foreach ($pvar in $($PublishedData.Keys)) {
        $vValue = $null
        $sVal = $null
        # make sure the complex objects arrive deserialized, otherwise this may block the GUI
        $vValue = $PublishedData[$pvar]
        if ($vValue -as [string]) {
            $sVal = $vValue -as [string]
        }
        else {
            $sVal = $vValue.GetType().FullName
        }
        # avoid display of internal remote runbook execution results
        if (!($pvar.StartsWith("RunbookSummary_") -or $pvar.StartsWith("RunbookArtefacts_") -or $pvar.StartsWith("PublishedData_"))) {
            $NewGuiData += [PSCustomObject]@{Name=$pvar; Value=$sVal}
        }
    }

    #############################################
    # read the existing published data GUI objects
    $GuiData = @()
    if ($syncHash.window.Control_PublishedData.ItemsSource) {
        $GuiData += $syncHash.window.Control_PublishedData.ItemsSource
    }

    #############################################
    # update the GUI only if there are differences
    if (Compare-Object -ReferenceObject $NewGuiData -DifferenceObject $GuiData -Property Name,Value) {
        $syncHash.window.Control_PublishedData.Dispatcher.invoke([action]{$syncHash.window.Control_PublishedData.ItemsSource = $NewGuiData })
    }
}

function Show-SPOTRunbookStepDetails ( $GUID ) {
    
    $StepDetailsData = @()
    if ($GUID -in $AllRunbookSteps.Keys) {
        # this is a runbookstep
        $RunbookStep = $AllRunbookSteps[$GUID]
        $Type = $RunbookStep.Type
        $StepDetailsData += @(
        [PSCustomObject]@{ Name = "Type";               Value = $Type;                                                    Type = "Step Parameters" },
        [PSCustomObject]@{ Name = "Name";               Value = $RunbookStep.Name;                                        Type = "Step Parameters" },
        [PSCustomObject]@{ Name = "Description";        Value = $RunbookStep.Description;                                 Type = "Step Parameters" },
        [PSCustomObject]@{ Name = "Sequence";           Value = $RunbookStep.Seq;                                         Type = "Step Parameters" },
        [PSCustomObject]@{ Name = "GUID";               Value = $RunbookStep.GUID;                                        Type = "Step Parameters" },
        [PSCustomObject]@{ Name = "Status";             Value = $RunbookStep.Status;                                      Type = "Step Parameters" },
        [PSCustomObject]@{ Name = "ContinueOnError";    Value = $RunbookStep.ContinueOnError;                             Type = "Step Parameters" },
        [PSCustomObject]@{ Name = "RetryCount";         Value = $RunbookStep.RetryCount;                                  Type = "Step Parameters" },
        [PSCustomObject]@{ Name = "RetryDelay";         Value = $RunbookStep.RetryDelay;                                  Type = "Step Parameters" },
        [PSCustomObject]@{ Name = "Disabled";           Value = $RunbookStep.Disabled;                                    Type = "Step Parameters" },
        [PSCustomObject]@{ Name = "Conditions";         Value = $RunbookStep.Conditions;                                  Type = "Step Parameters" },
        [PSCustomObject]@{ Name = "ArtefactsPath";      Value = $RunbookStep.ArtefactsPath;                               Type = "Step Parameters" },
        [PSCustomObject]@{ Name = "VariablesToPublish"; Value = $RunbookStep.StepParameters.VariablesToPublish -join ','; Type = "Step Parameters" },
        [PSCustomObject]@{ Name = "Command";            Value = $RunbookStep.StepParameters.CommandName;                  Type = "Step Parameters" }
        )
        # add extra potential details specific for RunbookSteps
        if ($Type -like "*Remote*") {
            $StepDetailsData += [PSCustomObject]@{ Name = "RemoteComputer" ; Value = $RunbookStep.StepParameters.RemoteComputer -join ','; Type = "Step Parameters" }
            $StepDetailsData += [PSCustomObject]@{ Name = "Credential" ;     Value = $RunbookStep.StepParameters.Credential.UserName ;     Type = "Step Parameters" }
        }
        if ($RunbookStep.StepParameters.CommandParameters) {
            foreach ($fParam in $RunbookStep.StepParameters.CommandParameters.GetEnumerator() ) {
                if ($fParam.Value) {
                    if ($fParam.Value.GetType().Name -eq "PSCredential") {
                        $StepDetailsData += [PSCustomObject]@{ Name = $fParam.Name ; Value = $fParam.Value.UserName ; Type = "Command Parameters" }
                        continue
                    }
                }
                $StepDetailsData += [PSCustomObject]@{ Name = $fParam.Name ; Value = $fParam.Value ; Type = "Command Parameters" }
            }
        }
    }
    elseif ($GUID -in $AllRunbooks.Keys) {
        # this is a runbook
        $RunbookStep = $AllRunbooks[$GUID]
        $Type = "Runbook"
        $StepDetailsData += @(
        [PSCustomObject]@{ Name = "Type";           Value = $Type;                        Type = "Step Parameters" },
        [PSCustomObject]@{ Name = "Name";           Value = $RunbookStep.Name;            Type = "Step Parameters" },
        [PSCustomObject]@{ Name = "Description";    Value = $RunbookStep.Description;     Type = "Step Parameters" },
        [PSCustomObject]@{ Name = "Sequence";       Value = $RunbookStep.Seq;             Type = "Step Parameters" },
        [PSCustomObject]@{ Name = "GUID";           Value = $RunbookStep.GUID;            Type = "Step Parameters" },
        [PSCustomObject]@{ Name = "Status";         Value = $RunbookStep.Status;          Type = "Step Parameters" },
        [PSCustomObject]@{ Name = "ContinueOnError";Value = $RunbookStep.ContinueOnError; Type = "Step Parameters" },
        [PSCustomObject]@{ Name = "Disabled";       Value = $RunbookStep.Disabled;        Type = "Step Parameters" },
        [PSCustomObject]@{ Name = "Conditions";     Value = $RunbookStep.Conditions;      Type = "Step Parameters" },
        [PSCustomObject]@{ Name = "ArtefactsPath";  Value = $RunbookStep.ArtefactsPath;   Type = "Step Parameters" }
        )
        # add extra potential details specific for Runbooks
        if ($RunbookStep.RemoteParameters) {
            foreach ($rParam in $RunbookStep.RemoteParameters.GetEnumerator() ) {
                if ($rParam.Value.GetType().Name -eq "PSCredential") {
                    $StepDetailsData += [PSCustomObject]@{ 
                        Name  = $rParam.Name; 
                        Value = $rParam.Value.UserName; 
                        Type  = "Remote Parameters" 
                    }
                }
                else {
                    $StepDetailsData += [PSCustomObject]@{ 
                        Name = $rParam.Name; 
                        Value = $rParam.Value;          
                        Type = "Remote Parameters" 
                    }
                }
            }
        }
        if ($RunbookStep.RunbookParameters) {
            foreach ($rbParam in $RunbookStep.RunbookParameters.GetEnumerator() ) {
                if ($rbParam.Value -as [string]) {
                    $StepDetailsData += [PSCustomObject]@{ 
                        Name  = $rbParam.Name; 
                        Value = $rbParam.Value -as [string];                
                        Type  = "Runbook Parameters" 
                    }
                }
                else {
                    $StepDetailsData += [PSCustomObject]@{ 
                        Name = $rbParam.Name; 
                        Value = $rbParam.Value.GetType().Name; 
                        Type = "Runbook Parameters" 
                    }
                }
            }
        }
    }
    
    # Clear previous details
    $window.Control_RunbookStepDetails.ItemsSource = $null

    # Create a CollectionView for the data and set up grouping
    $SDcollectionView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($StepDetailsData)
    $SDGD = New-Object System.Windows.Data.PropertyGroupDescription "Type"
    $SDcollectionView.GroupDescriptions.Add($SDGD)

    # set the label content
    $window.Control_LabelStep.Content = "RunbookStep: $($RunbookStep.Name)"

    # Set the ListView's ItemsSource to the collection view
    $window.Control_RunbookStepDetails.ItemsSource = $SDcollectionView

    # reset the column width
    $gridView = $window.Control_RunbookStepDetails.View -as [System.Windows.Controls.GridView]
    foreach ($column in $gridView.Columns) {
        # Set the width to 0 and then back to Auto
        $column.Width = 0
        $column.Width = [double]::NaN # NaN corresponds to 'Auto' in XAML
    }
}

function Update-SPOTRunbookNodeObjects ( $NodeObjects ) {
    
    foreach ($NodeObject in $NodeObjects) {
        if ($NodeObject.Children) {
            # this represents a Runbook object
            $Runbook = $AllRunbooks[$NodeObject.Tag]
            if ($NodeObject.IconPath -ne "$SPOTPath\res\$($Runbook.Status).png") {
                $NodeObject.IconPath = "$SPOTPath\res\$($Runbook.Status).png"
            }
            Update-SPOTRunbookNodeObjects -NodeObjects $NodeObject.Children
        }
        else {
            # this represents a RunbookStep object
            $RunbookStep = $AllRunbookSteps[$NodeObject.Tag]
            if ($NodeObject.IconPath -ne "$SPOTPath\res\$($RunbookStep.Status).png") {
                $NodeObject.IconPath = "$SPOTPath\res\$($RunbookStep.Status).png"
            }
        }
    }

}

function Prompt-SPOTMasterPassword {
    
    if ($syncHash.pwindow) {
        # the pWindow exists; make it appear
        
        ###################
        $syncHash.pwindow.TopMost = $true
        $syncHash.pwindow.ShowDialog()

        ###################
        # after closing the window, try to unlock the store with the given password, if not empty
        try {
            if (!$syncHash.pwindow.Control_InputBox.Password) {
                Write-SPOTConsole "ERROR: The provided Master Password is null or empty."
                Write-SPOTLog "GUI: ERROR: The provided Master Password is null or empty."
                return
            }
            elseif ($syncHash.pwindow.Control_Prestage.IsChecked) {
                Register-SPOTMasterPassword -Password $syncHash.pwindow.Control_InputBox.Password
                Unlock-SPOTSecretStore
            }
            else {
                Unlock-SPOTSecretStore -MasterPassword $syncHash.pwindow.Control_InputBox.Password
            }
        }
        catch {
            Write-SPOTConsole "ERROR: The SPOT secret store could not be unlocked with the provided Master Password."
            Write-SPOTLog "GUI: ERROR: The SPOT secret store could not be unlocked with the provided Master Password."
            return
        }
        ###################
        Write-SPOTConsole "The SPOT secret store was unlocked with the provided password."
        Write-SPOTLog "GUI: The SPOT secret store was unlocked with the provided password."

    }
    else {
        # the pWindow does not exist; create it
        [xml]$pxaml = @"
        <Window
            xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
            xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
            x:Name="PassWindow"
            Title="PassWindow"  
            AllowsTransparency="True" 
            WindowStyle="None"  
            Background="Transparent"
            Height="160" 
            Width="320">

            <Border CornerRadius="5" Background="#282c38" BorderBrush="#282c38" BorderThickness="2">
                <Grid Name="BaseGrid" Background="#282c38">
	             <Grid.RowDefinitions>
	              <RowDefinition Height="*" />
	             </Grid.RowDefinitions>
                    <Rectangle Name="DragArea" Grid.Row="0" Fill="Transparent" />
                    <StackPanel Grid.Row="0">
                        <TextBlock Name="Title" Text="Please provide the secret store Master Password!" FontSize="12" FontWeight="Bold" Foreground="White" Margin="10" HorizontalAlignment="Center" VerticalAlignment="Center" />
                        <PasswordBox Name="InputBox" Height="20" Width="150" Margin="10"/> 
                        <CheckBox Name="Prestage" Content='Prestage for later use' Foreground="White" HorizontalAlignment="Center" Margin="5"/>
                        <Button Name="OK" IsDefault="True" Height="25" Width="100" Content='OK' HorizontalAlignment="Center" Margin="10"/>
                    </StackPanel>   
                </Grid>
            </Border>
        </Window>
"@
        ### 
        $preader = (New-Object System.Xml.XmlNodeReader $pxaml)
        $pwindow = [Windows.Markup.XamlReader]::Load($preader)

        # get all named controls
        foreach ($pName in (            
            $pxaml |             
            Select-Xml '//*/@Name' |             
            foreach { $_.Node.Value}            
            )) {
            $pwindow | Add-Member NoteProperty -Name "Control_$pName" -Value $pwindow.FindName($pName) -Force          
        } 

        ###################
        # Attach the MouseLeftButtonDown event to the Rectangle to drag the window
        $pwindow.Control_DragArea.Add_MouseLeftButtonDown({
             $pwindow.DragMove()  # Allow dragging the window
         })
        # Attach the MouseLeftButtonDown event to the Title text to drag the window
        $pwindow.Control_Title.Add_MouseLeftButtonDown({
             $pwindow.DragMove()  # Allow dragging the window
         })
        # Attach the Click event to the OK button to close the popup window
        $pwindow.Control_OK.Add_Click({
            $pwindow.close()
        })

        ###################
        $pwindow.TopMost = $true
        $pwindow.ShowDialog()

        ###################
        # after closing the window, try to unlock the store with the given password, if not empty
        try {
            if (!$pwindow.Control_InputBox.Password) {
                Write-SPOTConsole "ERROR: The provided Master Password is null or empty."
                Write-SPOTLog "GUI: ERROR: The provided Master Password is null or empty."
                return
            }
            elseif ($pwindow.Control_Prestage.IsChecked) {
                Register-SPOTMasterPassword -Password $pwindow.Control_InputBox.Password
                Unlock-SPOTSecretStore
            }
            else {
                Unlock-SPOTSecretStore -MasterPassword $pwindow.Control_InputBox.Password
            }
        }
        catch {
            Write-SPOTConsole "ERROR: The SPOT secret store could not be unlocked with the provided Master Password."
            Write-SPOTLog "GUI: ERROR: The SPOT secret store could not be unlocked with the provided Master Password."
            return
        }
        ###################
        Write-SPOTConsole "The SPOT secret store was unlocked with the provided password."
        Write-SPOTLog "GUI: The SPOT secret store was unlocked with the provided password."

        ###################
        $global:syncHash.pwindow = $pwindow

    }

}

#endregion GUI functions

##############################################################
# get SPOT path
try {
    $SPOTPath = Get-SPOTPath
}
catch {
    Write-SPOTConsole "ERROR: while getting the SPOT path: $_. Cannot continue."
    # disable the Load Project button since there is no SPOT tool properly detected on this system
    $window.Control_LoadProject.IsEnabled = $false
}

# test for Initialized status
try {
    $SPOTStatus = Get-SPOTStatus
}
catch {
    if (($_.Exception.Message -like "*no master password provided*") -or ($_.Exception.Message -like "*error unlocking the secret store*")) {
        Write-SPOTConsole "Registered master password wrong or no registered master password. Asking for the master password."
        Write-SPOTLog "GUI: Registered master password wrong or no registered master password. Asking for the master password."
        Prompt-SPOTMasterPassword
        if (!(Get-SPOTSecretStoreState)) {
            Write-SPOTConsole "ERROR: The SPOT secrets could not be unlocked."
            Write-SPOTLog "GUI: ERROR: The SPOT secrets could not be unlocked."
            return
        }
        ###################
        $SPOTStatus = Get-SPOTStatus
    }
    else {
        Write-SPOTConsole "ERROR: while getting the SPOT status: $_. Cannot continue."
        return
    }
}

if ($SPOTStatus -ne "Initialized") {
    Write-SPOTConsole "ERROR: The SPOT tool is not initialized. Current status: $SPOTStatus. Cannot continue."
    # disable the Load Project button since the SPOT tool is not properly initialized on this system
    $window.Control_LoadProject.IsEnabled = $false
}

# load the internal SPOT classes to be available for any event handler defined later
. "$SPOTPath\classes\Classes.ps1"

# log user context
Write-SPOTConsole "Main Executing as user: $(whoami)."
Write-SPOTLog "GUI: Main Executing as user: $(whoami)."

##############################################################
# Add click event handler for the Load Project button
$window.Control_LoadProject.Add_Click({
    # Create and configure the FolderBrowserDialog
    $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderDialog.Description = "Select a SPOT project folder"
    $folderDialog.ShowNewFolderButton = $false

    # Show the dialog and get the result
    if ($folderDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        
        # set initial GUI status before the loading progress
        $Window.Control_LoadProject.IsEnabled = $false
        $Window.Control_LoadProject.Content = "Loading"
        $Window.Control_SmallProgressBar.Value = 0
        $Window.Control_ComboRunbook.SelectedValue = $null
        $Window.Control_ComboRunbook.IsEnabled = $false
        $Window.Control_ComboRunbook.ItemsSource = $null
        $Window.Control_LoadRunbook.IsEnabled = $false
        $window.Control_MainRunbook.ItemsSource = $null
        $window.Control_LoadedRunbook.Content = "Runbook:"
        $window.Control_LabelStep.Content = "RunbookStep:"
        $window.Control_RunbookStepDetails.ItemsSource = $null
        $window.Control_ProjectDetails.ItemsSource = $null

        $RunspaceScriptBlockParameters = @{
            ProjectPath = $folderDialog.SelectedPath
        }
        $RunspaceScriptBlock = {
            Param ($ProjectPath)

            # stamp all internal functions
            foreach ($funcName in $SFunctionNames) {
                (Get-Command -Name $funcName -CommandType Function -ErrorAction Stop).Description = "#SPOT"
            }

            # validate the SPOT path is available
            if (!$SPOTPath) {
                Write-SPOTConsole "ERROR: The SPOT tool was not detected properly: $SPOTPath. Cannot continue."
                # disable the Load Project button since there is no SPOT module path available
                $syncHash.window.Control_LoadProject.Dispatcher.invoke([action]{$syncHash.window.Control_LoadProject.IsEnabled = $false })
                return
            }

            # validate that this folder is a proper SPOT Project
            if (!(Validate-SPOTProjectFolder -TargetPath $ProjectPath)) {
                Write-SPOTConsole "ERROR: The target project folder does not seem to be a valid SPOT Project folder."
                Write-SPOTLog "GUI: ERROR: The target project folder does not seem to be a valid SPOT Project folder."
                $syncHash.window.Control_LoadProject.Dispatcher.invoke([action]{
                    $syncHash.window.Control_LoadProject.IsEnabled = $true
                    $syncHash.window.Control_LoadProject.Content = "Load Project"
                })
                return
            }

            #######################
            # unlock secret store to have access to the secret names for GUI display and later to the secrets to load them in the Runbooks
            try {
                if ($syncHash.pwindow.Control_InputBox.Password) {
                    Unlock-SPOTSecretStore -MasterPassword $syncHash.pwindow.Control_InputBox.Password
                }
                else {
                    Unlock-SPOTSecretStore
                }
            }
            catch {
                if (($_.Exception.Message -like "*no master password provided*") -or ($_.Exception.Message -like "*error unlocking the secret store*")) {
                    Write-SPOTConsole "Registered master password wrong or no registered master password. Asking for the master password."
                    Write-SPOTLog "GUI: Registered master password wrong or no registered master password. Asking for the master password."
                    Prompt-SPOTMasterPassword
                    if (!(Get-SPOTSecretStoreState)) {
                        Write-SPOTConsole "ERROR: The SPOT secrets could not be unlocked."
                        Write-SPOTLog "GUI: ERROR: The SPOT secrets could not be unlocked."
                        return
                    }
                }
                else {
                    Write-SPOTConsole "ERROR: while getting the SPOT status: $_. Cannot continue."
                    return
                }
            }

            #######################
            # check for secrets file and use it if present to refresh the Vault, using the master password if it was given earlier
            try {
                # import project secrets without master password since the store should be already unlocked from just before
                Import-SPOTProjectSecrets -ProjectPath $ProjectPath
            }
            catch {
                Write-SPOTConsole "ERROR: The SPOT secrets could not be refreshed."
                Write-SPOTLog "GUI: ERROR: The SPOT secrets could not be refreshed."
                return
            }
            
            ######################
            Set-SPOTSmallPG -percent 25
            #######################
            # initialize the SPOT variables with internal and project values
            try {
                Initialize-SPOTVariables -ProjectPath $ProjectPath
            }
            catch {
                Write-SPOTConsole "ERROR: The OrchVars could not be loaded."
                Write-SPOTLog "GUI: ERROR: The OrchVars could not be loaded."
                $syncHash.window.Control_LoadProject.Dispatcher.invoke([action]{
                    $syncHash.window.Control_LoadProject.IsEnabled = $true
                    $syncHash.window.Control_LoadProject.Content = "Load Project"
                })
                return
            }

            # load all project FunctionFiles
            foreach ($FunctionsFile in (Get-ChildItem -Path "$($OrchVars._ProjectPath)\_HelperFunctions")) {
                . $FunctionsFile.FullName
            }

            # load all SPOT Step functions
            . "$SPOTPath\SPOTStepFunctions.ps1"

            # overwrite SPOT Runbook functions (to be able to populate the runbook functions based on scriptlock file)
            . "$SPOTPath\SPOTRunbookFunctions.ps1"

            # get all project commands and define all project scripts as functions
            . Convert-SPOTProjectScriptsToFunctions

            # stamp all project functions
            foreach ($function in (Get-SPOTProjectFunctions)) {
                $function.Description = "#SPOT"
            }

            ###########################################
            # populate the list of Runbook functions (to be used to create inidividual runspaces for Runbook execution) 
            # and the list of Payload/Step functions (to be used for the Main Runspace Pool initial session state)
            # and the list of ProjectFunctions (to be used by the validations during runbook loading)
            $OrchVars._ProjectFunctions += (Get-SPOTProjectFunctions).Name
            $OrchVars._StepFunctions = @($OrchVars._ProjectFunctions) + ("Write-SPOTLog",
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
            $OrchVars._RunbookFunctions += (Get-Command | Where {($_.ScriptBlock.File -eq "$SPOTPath\SPOTRunbookFunctions.ps1")}).Name
            $OrchVars._RunbookFunctions = $OrchVars._RunbookFunctions | Select-Object -Unique

            ######################
            Set-SPOTSmallPG -percent 50
            #######################
            # load the project details in the GUI
            $ProjectDetailsData = @()
            $ProjectDetailsData += @( 
            [PSCustomObject]@{ Name = "Project Path";    Value = $OrchVars._ProjectPath;     Type = "Project Details"},
            [PSCustomObject]@{ Name = "SPOTPath";        Value = $OrchVars._SPOTPath;        Type = "Project Details"},
            [PSCustomObject]@{ Name = "AnyFailFail";     Value = $OrchVars._AnyFailFail;     Type = "Project Details"},
            [PSCustomObject]@{ Name = "RetryCount";      Value = $OrchVars._RetryCount;      Type = "Project Details"},
            [PSCustomObject]@{ Name = "RetryDelay";      Value = $OrchVars._RetryDelay;      Type = "Project Details"},
            [PSCustomObject]@{ Name = "VaultName";       Value = $OrchVars._VaultName;       Type = "Project Details"},
            [PSCustomObject]@{ Name = "ContinueOnError"; Value = $OrchVars._ContinueOnError; Type = "Project Details"},
            [PSCustomObject]@{ Name = "PsExecPath" ;     Value = $OrchVars._PsExecPath;      Type = "Project Details"},
            [PSCustomObject]@{ Name = "SshNetPath";      Value = $OrchVars._SshNetPath;      Type = "Project Details"},
            [PSCustomObject]@{ Name = "SPOTCapability";  Value = $OrchVars._SPOTCapability;  Type = "Project Details"},
            [PSCustomObject]@{ Name = "StepTimeout";     Value = $OrchVars._StepTimeout;     Type = "Project Details"},
            [PSCustomObject]@{ Name = "SPOTRsPoolMax";   Value = $OrchVars._SPOTRsPoolMax;   Type = "Project Details"},
            [PSCustomObject]@{ Name = "Debug";           Value = $OrchVars._Debug;           Type = "Project Details"}
            )

            # OrchVars
            foreach ($var in $OrchVars.GetEnumerator()) {
                if (!$var.Name.StartsWith("_") -and $var.Value.GetType().Name -ne "hashtable") {
                    if ($var.Value -as [string]) {
                        $ProjectDetailsData += [PSCustomObject]@{Name = $var.Name; Value = ($var.Value -as [string]); Type = "OrchVars Variables"}
                    }
                    else {
                        $ProjectDetailsData += [PSCustomObject]@{Name = $var.Name; Value = "[$($var.Value.GetType().Name)]"; Type = "OrchVars Variables"}
                    }
                }
            }

            # Secrets
            $VaultNamePrefix = "$($OrchVars._VaultName)%_%"
            foreach ($sec in $SVars.Keys) {
                $ProjectDetailsData += [PSCustomObject]@{Name = $sec; Value = "[$($SVars.$sec.GetType().Name)]"; Type = "Project Secrets"}
            }

            # Create a CollectionView for the data and set up grouping
            $collectionView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($ProjectDetailsData)
            $groupDescription = New-Object System.Windows.Data.PropertyGroupDescription "Type"
            $collectionView.GroupDescriptions.Add($groupDescription)

            $syncHash.window.Control_ProjectDetails.Dispatcher.invoke([action]{
                # Set the ListView's ItemsSource to the collection view
                $syncHash.window.Control_ProjectDetails.ItemsSource = $collectionView

                # reset the column width
                $gridView = $syncHash.window.Control_ProjectDetails.View -as [System.Windows.Controls.GridView]
                foreach ($column in $gridView.Columns) {
                    # Set the width to 0 and then back to Auto
                    $column.Width = 0
                    $column.Width = [double]::NaN # NaN corresponds to 'Auto' in XAML
                }
            })

            ######################
            Set-SPOTSmallPG -percent 75
            #######################
            # load the existing runbooks in the GUI
            $ExistingRunbooks = @()
            $ExistingRunbooks += (Get-ChildItem -Path "$ProjectPath\__SPOT_Runbooks" -Recurse -File -Include *.yaml).BaseName | Select-Object -Unique
            $syncHash.window.Control_ComboRunbook.Dispatcher.invoke([action]{
                $syncHash.window.Control_ComboRunbook.IsEnabled = $true
                $syncHash.window.Control_ComboRunbook.ItemsSource = $ExistingRunbooks
            })
            ######################
            Set-SPOTSmallPG -percent 100
            #######################
            # finished loading project
            Write-SPOTConsole "The SPOT project from the path ""$ProjectPath"" was loaded."
            Write-SPOTLog "GUI: The SPOT project from the path ""$ProjectPath"" was loaded."
            $syncHash.window.Control_LoadProject.Dispatcher.invoke([action]{
                $syncHash.window.Control_LoadProject.IsEnabled = $true
                $syncHash.window.Control_LoadProject.Content = "Load Project"
            })

            ############################################################
            # prepare the SessionState for future OffloadFunction executions now that all functions (Internal and Project) are available, as well as the OrchVars
            $SessionFunctions = Get-Command | Where {$_.Description -eq "#SPOT"}

            ######################################
            # Create initial session state
            $SessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
            foreach ($funcName in $SessionFunctions) {
                $func = Get-Command -Name $funcName -CommandType Function -ErrorAction Stop
                $SessionState.Commands.Add(
                    [System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($func.Name, $func.Definition)
                )
            }
            $SessionState.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new("SFunctionNames", $SessionFunctions.Name, "Injected SPOT Functions"))
            $SessionState.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new("SPOTPath", (Get-SPOTPath), "The path to the SPOT Module"))

            ######################
            # attach the OffloadFunction SessionState to the GUI synchronized hashtable
            $syncHash.SessionState = $SessionState

        }
        Offload-SPOTRunspace -RunspaceScriptBlockParameters $RunspaceScriptBlockParameters -RunspaceScriptBlock $RunspaceScriptBlock
        
    }
    #Write-Host "LoadProject event finished."
})

###################
# event handler for potential change of the runbook to be loaded
$window.Control_ComboRunbook.Add_DropDownClosed({
    if (!($window.Control_LoadedRunbook.Content -split ":")[1] -and ($window.Control_ComboRunbook.SelectedItem)) {
        $window.Control_LoadRunbook.IsEnabled = $true
    }
    if ((($window.Control_LoadedRunbook.Content -split ":")[1]) -and (($window.Control_LoadedRunbook.Content -split ":")[1] -ne $window.Control_ComboRunbook.SelectedItem)) {
        $window.Control_LoadRunbook.IsEnabled = $true
    }
    if ((($window.Control_LoadedRunbook.Content -split ":")[1]) -and (($window.Control_LoadedRunbook.Content -split ":")[1] -eq $window.Control_ComboRunbook.SelectedItem)) {
        $window.Control_LoadRunbook.IsEnabled = $false
    }
})

###################
# Event handler for the Load Runbook button
$window.Control_LoadRunbook.Add_Click({
    # get the selected runbook
    $SelectedRunbookName = $window.Control_ComboRunbook.SelectedItem

    # set initial GUI status before the loading progress
    $Window.Control_SmallProgressBar.Value = 0
    $Window.Control_LoadRunbook.Content = "Loading"
    $window.Control_LoadRunbook.IsEnabled = $false
    $Window.Control_LoadProject.IsEnabled = $false
    $window.Control_MainRunbook.ItemsSource = $null
    $window.Control_LoadedRunbook.Content = "Runbook:"
    $window.Control_LabelStep.Content = "RunbookStep:"
    $window.Control_RunbookStepDetails.ItemsSource = $null
    $window.Control_PublishedData.ItemsSource = $null
    $window.Control_StartStop.IsEnabled = $false

    # cleanup the existing runbook related objects
    $global:AllRunbooks = [hashtable]::Synchronized(@{})
    $global:AllRunbookSteps = [hashtable]::Synchronized(@{})
    $global:PublishedData = [hashtable]::Synchronized(@{})

    # prepare for offload
    $RunspaceScriptBlockParameters = @{
        SelectedRunbookName = $SelectedRunbookName
    }
    $RunspaceScriptBlock = {
        Param ($SelectedRunbookName)

        # validate the SPOT path is available
        if (!$SPOTPath) {
            Write-SPOTConsole "ERROR: The SPOTPath variable was empty inside the GUI runspace. Cannot continue."
            # disable the Load Project button since there is no SPOT path available at this point
            $syncHash.window.Control_LoadProject.Dispatcher.invoke([action]{$syncHash.window.Control_LoadProject.IsEnabled = $false })
            return
        }

        # load the runbook to have the objects available for validation here and for other handling in the main powershell session as well
        try {
            $RunbookGUID = Load-SPOTRunbook -Name $SelectedRunbookName -ArtefactsPath "$($OrchVars._ProjectPath)\__SPOT_Artefacts"
        }
        catch {
            Write-SPOTConsole "T.ERROR: The runbook ""$SelectedRunbookName"" failed to load: $_."
            Write-SPOTLog "GUI: T.ERROR: The runbook ""$SelectedRunbookName"" failed to load: $_."
            Set-SPOTSmallPG -percent 0
            $syncHash.window.Dispatcher.invoke([action]{
                $syncHash.window.Control_LoadProject.IsEnabled = $true
                $syncHash.window.Control_LoadRunbook.IsEnabled = $true
                $syncHash.window.Control_LoadRunbook.Content = "Load Runbook"
            })
            #return $false
            return
        }

        # extract relevant data from the runbooks to be loaded in the treeview
        $observableTreeData = [System.Collections.ObjectModel.ObservableCollection[TreeNode]](ConvertTo-SPOTTreeNodes -Runbook $AllRunbooks.$RunbookGUID -Main $true)

        # load the relevant data to the treeview, via the dispatcher
        $syncHash.window.Dispatcher.invoke([action]{
            $syncHash.window.Control_MainRunbook.ItemsSource = $observableTreeData
            $syncHash.window.Control_LoadedRunbook.Content = "Runbook: $SelectedRunbookName"
            $syncHash.window.Control_StartStop.IsEnabled = $true
            $syncHash.window.Control_StartStop.Content = "Start"
            $syncHash.window.Control_SmallProgressBar.Value = 100 
            $syncHash.window.Control_LoadRunbook.Content = "Load Runbook"
            $syncHash.window.Control_LoadRunbook.IsEnabled = $true
            $syncHash.Window.Control_LoadProject.IsEnabled = $true
        })
        
        #######################
        # finished loading project
        Write-SPOTConsole "The target runbook ""$SelectedRunbookName"" was loaded."
        Write-SPOTLog "GUI: The target runbook ""$SelectedRunbookName"" was loaded."
    }
    Offload-SPOTRunspace -RunspaceScriptBlockParameters $RunspaceScriptBlockParameters -RunspaceScriptBlock $RunspaceScriptBlock -SessionState $syncHash.SessionState
})

###################
# Event handler for the Start/Stop Runbook button
$window.Control_StartStop.Add_Click({
    $Action = $window.Control_StartStop.Content
    if ($Action -eq "Start") {
        # remove previous logs to start logging from scratch
        Remove-Item -Path "$($OrchVars._ProjectPath)\__SPOT_Artefacts\*" -Recurse -ErrorAction SilentlyContinue
        # initialize related controls
        $window.Control_ProgressBar.Value = 0
        $window.Control_StartStop.Content = "Stop"
        $window.Control_StartStop.IsEnabled = $true
        $window.Control_LoadRunbook.IsEnabled = $false
        $window.Control_LoadProject.IsEnabled = $false
        
        # get the loaded runbook 
        $TargetRunbookName = ($window.Control_LoadedRunbook.Content -split ":")[1].Trim()

        # prepare runbook offload
        $RunspaceScriptBlockParameters = @{
            TargetRunbookName = $TargetRunbookName
        }
        $RunspaceScriptBlock = {
            Param ($TargetRunbookName)
            
            # stamp all SPOT functions
            foreach ($funcName in $SFunctionNames) {
                (Get-Command -Name $funcName -CommandType Function -ErrorAction Stop).Description = "#SPOT"
            }

            # validate the SPOT path is available
            if (!$SPOTPath) {
                Write-SPOTConsole "ERROR: The SPOT path was not detected properly: $SPOTPath. Cannot continue."
                # disable the Load Project button since there is no SPOT module path available
                $syncHash.window.Control_LoadProject.Dispatcher.invoke([action]{$syncHash.window.Control_LoadProject.IsEnabled = $false })
                return
            }

            # get target runbook object
            $TargetRunbook = Get-SPOTRunbookByName -Name $TargetRunbookName

            # just before starting the main Runbook Job, start also the SPOT RunspacePool
            $global:_spot_MainWorkerPool = Create-SPOTRsPool -MaxNumber $OrchVars._SPOTRsPoolMax

            # log the beginnig of the execution
            Write-SPOTConsole "Starting runbook ""$($TargetRunbook.Name)"" execution."

            # launch runbook execution in a separate job
            $MainJob = Start-SPOTRunbookJob -GUID $TargetRunbook.GUID

            # wait a little for the dedicated runspace to start
            Start-Sleep -Seconds 4

            # check the status in a loop, until the orchestration is finished
            while ($true) {
                Start-Sleep -Seconds 5

                # progress report
                $CurrentStatus = [math]::floor(($AllRunbookSteps.Values.Where({($_.Status -eq "Completed") -or (($_.Status -eq "Error") -and ($_.ContinueOnError -eq $true))}).Count/$AllRunbookSteps.Values.Where({$_.Disabled -eq $false}).Count)*100)
                if ($CurrentStatus -ne $GUIStatus) {
                    $GUIStatus = $CurrentStatus
                    Set-SPOTMainPG -percent $GUIStatus
                }
                $syncHash.window.Control_MainRunbook.Dispatcher.invoke([action]{ Update-SPOTRunbookNodeObjects -NodeObjects $syncHash.window.Control_MainRunbook.Items })
                Update-SPOTPublishedData

                if ($MainJob.handle.IsCompleted) {break}
            } 

            # manage the runbook job
            Get-SPOTRunbookJobResult -RunbookJob $MainJob
            
            # one last cycle, to make sure there is no status missed
            $syncHash.window.Control_MainRunbook.Dispatcher.invoke([action]{ Update-SPOTRunbookNodeObjects -NodeObjects $syncHash.window.Control_MainRunbook.Items })
            Update-SPOTPublishedData

            # close and dispose the main worker pool
            $_spot_MainWorkerPool.Dispose()

            #######################
            # finished executing runbook
            # set actual progress here
            $CurrentStatus = [math]::floor(($AllRunbookSteps.Values.Where({($_.Status -eq "Completed") -or (($_.Status -eq "Error") -and ($_.ContinueOnError -eq $true))}).Count/$AllRunbookSteps.Values.Where({$_.Disabled -eq $false}).Count)*100)
            if ($CurrentStatus -ne $GUIStatus) {
                $GUIStatus = $CurrentStatus
                Set-SPOTMainPG -percent $GUIStatus
            }

            # if there are still steps in Initial state or steps in Error state that have the ContinueOnError disabled, rename button to Resume, else, rename the button to Start
            if (($AllRunbookSteps.Values.Where({($_.Status -eq "Initial") -and ($_.Disabled -eq $false)}).Count -ne 0) -or ($AllRunbookSteps.Values.Where({($_.Status -eq "Error") -and ($_.ContinueOnError -eq $false)}).Count -ne 0)) {
                $syncHash.window.Control_StartStop.Dispatcher.invoke([action]{
                    $syncHash.window.Control_StartStop.Content = "Resume" 
                    $syncHash.window.Control_StartStop.IsEnabled = $true
                    $syncHash.window.Control_LoadRunbook.IsEnabled = $true
                    $syncHash.window.Control_LoadProject.IsEnabled = $true
                })
                # interpret the main exit value
                if ($TargetRunbook.ExitValue -eq $false) {
                    Write-SPOTConsole "Runbook ""$($TargetRunbook.Name)"" execution paused and returned failure."
                }
                elseif ($TargetRunbook.ExitValue -eq $true) {
                    Write-SPOTConsole "Runbook ""$($TargetRunbook.Name)"" execution paused and returned success."
                }
            }
            else {
                # when completed, for a ReStart, load the runbook again to have it properly initialized; here, we stop the possible options to continue
                $syncHash.window.Control_StartStop.Dispatcher.invoke([action]{
                    $syncHash.window.Control_StartStop.Content = "Completed" 
                    $syncHash.window.Control_StartStop.IsEnabled = $false
                    $syncHash.window.Control_LoadRunbook.IsEnabled = $true
                    $syncHash.window.Control_LoadProject.IsEnabled = $true
                    })
                # interpret the main exit value
                if ($TargetRunbook.ExitValue -eq $false) {
                    Write-SPOTConsole "Runbook ""$($TargetRunbook.Name)"" execution finished and returned failure."
                }
                elseif ($TargetRunbook.ExitValue -eq $true) {
                    Write-SPOTConsole "Runbook ""$($TargetRunbook.Name)"" execution finished and returned success."
                }
            }
        }

        # launch runbook offload
        Offload-SPOTRunspace -RunspaceScriptBlockParameters $RunspaceScriptBlockParameters -RunspaceScriptBlock $RunspaceScriptBlock -SessionState $syncHash.SessionState
    
    }
    elseif ($Action -eq "Stop") {
        # activate the stop flag in the OrchVars
        $OrchVars._StopFlag = $true
        # disable and change the name of the button to Stopping, while waiting for all running jobs to finish and stop runbook processing
        $window.Control_StartStop.Content = "Stopping"
        $window.Control_StartStop.IsEnabled = $false

    }
    elseif ($Action -eq "Resume") {
        # deactivate the stop flag in the OrchVars
        $OrchVars._StopFlag = $false

        # change the button label to Stop and make sure it is active
        $window.Control_StartStop.Content = "Stop"
        $window.Control_StartStop.IsEnabled = $true
        $window.Control_LoadRunbook.IsEnabled = $false
        $window.Control_LoadProject.IsEnabled = $false

        # resume target runbook
        $TargetRunbookName = ($window.Control_LoadedRunbook.Content -split ":")[1].Trim()

        $RunspaceScriptBlockParameters = @{
            TargetRunbookName = $TargetRunbookName
        }
        $RunspaceScriptBlock = {
            Param ($TargetRunbookName)
            
            # stamp all SPOT functions
            foreach ($funcName in $SFunctionNames) {
                (Get-Command -Name $funcName -CommandType Function -ErrorAction Stop).Description = "#SPOT"
            }

            # validate the SPOT path is available
            if (!$SPOTPath) {
                Write-SPOTConsole "ERROR: The SPOT path was not detected properly: $SPOTPath. Cannot continue."
                # disable the Load Project button since there is no SPOT module path available
                $syncHash.window.Control_LoadProject.Dispatcher.invoke([action]{$syncHash.window.Control_LoadProject.IsEnabled = $false })
                return
            }
            
            # get target runbook object
            $TargetRunbook = Get-SPOTRunbookByName -Name $TargetRunbookName

            # just before starting the main Runbook Job, start also the SPOT RunspacePool
            $global:_spot_MainWorkerPool = Create-SPOTRsPool -MaxNumber $OrchVars._SPOTRsPoolMax

            # log the beginnig of the execution
            Write-SPOTConsole "Resuming runbook ""$($TargetRunbook.Name)"" execution."

            # resume runbook execution in a separate job
            $MainJob = Start-SPOTRunbookJob -GUID $TargetRunbook.GUID -Resume $true

            # wait a little for the dedicated runspace to start
            Start-Sleep -Seconds 4

            # check the status in a loop, until the orchestration is finished
            while ($true) {
                Start-Sleep -Seconds 5
                # progress report
                $CurrentStatus = [math]::floor(($AllRunbookSteps.Values.Where({($_.Status -eq "Completed") -or (($_.Status -eq "Error") -and ($_.ContinueOnError -eq $true))}).Count/$AllRunbookSteps.Values.Where({$_.Disabled -eq $false}).Count)*100)
                if ($CurrentStatus -ne $GUIStatus) {
                    $GUIStatus = $CurrentStatus
                    Set-SPOTMainPG -percent $GUIStatus
                }

                # load the relevant data to the treeview, via the dispatcher, if it has changed
                $syncHash.window.Control_MainRunbook.Dispatcher.invoke([action]{ Update-SPOTRunbookNodeObjects -NodeObjects $syncHash.window.Control_MainRunbook.Items })
                Update-SPOTPublishedData

                if ($MainJob.handle.IsCompleted) {break}
            } 

            # manage the runbook job
            Get-SPOTRunbookJobResult -RunbookJob $MainJob
            
            # one last cycle, to make sure there is no status missed
            $syncHash.window.Control_MainRunbook.Dispatcher.invoke([action]{ Update-SPOTRunbookNodeObjects -NodeObjects $syncHash.window.Control_MainRunbook.Items })
            Update-SPOTPublishedData

            # close and dispose the main worker pool
            $_spot_MainWorkerPool.Dispose()

            # interpret the main exit value
            if ($TargetRunbook.ExitValue -eq $false) {
                Write-SPOTConsole "Runbook ""$($TargetRunbook.Name)"" execution finished and returned failure."
                Write-SPOTLog "GUI: Runbook ""$($TargetRunbook.Name)"" execution finished and returned failure."
            }
            elseif ($TargetRunbook.ExitValue -eq $true) {
                Write-SPOTConsole "Runbook ""$($TargetRunbook.Name)"" execution finished and returned success."
                Write-SPOTLog "GUI: Runbook ""$($TargetRunbook.Name)"" execution finished and returned success."
            }

            #######################
            # finished executing runbook
            # set actual progress here
            $CurrentStatus = [math]::floor(($AllRunbookSteps.Values.Where({($_.Status -eq "Completed") -or (($_.Status -eq "Error") -and ($_.ContinueOnError -eq $true))}).Count/$AllRunbookSteps.Values.Where({$_.Disabled -eq $false}).Count)*100)
            if ($CurrentStatus -ne $GUIStatus) {
                $GUIStatus = $CurrentStatus
                Set-SPOTMainPG -percent $GUIStatus
            }

            # if there are still steps in Initial state or steps in Error state that have the CoontinueOnError disabled, rename button to Resume, else, rename the button to Start
            if (($AllRunbookSteps.Values.Where({$_.Status -eq "Initial"}).Count -ne 0) -or ($AllRunbookSteps.Values.Where({($_.Status -eq "Error") -and ($_.ContinueOnError -eq $false)}).Count -ne 0)) {
                $syncHash.window.Control_StartStop.Dispatcher.invoke([action]{
                    $syncHash.window.Control_StartStop.Content = "Resume" 
                    $syncHash.window.Control_StartStop.IsEnabled = $true
                    $syncHash.window.Control_LoadRunbook.IsEnabled = $true
                    $syncHash.window.Control_LoadProject.IsEnabled = $true
                })
            }
            else {
                # when completed, for a ReStart, load teh runbook again to have it properly initialized; here, we stop the possible options to continue
                $syncHash.window.Control_StartStop.Dispatcher.invoke([action]{
                    $syncHash.window.Control_StartStop.Content = "Completed" 
                    $syncHash.window.Control_StartStop.IsEnabled = $false
                    $syncHash.window.Control_LoadRunbook.IsEnabled = $true
                    $syncHash.window.Control_LoadProject.IsEnabled = $true
                    })
            }
        }

        # launch runbook offload
        Offload-SPOTRunspace -RunspaceScriptBlockParameters $RunspaceScriptBlockParameters -RunspaceScriptBlock $RunspaceScriptBlock -SessionState $syncHash.SessionState
    }
    else {
        Write-Host "WARNING: In this state: ""$Action"", the button should be disabled!!"
    }
})

###################
# Event handler for when a step is selected in the TreeView
$window.Control_MainRunbook.Add_SelectedItemChanged({
    $selectedItem = $window.Control_MainRunbook.SelectedItem
    if ($selectedItem) {
        Show-SPOTRunbookStepDetails $selectedItem.Tag
    }
})

###################
# Attach the MouseLeftButtonDown event to the Rectangle to drag the window
$window.Control_DragArea.Add_MouseLeftButtonDown({
     $window.DragMove()  # Allow dragging the window
 })

###################
# main button handlers
$window.Control_CloseButton.Add_MouseLeftButtonUp({
    $window.close()
})
$window.Control_MaximizeButton.Add_MouseLeftButtonUp({
    if ($window.WindowState -ne "Maximized") {
        $window.WindowState = "Maximized"
        $window.Control_MaximizeButton.ToolTip = "Normal"
    }
    else {
        $window.WindowState = "Normal"
        $window.Control_MaximizeButton.ToolTip = "Maximize"
    }
})
$window.Control_MinimizeButton.Add_MouseLeftButtonUp({
    $window.WindowState = "Minimized"
})

###################
$window.ShowDialog()

##########################################################################
Write-SPOTLog "===== Finished function Start-SPOTGUI. ====="

} # end of Start-SPOTGUI function

######################################################################################################################
function Show-SPOTCapability {
<#
.SYNOPSIS
Returns the current capability detected in the local SPOT PowerShell module.

.DESCRIPTION
Returns the current capability detected in the local SPOT PowerShell module, which may be either "Core" or "Extended".
The difference between the two is the presence of the additional tools PsExec and SshNet.

.INPUTS
None. You can't pipe objects to Show-SPOTCapability.

.OUTPUTS
System.String. Show-SPOTCapability may return only string output. 
#>
   
    ####################################################################
    Write-SPOTLog "===== Starting function Show-SPOTCapability. =====" -Output $false

    ####################################################################
    # Get the Tools Path first
    $toolsPath = Join-Path -Path (Get-SPOTPath) -ChildPath 'Tools'

    ####################################################################
    ### Check if the dependency tools are present
    # check psexec
    $PsExecPresent = $false
    if (Test-Path -Path "$toolsPath\psexec\PsExec64.exe" -PathType Leaf) {
        $PsExecPresent = $true
        Write-SPOTLog "The PsExec tool was detected." -Output $false
    }
    else {
        Write-SPOTLog "The PsExec tool was not detected." -Output $false
    }

    ####################################################################
    # check SshNet
    $SshNetPresent = $false
    if ((Test-Path -Path "$toolsPath\SshNet\BouncyCastle.Cryptography.dll" -PathType Leaf) -and `
        (Test-Path -Path "$toolsPath\SshNet\Microsoft.Bcl.AsyncInterfaces.dll" -PathType Leaf) -and `
        (Test-Path -Path "$toolsPath\SshNet\Microsoft.Extensions.Logging.Abstractions.dll" -PathType Leaf) -and `
        (Test-Path -Path "$toolsPath\SshNet\Renci.SshNet.dll" -PathType Leaf) -and `
        (Test-Path -Path "$toolsPath\SshNet\Renci.SshNet.pdb" -PathType Leaf) -and `
        (Test-Path -Path "$toolsPath\SshNet\Renci.SshNet.xml" -PathType Leaf) -and `
        (Test-Path -Path "$toolsPath\SshNet\SshNet.Security.Cryptography.dll" -PathType Leaf) -and `
        (Test-Path -Path "$toolsPath\SshNet\System.Buffers.dll" -PathType Leaf) -and `
        (Test-Path -Path "$toolsPath\SshNet\System.Formats.Asn1.dll" -PathType Leaf) -and `
        (Test-Path -Path "$toolsPath\SshNet\System.Management.Automation.dll" -PathType Leaf) -and `
        (Test-Path -Path "$toolsPath\SshNet\System.Memory.dll" -PathType Leaf) -and `
        (Test-Path -Path "$toolsPath\SshNet\System.Numerics.Vectors.dll" -PathType Leaf) -and `
        (Test-Path -Path "$toolsPath\SshNet\System.Runtime.CompilerServices.Unsafe.dll" -PathType Leaf) -and `
        (Test-Path -Path "$toolsPath\SshNet\System.Threading.Tasks.Extensions.dll" -PathType Leaf)) {
        $SshNetPresent = $true
        Write-SPOTLog "The SshNet tool was detected." -Output $false
    }
    else {
        Write-SPOTLog "The SshNet tool was not detected." -Output $false
    }

    ####################################################################
    Write-SPOTLog "===== Finished function Show-SPOTCapability. =====" -Output $false

    ####################################################################
    # return SPOT Capability (Core or Extended)
    if ($PsExecPresent -and $SshNetPresent) {
        return "Extended"
    }
    elseif ($SshNetPresent) {
        return "SshNet"
    }
    else {
        return "Core"
    }
} # end of Show-SPOTCapability function

######################################################################################################################
function Extend-SPOTCapability {
<#
.SYNOPSIS
Extends the capability of the local SPOT PowerShell module.

.DESCRIPTION
Extends the capability of the local SPOT PowerShell module, if initially the capability is "Core".
The extending can be done either directly from the internet, if the local computer is online, either using the previously downloaded tools PsExec and SshNet, packaged as zip files.
For the extending using Online mode, the TLS handling is automatically set to a "TrustAllCertsPolicy" in order to allow proper downloading with PowerShell 5.1.
This change is execution specific and does not remain active on the system.

.PARAMETER Online
Specifies the option to download and extend the SPOT capability with the PsExec and SshNet tools directly from the internet.

.PARAMETER PsToolsZipPath
Specifies the local zip file path containing the PsTools.

.PARAMETER PoshSSHZipPath
Specifies the local zip file path containing the SshNet.

.INPUTS
None. You can't pipe objects to Extend-SPOTCapability.

.OUTPUTS
System.String. Extend-SPOTCapability may return only logging output. 

.EXAMPLE
PS> Extend-SPOTCapability -Online
In this example the SPOT capability is extended by downloading the additional tools PsExec and SshNet from the internet.

.EXAMPLE
PS> Extend-SPOTCapability -PsToolsZipPath "C:\temp\PsTools.zip" -PoshSSHZipPath "C:\temp\SshNet.zip"
In this example the SPOT capability is extended using the previously downloaded tools PsExec and SshNet, packaged as zip files. 
#>

    [CmdletBinding(DefaultParameterSetName = 'OnlineSource')]
    Param (
        [Parameter(ParameterSetName = 'OnlineSource', Mandatory = $true)]
        [switch]
        # set the function to download the dependencies from the Internet
        $Online,
        [Parameter(ParameterSetName = 'LocalSource', Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # The path to the already downloaded PsTools zip file
        $PsToolsZipPath, 
        [Parameter(ParameterSetName = 'LocalSource', Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # The path to the already downloaded PoshSSH module zip file
        $PoshSSHZipPath
    )

    ####################################################################
    Write-SPOTLog "===== Starting function Extend-SPOTCapability. ====="

    # Get the current SPOT Capability
    $SPOTCapability = Show-SPOTCapability

    if ($SPOTCapability -eq "Extended") {
        Write-SPOTLog -Message "The current SPOT Capability is already ""Extended"". Nothing to do."
    }
    else {
        # get destination path
        $ToolsPath = Join-Path -Path $PSScriptRoot -ChildPath 'Tools'
        
        ####################
        # enable the zip handling
        Add-Type -Assembly "system.io.compression.filesystem"

        # download or use from local paths
        switch ($PSCmdlet.ParameterSetName) {
            'OnlineSource' {
                ############################################
                Write-SPOTLog "Downloading the tools for the extended SPOT capability."
                $continue = $true
                ### download and setup the tools
                
                ####################
                # set certificate trust to allow PowerShell 5.1 functionality
                Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint, 
        X509Certificate certificate,
        WebRequest request, 
        int certificateProblem) {
        return true;
    }
}
"@
                [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

                if ($SPOTCapability -eq "Core") {
                    ############################################
                    # SshNet not available
                    $PoshSSHURI = "https://www.powershellgallery.com/api/v2/package/Posh-SSH/3.2.7"
                    Write-SPOTLog ">>> Downloading the SshNet tool."
                    $TFP = [System.IO.Path]::GetTempFileName()
                    try {
                        Invoke-WebRequest -UserAgent "Wget" -Uri $PoshSSHURI -OutFile $TFP -ErrorAction Stop
                    }
                    catch {
                        Write-SPOTLog "ERROR: while downloading PoshSSH for the extended SPOT capability: $_."
                        $continue = $false
                    }
                    if ((Get-Item -Path $TFP -ErrorAction SilentlyContinue).Length -gt 0) {
                        # some content has been downloaded; moving on
                        $continue = $true
                        Write-SPOTLog ">>> Setting the SshNet tool."
                        $TempFolder = New-Item -ItemType Directory -Path ([System.IO.Path]::GetTempPath() + [System.IO.Path]::GetRandomFileName())
                        [io.compression.zipfile]::ExtractToDirectory($TFP,$TempFolder.FullName)
                        Remove-Item -Path $TFP -Confirm:$false -Force
                        try {
                            Copy-Item -Path "$($TempFolder.FullName)\Assembly\*" -Destination "$ToolsPath\SshNet" -Recurse -Confirm:$false -Force -ErrorAction Stop
                        }
                        catch {
                            Write-SPOTLog "ERROR: while copying the SshNet assembly files from the PoshSSH module archive: $_."
                            $continue = $false
                        }
                        Remove-Item -Path $TempFolder.FullName -Recurse -Confirm:$false -Force
                    }
                    else {
                        Write-SPOTLog "ERROR: the downloaded SSHNet tool file semms to be empty. Cannot extend with this tool."
                        $continue = $false
                    }
                }
                
                if ($continue) {
                    ############################################
                    # PSExec
                    $PSToolsURI = "https://download.sysinternals.com/files/PSTools.zip"
                    Write-SPOTLog ">>> Downloading the PsExec tool."
                    $TFP = [System.IO.Path]::GetTempFileName()
                    try {
                        Invoke-WebRequest -UserAgent "Wget" -Uri $PSToolsURI -OutFile $TFP -ErrorAction Stop
                    }
                    catch {
                        Write-SPOTLog "ERROR: while downloading PsExec for the extended SPOT capability: $_."
                    }
                    if ((Get-Item -Path $TFP -ErrorAction SilentlyContinue).Length -gt 0) {
                        # some content has been downloaded; moving on
                        Write-SPOTLog ">>> Setting the PsExec tool."
                        $TempFolder = New-Item -ItemType Directory -Path ([System.IO.Path]::GetTempPath() + [System.IO.Path]::GetRandomFileName())
                        [io.compression.zipfile]::ExtractToDirectory($TFP,$TempFolder.FullName)
                        Remove-Item -Path $TFP -Confirm:$false -Force
                        Get-ChildItem -Path $TempFolder.FullName -Recurse -File | Where {$_.Name -eq "psexec64.exe"} | `
                            Copy-Item -Destination "$ToolsPath\psexec\PsExec64.exe" -Confirm:$false -Force
                        Remove-Item -Path $TempFolder.FullName -Recurse -Confirm:$false -Force
                        # check EULA acceptance
                        Write-SPOTLog ">>> Managing the PsExec EULA. To use PsExec (Sysinternals, Microsoft) from SPOT, its EULA must be accepted."
                        if (Test-Path -Path "HKCU:\Software\Sysinternals\PsExec" -PathType Container) {
                            $InitialSysinternalsEula = (Get-ItemProperty -Path "HKCU:\Software\Sysinternals\PsExec" -ErrorAction SilentlyContinue).EulaAccepted
                        }
                        if ($InitialSysinternalsEula -eq "1") {
                            Write-SPOTLog ">>> PsExec EULA found already accepted. No need to trigger the pop-up window and accept it again."
                        }
                        else {
                            # trigger PsExec EULA
                            & "$ToolsPath\psexec\PsExec64.exe" cmd /c exit
                            # check EULA acceptance and revert the tool setup if not accepted
                            if (Test-Path -Path "HKCU:\Software\Sysinternals\PsExec" -PathType Container) {
                                $SysinternalsEula = (Get-ItemProperty -Path "HKCU:\Software\Sysinternals\PsExec" -ErrorAction SilentlyContinue).EulaAccepted
                            }
                            if ($SysinternalsEula -eq "1") {
                                Write-SPOTLog ">>> PsExec EULA accepted after setup."
                            }
                            else {
                                # revert the PsExec tool setup by deleting the file
                                Write-SPOTLog ">>> PsExec EULA acceptance not found in the registry after setup! Reverting PsExec setup."
                                Remove-Item -Path "$ToolsPath\psexec\PsExec64.exe" -Confirm:$false -Force
                            }
                        }
                    }
                    else {
                        Write-SPOTLog "ERROR: the downloaded PsExec tool file semms to be empty. Cannot extend with this tool."
                    }
                }
            }
            'LocalSource' {
                ############################################
                Write-SPOTLog "Using local tools for the extended SPOT capability."

                ############################################
                $LocalSourcesAvailable = $true
                if (!(Test-Path -Path $PsToolsZipPath -PathType Leaf)) {
                    Write-SPOTLog "ERROR: The PsTools path ""$PsToolsZipPath"" was not detected."
                    $LocalSourcesAvailable = $false
                }
                if (!(Test-Path -Path $PoshSSHZipPath -PathType Leaf)) {
                    Write-SPOTLog "ERROR: The PoshSSH path ""$PoshSSHZipPath"" was not detected."
                    $LocalSourcesAvailable = $false
                }

                if ($LocalSourcesAvailable) {
                    ############################################
                    # un-archive and copy the tools from local paths
                    $continue = $true
                    Add-Type -Assembly "system.io.compression.filesystem"
                    
                    if ($SPOTCapability -eq "Core") {
                        ############################################
                        # SshNet
                        Write-SPOTLog ">>> Setting the SshNet tool."
                        $TempFolder = New-Item -ItemType Directory -Path ([System.IO.Path]::GetTempPath() + [System.IO.Path]::GetRandomFileName())
                        [io.compression.zipfile]::ExtractToDirectory($PoshSSHZipPath,$TempFolder.FullName)
                        try {
                            Copy-Item -Path "$($TempFolder.FullName)\Assembly\*" -Destination "$ToolsPath\SshNet" -Recurse -Confirm:$false -Force -ErrorAction Stop
                        }
                        catch {
                            Write-SPOTLog "ERROR: while copying the SshNet assembly files from the PoshSSH module archive: $_."
                            $continue = $false
                        }
                        Remove-Item -Path $TempFolder.FullName -Recurse -Confirm:$false -Force
                    }
                    
                    if ($continue) {
                        ############################################
                        # PSExec
                        Write-SPOTLog ">>> Setting the PsExec tool."
                        $TempFolder = New-Item -ItemType Directory -Path ([System.IO.Path]::GetTempPath() + [System.IO.Path]::GetRandomFileName())
                        [io.compression.zipfile]::ExtractToDirectory($PsToolsZipPath,$TempFolder.FullName)
                        Get-ChildItem -Path $TempFolder.FullName -Recurse -File | Where {$_.Name -eq "psexec64.exe"} | `
                            Copy-Item -Destination "$ToolsPath\psexec\PsExec64.exe" -Confirm:$false -Force
                        Remove-Item -Path $TempFolder.FullName -Recurse -Confirm:$false -Force
                        # check EULA acceptance
                        Write-SPOTLog ">>> Managing the PsExec EULA. To use PsExec (Sysinternals, Microsoft) from SPOT, its EULA must be accepted."
                        if (Test-Path -Path "HKCU:\Software\Sysinternals\PsExec" -PathType Container) {
                            $InitialSysinternalsEula = (Get-ItemProperty -Path "HKCU:\Software\Sysinternals\PsExec" -ErrorAction SilentlyContinue).EulaAccepted
                        }
                        if ($InitialSysinternalsEula -eq "1") {
                            Write-SPOTLog ">>> PsExec EULA found already accepted. No need to trigger the pop-up window and accept it again."
                        }
                        else {
                            # trigger PsExec EULA
                            & "$ToolsPath\psexec\PsExec64.exe" cmd /c exit
                            # check EULA acceptance and revert the tool setup if not accepted
                            if (Test-Path -Path "HKCU:\Software\Sysinternals\PsExec" -PathType Container) {
                                $SysinternalsEula = (Get-ItemProperty -Path "HKCU:\Software\Sysinternals\PsExec" -ErrorAction SilentlyContinue).EulaAccepted
                            }
                            if ($SysinternalsEula -eq "1") {
                                Write-SPOTLog ">>> PsExec EULA accepted after setup."
                            }
                            else {
                                # revert the PsExec tool setup by deleting the file
                                Write-SPOTLog ">>> PsExec EULA acceptance not found in the registry after setup! Reverting PsExec setup."
                                Remove-Item -Path "$ToolsPath\psexec\PsExec64.exe" -Confirm:$false -Force
                            }
                        }
                    }
                }
                else {
                    ############################################
                    # log error and exit
                    Write-SPOTLog "ERROR: Some of the required local tool file paths are missing. Cannot continue."
                }
            }
        }
        ############################################
        # check again the SPOT Capability at the end
        $SPOTCapability = Show-SPOTCapability
        if ($SPOTCapability -eq "Extended") {
            Write-SPOTLog -Message "After extending, the SPOT Capability is fully ""Extended""."
        }
        elseif ($SPOTCapability -eq "SshNet") {
            Write-SPOTLog -Message "After extending, the SPOT Capability allows the use of ""SshNet""."
        }
        else {
            Write-SPOTLog -Message "ERROR: The SPOT Capability failed to extend."
        }
    }

    ####################################################################
    Write-SPOTLog "===== Finished function Extend-SPOTCapability. ====="

} # end of Extend-SPOTCapability function

######################################################################################################################
function Show-SPOTDetails {
<#
.SYNOPSIS
Returns the current details of the local SPOT PowerShell module.

.DESCRIPTION
Returns the current details of the local SPOT PowerShell module, which include data about SPOT version, SPOT status, SPOT capability, Secret Store status, additional tools versions.

.PARAMETER MasterPassword
Specifies the password to be used for unlocking the secret store, if it is not registered.

.INPUTS
None. You can't pipe objects to Show-SPOTDetails.

.OUTPUTS
System.String. Show-SPOTDetails may return only string output.
#>

    Param ( 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]
        # The password to be used for unlocking the secret store, if it is not prestaged
        $MasterPassword
        )

    ####################################################################
    Write-SPOTLog "===== Starting function Show-SPOTDetails. ====="

    ####################################################################
    # get the SPOT module path
    $SPOTPath = Get-SPOTPath
    $toolsPath = Join-Path -Path $SPOTPath -ChildPath 'Tools'

    ####################################################################
    # get SPOT details
    Write-SPOTLog "SPOT version       : $((Get-Module -Name SPOT).Version.ToString())"
    
    ###
    if ($MasterPassword) {
        $CurrentSPOTStatus = Get-SPOTStatus -MasterPassword $MasterPassword
    }
    else {
        $CurrentSPOTStatus = Get-SPOTStatus
    }
    Write-SPOTLog "SPOT Status        : $CurrentSPOTStatus"

    ###
    Write-SPOTLog "SPOT Capability    : $(Show-SPOTCapability)"
    
    ####################################################################
    # get SPOTSecretStore details
    $SPOT_SecretStore_Status = Get-SPOTSecretStoreStatus
    
    ###
    Write-SPOTLog "SPOT Secret Store  : $SPOT_SecretStore_Status"

    if ($SPOT_SecretStore_Status -eq "Initialized") {
        $SPOT_Init_Flag = Get-Secret -Name "_SPOT_INITIALIZATION_FLAG_" -Vault "SecretStore" -AsPlainText -ErrorAction SilentlyContinue
        $SPOT_Init_Date = [DateTimeOffset]::FromUnixTimeSeconds($SPOT_Init_Flag).ToString("yyyy-MM-ddTHH:mm:ssZ")
        
        ###
        Write-SPOTLog ">> Store.Init.Date : $SPOT_Init_Date"
    }

    ####################################################################
    # get tool details
    if (Test-Path -Path "$toolsPath\psexec\PsExec64.exe" -PathType Leaf) {
        $PsExec = Get-Item -Path "$toolsPath\psexec\PsExec64.exe"
        Write-SPOTLog "PsExec version     : $($PsExec.VersionInfo.FileVersion)"
    }
    else {
        Write-SPOTLog "PsExec not detected."
    }
    ###
    if (Test-Path -Path "$toolsPath\SshNet\Renci.SshNet.dll" -PathType Leaf) {
        $SshNet = Get-Item -Path "$toolsPath\SshNet\Renci.SshNet.dll"
        Write-SPOTLog "SshNet version     : $($SshNet.VersionInfo.FileVersion)"
    }
    else {
        Write-SPOTLog "SshNet not detected."
    }

    ####################################################################
    Write-SPOTLog "===== Finished function Show-SPOTDetails. ====="

} # end of Show-SPOTDetails function

######################################################################################################################
function Get-SPOTStatus {
<#
.SYNOPSIS
Gets the status of the local SPOT PowerShell module.

.DESCRIPTION
Check if the module files and prerequisistes for running SPOT are set on the local computer (firewall rules, PSSession setting, dependency modules).
The returned status may be Incomplete, MissingDependencies, NotInitialized or Initialized.

.PARAMETER MasterPassword
Specifies the password to be used for unlocking the secret store, if it is not registered.

.INPUTS
None. You can't pipe objects to Get-SPOTStatus.

.OUTPUTS
System.String. Get-SPOTStatus returns a status string. 
#>

    Param ( 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]
        # The password to be used for unlocking the secret store, if it is not prestaged
        $MasterPassword
        )
         
    ####################################################################
    Write-SPOTLog "===== Starting function Get-SPOTStatus. =====" -Output $false

    ####################################################################
    # get the SPOT module path
    $SPOTPath = Get-SPOTPath

    ####################################################################
    # check if the module is complete (script files, configs)
    ####################################################################
    $FileSet = $true
    if (!(Test-Path -Path "$SPOTPath\config\StepTypeDefinitions.yaml")) {
        Write-SPOTLog "ERROR: The file StepTypeDefinitions.yaml is missing from the config folder." -Output $false
        $FileSet = $false
    }
    if (!(Test-Path -Path "$SPOTPath\config\StepTemplates.yaml")) {
        Write-SPOTLog "ERROR: The file StepTemplates.yaml is missing from the config folder." -Output $false
        $FileSet = $false
    }
    if (!(Test-Path -Path "$SPOTPath\classes\Classes.ps1")) {
        Write-SPOTLog "ERROR: The file Classes.ps1 is missing from the classes folder." -Output $false
        $FileSet = $false
    }
    if (!(Test-Path -Path "$SPOTPath\res\completed.png")) {
        Write-SPOTLog  "ERROR: The file completed.png is missing from the res folder." -Output $false
        $FileSet = $false
    }
    if (!(Test-Path -Path "$SPOTPath\res\error.png")) {
        Write-SPOTLog  "ERROR: The file error.png is missing from the res folder." -Output $false
        $FileSet = $false
    }
    if (!(Test-Path -Path "$SPOTPath\res\executing.png")) {
        Write-SPOTLog  "ERROR: The file executing.png is missing from the res folder." -Output $false
        $FileSet = $false
    }
    if (!(Test-Path -Path "$SPOTPath\res\initial.png")) {
        Write-SPOTLog  "ERROR: The file initial.png is missing from the res folder." -Output $false
        $FileSet = $false
    }
    if (!(Test-Path -Path "$SPOTPath\res\skipped.png")) {
        Write-SPOTLog  "ERROR: The file skipped.png is missing from the res folder." -Output $false
        $FileSet = $false
    }
    if (!(Test-Path -Path "$SPOTPath\res\disabled.png")) {
        Write-SPOTLog  "ERROR: The file disabled.png is missing from the res folder." -Output $false
        $FileSet = $false
    }

    ####################################################################
    # check that all required modules are installed
    ####################################################################
    $DepModules = $true
    if (!(Get-Module -Name microsoft.powershell.secretmanagement -ListAvailable | Where {$_.Version -eq "1.1.2"})) {
        Write-SPOTLog "ERROR: The secretmanagement PowerShell Module version 1.1.2 is missing." -Output $false
        $DepModules = $false
    }
    #######
    if (!(Get-Module -Name microsoft.powershell.secretstore -ListAvailable | Where {$_.Version -eq "1.0.6"})) {
        Write-SPOTLog "ERROR: The secretstore PowerShell Module version 1.0.6 is missing." -Output $false
        $DepModules = $false
    }
    #######
    if (!(Get-Module -Name powershell-yaml -ListAvailable | Where {$_.Version -eq "0.4.12"})) {
        Write-SPOTLog "ERROR: The powershell-yaml PowerShell Module version 0.4.12 is missing." -Output $false
        $DepModules = $false
    }

    ####################################################################
    # check the PSRemoting local trust
    ####################################################################
    $PSRemoting = $true
    if ((Get-Item WSMan:\localhost\Client\TrustedHosts | Select-Object -ExpandProperty Value) -ne "*") {
        Write-SPOTLog "WARNING: The PSRemoting is not set to trust all hosts." -Output $false
        $PSRemoting = $false
    }

    # check the PSRemoting status
    ####
    if ((Get-Service | where {$_.Name -eq "WinRM"} | Select-Object -ExpandProperty Status) -ne "Running") {
        Write-SPOTLog "WARNING: The WinRM service is not running." -Output $false
        $PSRemoting = $false
    }
    ####
    if (!(Test-WSMan -ErrorAction SilentlyContinue)) {
        Write-SPOTLog "WARNING: The WSMan local endpoint is not enabled." -Output $false
        $PSRemoting = $false
    }
    ####
    $session = New-PSSession -ComputerName localhost -ErrorAction SilentlyContinue
    if (!($session)) {
        Write-SPOTLog "WARNING: The PSSessions are disabled locally." -Output $false
        $PSRemoting = $false
    }
    else {
        Remove-PSSession -Session $session -Confirm:$false
    }

    ####################################################################
    # check the firewall
    ####################################################################
    $FirewallStatus = $true
    if (!(Get-NetFirewallRule | Where {$_.DisplayName -eq "Allow TCP 5985/445/22/23 Outbound"})) {
        Write-SPOTLog "WARNING: The Firewall rule for TCP 5985/445/22/23 outbound access was not detected." -Output $false
        $FirewallStatus = $false
    }

    ####################################################################
    Write-SPOTLog "===== Finished function Get-SPOTStatus. =====" -Output $false

    ####################################################################
    # return status
    ####################################################################
    if (!$FileSet) {
        return "Incomplete"
    }
    elseif (!$DepModules) {
        return "MissingDependencies"
    }
    elseif (!$PSRemoting -or !$FirewallStatus) {
        return "NotInitialized"
    }
    else {
        return "Initialized"
    }

} # end of Get-SPOTStatus function

######################################################################################################################
function Register-SPOTMasterPassword {
<#
.SYNOPSIS
Registers a SPOT master password on the local computer.

.DESCRIPTION
Registers a SPOT master password on the local computer, in the "SPOTKey" environment variable.
The master password is specified in plain text, but it is registered as a secure string.

.PARAMETER Password
Specifies the plain text password to be registered on the local computer.

.INPUTS
None. You can't pipe objects to Register-SPOTMasterPassword.

.OUTPUTS
System.Bool. Register-SPOTMasterPassword may return only a boolean value, depending on the success of the function. 

.EXAMPLE
PS> Register-SPOTMasterPassword -Password "Passw0rd"
In this example, the password "Passw0rd" is registered on the local computer, in the "SPOTKey" environment variable.
#>

    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # The password to be prestaged, in plain text
        $Password 
        )
    
    # convert to secure string
    $SSPassword = ConvertTo-SecureString $Password -AsPlainText -Force

    # prestage the secure string in a user environment variable
    [Environment]::SetEnvironmentVariable("SPOTKey", "$($SSPassword | ConvertFrom-SecureString)", [System.EnvironmentVariableTarget]::User)

} # end of Register-SPOTMasterPassword function

######################################################################################################################
function Import-SPOTProjectSecrets {
<#
.SYNOPSIS
Imports in a project Secret Vault the secrets defined in a secrets project file.

.DESCRIPTION
Imports in a project Secret Vault the secrets defined in a secrets project file, which may be the default one or a custom one, specified by path.
The import may be done as an update where old secrets no longer provided in the secrets file are left in place, or as a replace from scratch,
where all existing secrets are deleted before importing the ones from the secrets file.
If the master password is not registered on the local computer, it must be specified as a parameter.

.PARAMETER ProjectPath
Specifies the path to the Project folder.

.PARAMETER MasterPassword
Specifies the password to be used for unlocking the secret store, if it is not registered.

.PARAMETER SecretsFilePath
Specifies the Path of the DevHelper.ps1 file generated by the current function.

.PARAMETER Cleanup
Specifies if the existing secrets from the Secret Vault should be deleted or not.

.INPUTS
None. You can't pipe objects to Import-SPOTProjectSecrets.

.OUTPUTS
None.

.EXAMPLE
PS> Import-SPOTProjectSecrets -ProjectPath "C:\test\project" -SecretsFilePath "C:\test\Secrets.yaml" -MasterPassword "Passw0rd" -Cleanup $true
In this example the SPOT Secret Vault for project "C:\test\project" is cleaned up and then populated with secret information from the custom file "C:\test\Secrets.yaml".
The MasterPassword is specified because, probably, it is not registered locally in the environment variable.

.EXAMPLE
PS> Import-SPOTProjectSecrets -ProjectPath "C:\test\project"
In this example the SPOT Secret Vault for project "C:\test\project" is populated (updated) with secret information from the default secrets file location "C:\test\project\__SPOT_Config\SInputs.yaml".
The MasterPassword is not specified because, probably, it is registered locally in the environment variable.
#>

    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the path to the Project folder
        $ProjectPath, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]
        # The password to be used for unlocking the secret store, if it is not prestaged
        $MasterPassword, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the (custom) path to the secrets file
        $SecretsFilePath, 
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [bool]
        # set the cleanup flag to make sure there will be no other secrets in the project vault besides the ones found in the source secrets file
        $Cleanup = $false 
        )

    # the function pushes inside the default SecretStore all secrets from the secrets file, if the secrets file is detected
    
    #################################################
    Write-SPOTLog "===== Starting function Import-SPOTProjectSecrets =====" -Output $false

    #################################################
    # handle the secrets file path; 
    if ($SecretsFilePath) {
        Write-SPOTLog "The SecretsFilePath parameter has been specified to $SecretsFilePath." -Output $false -DBG $true
    }
    else {
        $SecretsFilePath = "$ProjectPath\__SPOT_Config\SInputs.yaml"
        Write-SPOTLog "The SecretsFilePath parameter has NOT been specified. Using the default value: $SecretsFilePath." -Output $false -DBG $true
    }

    #################################################
    # before anything, check if the secrets file path is accessible
    if (!(Test-Path -Path $SecretsFilePath -PathType Leaf)) {
        Write-SPOTLog "The secret inputs file, ""$SecretsFilePath"", does not exist or it is not reachable. Nothing to do." -Output $false -DBG $true
        return
    }

    ###########################################
    # unlock the secrets store, if not already unlocked
    if (!(Get-SPOTSecretStoreState)) {
        # unlock the secret store
        if ($MasterPassword) {
            Unlock-SPOTSecretStore -MasterPassword $MasterPassword
        }
        else {
            Unlock-SPOTSecretStore
        }
        Write-SPOTLog "The SPOT secret store was unlocked." -Output $false -DBG $true
    }

    #################################################
    # get the Vault name prefix for the current project
    $ProjectConfigPath = "$ProjectPath\__SPOT_Config\OrchVars.yaml"

    # testing project config file path
    if (!(Test-Path -Path $ProjectConfigPath -PathType Leaf)) {
        Write-SPOTLog "ERROR: No project config file detected at the expected location: $ProjectConfigPath. Exiting." -Output $false
        throw "Import-SPOTProjectSecrets: OrchVars file not found!"
    }

    # load the project config file
    $ProjectConfigsRaw = Get-Content -Path $ProjectConfigPath -raw
    try {
        $ProjectConfigs = ConvertFrom-Yaml $ProjectConfigsRaw
    }
    catch {
        Write-SPOTLog "ERROR: while loading the yaml file $ProjectConfigPath. Error details: $_." -Output $false
        throw "Import-SPOTProjectSecrets: error loading OrchVars file!"
    }

    if (!$ProjectConfigs._VaultName) {
        Write-SPOTLog "INFO: The VaultName was not set in the Project Config. Using the default value of project name." -Output $false -DBG $true
        $VaultName = Split-Path -Path $ProjectPath -Leaf
    }
    else {
        $VaultName = $ProjectConfigs._VaultName
    }
    $VaultNamePrefix = "$($VaultName)%_%"

    #################################################
    # load secrets from yaml file
    $Secrets = Get-Content -Path $SecretsFilePath -raw
    try {
        $SecretsTable = ConvertFrom-Yaml $Secrets
    }
    catch {
        Write-SPOTLog "ERROR: while loading the yaml file $SecretsFilePath. Error details: $_." -Output $false
        throw "Import-SPOTProjectSecrets: error loading secrets file!"
    }

    #################################################
    # populate current secrets
    foreach ($Name in $($SecretsTable.Secrets.Keys)) {
        try {
            Set-Secret -Name "$VaultNamePrefix$Name" -Secret $SecretsTable.Secrets.$Name.Value
        }
        catch {
            Write-SPOTLog "ERROR: while trying to set new secret with name: $Name. The error was: $_. Cannot continue." -Output $false
            throw "Import-SPOTProjectSecrets: error loading secret!"
        }
    }

    #################################################
    # populate current credentials as secrets
    foreach ($Name in $($SecretsTable.Credentials.Keys)) {
        try {
            Set-Secret -Name "$VaultNamePrefix$Name" -Secret (New-Object -TypeName System.Management.Automation.PSCredential `
                -ArgumentList $SecretsTable.Credentials.$Name.Username,(ConvertTo-SecureString -String ($SecretsTable.Credentials.$Name.Password) -AsPlainText -Force))
        }
        catch {
            Write-SPOTLog "ERROR: while trying to set new credential secret with name: $Name. The error was: $_. Cannot continue." -Output $false
            throw "Import-SPOTProjectSecrets: error loading secret!"
        }
    }

    #################################################
    # remove any secrets from the Vault for the current project, that are not defined anymore in the project secrets file (secret cleanup)
    if ($Cleanup) {
        Write-SPOTLog "The Cleanup flag has been set. Performing cleanup against the current secrets file." -Output $false -DBG $true
        foreach ($i in (Get-SecretInfo | Where {$_.Name -like "$VaultNamePrefix*" -and $_.Type -eq "String"})) {
            if (($i.Name -split '%_%')[1] -notin $SecretsTable.Secrets.Keys) {
                # remove extra secret
                Write-SPOTLog "Removing extra secret named $(($i.Name -split '%_%')[1])." -Output $false -DBG $true
                Remove-Secret -Vault SecretStore -Name $i.Name -Confirm:$false
            }
        }
        foreach ($i in (Get-SecretInfo | Where {$_.Name -like "$VaultNamePrefix*" -and $_.Type -eq "PSCredential"})) {
            if (($i.Name -split '%_%')[1] -notin $SecretsTable.Credentials.Keys) {
                # remove extra secret
                Write-SPOTLog "Removing extra credential named $(($i.Name -split '%_%')[1])." -Output $false -DBG $true
                Remove-Secret -Vault SecretStore -Name $i.Name -Confirm:$false
            }
        }
    }

    #################################################
    Write-SPOTLog "===== Finished function Import-SPOTProjectSecrets =====" -Output $false

} # end of Import-SPOTProjectSecrets function

######################################################################################################################
function Initialize-SPOTSecretStore {
<#
.SYNOPSIS
Initializes the SPOT secret store on the local computer.

.DESCRIPTION
Initializes the SPOT secret store by resetting it with the master password provided or previously registered.
The reset of the secret store involves deleting all existing secret vaults, along with any secrets they may contain.
The secret store authentication is set to password authentication and the Password Timeout is set to 180 seconds.
The default SPOT secret vault, called "SecretStore" is created.
This secret vault contains all secrets from all initialized SPOT projects from the current computer and with the current user.

.PARAMETER MasterPassword
Specifies the password to be used for unlocking the secret store, usually if it is not registered.

.INPUTS
None. You can't pipe objects to Initialize-SPOTSecretStore.

.OUTPUTS
None. 

.EXAMPLE
PS> Initialize-SPOTSecretStore -MasterPassword "Passw0rd"
In this example the SPOT secret store is initialized with the master password "Passw0rd" which may not be registered locally in the environment variable.

.EXAMPLE
PS> Initialize-SPOTSecretStore
In this example the SPOT secret store is initialized with the already registered master password from the environment variable.
#>

    Param (
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]
        # The password to be used for initialization, in plain text
        $MasterPassword 
        )
    
    # this function deletes all secrets already existing, for all projects, sets the password to the prestaged or provided one and the timeout to the default 180 seconds value
    # should be executed only once during SPOT initialization (or when the master password is forgotten) per user per computer!!

    ########################################################
    Write-SPOTLog "===== Starting function Initialize-SPOTSecretStore. ====="
    Import-Module -Name microsoft.powershell.secretstore
    if (!(Get-Module -Name microsoft.powershell.secretstore)) {
        Write-SPOTLog "ERROR: The ""microsoft.powershell.secretstore"" powershell module was not detected locally. Cannot continue."
        throw "Initialize-SPOTSecretStore: error loading secretstore module!"
    }

    if ((Get-SPOTSecretStoreStatus) -ne "Initialized") {
        ########################################################
        # handle the Master Password
        if ($MasterPassword) {
            # the master password is available from parameter
            $SSMasterPassword = $MasterPassword | ConvertTo-SecureString -AsPlainText -Force
        }
        else {
            # get the SPOT master password from the current user environment variable
            if ('SPOTKey' -in [System.Environment]::GetEnvironmentVariables("User").Keys) {
                $SSMasterPassword = [System.Environment]::GetEnvironmentVariable('SPOTKey','User') | ConvertTo-SecureString
            }
            else {
                Write-SPOTLog "ERROR: The MasterPassword was not found to be prestaged as user environment variable. Cannot continue."
                throw "Initialize-SPOTSecretStore: missing prestaged master password!"
            }
        }

        ########################################################
        # reinitialize the secret store and sets its configuration to remain unlocked for 3 minutes after unlocking
        try {
            Reset-SecretStore -Password $SSMasterPassword -Scope CurrentUser -Authentication Password -PasswordTimeout 180 -Interaction None -Confirm:$false -Force
        }
        catch {
            Write-SPOTLog "ERROR: while resetting the SecretStore: $_."
            throw "Initialize-SPOTSecretStore: error resetting secret store!"
        }

        ########################################################
        # remove any existing SecretStore Vault
        try {
            Get-SecretVault | Where {$_.Name -eq "SecretStore"} | Unregister-SecretVault -Confirm:$false
        }
        catch {
            Write-SPOTLog "ERROR: while removing all existing Vaults: $_."
            throw "Initialize-SPOTSecretStore: error resetting secret store!"
        }

        ########################################################
        # create the default vault from scratch
        try {
            Register-SecretVault -Name SecretStore -DefaultVault -ModuleName Microsoft.PowerShell.SecretStore
        }
        catch {
            Write-SPOTLog "ERROR: while creating the default Vault: $_."
            throw "Initialize-SPOTSecretStore: error resetting secret store!"
        }
    
        ########################################################
        # unlock the secret vault after resetting
        Unlock-SecretStore -Password $SSMasterPassword

        ########################################################
        # add the SPOT secret for flagging the initialization
        Set-Secret -Name "_SPOT_INITIALIZATION_FLAG_" -Secret "$([DateTimeOffset]::Now.ToUnixTimeSeconds())" -Vault SecretStore
    }
    else {
         Write-SPOTLog " > The SPOT SecretStore is already initialized. Nothing to do."
    }

    ########################################################
    Write-SPOTLog "===== Finished function Initialize-SPOTSecretStore. ====="

} # end of Initialize-SPOTSecretStore function

######################################################################################################################
function Get-SPOTSecretStoreStatus {
<#
.SYNOPSIS
Returns the current status of the local SPOT SecretStore.

.DESCRIPTION
Returns the current status of the local SPOT SecretStore. It can be Initialized or NotInitialized.

.PARAMETER MasterPassword
Specifies the password to be used for unlocking the secret store, if it is not registered.

.INPUTS
None. You can't pipe objects to Get-SPOTSecretStoreStatus.

.OUTPUTS
System.String. Get-SPOTSecretStoreStatus may return only string output.
#> 

    Param ( 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]
        # The password to be used for unlocking the secret store, if it is not prestaged
        $MasterPassword
        )

    #################################
    if ((Get-SecretVault -ErrorAction SilentlyContinue | Where {$_.Name -eq "SecretStore"})) {
        #####################
        # unlock the secrets store, if not already unlocked
        if (!(Get-SPOTSecretStoreState)) {
            # unlock the secret store
            if ($MasterPassword) {
                Unlock-SPOTSecretStore -MasterPassword $MasterPassword
            }
            else {
                Unlock-SPOTSecretStore
            }
            Write-SPOTLog "The SPOT secret store was unlocked." -Output $false -DBG $true
        }

        #####################
        # get the SecretStore details
        $SSConfig = Get-SecretStoreConfiguration -ErrorAction SilentlyContinue
        if ($SSConfig.PasswordTimeout -eq "180") {
            $SPOT_Init_Flag = Get-Secret -Name "_SPOT_INITIALIZATION_FLAG_" -Vault "SecretStore" -ErrorAction SilentlyContinue
            if ($SPOT_Init_Flag) {
                return "Initialized"
            }
            else {
                return "NotInitialized"
            }
        }
        else {
            return "NotInitialized"
        }
    }
    else {
        return "NotInitialized"
    }

} # end of Get-SPOTSecretStoreStatus function

######################################################################################################################
function Get-SPOTProjectFunctionList {
<#
.SYNOPSIS
Gets the full list of SPOT functions available for use as step functions in a SPOT project.

.DESCRIPTION
The functions queries all functions defined in a SPOT project folder (scripts and helper functions) and adds also all built-in SPOT step functions.
Some user-defined functions may only be suitable as helper functions, specially from the helper function files. However, they will appear in the output from this function.
In the end, the user should be aware which ones are suitable as step functions and which ones are not. This functions returns all project functions available for runbook steps.
None of these functions are available/exported outside of the SPOT module since they may not be suitable for standalone use.

.PARAMETER ProjectPath
Specifies the path to the target Project folder.

.INPUTS
None. You can't pipe objects to Get-SPOTProjectFunctionList.

.OUTPUTS
[System.Object[]]. Get-SPOTProjectFunctionList returns an array of SPOT project System.Management.Automation.FunctionInfo objects.  

.EXAMPLE
PS> Get-SPOTProjectFunctionList -ProjectPath "C:\test\project"
In this example all functions available as step function for the SPOT project "C:\test\project" are queried.
#>

    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the path to the Project folder
        $ProjectPath 
    )
    
    $SPOTPath = Get-SPOTPath

    # get the full list of project step functions (including the built-in SPOT step functions, applicable to all projects)
    $SPOTPrjCommands = @()

    # load all project FunctionFiles
    foreach ($FunctionsFile in (Get-ChildItem -Path "$ProjectPath\_HelperFunctions" -Recurse -File -Include *.ps1)) {
        . $FunctionsFile.FullName
    }

    # load all project scripts and transform them into functions
    $ProjectScriptFiles = Get-ChildItem -Path "$ProjectPath\_Scripts" -Recurse | Where-Object {$_.Extension -eq ".ps1"}
    $ProjectScripts = @()
    foreach ($i in $ProjectScriptFiles) {
        $ProjectScripts += Get-Command -Name $i.FullName
    }
    foreach ($i in $ProjectScripts) {
        $ScriptName = $i.Name -replace ".ps1",""
        Set-Item "Function:\$ScriptName" ($i | Select-Object -ExpandProperty ScriptBlock)
    }

    # get all SPOT step functions and project functions together
    $SPOTPrjCommands += Get-Command | Where {$_.ScriptBlock.File -like "$ProjectPath*"}
    $SPOTPrjCommands += Get-Command | Where {$_.ScriptBlock.File -eq "$SPOTPath\SPOTStepFunctions.ps1"}

    # return the functions collection
    return $SPOTPrjCommands.Name

} # end of Get-SPOTProjectFunctionList function

######################################################################################################################
function Add-SPOTSSHTrustedHostKey {
<#
.SYNOPSIS
Inserts the details of a SSH key needed for key validation into an existing SPOT Trusted Hosts csv file.
If the referenced SPOT Trusted Hosts file does not exist or if is empty, it is first initialized as a SPOT Trusted Hosts csv file.

.DESCRIPTION
Depending on the parameters used, this script can insert the SSH key details based on:
1) KeyFile - a key file path is specified
2) KeyValues - the key type and SHA256 fingerprint values are specified
3) KeyObjects - an array of hashtable objects, each representing the details from a SSH Key to be added to the file
The Port value can be also specified but it is not mandatory. If not specified, the default value 22 is used.

.PARAMETER THFilePath
Specifies the path to the SPOT Trusted Hosts csv file. The file must not exist, in which case it will be initialized
with the provided key details as a first entry.
Mandatory and common for all ParameterSets.

.PARAMETER TargetHost
Specifies the target Hostname or IP Address used to initiate the SSH connection for which the SSH key will be verified.
For a successful match during verification, the same form must be used here as well as in the SSH connection.
Mandatory and common for all ParameterSets.

.PARAMETER Port
Specifies the SSH port number, specially for cases where it is not the default one.
Not mandatory and common for all ParameterSets.
Default value is 22.

.PARAMETER KeyFilePath
Specifies the path to a SSH Key file, copied over from a trusted target system. No encoding adaptations should be required on the key file.
Mandatory and specific for the "KeyFile" ParameterSet.

.PARAMETER KeyType
Specifies the SSH Key type to be added to the TrustedHosts file. It can be either: "ssh-rsa", "ssh-ed25519" or a value starting with "ecdsa-sha2-".
The value can be obtained from the SPOT log generated during a trusted SSH session to the desired target host. Sample log entry below:
INFO: SSH server key details: Host=>xx.xx.xx.xx,Port=>22,Type=>ssh-ed25519,SHA256Fingerprint=>xxxx....
Mandatory and specific for the "KeyValues" ParameterSet.

.PARAMETER KeyFingerprint
Specifies the SSH Key SHQ256 fingerprint to be added to the TrustedHosts file.
The value can be obtained from the SPOT log generated during a trusted SSH session to the desired target host. Sample log entry below:
INFO: SSH server key details: Host=>xx.xx.xx.xx,Port=>22,Type=>ssh-ed25519,SHA256Fingerprint=>xxxx....
Mandatory and specific for the "KeyValues" ParameterSet.

.PARAMETER KeyObjects
Specifies an array of one or multiple SSH Key hashtable objects that must contain the attributes "TargetHost","Port","KeyType","Fingerprint".
Mandatory and specific for the "KeyObjects" ParameterSet.

.PARAMETER Overwrite
Specifies the behavior for the cases when a different Fingerprint is already defined in the TrustedHosts csv file for the same TargetHost, Port and KeyType.
If Overwrite is set to true, when this conflict occurs the current entry will replace the existing entry and the function will return True (success).
If Overwrite is set to false, when this conflict occurs the function will just return False (failure) and not do any modifications.
Not mandatory and common for all ParameterSets.
Default value is False.

.INPUTS
None. You can't pipe objects to the SPOT-Installer script.

.OUTPUTS
System.Bool. True or False depending if the execution is successful or not. 

.EXAMPLE
Add-SPOTSSHTrustedHostKey -THFilePath "C:\SPOTProject\Files\TrustedHosts.csv" -TargetHost "10.20.30.40" -KeyFilePath "C:\temp\ssh_host_rsa_key.pub" -Overwrite $true
In this example, an existing SSH Key file, located here: "C:\temp\ssh_host_rsa_key.pub", is used to populate the SPOT TrustedHosts file located
here: "C:\SPOTProject\Files\TrustedHosts.csv". In case an entry for the same TargetHost (provided value "10.20.30.40") and Port (default value 22) is already
present in the file with a different Fingerprint, the function will overwrite the existing entry and will return True.

.EXAMPLE
Add-SPOTSSHTrustedHostKey -THFilePath "C:\SPOTProject\Files\TrustedHosts.csv" -TargetHost "10.20.30.40" -KeyType "ssh-ed25519" -KeyFingerprint "xxxx..."
In this example, SSH Key values for all needed SSH Key entry parameters are used to populate the SPOT TrustedHosts file located here: "C:\SPOTProject\Files\TrustedHosts.csv".
In case an entry for the same TargetHost (provided value "10.20.30.40"), Port (default value 22) and Key type (provided value "ssh-ed25519") is already present
in the file with a different Fingerprint than the provided one ("xxxx..."), the function will not overwrite the existing entry and will return False.
#>

    [CmdletBinding(DefaultParameterSetName = 'KeyFile')]
    Param (
        [Parameter(Mandatory, ParameterSetName = 'KeyFile')]
        [Parameter(Mandatory, ParameterSetName = 'KeyValues')]
        [Parameter(Mandatory, ParameterSetName = 'KeyObjects')]
        [ValidateNotNullOrEmpty()]
        [string]
        # the path to the TrustedHosts file
        $THFilePath, 
        [Parameter(Mandatory, ParameterSetName = 'KeyFile')]
        [Parameter(Mandatory, ParameterSetName = 'KeyValues')]
        [ValidateNotNullOrEmpty()]
        [string]
        # The Host to be added (hostname or IP Address)
        $TargetHost,
        [Parameter(ParameterSetName = 'KeyFile')]
        [Parameter(ParameterSetName = 'KeyValues')]
        [ValidateNotNullOrEmpty()]
        [int]
        # The port to be added (if not specified, the default port is used)
        $Port = 22,
        [Parameter(Mandatory, ParameterSetName = 'KeyFile')]
        [ValidateNotNullOrEmpty()]
        [string]
        # the SSH Key file
        $KeyFilePath,
        [Parameter(Mandatory, ParameterSetName = 'KeyValues')]
        [ValidatePattern('^(ssh-rsa|ssh-ed25519|ecdsa-sha2-.*)$')]
        [ValidateNotNullOrEmpty()]
        [string]
        # the type of the SSH Key
        $KeyType,
        [Parameter(Mandatory, ParameterSetName = 'KeyValues')]
        [ValidateNotNullOrEmpty()]
        [string]
        # the SSH Key SHQ256 fingerprint
        $KeyFingerprint,
        [Parameter(Mandatory, ParameterSetName = 'KeyObjects')]
        [ValidateNotNullOrEmpty()]
        [object[]]
        # The key object(s) with the details from one or multiple SSH Keys
        $KeyObjects,
        [Parameter(ParameterSetName = 'KeyFile')]
        [Parameter(ParameterSetName = 'KeyValues')]
        [Parameter(ParameterSetName = 'KeyObjects')]
        [ValidateNotNullOrEmpty()]
        [bool]
        # set the overwrite flag for cases when the same Host is already defined in the TrustedHosts file for the same Key Type but with different Fingerprint
        $Overwrite = $false 
    )

    #################################################
    Write-SPOTLog "===== Starting function Add-SPOTSSHTrustedHostKey =====" -Output $false

    ########################
    # check the THFile and initialize the TrustedHosts object array
    $RequiredProperties = @("TargetHost","Port","KeyType","Fingerprint")
    if (Test-Path -Path $THFilePath -PathType Leaf) {
        $THFilePath = (Get-Item -Path $THFilePath -ErrorAction Stop).FullName
        Write-SPOTLog " > TrustedHosts file path detected as ""$THFilePath""." -Output $false
        ###############
        $THContent = Get-Content -Path $THFilePath -Encoding UTF8 -ErrorAction SilentlyContinue
        if (!$THContent) {
            # if empty file detected, initialize from scratch
            Write-SPOTLog " > TrustedHosts file seems empty. Will be initialized." -Output $false
            $TrustedHostKeys = @()
        }
        elseif ($THContent.Count -ge 1) {
            $THHeaders = $THContent[0] -split ";" | ForEach-Object { $_.Trim().Trim('"').Trim("'") }
            $MissingProperties = $RequiredProperties | Where-Object { $_ -notin $THHeaders }
            $ExtraProperties   = $THHeaders | Where-Object { $_ -notin $RequiredProperties }
            if ($MissingProperties) {
                Write-SPOTLog " > ERROR: the TrustedHosts csv file is missing some required properties: $($MissingProperties -join ","). Cannot continue." -Output $false
                return $false
            }
            if ($ExtraProperties) {
                Write-SPOTLog " > WARNING: the TrustedHosts csv file has some extra properties: $($ExtraProperties -join ",")." -Output $false
            }
            ###############
            # check if there are already key objects in the file
            try {
                $TrustedHostKeys = @(Import-Csv -Path $THFilePath -Delimiter ";" -Encoding UTF8 -ErrorAction Stop)
            }
            catch {
                Write-SPOTLog " > ERROR: while loading the objects inside the TrustedHosts file in the provided path ""$THFilePath"": $_." -Output $false
                return $false
            }
            if (!$TrustedHostKeys) {
                # if no key objects detected, initialize from scratch
                Write-SPOTLog " > TrustedHosts file seems to have no objects. Will be initialized." -Output $false
                $TrustedHostKeys = @()
            }
            else {
                # validate the first detected oject
                $MissingObjectProperties = $RequiredProperties | Where-Object { $_ -notin $TrustedHostKeys[0].PSObject.Properties.Name }
                $ExtraObjectProperties   = $TrustedHostKeys[0].PSObject.Properties.Name | Where-Object { $_ -notin $RequiredProperties }
                if ($MissingObjectProperties) {
                    Write-SPOTLog " > ERROR: at least the first TrustedHosts object is missing some required properties: $($MissingObjectProperties -join ","). Cannot continue." -Output $false
                    return $false
                }
                if ($ExtraObjectProperties) {
                    Write-SPOTLog " > WARNING: at least the first TrustedHosts object has some extra properties: $($ExtraObjectProperties -join ",")." -Output $false
                }
            }
            
        }
    }
    else {
        ###############
        # if no file detected, create it and initialize from scrach
        Write-SPOTLog " > TrustedHosts file path not detected. Will be created from scratch." -Output $false
        try {
            New-Item -Path $THFilePath -ItemType File -Confirm:$false -Force -ErrorAction Stop | Out-Null
            $THFilePath = (Get-Item -Path $THFilePath -ErrorAction Stop).FullName
        }
        catch {
            Write-SPOTLog " > ERROR: while creating the TrustedHosts file in the provided path ""$THFilePath"": $_." -Output $false
            return $false
        }
        $TrustedHostKeys = @()
    }
    $NewTrustedHostKeys = @()

    ########################
    # process the key(s) based on parameter set
    switch ($PSCmdlet.ParameterSetName) {

        'KeyFile' {
            Write-SPOTLog " > Processing new entry based on key file." -Output $false
            ########################
            # check if the KeyFile exists and make sure the file path is absolute
            if (Test-Path -Path $KeyFilePath -PathType Leaf) {
                $KeyFilePath = (Get-Item -Path $KeyFilePath -ErrorAction Stop).FullName
                Write-SPOTLog " > Key file path detected as ""$KeyFilePath""." -Output $false
            }
            else {
                Write-SPOTLog " > ERROR: Key file path not detected. Cannot continue." -Output $false
                return $false
            }

            ########################
            # validate the KeyFile
            $PKL = (Get-Content -Path $KeyFilePath -Encoding UTF8).Trim()
            $PKLParts = $PKL -split ' '
            if ($PKLParts.Count -lt 2) {
                Write-SPOTLog " > ERROR: Invalid SSH public key format. Cannot continue." -Output $false
                return $false
            }
            $kType = $PKLParts[0]
            $base64Key = $PKLParts[1]
            if ($kType -notmatch '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-)') {
                Write-SPOTLog " > ERROR: Unsupported key type: $kType. Cannot continue." -Output $false
                return $false
            }
            $sha256 = [System.Security.Cryptography.SHA256]::Create()
            ########################
            # get SSH Key values from file
            $FingerPrint = [Convert]::ToBase64String($sha256.ComputeHash([Convert]::FromBase64String($base64Key)))
            $NewTrustedHostKeys += [pscustomobject]@{
                TargetHost = $TargetHost
                Port = $Port
                KeyType = $kType
                Fingerprint = $FingerPrint
            }
            
        }
        'KeyValues' {
            Write-SPOTLog " > Processing new entry based on key values." -Output $false
            ########################
            # get SSH Key values from parameter values
            $NewTrustedHostKeys += [pscustomobject]@{
                TargetHost = $TargetHost
                Port = $Port
                KeyType = $KeyType
                Fingerprint = $KeyFingerprint
            }
        }
        'KeyObjects' {
            foreach ($i in $KeyObjects) {
                $NewTrustedHostKeys += [pscustomobject]@{
                    TargetHost  = $i.TargetHost
                    Port        = $i.Port
                    KeyType     = $i.KeyType
                    Fingerprint = $i.Fingerprint
                }
            }
        }
    }

    ########################
    # inserting the new key object(s)
    foreach ($nKey in $NewTrustedHostKeys) {
        $PreExistingKey = $null
        Write-SPOTLog " > Processing new key with details: $($nKey.TargetHost), $($nKey.Port), $($nKey.KeyType) ,$($nKey.Fingerprint)." -Output $false
        $PreExistingKey = $TrustedHostKeys | Where {$_.TargetHost -eq $nKey.TargetHost -and $_.Port -eq $nKey.Port -and $_.KeyType -eq $nKey.KeyType}
        if ($PreExistingKey) {
            ##########
            # possile conflict detected
            if (@($PreExistingKey).Count -ne 1) {
                Write-SPOTLog " > ERROR: Multiple SSH keys of the same type for the same host and port detected in the TrustedHosts file: $($PreExistingKey.Fingerprint -join ","). Cannot continue." -Output $false
                return $false
            }
            else {
                if ($PreExistingKey.Fingerprint -eq $nKey.Fingerprint) {
                    Write-SPOTLog " > WARNING: The currently processed key is already present in the TrustedHosts file. Skipping it." -Output $false
                }
                else {
                    # the processed key already exists in the TrustedHosts file but it has a new fingerprint
                    if ($Overwrite) {
                        Write-SPOTLog " > WARNING: The currently processed key is already present in the TrustedHosts file with another Fingerprint. Overwriting it based on the Overwrite flag." -Output $false
                        $PreExistingKey.Fingerprint = $nKey.Fingerprint
                    }
                    else {
                        Write-SPOTLog " > WARNING: The currently processed key is already present in the TrustedHosts file with another Fingerprint: $($PreExistingKey.Fingerprint). Skipping it based on the Overwrite flag." -Output $false
                    }
                }
            }
        }
        else {
            # the current key does not exist in the TrustedHosts file; adding it now
            Write-SPOTLog " > The currently processed key does not exist in the TrustedHosts file. Adding it now." -Output $false
            $TrustedHostKeys += $nKey
        }
    }
    
    ########################
    # save the key objects back into the TrustedHosts file to update it
    Write-SPOTLog " > Saving the TrustedHostKeys objects to file now." -Output $false
    try {
        $TrustedHostKeys | Export-Csv -Path $THFilePath -NoTypeInformation -Delimiter ";" -Encoding UTF8 -Confirm:$false -Force
    }
    catch {
        Write-SPOTLog " > ERROR: while saving the updated TrustedHost objects back into the TrustedHosts file: $_." -Output $false
        return $false
    }
    
    #################################################
    Write-SPOTLog "===== Finished function Add-SPOTSSHTrustedHostKey =====" -Output $false
    return $true
} # end of Add-SPOTSSHTrustedHostKey function

######################################################################################################################