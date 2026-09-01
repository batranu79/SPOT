# Changelog

## [1.0.6] - 26.04.2026
- initial public version

## [1.1.0] - 17.05.2026

### Added
- New RunbookParameters feature
- New Replace-SPOTVarsInRunbookJIT and Replace-SPOTVarsInRunbookStepJIT (just in time replace functions)

### Changed
- The Execute-SSHScript and Execute-TelnetScript built-in step functions were updated to align with the new RunbookParameters feature
- Simplified the object constructors for the SPOT classes
- Changed Replace Vars and Validate functions related to Load-SPOTRunbook
- Enhancements in the Start-SPOTGUI function

### Fixed
- Fixed the Upload-FolderSFTP built-in step function recursive call
- Fixed single line step output in PowershellCommandRemote reported as failed
- Fixed Load-SPOTRunbook to return only $false when encountering an error loading the yaml file

## [1.1.1] - 03.07.2026

### Added
- several new public functions for SecretStore handling: Initialize-SPOTSecretStore, Get-SPOTSecretStoreStatus,Remove-SPOTProjectSecrets and Show-SPOTProjectSecretsInfo
- support for variable references (including mixed strings) inside VariablesToPublish entries
- AsSystem parameter for remote runbook execution with supporting ExecFunctions
- internal function Process-SPOTCommandParamsLocalRF

### Changed
- improved various functions internal and external functions (for overall better error handling)
- for WMI related step types the remote powershell process has been set to hidden
- improved the custom PSSessionConfiguration handling inside the PowershellCommandRemote type function
- enhancements in the Start-SPOTGUI function for better refresh
- removed some unnecessary functions and improved Runbook loading and validations

### Fixed
- the Finalize-SPOTRemoteExecution function to restore the initial state of the remote computer
- the Process-SPOTCommandParamsRF function 

## [1.1.2] - 31.08.2026

### Added
- two new SPOT Built-in step function: Reboot-LinuxComputer and Reboot-WindowsComputer
- support for WinRM over HTTPS in the type functions PowershellCommandRemote and PowershellCommandRemoteSJ (and implicitly in Runbook Remote Parameters)

### Changed
- small error handling correction in all SPOT Built-in step functions

