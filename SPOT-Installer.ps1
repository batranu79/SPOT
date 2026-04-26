# SPOT Installer Script 
# v1.0 - 26.04.2026 - initial version
#
#
#
######################################################################################################################

<#
.SYNOPSIS
Installs or updates the SPOT module on the current computer directly with Extended Capability (the extra tools in place for SSH commands and PsExec).
The PsExec EULA is triggered and if not previously accepted, it must be accepted for PsExec related functionality.

.DESCRIPTION
Depending on the parameters used, this script can perform any of the following actions:
1) install SPOT directly from the internet (for online installations, without the need for PowerShell repository);
2) install SPOT from a thick SPOT package (for isolated/offline environments);
3) create a thick SPOT package from the internet (for future offline installations in isolated/offline environments);

.PARAMETER InstallFromInternet
Specifies that the installation is to be performed online, using the internet as a source.
When this parameter is used, the 'SPOTVersion' parameter is optional.

.PARAMETER InstallFromSPOTPackage
Specifies that the installation is to be performed using a previously saved thick SPOT package as a source.
When this parameter is used, also the parameter 'SPOTPackagePath' needs to be provided.

.PARAMETER CreateSPOTPackage
Specifies that a thick SPOT package (for later use) shall be created, using the internet as a source.
When this parameter is used, also the parameter 'SPOTPackagePath' needs to be provided.
When this parameter is used, the 'SPOTVersion' parameter is optional.

.PARAMETER SPOTPackagePath
Specifies the path to the thick SPOT package, in order to be used as a source or to be created, depending on the context.
The thick SPOT package is always a zip archive file.

.PARAMETER SPOTVersion
Specifies the SPOT version desired to be installed. Useful for situations where a previous version is targeted.
Only 3 part version numbers are accepted or the value 'latest'. The value 'latest' is also implicit.
This parameter is not mandatory and if not used, the latest SPOT version will be targeted.
This parameter is usable next to 'InstallFromInternet' or 'CreateSPOTPackage' parameters.

.PARAMETER Extended
Specifies is the optional dependencies, PsExec and SshNet, will be installed or not.
The default value for this non-mandatory parameter is $true.
If the PsExec optional dependency is not desired, its installation can be avoided by declining the PsExec EULA, which is triggered automatically.

.INPUTS
None. You can't pipe objects to the SPOT-Installer script.

.OUTPUTS
System.String. SPOT-Installer may return only logging output. 

.EXAMPLE
PS> .\SPOT-Installer -InstallFromInternet -Extended $true
In this example the latest version of the SPOT module is installed online, from the internet, without using any repositories.
The optional dependencies, PsExec and SshNet, will be installed.

.EXAMPLE
PS> .\SPOT-Installer -InstallFromInternet -SPOTVersion 1.0.4
In this example the version 1.0.4 of the SPOT module is installed online, from the internet, without using any repositories.

.EXAMPLE
PS> .\SPOT-Installer -InstallFromSPOTPackage -SPOTPackagePath "C:\temp\ThickSPOTPackage.zip"
In this example the SPOT module is installed offline, using the provided thick SPOT package as a source.

.EXAMPLE
PS> .\SPOT-Installer -CreateSPOTPackage -SPOTPackagePath "C:\temp\ThickSPOTPackage.zip"
In this example a thick SPOT package is created, using the internet as a source.
#>

[CmdletBinding(DefaultParameterSetName = 'InstallFromInternet')]
param(
    [Parameter(Mandatory, ParameterSetName = 'InstallFromInternet')]
    [switch]$InstallFromInternet,

    [Parameter(Mandatory, ParameterSetName = 'InstallFromSPOTPackage')]
    [switch]$InstallFromSPOTPackage,

    [Parameter(Mandatory, ParameterSetName = 'CreateSPOTPackage')]
    [switch]$CreateSPOTPackage,

    # Common parameter for offline sets
    [Parameter(Mandatory, ParameterSetName = 'InstallFromSPOTPackage')]
    [Parameter(Mandatory, ParameterSetName = 'CreateSPOTPackage')]
    [ValidateNotNullOrEmpty()]
    [string]$SPOTPackagePath,

    # Common parameter for online sets
    [Parameter(ParameterSetName = 'InstallFromInternet')]
    [Parameter(ParameterSetName = 'CreateSPOTPackage')]
    [ValidateNotNullOrEmpty()]
    [string]$SPOTVersion = "latest",

    # Common parameter for install sets
    [Parameter(ParameterSetName = 'InstallFromInternet')]
    [Parameter(ParameterSetName = 'InstallFromSPOTPackage')]
    [bool]$Extended = $true
)

##############################
Write-Output "Starting SPOT-Installer script with the action ""$($PSCmdlet.ParameterSetName)""."

##############################
if ($PSCmdlet.ParameterSetName -in ('InstallFromInternet','CreateSPOTPackage')) {
    if ($SPOTVersion -ne "latest") {
        # validate the provided version number
        if ($SPOTVersion -notmatch '^\d+\.\d+\.\d+$') {
            Write-Output " > ERROR: the provided SPOT version is not valid ""$SPOTVersion"". It must be a 3 digit version number. Cannot continue."
            return $false
        }
    }
}

##############################
#region functions

function Extract-Archive {
    Param (
    [Parameter(Mandatory=$true)]
    [String]
    $TargetFolder, # The folder which will be archived
    [Parameter(Mandatory=$true)]
    [String]
    $ZipPath # The path to the Zip archive
    )

    # extract the archive
    Add-Type -Assembly "system.io.compression.filesystem"
    [io.compression.zipfile]::ExtractToDirectory($ZipPath,$TargetFolder)

}

function Create-Archive {
    Param (
    [Parameter(Mandatory=$true)]
    [String]
    $TargetFolder, # The folder which will be archived
    [Parameter(Mandatory=$true)]
    [String]
    $ZipPath # The path to the Zip archive
    )

    # create the archive
    Add-Type -Assembly "system.io.compression.filesystem"
    [io.compression.zipfile]::CreateFromDirectory($TargetFolder,$ZipPath)

} 

function Download-SPOTPackages {
    Param (
    [Parameter(Mandatory=$true)]
    [String]
    $TargetFolder # The folder where the packages will be downloaded
    )

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

    ####################
    # download SPOT
    Write-Output " > Downloading SPOT version ""$SPOTVersion""."
    if ($SPOTVersion -eq "latest") {
        # detect what latest means
        $SpotURILatest = "https://www.powershellgallery.com/api/v2/package/spot"
        try {
            Invoke-WebRequest -Uri $SpotURILatest -MaximumRedirection 0 -ErrorAction Stop
        }
        catch [System.Net.WebException] {
            $ex = $_.Exception
            if ($ex.Response) {
                $statusCode = [int]$ex.Response.StatusCode
                if ($statusCode -in 301,302,303,307,308) {
                    # this should be the redirect; getting the latest version number
                    $SPOTVersion = ($ex.Response.Headers["Location"] -split '/')[-1]
                    Write-Output " >> SPOT ""latest"" version translated to: $SPOTVersion."
                }
                else {
                    # unsuccessful status code returned
                    Write-Output " >> HTTP error while getting SPOT version data: $statusCode."
                    return $false
                }
            }
            else {
                # No HTTP response -> network issue
                Write-Output " >> Network error while getting SPOT version data: $($ex.Status)."
                return $false
            }
        }
        catch {
            # anything unexpected
            Write-Output " >> Unexpected error while getting SPOT version data: $_."
            return $false
        }
    }
    
    ######
    # use the given or latest detected SPOT version number
    $SpotURI = "https://www.powershellgallery.com/api/v2/package/spot/$SPOTVersion"
    
    ######
    try {
        Invoke-WebRequest -UserAgent "Wget" -Uri $SpotURI -OutFile "$TargetFolder\SPOT.$SPOTVersion.zip"
    }
    catch {
        Write-Output " >> ERROR: while downloading SPOT: $_."
        Write-Output " >> Cannot continue."
        Remove-Item -Path $TargetFolder -Recurse -Force -Confirm:$false
        return $false
    }

    ####################
    # download powershell-yaml 0.4.12
    Write-Output " > Downloading powershell-yaml version 0.4.12."
    $YamlURI = "https://www.powershellgallery.com/api/v2/package/powershell-yaml/0.4.12"
    try {
        Invoke-WebRequest -UserAgent "Wget" -Uri $YamlURI -OutFile "$TargetFolder\powershell-yaml.0.4.12.zip"
    }
    catch {
        Write-Output " >> ERROR: while downloading powershell-yaml: $_."
        Write-Output " >> Cannot continue."
        Remove-Item -Path $TargetFolder -Recurse -Force -Confirm:$false
        return $false
    }

    ####################
    # download secretstore 1.0.6
    Write-Output " > Downloading secretstore version 1.0.6."
    $SecStoreURI = "https://www.powershellgallery.com/api/v2/package/Microsoft.PowerShell.SecretStore/1.0.6"
    try {
        Invoke-WebRequest -UserAgent "Wget" -Uri $SecStoreURI -OutFile "$TargetFolder\microsoft.powershell.secretstore.1.0.6.zip"
    }
    catch {
        Write-Output " >> ERROR: while downloading secretstore: $_."
        Write-Output " >> Cannot continue."
        Remove-Item -Path $TargetFolder -Recurse -Force -Confirm:$false
        return $false
    }

    ####################
    # download secretmanagement 1.1.2
    Write-Output " > Downloading secretmanagement version 1.1.2."
    $SecMgmtURI = "https://www.powershellgallery.com/api/v2/package/Microsoft.PowerShell.SecretManagement/1.1.2"
    try {
        Invoke-WebRequest -UserAgent "Wget" -Uri $SecMgmtURI -OutFile "$TargetFolder\microsoft.powershell.secretmanagement.1.1.2.zip"
    }
    catch {
        Write-Output " >> ERROR: while downloading secretmanagement: $_."
        Write-Output " >> Cannot continue."
        Remove-Item -Path $TargetFolder -Recurse -Force -Confirm:$false
        return $false
    }

    ####################
    # download PSTools
    Write-Output " > Downloading PSTools."
    $PSToolsURI = "https://download.sysinternals.com/files/PSTools.zip"
    try {
        Invoke-WebRequest -UserAgent "Wget" -Uri $PSToolsURI -OutFile "$TargetFolder\PSTools.zip"
    }
    catch {
        Write-Output " >> ERROR: while downloading PSTools: $_."
        Write-Output " >> Cannot continue."
        Remove-Item -Path $TargetFolder -Recurse -Force -Confirm:$false
        return $false
    }

    ####################
    # download Posh-SSH 3.2.7
    Write-Output " > Downloading Posh-SSH version 3.2.7."
    $PoshSSHURI = "https://www.powershellgallery.com/api/v2/package/Posh-SSH/3.2.7"
    try {
        Invoke-WebRequest -UserAgent "Wget" -Uri $PoshSSHURI -OutFile "$TargetFolder\posh-ssh.3.2.7.zip"
    }
    catch {
        Write-Output " >> ERROR: while downloading Posh-SSH: $_."
        Write-Output " >> Cannot continue."
        Remove-Item -Path $TargetFolder -Recurse -Force -Confirm:$false
        return $false
    }

    ####################
    # Notepad++
    Write-Output " > Downloading Notepad++ version 8.7.5."
    $NppURI = "https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.7.5/npp.8.7.5.Installer.x64.exe"
    try {
        Invoke-WebRequest -UserAgent "Wget" -Uri $NppURI -OutFile "$TargetFolder\npp.8.7.5.Installer.x64.exe"
    }
    catch {
        Write-Output " >> ERROR: while downloading Notepad++: $_."
        Write-Output " >> Cannot continue."
        Remove-Item -Path $TargetFolder -Recurse -Force -Confirm:$false
        return $false
    }
}

function Install-SPOTPackages {
    Param (
    [Parameter(Mandatory=$true)]
    [String]
    $SourceFolder # The folder from where the packages will be installed
    )

    #########################################
    # install the packages
    Write-Output " > Installing the packages with Extended set to ""$Extended""."
    
    #########################################
    # detect the source folder and make path full
    if (Test-Path -Path $SourceFolder -PathType Container) {
        $SourceFolder = (Get-Item -Path $SourceFolder -ErrorAction Stop).FullName
    }
    else {
        Write-Output " >> The Source Folder ""$SourceFolder"" was not detected. Cannot continue."
        return $false
    }

    ####################
    # detect which SPOT version is available in the source folder
    $SPOTPackageItem = Get-ChildItem -Path $SourceFolder -Recurse -File | Where {$_.Name -like "SPOT.*.zip"} | Sort-Object -Descending | Select-Object -First 1
    if ($SPOTPackageItem) {
        $SPOTVersion = $SPOTPackageItem.BaseName.Substring(5)
    }
    else {
        Write-Output " >> No SPOT Package was detected inside the Source Folder ""$SourceFolder"". Cannot continue."
        return $false
    }

    ####################
    Write-Output " > Installing ""SPOT"" version ""$SPOTVersion""."
    $installSpot = $false
    $SpotModule = Get-Module -Name SPOT -ListAvailable | Where {$_.Version -eq $SPOTVersion}
    if ($SpotModule) {
        Write-Output " >> The PowerShell module ""SPOT"" detected as installed with the source version, ""$SPOTVersion""."
        if ($SpotModule.ModuleBase -eq "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion") {
            Write-Output " >> The PowerShell module ""SPOT"" detected as installed in the correct program location."
        }
        else {
            Write-Output " >> WARNING: The PowerShell module ""SPOT"" detected as installed, but in a different location as expected: $($SpotModule.ModuleBase)."
        }
    }
    else {
        Write-Output " >> The PowerShell module ""SPOT"" version ""$SPOTVersion"" was not detected as installed. Will install."
        $installSpot = $true
    }

    if ($installSpot) {
        if (Test-Path -Path "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion" -PathType Container) {
            Remove-Item -Path "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion" -Recurse -Force -Confirm:$false
        }
        Extract-Archive -ZipPath "$SourceFolder\SPOT.$SPOTVersion.zip" -TargetFolder "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion"
        Write-Output " >> The PowerShell module ""SPOT"" version ""$SPOTVersion"" was installed."
    }

    ####################
    Write-Output " > Installing ""powershell-yaml"" version ""0.4.12""."
    $installYaml = $false
    $YamlModule = Get-Module -Name powershell-yaml -ListAvailable | Where {$_.Version -eq "0.4.12"}
    if ($YamlModule) {
        Write-Output " >> The PowerShell module ""powershell-yaml"" detected as installed with the expected version, ""0.4.12""."
        if ($YamlModule.ModuleBase -eq "$env:ProgramFiles\WindowsPowerShell\Modules\powershell-yaml\0.4.12") {
            Write-Output " >> The PowerShell module ""powershell-yaml"" detected as installed in the correct program location."
        }
        else {
            Write-Output " >> WARNING: The PowerShell module ""powershell-yaml"" detected as installed, but in a different location as expected: $($YamlModule.ModuleBase)."
        }
    }
    else {
        Write-Output " >> The PowerShell module ""powershell-yaml"" version ""0.4.12"" was not detected as installed. Will install."
        $installYaml = $true
    }

    if ($installYaml) {
        if (Test-Path -Path "$env:ProgramFiles\WindowsPowerShell\Modules\powershell-yaml\0.4.12" -PathType Container) {
            Remove-Item -Path "$env:ProgramFiles\WindowsPowerShell\Modules\powershell-yaml\0.4.12" -Recurse -Force -Confirm:$false
        }
        Extract-Archive -ZipPath "$SourceFolder\powershell-yaml.0.4.12.zip" -TargetFolder "$env:ProgramFiles\WindowsPowerShell\Modules\powershell-yaml\0.4.12"
        Write-Output " >> The PowerShell module ""powershell-yaml"" version ""4.0.12"" was installed."
    }

    ####################
    Write-Output " > Installing ""microsoft.powershell.secretstore"" version ""1.0.6""."
    $installSecStore = $false
    $SecStoreModule = Get-Module -Name microsoft.powershell.secretstore -ListAvailable | Where {$_.Version -eq "1.0.6"}

    if ($SecStoreModule) {
        Write-Output " >> The PowerShell module ""microsoft.powershell.secretstore"" detected as installed with the expected version, ""1.0.6""."
        if ($SecStoreModule.ModuleBase -eq "$env:ProgramFiles\WindowsPowerShell\Modules\microsoft.powershell.secretstore\1.0.6") {
            Write-Output " >> The PowerShell module ""microsoft.powershell.secretstore"" detected as installed in the correct program location."
        }
        else {
            Write-Output " >> WARNING: The PowerShell module ""microsoft.powershell.secretstore"" detected as installed, but in a different location as expected: $($SecStoreModule.ModuleBase)."
        }
    }
    else {
        Write-Output " >> The PowerShell module ""microsoft.powershell.secretstore"" version ""1.0.6"" was not detected as installed. Will install."
        $installSecStore = $true
    }

    if ($installSecStore) {
        if (Test-Path -Path "$env:ProgramFiles\WindowsPowerShell\Modules\microsoft.powershell.secretstore\1.0.6" -PathType Container) {
            Remove-Item -Path "$env:ProgramFiles\WindowsPowerShell\Modules\microsoft.powershell.secretstore\1.0.6" -Recurse -Force -Confirm:$false
        }
        Extract-Archive -ZipPath "$SourceFolder\microsoft.powershell.secretstore.1.0.6.zip" -TargetFolder "$env:ProgramFiles\WindowsPowerShell\Modules\microsoft.powershell.secretstore\1.0.6"
        Write-Output " >> The PowerShell module ""microsoft.powershell.secretstore"" version ""1.0.6"" was installed."
    }
    
    ####################
    Write-Output " > Installing ""microsoft.powershell.secretmanagement"" version ""1.1.2""."
    $installSecMgmt = $false
    $SecMgmtModule = Get-Module -Name microsoft.powershell.secretmanagement -ListAvailable | Where {$_.Version -eq "1.1.2"}

    if ($SecMgmtModule) {
        Write-Output " >> The PowerShell module ""microsoft.powershell.secretmanagement"" detected as installed with the expected version, ""1.1.2""."
        if ($SecMgmtModule.ModuleBase -eq "$env:ProgramFiles\WindowsPowerShell\Modules\microsoft.powershell.secretmanagement\1.1.2") {
            Write-Output " >> The PowerShell module ""microsoft.powershell.secretmanagement"" detected as installed in the correct system location."
        }
        else {
            Write-Output " >> WARNING: The PowerShell module ""microsoft.powershell.secretmanagement"" detected as installed, but in a different location as expected: $($SecMgmtModule.ModuleBase)."
        }
    }
    else {
        Write-Output " >> The PowerShell module ""microsoft.powershell.secretmanagement"" version ""1.1.2"" was not detected as installed. Will install."
        $installSecMgmt = $true
    }

    if ($installSecMgmt) {
        if (Test-Path -Path "$env:ProgramFiles\WindowsPowerShell\Modules\microsoft.powershell.secretmanagement\1.1.2" -PathType Container) {
            Remove-Item -Path "$env:ProgramFiles\WindowsPowerShell\Modules\microsoft.powershell.secretmanagement\1.1.2" -Recurse -Force -Confirm:$false
        }
        Extract-Archive -ZipPath "$SourceFolder\microsoft.powershell.secretmanagement.1.1.2.zip" -TargetFolder "$env:ProgramFiles\WindowsPowerShell\Modules\microsoft.powershell.secretmanagement\1.1.2"
        Write-Output " >> The PowerShell module ""microsoft.powershell.secretmanagement"" version ""1.1.2"" was installed."
    }
    
    if ($Extended) {
        ####################
        # PsExec
        Write-Output " > Installing ""PsExec"" inside SPOT."

        if (Test-Path -Path "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion\tools\psexec\PsExec64.exe" -PathType Leaf) {
            Write-Output " >> The PsExec64.exe tool detected inside the SPOT module."
        }
        else {
            Write-Output " >> The PsExec64.exe tool not detected inside the SPOT module. Will install."
            # cleanup to start from scratch
            if (Test-Path -Path "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion\tools\psexec" -PathType Container) {
                Remove-Item -Path "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion\tools\psexec" -Recurse -Force -Confirm:$false
            }
            if (Test-Path -Path "$SourceFolder\PSTools" -PathType Container) {
                Remove-Item -Path "$SourceFolder\PSTools" -Recurse -Force -Confirm:$false
            }
            # extract
            Extract-Archive -ZipPath "$SourceFolder\PSTools.zip" -TargetFolder "$SourceFolder\PSTools"
            # copy only the needed files
            if (!(Test-Path -Path "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion\tools\psexec" -PathType Container)) {
                New-Item -Path "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion\tools\psexec" -ItemType Directory -Confirm:$false -Force | Out-Null
            }
            Get-ChildItem -Path "$SourceFolder\PSTools" -Recurse -File | Where {$_.Name -eq "PsExec64.exe"} | Copy-Item -Destination "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion\tools\psexec\PsExec64.exe" -Confirm:$false -Force
            Write-Output " >> The PsExec tool was installed inside the SPOT module."

            # trigger the PsExec EULA since this is an offline install and potential previous versions may have had only the Core capability
            Write-Output " >> Managing the PsExec EULA. To use PsExec (Sysinternals, Microsoft) from SPOT, its EULA must be accepted."
            if (Test-Path -Path "HKCU:\Software\Sysinternals\PsExec" -PathType Container) {
                $InitialSysinternalsEula = (Get-ItemProperty -Path "HKCU:\Software\Sysinternals\PsExec" -ErrorAction SilentlyContinue).EulaAccepted
            }
            if ($InitialSysinternalsEula -eq "1") {
                Write-Output " >> PsExec EULA found already accepted. No need to trigger the pop-up window and accept it again."
            }
            else {
                # trigger PsExec EULA
                & "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion\tools\psexec\PsExec64.exe" cmd /c exit
                # check EULA acceptance and revert the tool setup if not accepted
                if (Test-Path -Path "HKCU:\Software\Sysinternals\PsExec" -PathType Container) {
                    $SysinternalsEula = (Get-ItemProperty -Path "HKCU:\Software\Sysinternals\PsExec" -ErrorAction SilentlyContinue).EulaAccepted
                }
                if ($SysinternalsEula -eq "1") {
                    Write-Output " >> PsExec EULA accepted after setup."
                }
                else {
                    # revert the PsExec tool setup by deleting the file
                    Write-Output " >> PsExec EULA acceptance not found in the registry after setup! Reverting PsExec setup and continuing"
                    Remove-Item -Path "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion\tools\psexec\PsExec64.exe" -Confirm:$false -Force
                }
            }
        }

        ####################
        # SshNet
        Write-Output " > Installing ""SshNet"" inside SPOT."

        if ((Test-Path -Path "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion\tools\SshNet\BouncyCastle.Cryptography.dll" -PathType Leaf) -and `
            (Test-Path -Path "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion\tools\SshNet\Microsoft.Bcl.AsyncInterfaces.dll" -PathType Leaf) -and `
            (Test-Path -Path "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion\tools\SshNet\Microsoft.Extensions.Logging.Abstractions.dll" -PathType Leaf) -and `
            (Test-Path -Path "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion\tools\SshNet\Renci.SshNet.dll" -PathType Leaf) -and `
            (Test-Path -Path "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion\tools\SshNet\Renci.SshNet.pdb" -PathType Leaf) -and `
            (Test-Path -Path "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion\tools\SshNet\Renci.SshNet.xml" -PathType Leaf) -and `
            (Test-Path -Path "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion\tools\SshNet\SshNet.Security.Cryptography.dll" -PathType Leaf) -and `
            (Test-Path -Path "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion\tools\SshNet\System.Buffers.dll" -PathType Leaf) -and `
            (Test-Path -Path "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion\tools\SshNet\System.Formats.Asn1.dll" -PathType Leaf) -and `
            (Test-Path -Path "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion\tools\SshNet\System.Management.Automation.dll" -PathType Leaf) -and `
            (Test-Path -Path "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion\tools\SshNet\System.Memory.dll" -PathType Leaf) -and `
            (Test-Path -Path "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion\tools\SshNet\System.Numerics.Vectors.dll" -PathType Leaf) -and `
            (Test-Path -Path "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion\tools\SshNet\System.Runtime.CompilerServices.Unsafe.dll" -PathType Leaf) -and `
            (Test-Path -Path "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion\tools\SshNet\System.Threading.Tasks.Extensions.dll" -PathType Leaf)) {
            Write-Output " >> The SshNet tool detected inside the SPOT module."
        }
        else {
            Write-Output " >> The SshNet tool not detected inside the SPOT module. Will install."
            # cleanup to start from scratch
            if (Test-Path -Path "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion\tools\SshNet" -PathType Container) {
                Remove-Item -Path "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion\tools\SshNet" -Recurse -Force -Confirm:$false
            }
            if (Test-Path -Path "$SourceFolder\SshNet" -PathType Container) {
                Remove-Item -Path "$SourceFolder\SshNet" -Recurse -Force -Confirm:$false
            }
            # extract
            Extract-Archive -ZipPath "$SourceFolder\posh-ssh.3.2.7.zip" -TargetFolder "$SourceFolder\SshNet"
            # copy only the needed files
            if (!(Test-Path -Path "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion\tools\SshNet" -PathType Container)) {
                New-Item -Path "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion\tools\SshNet" -ItemType Directory -Confirm:$false -Force | Out-Null
            }
            Copy-Item -Path "$SourceFolder\SshNet\Assembly\*" -Destination "$env:ProgramFiles\WindowsPowerShell\Modules\SPOT\$SPOTVersion\tools\SshNet\" -Recurse -Confirm:$false -Force
            Write-Output " >> The SshNet tool was installed from posh-ssh version 3.2.7 inside the SPOT module."
        }
    }
    

    ####################
    # install Notepad++ as really necessary to edit all yaml files
    Write-Output " > Installing ""Notepad++""."

    if (!(Get-Package | Where {$_.Name -like "*Notepad++*"})) {
        Write-Output " >> The Nodepad++ not detected. Will install."
        # install notepad++
        $setup = (Get-ChildItem -Path $SourceFolder -Filter "*npp*Installer*.exe" | Select-Object -First 1).FullName
        $arguments = "/S"
        $proc = Start-Process $setup -ArgumentList $arguments -NoNewWindow -PassThru -Wait

        if (("0","3010") -notcontains $proc.ExitCode) {
            Write-Output " >> ERROR: Notepad++ installation failed with exit code: $($proc.ExitCode)"
        }
        else {
            Write-Output " >> Notepad++ was installed."
        }
    }
    else {
        Write-Output " >> The Notepad++ application is already installed."
    }
}

#endregion functions

switch ($PSCmdlet.ParameterSetName) {

    'InstallFromInternet' {
        ####################
        # check internet connectivity
        try {
            $response = Invoke-WebRequest -Uri "https://www.msftconnecttest.com/connecttest.txt" -UseBasicParsing -Method Head -TimeoutSec 5
        }
        catch {
            Write-Output "ERROR: while checking internet connectivity: $_."
            Write-Output "Cannot continue."
            return $false
        }

        ####################
        # create temp folder
        $TempFolder = New-Item -ItemType Directory -Path ([System.IO.Path]::GetTempPath() + [System.IO.Path]::GetRandomFileName())

        ####################
        # call the Download function
        Download-SPOTPackages -TargetFolder $TempFolder.FullName

        ####################
        # check if the download was successfull
        if (!(Test-Path -Path $TempFolder.FullName -PathType Container)) {
            Write-Output " >> There was an error while downloading the packages. Cannot continue."
            return $false
        }
        
        ####################
        # call the Install function
        Install-SPOTPackages -SourceFolder $TempFolder.FullName

        ####################
        # delete the temp folder
        Remove-Item -Path $TempFolder.FullName -Recurse -Force -Confirm:$false

        ####################
        Write-Output "Finished SPOT-Installer script with the action ""$($PSCmdlet.ParameterSetName)""."

    }

    'InstallFromSPOTPackage' {
        ####################
        # check the $SPOTPackagePath
        if (Test-Path -Path $SPOTPackagePath -PathType Leaf) {
            # transform to full path, if necessary
            $SPOTPackagePath = (Get-Item -Path $SPOTPackagePath).FullName
        }
        else {
            Write-Output "ERROR: the provided SPOT package path ""$SPOTPackagePath"" is not detected. Cannot continue."
            return $false
        }

        ####################
        # create temp folder
        $TempFolder = New-Item -ItemType Directory -Path ([System.IO.Path]::GetTempPath() + [System.IO.Path]::GetRandomFileName())

        ####################
        # extract the SPOT thick package
        Extract-Archive -ZipPath $SPOTPackagePath -TargetFolder $TempFolder.FullName

        ####################
        # call the Install function
        Install-SPOTPackages -SourceFolder $TempFolder.FullName

        ####################
        # delete the temp folder
        Remove-Item -Path $TempFolder.FullName -Recurse -Force -Confirm:$false

        ####################
        Write-Output "Finished SPOT-Installer script with the action ""$($PSCmdlet.ParameterSetName)""."

    }

    'CreateSPOTPackage' {
        ####################
        # check the $SPOTPackagePath
        if (Test-Path -Path $SPOTPackagePath -PathType Leaf) {
            Write-Output "The provided SPOT package path ""$SPOTPackagePath"" is detected. Cannot continue."
            return $false
        }

        ####################
        # create temp folder
        $TempFolder = New-Item -ItemType Directory -Path ([System.IO.Path]::GetTempPath() + [System.IO.Path]::GetRandomFileName())

        ####################
        # call the Download function
        Download-SPOTPackages -TargetFolder $TempFolder.FullName

        ####################
        # check if the download was successfull
        if (!(Test-Path -Path $TempFolder.FullName -PathType Container)) {
            Write-Output " >> There was an error while downloading the packages. Cannot continue."
            return $false
        }

        ####################
        # archive the SPOT thick package
        Create-Archive -TargetFolder $TempFolder.FullName -ZipPath $SPOTPackagePath

        ####################
        # delete the temp folder
        Remove-Item -Path $TempFolder.FullName -Recurse -Force -Confirm:$false

        ####################
        Write-Output "Finished SPOT-Installer script with the action ""$($PSCmdlet.ParameterSetName)""."

    }
}





