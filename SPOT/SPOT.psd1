# Module manifest for module 'SPOT'
# v1.0 - 26.04.2026 - initial version
#
#
#
######################################################################################################################

@{

    # Script module or binary module file associated with this manifest.
    RootModule = 'SPOT.psm1'

    # Version number of this module.
    ModuleVersion = '1.0.6'

    # ID used to uniquely identify this module
    GUID = '89e24a1f-8002-47bf-b97f-e49ea97cce04'

    # Author of this module
    Author = 'Narcis-Ionel Mircea'

    # Company or vendor of this module
    # CompanyName = ''

    # Copyright statement for this module
    # Copyright = ''

    # Description of the functionality provided by this module
    Description = 'Simple Powershell Orchestration Tool' 

    # Minimum version of the Windows PowerShell engine required by this module
    PowerShellVersion = '5.1'

    # Modules that must be imported into the global environment prior to importing this module
    RequiredModules = @(
            @{ ModuleName='microsoft.powershell.secretmanagement'; RequiredVersion='1.1.2' },
            @{ ModuleName='microsoft.powershell.secretstore';      RequiredVersion='1.0.6' },
            @{ ModuleName='powershell-yaml';                       RequiredVersion='0.4.12'})

    # Functions to export from this module
    FunctionsToExport = @('Initialize-SPOT',
                        'Initialize-SPOTProject',
                        'Show-SPOTCapability',
                        'Extend-SPOTCapability',
                        'Export-SPOTDevHelperFile',
                        'Start-SPOT',
                        'Start-SPOTGUI',
                        'Register-SPOTMasterPassword',
                        'Import-SPOTProjectSecrets',
                        'Initialize-SPOTSecretStore',
                        'Get-SPOTPath',
                        'Get-SPOTStatus',
                        'Show-SPOTDetails',
                        'Get-SPOTProjectFunctionList',
                        'Add-SPOTSSHTrustedHostKey')

    # Private data to pass to the module specified in RootModule/ModuleToProcess
    PrivateData = @{
        PSData = @{
           ProjectUri = 'https://github.com/batranu79/SPOT'
        }
    }

}