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