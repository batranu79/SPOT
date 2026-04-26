# SPOT Built-in Runbook Step Functions 
# v1.0 - 26.04.2026 - initial version
#
#
#
######################################################################################################################
function Set-FileExecutableSFTP {
<#
.SYNOPSIS
Adds execute permissions for everyone on a file from a remote Linux file system.

.DESCRIPTION
Connects remotely to a Linux computer over SFTP, checks the existence of the target file then adds execute permissions for everyone.
It depends on several SPOT functions, like Test-SPOTTCPPort, Write-SPOTLog, Get-SPOTSshNetPath and New-SPOTSFTPSession.

.PARAMETER TargetIP
Specifies the target IP Address or hostname on which to connect remotely.

.PARAMETER Port
Specifies the port to be used, in case it is different from the default

.PARAMETER FilePath
Specifies the path to the remote file to enable exe rights on.

.PARAMETER Credential
Specifies the SSH credentials to be used for remote authentication.

.PARAMETER TrustedHostsFilePath
Specifies the file path for a SPOT Trusted Hosts csv file to be used for SSH key validation.
If this parameter is not specified or empty, the SSH key validation is not enabled.

.PARAMETER OutputFlag
Sets the function to write output or not (true for executions as a step function; false for execution as part of another script/function).

.PARAMETER SshNetPath
Specifies the local path to the Renci.SSHNet.dll file.

.INPUTS
None. You can't pipe objects to Set-FileExecutableSFTP.

.OUTPUTS
System.String. Set-FileExecutableSFTP may return only logging output, or not. 

.EXAMPLE
PS> Set-FileExecutableSFTP -TargetIP "192.168.0.2" -FilePath "/root/test.sh" -Credential $PSCredential
In this example the file "/root/test.sh" from "192.168.0.2" is configured with execute permissions for everyone.
The logging is enabled by default and the path to the SshNet tool is not specified, as they should for a step function.

.EXAMPLE
PS> Set-FileExecutableSFTP -TargetIP "192.168.0.2" -FilePath "/root/test.sh" -Credential $PSCredential -OutputFlag $false -SshNetPath "C:\Program Files\WindowsPowerShell\Modules\SPOT\tools\SshNet\Renci.SshNet.dll"
In this example the file "/root/test.sh" from "192.168.0.2" is configured with execute permissions for everyone.
The logging is disabled and the path to the SshNet tool is specified, as they should for a helper function being used inside other function.
#>

    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the target IP Address or hostname on which to connect remotely 
        $TargetIP,
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int]
        # the port to be used, in case it is different from the default
        $Port = 22,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the path to the remote file to enable exe rights on
        $FilePath, 
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
        [bool]
        # set the function to write output or not (true for executions as a step payload; false for execution as part of another script/function)
        $OutputFlag = $true, 
        [Parameter(Mandatory=$false)]
        [string]
        # the local path to the Renci.SSHNet.dll file
        $SshNetPath 
        )

    #################################
    Write-SPOTLog "Starting function Set-FileExecutableSFTP for the target ""$TargetIP"" and FilePath ""$FilePath""." -Output $OutputFlag

    #################################
    # testing the availability of the TCP port on the remote computer
    $TCPTestResult = Test-SPOTTCPPort -TargetIP $TargetIP -TCPPort $Port
    if (!($TCPTestResult.TcpTestSucceeded)) {
        Write-SPOTLog "ERROR: The connectivity to the SSH port for host ""$TargetIP"" is not successfull. Ping test result was: $($TCPTestResult.PingSucceeded)." -Output $OutputFlag
        throw "Set-FileExecutableSFTP: SSH port unreachable!"
    }

    #################################
    # test/detect the local Renci.SSHNet.dll file
    $SshNetPath = Get-SPOTSshNetPath -SshNetPath $SshNetPath
    if (!$SshNetPath) {
        Write-SPOTLog "ERROR: The SshNetPath was not provided/determined/detected. Cannot continue."
        throw "Set-FileExecutableSFTP: SshNetPath not provided/determined/detected!"
    }

    #################################
    # connect over SFTP to the target IP
    $SFTPSession = New-SPOTSFTPSession -TargetIP $TargetIP -Port $Port -Credential $Credential -TrustedHostsFilePath $TrustedHostsFilePath -SshNetPath $SshNetPath
    if ($SFTPSession -eq $false) {
        Write-SPOTLog "ERROR: the SFTP Session could not be established. Cannot continue." -Output $OutputFlag
        throw "Set-FileExecutableSFTP: SFTP Session not established!"
    }

    #################################
    # test path existence
    $FilePathExists = $false
    if ($SFTPSession.Exists($FilePath)) {
        if (!$SFTPSession.GetAttributes($FilePath).IsDirectory) {
            $FilePathExists = $true
        }
    }
    if (!$FilePathExists) {
        Write-SPOTLog "ERROR: the remote file path $FilePath was not detected. Cannot continue." -Output $OutputFlag
        $SFTPSession.Disconnect()
        $SFTPSession.Dispose()
        throw "Set-FileExecutableSFTP: remote file path not detected!"
    }

    #################################
    # Get current permissions
    $attrs = $SFTPSession.GetAttributes($FilePath)

    # Add the execute permissions to the existing ones
    $attrs.OwnerCanExecute = $true
    $attrs.GroupCanExecute = $true
    $attrs.OthersCanExecute = $true

    # Apply the new permissions
    try {
        $SFTPSession.SetAttributes($FilePath, $attrs)
    }
    catch {
        Write-SPOTLog "ERROR: while trying to set the new permissions to the $FilePath file: $_." -Output $OutputFlag
        $SFTPSession.Disconnect()
        $SFTPSession.Dispose()
        throw "Set-FileExecutableSFTP: error while setting the new permissions!"
    }

    #################################
    # close the session and return 
    Write-SPOTLog "Finished function Set-FileExecutableSFTP for the target ""$TargetIP"" and FilePath ""$FilePath""." -Output $OutputFlag
    $SFTPSession.Disconnect()
    $SFTPSession.Dispose()

} # end of Set-FileExecutableSFTP function

######################################################################################################################
function Download-FileSFTP {
<#
.SYNOPSIS
Downloads a file from a remote Linux file system over SFTP.

.DESCRIPTION
Connects remotely to a Linux computer over SFTP, checks the existence of the target file then downloads it locally if the file is not already present locally.
The local file existence check is based on file size.
If the parent folder of the local path does not exit, it will be created.
It depends on several SPOT functions, like Test-SPOTTCPPort, Write-SPOTLog, Get-SPOTSshNetPath and New-SPOTSFTPSession.

.PARAMETER TargetIP
Specifies the IP Address or hostname of the SFTP server from which to download the file.

.PARAMETER Port
Specifies the port to be used, in case it is different from the default

.PARAMETER RemotePath
Specifies the path of the file to be downloaded, on the remote system (from where?).

.PARAMETER LocalPath
Specifies the local path where the file shall be downloaded to, on the local system (where to?).

.PARAMETER Credential
Specifies the credential to connect to the remote system.

.PARAMETER TrustedHostsFilePath
Specifies the file path for a SPOT Trusted Hosts csv file to be used for SSH key validation.
If this parameter is not specified or empty, the SSH key validation is not enabled.

.PARAMETER OutputFlag
Sets the function to write output or not (true for executions as a step function; false for execution as part of another script/function).

.PARAMETER SshNetPath
Specifies the local path to the Renci.SSHNet.dll file.

.INPUTS
None. You can't pipe objects to Download-FileSFTP.

.OUTPUTS
System.String. Download-FileSFTP may return only logging output, or not. 

.EXAMPLE
PS> Download-FileSFTP -TargetIP "192.168.0.2" -RemotePath "/root/test.sh" -LocalPath "C:\temp\test.sh" -Credential $PSCredential
In this example the remote file "/root/test.sh" from "192.168.0.2" is downloaded locally in "C:\temp\test.sh".
The logging is enabled by default and the path to the SshNet tool is not specified, as they should for a step function.

.EXAMPLE
PS> Download-FileSFTP -TargetIP "192.168.0.2" -RemotePath "/root/test.sh" -LocalPath "C:\temp\test.sh" -Credential $PSCredential -OutputFlag $false -SshNetPath "C:\Program Files\WindowsPowerShell\Modules\SPOT\tools\SshNet\Renci.SshNet.dll"
In this example the remote file "/root/test.sh" from "192.168.0.2" is downloaded locally in "C:\temp\test.sh".
The logging is disabled and the path to the SshNet tool is specified, as they should for a helper function being used inside other function.
#>

    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the IP Address or hostname of the SFTP server from which to download the file
        $TargetIP,
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int]
        # the port to be used, in case it is different from the default
        $Port = 22,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the path of the file to be downloaded, on the remote system (from where?)
        $RemotePath, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the local path where the file shall be downloaded to, on the local system (where to?)
        $LocalPath, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.Management.Automation.PSCredential]
        # the credential to connect to the remote system
        $Credential,
        [Parameter(Mandatory=$false)]
        [AllowNull()]
        [string]
        # the path to the TrustedHosts file
        $TrustedHostsFilePath,
        [Parameter(Mandatory=$false)]
        [bool]
        # set the function to write output or not (true for executions as a step payload; false for execution as part of another script/function)
        $OutputFlag = $true, 
        [Parameter(Mandatory=$false)]
        [string]
        # the local path to the Renci.SSHNet.dll file
        $SshNetPath 
        )
    
    ###
    Write-SPOTLog "Starting function Download-FileSFTP with the parameters: TargetIP ""$TargetIP"", RemotePath ""$RemotePath"", LocalPath ""$LocalPath"", Credential ""$($Credential.UserName)""." -Output $OutputFlag

    #################################
    # correct the $RemotePath if needed, by removing any ending spaces
    $RemotePath = $RemotePath.TrimEnd("").TrimEnd("/")

    #################################
    # testing the availability of the TCP port on the remote computer
    $TCPTestResult = Test-SPOTTCPPort -TargetIP $TargetIP -TCPPort $Port
    if (!($TCPTestResult.TcpTestSucceeded)) {
        Write-SPOTLog "ERROR: The connectivity to the SSH port for host ""$TargetIP"" is not successfull. Ping test result was: $($TCPTestResult.PingSucceeded)." -Output $OutputFlag
        throw "Download-FileSFTP: SSH port unreachable!"
    }

    #################################
    # test/detect the local Renci.SSHNet.dll file
    $SshNetPath = Get-SPOTSshNetPath -SshNetPath $SshNetPath
    if (!$SshNetPath) {
        Write-SPOTLog "ERROR: The SshNetPath was not provided/determined/detected. Cannot continue."
        throw "Download-FileSFTP: SshNetPath not provided/determined/detected!"
    }

    #################################
    # connect over SFTP to the target IP
    $SFTPSession = New-SPOTSFTPSession -TargetIP $TargetIP -Port $Port -Credential $Credential -TrustedHostsFilePath $TrustedHostsFilePath -SshNetPath $SshNetPath
    if ($SFTPSession -eq $false) {
        Write-SPOTLog "ERROR: the SFTP Session could not be established. Cannot continue." -Output $OutputFlag
        throw "Download-FileSFTP: SFTP Session not established!"
    }

    #################################
    # test remote (source) file path existence
    $RemoteFilePathExists = $false
    if ($SFTPSession.Exists($RemotePath)) {
        if (!$SFTPSession.GetAttributes($RemotePath).IsDirectory) {
            $RemoteFilePathExists = $true
        }
    }
    if (!$RemoteFilePathExists) {
        Write-SPOTLog "ERROR: the remote (source) file path $RemotePath was not detected. Cannot continue." -Output $OutputFlag
        $SFTPSession.Disconnect()
        $SFTPSession.Dispose()
        throw "Download-FileSFTP: remote file path not detected!"
    }

    #######################################
    # check if the file is already present locally
    Write-SPOTLog "Copying the target (source) remote file locally." -Output $OutputFlag -DBG $true
    if (Test-Path -Path $LocalPath -PathType Leaf) {
        Write-SPOTLog "Local file path detected." -Output $OutputFlag -DBG $true
        # local path exists, checking file size
        if ((Get-Item -Path $LocalPath).Length -eq $SFTPSession.GetAttributes($RemotePath).Size) {
            Write-SPOTLog "Local file size is the same as the remote (source) file. Nothing to do. Disconnecting." -Output $OutputFlag -DBG $true
            $SFTPSession.Disconnect()
            $SFTPSession.Dispose()
            Write-SPOTLog "Finished function Download-FileSFTP." -Output $OutputFlag
            return
        }
    }
    else {
        # if the file is not present already, make sure the parent folder is present
        $ParentFolder = Split-Path -Path $LocalPath -Parent
        if (!(Test-Path -Path $ParentFolder)) {
            Write-SPOTLog "Parent folder ""$ParentFolder"" not detected. Creating it now." -Output $OutputFlag -DBG $true
            try {
                New-Item -Path $ParentFolder -ItemType Directory -Confirm:$false -Force | Out-Null
            }
            catch {
                Write-SPOTLog "ERROR: while creating the parent folder ""$ParentFolder"": $_." -Output $OutputFlag
                $SFTPSession.Disconnect()
                $SFTPSession.Dispose()
                throw "Download-FileSFTP: error creating parent folder!"
            }
        }
    }

    #######################################
    # start the transfer 
    Write-SPOTLog "Trying to copy the target file locally." -Output $OutputFlag -DBG $true
    try {
        $fs = [System.IO.File]::Create($LocalPath)
        $SFTPSession.DownloadFile($RemotePath, $fs)
        $fs.Close()
    }
    catch {
        Write-SPOTLog "ERROR: while downloading remote (source) file ""$RemotePath"": $_." -Output $OutputFlag
        $SFTPSession.Disconnect()
        $SFTPSession.Dispose()
        throw "Download-FileSFTP: error downloading remote file!"
    }

    #######################################
    Write-SPOTLog "Download of $RemotePath succeeded. Disconnect and clean at the end." -Output $OutputFlag -DBG $true
    $SFTPSession.Disconnect()
    $SFTPSession.Dispose()

    #######################################
    Write-SPOTLog "Finished function Download-FileSFTP." -Output $OutputFlag

  }  # end of Download-FileSFTP function

######################################################################################################################
function Upload-FileSFTP {
<#
.SYNOPSIS
Uploads a file to a remote Linux file system over SFTP.

.DESCRIPTION
Checks the local file exists, connects remotely to a Linux computer over SFTP, checks the target file path and if does not exist it uploads it remotely.
The remote file existence check is based on file size.
If the parent folder of the remote path does not exit, it will be created.
It depends on several SPOT functions, like Test-SPOTTCPPort, Write-SPOTLog, Get-SPOTSshNetPath and New-SPOTSFTPSession.

.PARAMETER TargetIP
Specifies the IP Address or hostname of the SFTP server from which to download the file.

.PARAMETER Port
Specifies the port to be used, in case it is different from the default

.PARAMETER RemotePath
Specifies the path where the file will be uploaded, on the remote system (where to?).

.PARAMETER LocalPath
Specifies the local path of the file to be uploaded (from where?).

.PARAMETER Credential
Specifies the credential to connect to the remote system.

.PARAMETER TrustedHostsFilePath
Specifies the file path for a SPOT Trusted Hosts csv file to be used for SSH key validation.
If this parameter is not specified or empty, the SSH key validation is not enabled.

.PARAMETER OutputFlag
Sets the function to write output or not (true for executions as a step function; false for execution as part of another script/function).

.PARAMETER SshNetPath
Specifies the local path to the Renci.SSHNet.dll file.

.INPUTS
None. You can't pipe objects to Upload-FileSFTP.

.OUTPUTS
System.String. Upload-FileSFTP may return only logging output, or not. 

.EXAMPLE
PS> Upload-FileSFTP -TargetIP "192.168.0.2" -RemotePath "/root/test.sh" -LocalPath "C:\temp\test.sh" -Credential $PSCredential
In this example the local file "C:\temp\test.sh" is uploaded remotely on "192.168.0.2" in "/root/test.sh".
The logging is enabled by default and the path to the SshNet tool is not specified, as they should for a step function.

.EXAMPLE
PS> Upload-FileSFTP -TargetIP "192.168.0.2" -RemotePath "/root/test.sh" -LocalPath "C:\temp\test.sh" -Credential $PSCredential -OutputFlag $false -SshNetPath "C:\Program Files\WindowsPowerShell\Modules\SPOT\tools\SshNet\Renci.SshNet.dll"
In this example the local file "C:\temp\test.sh" is uploaded remotely on "192.168.0.2" in "/root/test.sh".
The logging is disabled and the path to the SshNet tool is specified, as they should for a helper function being used inside other function.
#>

    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the IP Address or hostname of the SFTP server where to upload the file
        $TargetIP,
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int]
        # the port to be used, in case it is different from the default
        $Port = 22,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the path where the file will be uploaded, on the remote system (where to?)
        $RemotePath, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the local path of the file to be uploaded (from where?)
        $LocalPath, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.Management.Automation.PSCredential]
        # the credential to connect to the remote system
        $Credential,
        [Parameter(Mandatory=$false)]
        [AllowNull()]
        [string]
        # the path to the TrustedHosts file
        $TrustedHostsFilePath,
        [Parameter(Mandatory=$false)]
        [bool]
        # set the function to write output or not (true for executions as a step payload; false for execution as part of another script/function)
        $OutputFlag = $true, 
        [Parameter(Mandatory=$false)]
        [string]
        # the local path to the Renci.SSHNet.dll file
        $SshNetPath 
        )

    ###
    Write-SPOTLog "Starting function Upload-FileSFTP with the parameters: TargetIP ""$TargetIP"", RemotePath ""$RemotePath"", LocalPath ""$LocalPath"", Credential ""$($Credential.UserName)""." -Output $OutputFlag

    #################################
    # check the local (source) file exists
    if (!(Test-Path -Path $LocalPath -PathType Leaf)) {
        Write-SPOTLog "ERROR: the local (source) file path $LocalPath was not detected. Cannot continue." -Output $OutputFlag
        throw "Upload-FileSFTP: source path not detected!"
    }

    #################################
    # correct the $RemotePath if needed, by removing any ending spaces
    $RemotePath = $RemotePath.TrimEnd("").TrimEnd("/")

    #################################
    # testing the availability of the TCP port on the remote computer
    $TCPTestResult = Test-SPOTTCPPort -TargetIP $TargetIP -TCPPort $Port
    if (!($TCPTestResult.TcpTestSucceeded)) {
        Write-SPOTLog "ERROR: The connectivity to the SSH port for host ""$TargetIP"" is not successfull. Ping test result was: $($TCPTestResult.PingSucceeded)." -Output $OutputFlag
        throw "Upload-FileSFTP: SSH port unreachable!"
    }

    #################################
    # test/detect the local Renci.SSHNet.dll file
    $SshNetPath = Get-SPOTSshNetPath -SshNetPath $SshNetPath
    if (!$SshNetPath) {
        Write-SPOTLog "ERROR: The SshNetPath was not provided/determined/detected. Cannot continue."
        throw "Upload-FileSFTP: SshNetPath not provided/determined/detected!"
    }

    #################################
    # connect over SFTP to the target IP
    $SFTPSession = New-SPOTSFTPSession -TargetIP $TargetIP -Port $Port -Credential $Credential -TrustedHostsFilePath $TrustedHostsFilePath -SshNetPath $SshNetPath
    if ($SFTPSession -eq $false) {
        Write-SPOTLog "ERROR: the SFTP Session could not be established. Cannot continue." -Output $OutputFlag
        throw "Upload-FileSFTP: SFTP Session not established!"
    }

    #######################################
    # check if the file is already present remotely
    Write-SPOTLog "Copying the local (source) file remotely." -Output $OutputFlag -DBG $true
    if ($SFTPSession.Exists($RemotePath)) {
        if (!$SFTPSession.GetAttributes($RemotePath).IsDirectory) {
            Write-SPOTLog "Remote file path detected." -Output $OutputFlag -DBG $true
            # remote path exists, checking file size
            if ((Get-Item -Path $LocalPath).Length -eq $SFTPSession.GetAttributes($RemotePath).Size) {
                Write-SPOTLog "Remote file size is the same as the local (source) file. Nothing to do. Disconnecting." -Output $OutputFlag -DBG $true
                $SFTPSession.Disconnect()
                $SFTPSession.Dispose()
                Write-SPOTLog "Finished function Upload-FileSFTP." -Output $OutputFlag
                return
            }
        }
    }
    else {
        # if the remote file is not present already, make sure the parent folder is present
        $ParentPath = $RemotePath.Substring(0,$RemotePath.LastIndexOf("/"))
        $ParentFolderExists = $false
        if ($SFTPSession.Exists($ParentPath)) {
            if ($SFTPSession.GetAttributes($ParentPath).IsDirectory) {
                $ParentFolderExists = $true
            }
        }
        if (!$ParentFolderExists) {
            Write-SPOTLog "Parent folder ""$ParentPath"" not detected. Trying to create it." -Output $OutputFlag -DBG $true
            [Array]$dir = $ParentPath -split '/'
            $path = [System.String]::Empty
            for ($i=0; $i-lt $dir.Count; $i++){
                if ($i -lt $dir.Count){
                    $path+= $dir[$i] + '/'
                    if (!$SFTPSession.Exists($path) -or ($SFTPSession.Exists($path) -and !$SFTPSession.GetAttributes($path).IsDirectory)) {
                        Write-SPOTLog "Folder ""$path"" was not detected. Creating it now." -Output $OutputFlag -DBG $true
                        try {
                            $SFTPSession.CreateDirectory($path)
                        }
                        catch {
                            Write-SPOTLog "ERROR: while creating path folder ""$path"": $_." -Output $OutputFlag
                            $SFTPSession.Disconnect()
                            $SFTPSession.Dispose()
                            throw "Upload-FileSFTP: error creating parent folder path!"
                        }
                    }
                }
            }
        }
    }

    #######################################
    # start the transfer 
    Write-SPOTLog "Trying to copy the target file remotely." -Output $OutputFlag -DBG $true
    try {
        $fs = [System.IO.File]::OpenRead($LocalPath)
        $SFTPSession.UploadFile($fs, $RemotePath)
        $fs.Close()
    }
    catch {
        Write-SPOTLog "ERROR: while uploading local (source) file ""$LocalPath"": $_." -Output $OutputFlag
        $SFTPSession.Disconnect()
        $SFTPSession.Dispose()
        throw "Upload-FileSFTP: error uploading file!"
    }

    #######################################
    Write-SPOTLog "Upload of ""$LocalPath"" succeeded. Disconnect and clean at the end." -Output $OutputFlag -DBG $true
    $SFTPSession.Disconnect()
    $SFTPSession.Dispose()

    #######################################
    Write-SPOTLog "Finished function Upload-FileSFTP." -Output $OutputFlag

}  # end of Upload-FileSFTP function

######################################################################################################################
function Download-FolderSFTP {
<#
.SYNOPSIS
Downloads the folder content from a remote Linux file system over SFTP.

.DESCRIPTION
Connects remotely to a Linux computer over SFTP, checks the existence of the target folder then downloads its content locally if the folder content is not already present locally.
The local folder content existence check is based on file size check for every content file.
If the target local folder path does not exit, it will be created.
It depends on several SPOT functions, like Test-SPOTTCPPort, Write-SPOTLog, Get-SPOTSshNetPath and New-SPOTSFTPSession.

.PARAMETER TargetIP
Specifies the IP Address or hostname of the SFTP server from which to download the folder.

.PARAMETER Port
Specifies the port to be used, in case it is different from the default

.PARAMETER RemotePath
Specifies the path of the folder to be downloaded, on the remote system (from where?).

.PARAMETER LocalPath
Specifies the local path where the files from the source folder shall be downloaded to, on the local system (where to?).

.PARAMETER Credential
Specifies the credential to connect to the remote system.

.PARAMETER TrustedHostsFilePath
Specifies the file path for a SPOT Trusted Hosts csv file to be used for SSH key validation.
If this parameter is not specified or empty, the SSH key validation is not enabled.

.PARAMETER OutputFlag
Sets the function to write output or not (true for executions as a step function; false for execution as part of another script/function).

.PARAMETER SshNetPath
Specifies the local path to the Renci.SSHNet.dll file.

.INPUTS
None. You can't pipe objects to Download-FolderSFTP.

.OUTPUTS
System.String. Download-FolderSFTP may return only logging output, or not. 

.EXAMPLE
PS> Download-FolderSFTP -TargetIP "192.168.0.2" -RemotePath "/root/test" -LocalPath "C:\temp\test" -Credential $PSCredential
In this example the content of the remote folder "/root/test" from "192.168.0.2" is downloaded locally in "C:\temp\test".
The logging is enabled by default and the path to the SshNet tool is not specified, as they should for a step function.

.EXAMPLE
PS> Download-FolderSFTP -TargetIP "192.168.0.2" -RemotePath "/root/test" -LocalPath "C:\temp\test" -Credential $PSCredential -OutputFlag $false -SshNetPath "C:\Program Files\WindowsPowerShell\Modules\SPOT\tools\SshNet\Renci.SshNet.dll"
In this example the content of the remote folder "/root/test" from "192.168.0.2" is downloaded locally in "C:\temp\test".
The logging is disabled and the path to the SshNet tool is specified, as they should for a helper function being used inside other function.
#>

    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the IP Address or hostname of the SFTP server from which to download the folder
        $TargetIP,
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int]
        # the port to be used, in case it is different from the default
        $Port = 22,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the path of the folder to be downloaded, on the remote system (from where?)
        $RemotePath, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the local path where the files from the source folder shall be downloaded to, on the local system (where to?)
        $LocalPath, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.Management.Automation.PSCredential]
        # the credential to connect to the remote system 
        $Credential,
        [Parameter(Mandatory=$false)]
        [AllowNull()]
        [string]
        # the path to the TrustedHosts file
        $TrustedHostsFilePath,
        [Parameter(Mandatory=$false)]
        [bool]
        # set the function to write output or not (true for executions as a step payload; false for execution as part of another script/function)
        $OutputFlag = $true, 
        [Parameter(Mandatory=$false)]
        [string]
        # the local path to the Renci.SSHNet.dll file
        $SshNetPath 
        )
    
    ###
    Write-SPOTLog "Starting function Download-FolderSFTP with the parameters: TargetIP ""$TargetIP"", RemotePath ""$RemotePath"", LocalPath ""$LocalPath"", Credential ""$($Credential.UserName)""." -Output $OutputFlag

    #################################
    # correct the $RemotePath if needed, by removing any ending spaces or slashes
    $RemotePath = $RemotePath.TrimEnd("").TrimEnd("/")

    #################################
    # testing the availability of the TCP port on the remote computer
    $TCPTestResult = Test-SPOTTCPPort -TargetIP $TargetIP -TCPPort $Port
    if (!($TCPTestResult.TcpTestSucceeded)) {
        Write-SPOTLog "ERROR: The connectivity to the SSH port for host ""$TargetIP"" is not successfull. Ping test result was: $($TCPTestResult.PingSucceeded)." -Output $OutputFlag
        throw "Download-FolderSFTP: SSH port unreachable!"
    }

    #################################
    # test/detect the local Renci.SSHNet.dll file
    $SshNetPath = Get-SPOTSshNetPath -SshNetPath $SshNetPath
    if (!$SshNetPath) {
        Write-SPOTLog "ERROR: The SshNetPath was not provided/determined/detected. Cannot continue."
        throw "Download-FolderSFTP: SshNetPath not provided/determined/detected!"
    }

    #################################
    # connect over SFTP to the target IP
    $SFTPSession = New-SPOTSFTPSession -TargetIP $TargetIP -Port $Port -Credential $Credential -TrustedHostsFilePath $TrustedHostsFilePath -SshNetPath $SshNetPath
    if ($SFTPSession -eq $false) {
        Write-SPOTLog "ERROR: the SFTP Session could not be established. Cannot continue." -Output $OutputFlag
        throw "Download-FolderSFTP: SFTP Session not established!"
    }

    #################################
    # do the folder download
    # test remote (source) folder path existence
    $RemoteFolderPathExists = $false
    if ($SFTPSession.Exists($RemotePath)) {
        if ($SFTPSession.GetAttributes($RemotePath).IsDirectory) {
            $RemoteFolderPathExists = $true
        }
    }
    if (!$RemoteFolderPathExists) {
        Write-SPOTLog "ERROR: the remote (source) folder path $RemotePath was not detected. Cannot continue." -Output $OutputFlag
        $SFTPSession.Disconnect()
        $SFTPSession.Dispose()
        throw "Download-FolderSFTP: source folder path not detected!"
    }

    #######################################
    # Make sure the local (target) path is present
    if (!(Test-Path -Path $LocalPath -PathType Container)) {
        # if the folder is not present already, create it
        Write-SPOTLog "Local (target) folder path not detected. Creating it now." -Output $OutputFlag -DBG $true
        try {
            New-Item -Path $LocalPath -ItemType Directory -Confirm:$false -Force | Out-Null
        }
        catch {
            Write-SPOTLog "ERROR: while creating the local folder: $_." -Output $OutputFlag
            $SFTPSession.Disconnect()
            $SFTPSession.Dispose()
            throw "Download-FolderSFTP: error creating local folder!"
        }
    }

    #######################################
    # define function
    function Download-FolderContent {
        Param (
            [Parameter(Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [string]
            # the path of the folder to be downloaded, on the remote system (from where?)
            $RemotePath, 
            [Parameter(Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [string]
            # the local path where the files from the source folder shall be downloaded to, on the local system (where to?)
            $LocalPath, 
            [Parameter(Mandatory=$false)]
            [object]
            # the SFTP Session object
            $SFTPSession 
            )
    
        # get files from the target folder
        $ChildItems = $SFTPSession.ListDirectory($RemotePath) | Where {$_.Name -notin (".","..")}
        foreach ($ci in $ChildItems) {
            if ($ci.IsDirectory) {
                # create local folder
                if (Test-Path -Path $LocalPath -PathType Container) {
                    try {
                        New-Item -Path "$LocalPath\$($ci.Name)" -ItemType Directory -Confirm:$false -Force | Out-Null
                    }
                    catch {
                        Write-SPOTLog "ERROR: while creating local folder ""$LocalPath\$($ci.Name)"": $_." -Output $false
                        throw "Download-FolderContents: error creating local folder!"
                    }
                }
                # start the entire function again for this subfolder
                Download-FolderContent -RemotePath "$RemotePath/$($ci.Name)" -LocalPath "$LocalPath\$($ci.Name)" -SFTPSession $SFTPSession
            }
            else {
                # check if the file is already present locally
                if (Test-Path -Path "$LocalPath\$($ci.Name)" -PathType Leaf) {
                    Write-SPOTLog "Local file path ""$LocalPath\$($ci.Name)"" detected." -Output $false -DBG $true
                    # local path exists, checking file size
                    if ((Get-Item -Path "$LocalPath\$($ci.Name)").Length -eq $SFTPSession.GetAttributes("$RemotePath/$($ci.Name)").Size) {
                        Write-SPOTLog "Local file size is the same as the remote (source) file. Skipping this file." -Output $false -DBG $true
                        continue
                    }
                }
                # download the current file
                try {
                    $fs = [System.IO.File]::Create("$LocalPath\$($ci.Name)")
                    $SFTPSession.DownloadFile("$RemotePath/$($ci.Name)", $fs)
                    $fs.Close()
                }
                catch {
                    Write-SPOTLog "ERROR: while downloading remote file ""$RemotePath/$($ci.Name)"": $_." -Output $false
                    throw "Download-FolderContents: error downloading file!"
                }
            }
        }
    }
    
    #######################################
    # start the transfer 
    Write-SPOTLog "Trying to copy the remote (source) folder locally." -Output $OutputFlag -DBG $true
    try {
        Download-FolderContent -RemotePath $RemotePath -LocalPath $LocalPath -SFTPSession $SFTPSession
    }
    catch {
        Write-SPOTLog "ERROR: while downloading remote (source) folder ""$RemotePath"": $_." -Output $OutputFlag
        $SFTPSession.Disconnect()
        $SFTPSession.Dispose()
        throw "Download-FolderSFTP: error downloading folder content!"
    }

    #######################################
    Write-SPOTLog "Disconnect and clean at the end." -Output $OutputFlag -DBG $true
    $SFTPSession.Disconnect()
    $SFTPSession.Dispose()

    #######################################
    Write-SPOTLog "Finished function Download-FolderSFTP." -Output $OutputFlag

}  # end of Download-FolderSFTP function

######################################################################################################################
function Upload-FolderSFTP {
<#
.SYNOPSIS
Uploads the folder content to a remote Linux file system over SFTP.

.DESCRIPTION
Checks the local folder exists, connects remotely to a Linux computer over SFTP and uploads the local folder content.
The remote folder content existence check is based on file size check for every content file.
If the folder of the remote path does not exit, it will be created.
It depends on several SPOT functions, like Test-SPOTTCPPort, Write-SPOTLog, Get-SPOTSshNetPath and New-SPOTSFTPSession.

.PARAMETER TargetIP
Specifies the IP Address or hostname of the SFTP server where to upload the folder.

.PARAMETER Port
Specifies the port to be used, in case it is different from the default

.PARAMETER RemotePath
Specifies the path where the files of the source folder will be uploaded, on the remote system (where to?).

.PARAMETER LocalPath
Specifies the local path of the folder to be uploaded (from where?).

.PARAMETER Credential
Specifies the credential to connect to the remote system.

.PARAMETER TrustedHostsFilePath
Specifies the file path for a SPOT Trusted Hosts csv file to be used for SSH key validation.
If this parameter is not specified or empty, the SSH key validation is not enabled.

.PARAMETER OutputFlag
Sets the function to write output or not (true for executions as a step function; false for execution as part of another script/function).

.PARAMETER SshNetPath
Specifies the local path to the Renci.SSHNet.dll file.

.INPUTS
None. You can't pipe objects to Upload-FolderSFTP.

.OUTPUTS
System.String. Upload-FolderSFTP may return only logging output, or not. 

.EXAMPLE
PS> Upload-FolderSFTP -TargetIP "192.168.0.2" -RemotePath "/root/test" -LocalPath "C:\temp\test" -Credential $PSCredential
In this example the content of the local folder "C:\temp\test" is uploaded remotely on "192.168.0.2" in the folder "/root/test".
The logging is enabled by default and the path to the SshNet tool is not specified, as they should for a step function.

.EXAMPLE
PS> Upload-FolderSFTP -TargetIP "192.168.0.2" -RemotePath "/root/test" -LocalPath "C:\temp\test" -Credential $PSCredential -OutputFlag $false -SshNetPath "C:\Program Files\WindowsPowerShell\Modules\SPOT\tools\SshNet\Renci.SshNet.dll"
In this example the content of the local folder "C:\temp\test" is uploaded remotely on "192.168.0.2" in the folder "/root/test".
The logging is disabled and the path to the SshNet tool is specified, as they should for a helper function being used inside other function.
#>

    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the IP Address or hostname of the SFTP server where to upload the folder
        $TargetIP,
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int]
        # the port to be used, in case it is different from the default
        $Port = 22,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the path where the files of the source folder will be uploaded, on the remote system (where to?)
        $RemotePath, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the local path of the folder to be uploaded (from where?)
        $LocalPath, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.Management.Automation.PSCredential]
        # the credential to connect to the remote system
        $Credential,
        [Parameter(Mandatory=$false)]
        [AllowNull()]
        [string]
        # the path to the TrustedHosts file
        $TrustedHostsFilePath,
        [Parameter(Mandatory=$false)]
        [bool]
        # set the function to write output or not (true for executions as a step payload; false for execution as part of another script/function)
        $OutputFlag = $true, 
        [Parameter(Mandatory=$false)]
        [string]
        # the local path to the Renci.SSHNet.dll file
        $SshNetPath 
        )

    ###
    Write-SPOTLog "Starting function Upload-FolderSFTP with the parameters: TargetIP ""$TargetIP"", RemotePath ""$RemotePath"", LocalPath ""$LocalPath"", Credential ""$($Credential.UserName)""." -Output $OutputFlag

    #################################
    # check the local (source) folder exists
    if (!(Test-Path -Path $LocalPath -PathType Container)) {
        Write-SPOTLog "ERROR: the local (source) folder path $LocalPath was not detected. Cannot continue." -Output $OutputFlag
        throw "Upload-FolderSFTP: source folder not detected!"
    }

    #################################
    # correct the $RemotePath if needed, by removing any ending spaces or slashes
    $RemotePath = $RemotePath.TrimEnd("").TrimEnd("/")

    #################################
    # testing the availability of the TCP port on the remote computer
    $TCPTestResult = Test-SPOTTCPPort -TargetIP $TargetIP -TCPPort $Port
    if (!($TCPTestResult.TcpTestSucceeded)) {
        Write-SPOTLog "ERROR: The connectivity to the SSH port for host ""$TargetIP"" is not successfull. Ping test result was: $($TCPTestResult.PingSucceeded)." -Output $OutputFlag
        throw "Upload-FolderSFTP: SSH port unreachable!"
    }

    #################################
    # test/detect the local Renci.SSHNet.dll file
    $SshNetPath = Get-SPOTSshNetPath -SshNetPath $SshNetPath
    if (!$SshNetPath) {
        Write-SPOTLog "ERROR: The SshNetPath was not provided/determined/detected. Cannot continue."
        throw "Upload-FolderSFTP: SshNetPath not provided/determined/detected!"
    }

    #################################
    # connect over SFTP to the target IP
    $SFTPSession = New-SPOTSFTPSession -TargetIP $TargetIP -Port $Port -Credential $Credential -TrustedHostsFilePath $TrustedHostsFilePath -SshNetPath $SshNetPath
    if ($SFTPSession -eq $false) {
        Write-SPOTLog "ERROR: the SFTP Session could not be established. Cannot continue." -Output $OutputFlag
        throw "Upload-FolderSFTP: SFTP Session not established!"
    }

    #################################
    # make sure the remote (target) folder path exists
    $RemoteFolderPathExists = $false
    if ($SFTPSession.Exists($RemotePath)) {
        if ($SFTPSession.GetAttributes($RemotePath).IsDirectory) {
            $RemoteFolderPathExists = $true
        }
    }
    if (!$RemoteFolderPathExists) {
        Write-SPOTLog "Remote (target) folder ""$RemotePath"" not detected. Trying to create it." -Output $OutputFlag -DBG $true
        [Array]$dir = $RemotePath -split '/'
        $path = [System.String]::Empty
        for ($i=0; $i-lt $dir.Count; $i++){
            if ($i -lt $dir.Count){
                $path+= $dir[$i] + '/'
                if (!$SFTPSession.Exists($path) -or ($SFTPSession.Exists($path) -and !$SFTPSession.GetAttributes($path).IsDirectory)) {
                    Write-SPOTLog "Folder ""$path"" was not detected. Creating it now." -Output $OutputFlag -DBG $true
                    try {
                        $SFTPSession.CreateDirectory($path)
                    }
                    catch {
                        Write-SPOTLog "ERROR: while creating remote path folder ""$path"": $_." -Output $OutputFlag
                        $SFTPSession.Disconnect()
                        $SFTPSession.Dispose()
                        throw "Upload-FolderSFTP: error creating remote folder!"
                    }
                }
            }
        }
    }

    #######################################
    # define function
    function Upload-FolderContent {
        Param (
            [Parameter(Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [string]
            $RemotePath, # the path where to upload the source folder content, on the remote system (where to?)
            [Parameter(Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [string]
            $LocalPath, # the local path of the folder to be uploaded, on the local system (from where?)
            [Parameter(Mandatory=$false)]
            [object]
            $SFTPSession # the SFTP Session object
            )
    
        # get files from the local (source) folder
        $ChildItems = Get-ChildItem -Path $LocalPath
        foreach ($ci in $ChildItems) {
            if ($ci.PSIsContainer) {
                # create remote folder
                $RemoteFolderPathExists = $false
                if ($SFTPSession.Exists("$RemotePath/$($ci.Name)")) {
                    if ($SFTPSession.GetAttributes("$RemotePath/$($ci.Name)").IsDirectory) {
                        $RemoteFolderPathExists = $true
                    }
                }
                if (!$RemoteFolderPathExists) {
                    try {
                        $SFTPSession.CreateDirectory("$RemotePath/$($ci.Name)")
                    }
                    catch {
                        Write-SPOTLog "ERROR: while creating remote path folder ""$RemotePath/$($ci.Name)"": $_." -Output $false
                        $SFTPSession.Disconnect()
                        throw "Upload-FolderContents: error creating remote folder!"
                    }
                }
                # start the entire function again for this subfolder
                $result = Upload-FolderContent -RemotePath "$RemotePath/$($ci.Name)" -LocalPath "$LocalPath\$($ci.Name)" -SFTPSession $SFTPSession
                if (!$result) {
                    Write-SPOTLog "ERROR: while uploading local folder ""$LocalPath\$($ci.Name)"": $_." -Output $false
                    throw "Upload-FolderContents: error uploading folder!"
                }
            }
            else {
                # check if the file is already present remotely
                if ($SFTPSession.Exists("$RemotePath/$($ci.Name)")) {
                    if (!$SFTPSession.GetAttributes("$RemotePath/$($ci.Name)").IsDirectory) {
                        Write-SPOTLog "Remote file path ""$RemotePath/$($ci.Name)"" detected." -Output $false -DBG $true
                        # remote file path exists, checking file size
                        if ((Get-Item -Path "$LocalPath\$($ci.Name)").Length -eq $SFTPSession.GetAttributes("$RemotePath/$($ci.Name)").Size) {
                            Write-SPOTLog "Remote file size is the same as the local (source) file. Skipping this file." -Output $false -DBG $true
                            continue
                        }
                    }
                }
                # upload the current file
                try {
                    $fs = [System.IO.File]::OpenRead("$LocalPath\$($ci.Name)")
                    $SFTPSession.UploadFile($fs, "$RemotePath/$($ci.Name)")
                    $fs.Close()
                }
                catch {
                    Write-SPOTLog "ERROR: while uploading local file ""$LocalPath\$($ci.Name)"": $_." -Output $false
                    throw "Upload-FolderContents: error uploading file!"
                }
            }
        }
    }
    
    #######################################
    # start the transfer 
    Write-SPOTLog "Trying to copy the local (source) folder remotely." -Output $OutputFlag -DBG $true
    try {
        Upload-FolderContent -RemotePath $RemotePath -LocalPath $LocalPath -SFTPSession $SFTPSession
    }
    catch {
        Write-SPOTLog "ERROR: while uploading local (source) folder ""$LocalPath"": $_." -Output $OutputFlag
        $SFTPSession.Disconnect()
        $SFTPSession.Dispose()
        throw "Upload-FolderSFTP: error uploading folder content!"
    }
    
    #######################################
    Write-SPOTLog "Disconnect and clean at the end." -Output $OutputFlag -DBG $true
    $SFTPSession.Disconnect()
    $SFTPSession.Dispose()

    #######################################
    Write-SPOTLog "Finished function Upload-FolderSFTP." -Output $OutputFlag

  }  # end of Upload-FolderSFTP function

######################################################################################################################
function Test-FilePathSFTP {
<#
.SYNOPSIS
Checks the existence of a file from a remote Linux file system.

.DESCRIPTION
Connects remotely to a Linux computer over SFTP and checks the existence of the target file.
It depends on several SPOT functions, like Test-SPOTTCPPort, Write-SPOTLog, Get-SPOTSshNetPath and New-SPOTSFTPSession.

.PARAMETER TargetIP
Specifies the IP Address or hostname of the SFTP server.

.PARAMETER Port
Specifies the port to be used, in case it is different from the default

.PARAMETER FilePath
Specifies the file path to be tested for existence on the SFTP server.

.PARAMETER Credential
Specifies the SSH credentials to be used for remote authentication.

.PARAMETER TrustedHostsFilePath
Specifies the file path for a SPOT Trusted Hosts csv file to be used for SSH key validation.
If this parameter is not specified or empty, the SSH key validation is not enabled.

.PARAMETER OutputFlag
Sets the function to write output or not (true for executions as a step function; false for execution as part of another script/function).

.PARAMETER SshNetPath
Specifies the local path to the Renci.SSHNet.dll file.

.INPUTS
None. You can't pipe objects to Test-FilePathSFTP.

.OUTPUTS
System.String. Test-FilePathSFTP may return only logging output, or not. 

.EXAMPLE
PS> Test-FilePathSFTP -TargetIP "192.168.0.2" -FilePath "/root/test.sh" -Credential $PSCredential
In this example the file "/root/test.sh" from "192.168.0.2" is checked for existence.
The logging is enabled by default and the path to the SshNet tool is not specified, as they should for a step function.

.EXAMPLE
PS> Test-FilePathSFTP -TargetIP "192.168.0.2" -FilePath "/root/test.sh" -Credential $PSCredential -OutputFlag $false -SshNetPath "C:\Program Files\WindowsPowerShell\Modules\SPOT\tools\SshNet\Renci.SshNet.dll"
In this example the file "/root/test.sh" from "192.168.0.2" is checked for existence.
The logging is disabled and the path to the SshNet tool is specified, as they should for a helper function being used inside other function.
#>

    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the IP Address or hostname of the SFTP server
        $TargetIP,
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int]
        # the port to be used, in case it is different from the default
        $Port = 22,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the file path to be tested for existence on the SFTP server
        $FilePath, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.Management.Automation.PSCredential]
        # the credential to connect to the remote system
        $Credential,
        [Parameter(Mandatory=$false)]
        [AllowNull()]
        [string]
        # the path to the TrustedHosts file
        $TrustedHostsFilePath,
        [Parameter(Mandatory=$false)]
        [bool]
        # set the function to write output or not (true for executions as a step payload; false for execution as part of another script/function)
        $OutputFlag = $true, 
        [Parameter(Mandatory=$false)]
        [string]
        # the local path to the Renci.SSHNet.dll file
        $SshNetPath 
        )

    # function to test the existence of a file path over SFTP; test result can be published in PV from this function's variable $result
    Write-SPOTLog "Starting function Test-FilePathSFTP with the parameters: TargetIP ""$TargetIP"", FilePath ""$FilePath"" and Credential ""$($Credential.UserName)""." -Output $OutputFlag

    #################################
    # testing the availability of the TCP port on the remote computer
    $TCPTestResult = Test-SPOTTCPPort -TargetIP $TargetIP -TCPPort $Port
    if (!($TCPTestResult.TcpTestSucceeded)) {
        Write-SPOTLog "ERROR: The connectivity to the SSH port for host ""$TargetIP"" is not successfull. Ping test result was: $($TCPTestResult.PingSucceeded)." -Output $OutputFlag
        throw "Test-FilePathSFTP: SSH port unreachable!"
    }

    #################################
    # test/detect the local Renci.SSHNet.dll file
    $SshNetPath = Get-SPOTSshNetPath -SshNetPath $SshNetPath
    if (!$SshNetPath) {
        Write-SPOTLog "ERROR: The SshNetPath was not provided/determined/detected. Cannot continue."
        throw "Test-FilePathSFTP: SshNetPath not provided/determined/detected!"
    }

    #################################
    # connect over SFTP to the target IP
    $SFTPSession = New-SPOTSFTPSession -TargetIP $TargetIP -Port $Port -Credential $Credential -TrustedHostsFilePath $TrustedHostsFilePath -SshNetPath $SshNetPath
    if ($SFTPSession -eq $false) {
        Write-SPOTLog "ERROR: the SFTP Session could not be established. Cannot continue." -Output $OutputFlag
        throw "Test-FilePathSFTP: SFTP Session not established!"
    }

    #################################
    # Test the target path
    Write-SPOTLog "Testing the file path ""$FilePath""." -Output $OutputFlag -DBG $true
    $TargetFileExists = $false
    if ($SFTPSession.Exists($FilePath)) {
        if (!$SFTPSession.GetAttributes($FilePath).IsDirectory) {
            Write-SPOTLog "The file path ""$FilePath"" was detected on the targetIP ""$TargetIP""." -Output $OutputFlag -DBG $true
            $TargetFileExists = $true
        }
    }

    #######################################
    Write-SPOTLog "Disconnect after testing path." -Output $OutputFlag -DBG $true
    $SFTPSession.Disconnect()
    $SFTPSession.Dispose()

    #######################################
    Write-SPOTLog "Finished function Test-FilePathSFTP." -Output $OutputFlag
    
    return $TargetFileExists

}  # end of Test-FilePathSFTP function

######################################################################################################################
function Test-FolderPathSFTP {
<#
.SYNOPSIS
Checks the existence of a folder from a remote Linux file system.

.DESCRIPTION
Connects remotely to a Linux computer over SFTP and checks the existence of the target folder.
It depends on several SPOT functions, like Test-SPOTTCPPort, Write-SPOTLog, Get-SPOTSshNetPath and New-SPOTSFTPSession.

.PARAMETER TargetIP
Specifies the IP Address or hostname of the SFTP server.

.PARAMETER Port
Specifies the port to be used, in case it is different from the default

.PARAMETER FolderPath
Specifies the folder path to be tested for existence on the SFTP server.

.PARAMETER Credential
Specifies the SSH credentials to be used for remote authentication.

.PARAMETER TrustedHostsFilePath
Specifies the file path for a SPOT Trusted Hosts csv file to be used for SSH key validation.
If this parameter is not specified or empty, the SSH key validation is not enabled.

.PARAMETER OutputFlag
Sets the function to write output or not (true for executions as a step function; false for execution as part of another script/function).

.PARAMETER SshNetPath
Specifies the local path to the Renci.SSHNet.dll file.

.INPUTS
None. You can't pipe objects to Test-FolderPathSFTP.

.OUTPUTS
System.String. Test-FolderPathSFTP may return only logging output, or not. 

.EXAMPLE
PS> Test-FolderPathSFTP -TargetIP "192.168.0.2" -FilePath "/root/test" -Credential $PSCredential
In this example the folder "/root/test" from "192.168.0.2" is checked for existence.
The logging is enabled by default and the path to the SshNet tool is not specified, as they should for a step function.

.EXAMPLE
PS> Test-FolderPathSFTP -TargetIP "192.168.0.2" -FilePath "/root/test" -Credential $PSCredential -OutputFlag $false -SshNetPath "C:\Program Files\WindowsPowerShell\Modules\SPOT\tools\SshNet\Renci.SshNet.dll"
In this example the folder "/root/test" from "192.168.0.2" is checked for existence.
The logging is disabled and the path to the SshNet tool is specified, as they should for a helper function being used inside other function.
#>

    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the IP Address or hostname of the SFTP server
        $TargetIP,
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int]
        # the port to be used, in case it is different from the default
        $Port = 22,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the folder path to be tested for existence on the SFTP server
        $FolderPath, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.Management.Automation.PSCredential]
        # the credentials to connect to the remote system
        $Credential,
        [Parameter(Mandatory=$false)]
        [AllowNull()]
        [string]
        # the path to the TrustedHosts file
        $TrustedHostsFilePath,
        [Parameter(Mandatory=$false)]
        [bool]
        # set the function to write output or not (true for executions as a step payload; false for execution as part of another script/function)
        $OutputFlag = $true, 
        [Parameter(Mandatory=$false)]
        [string]
        # the local path to the Renci.SSHNet.dll file
        $SshNetPath 
        )

    # function to test the existence of a folder path over SFTP; test result can be published in PV from this function's variable $result
    Write-SPOTLog "Starting function Test-FolderPathSFTP with the parameters: TargetIP ""$TargetIP"", FolderPath ""$FolderPath"" and Credential ""$($Credential.UserName)""." -Output $OutputFlag

    #################################
    # testing the availability of the TCP port on the remote computer
    $TCPTestResult = Test-SPOTTCPPort -TargetIP $TargetIP -TCPPort $Port
    if (!($TCPTestResult.TcpTestSucceeded)) {
        Write-SPOTLog "ERROR: The connectivity to the SSH port for host ""$TargetIP"" is not successfull. Ping test result was: $($TCPTestResult.PingSucceeded)." -Output $OutputFlag
        throw "Test-FolderPathSFTP: SSH port unreachable!"
    }

    #################################
    # test/detect the local Renci.SSHNet.dll file
    $SshNetPath = Get-SPOTSshNetPath -SshNetPath $SshNetPath
    if (!$SshNetPath) {
        Write-SPOTLog "ERROR: The SshNetPath was not provided/determined/detected. Cannot continue."
        throw "Test-FolderPathSFTP: SshNetPath not provided/determined/detected!"
    }

    #################################
    # connect over SFTP to the target IP
    $SFTPSession = New-SPOTSFTPSession -TargetIP $TargetIP -Port $Port -Credential $Credential -TrustedHostsFilePath $TrustedHostsFilePath -SshNetPath $SshNetPath
    if ($SFTPSession -eq $false) {
        Write-SPOTLog "ERROR: the SFTP Session could not be established. Cannot continue." -Output $OutputFlag
        throw "Test-FolderPathSFTP: SFTP Session not established!"
    }

    #################################
    # Test the target path
    Write-SPOTLog "Testing the folder path ""$FolderPath""." -Output $OutputFlag -DBG $true
    $TargetFolderExists = $false

    if ($SFTPSession.Exists($FolderPath)) {
        if ($SFTPSession.GetAttributes($FolderPath).IsDirectory) {
            Write-SPOTLog "The folder path ""$FolderPath"" was detected on the targetIP ""$TargetIP""." -Output $OutputFlag -DBG $true
            $TargetFolderExists = $true
        }
    }

    #######################################
    Write-SPOTLog "Disconnect after testing path." -Output $OutputFlag -DBG $true
    $SFTPSession.Disconnect()
    $SFTPSession.Dispose()

    #######################################
    Write-SPOTLog "Finished function Test-FolderPathSFTP." -Output $OutputFlag

    return $TargetFolderExists

}  # end of Test-FolderPathSFTP function

######################################################################################################################
function Execute-CMDScript {
<#
.SYNOPSIS
Executes a CMD script with parameters and input data.

.DESCRIPTION
Executes a CMD script with the parameters provided. If input data is also provided, it monitors the output and sends the input value when the output line is matching the prompt match string.
After the output string matching, there must be 2 seconds of no other output received to be considered a prompt for a value.
The script path must allow renaming if the script extension is not cmd or bat.
The $_spot_CMDOutput variable contains the output, including the sent commands and the initial output.
It depends on the SPOT function Write-SPOTLog.

.PARAMETER ScriptPath
Specifies the path to the CMD script (can be absolute or RFI, for both local and remote executions).

.PARAMETER ScriptParameters
Specifies the parameters to be used for the CMD script.

.PARAMETER InputData
Specifies the input data to be used for the CMD script input requests (on each array element the input prompt match string and the value to be provided must be split by %_%)

.PARAMETER Timeout
Specifies the overall timeout of the entire cmd script execution, in seconds.

.INPUTS
None. You can't pipe objects to Execute-CMDScript.

.OUTPUTS
System.String. Execute-CMDScript may return only logging output. 

.EXAMPLE
PS> Execute-CMDScript -ScriptPath "C:\temp\test.cmd" -ScriptParameters "Par1 Par2" -InputData "username%_%john","age%_%25" -Timeout 180
In this example the script "C:\temp\test.cmd" is executed with the parameters "Par1 Par2".
If an output line contains the string "username" and waits around 1.5 seconds, the value "john" is provided. The same happens for the string "age" with the value "25".
The overall script execution stops if more than 180 seconds pass.

.EXAMPLE
PS> Execute-CMDScript -ScriptPath "C:\temp\test.cmd" -InputData "username%_%john" -Timeout 60
In this example the script "C:\temp\test.cmd" is executed without parameters.
If an output line contains the string "username" and waits around 1.5 seconds, the value "john" is provided.
The overall script execution stops if more than 60 seconds pass.
#>

    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the path to the CMD script (can be absolute or RFI, for both local and remote executions)
        $ScriptPath, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the parameters to be used for the CMD script
        $ScriptParameters, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string[]]
        # the input data to be used for the CMD script input requests (on each array element split input prompt match string and value to be provided by %_%)
        $InputData, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [int]
        # the overall timeout of the entire cmd script execution, in seconds
        $Timeout 
        )

    ######################
    Write-SPOTLog "Starting function Execute-CMDScript with the parameters: ScriptPath ""$ScriptPath"", ScriptParameters ""$ScriptParameters"", InputData ""$InputData"" and Timeout ""$Timeout""."

    ######################
    # if the extension of the CMD script is not cmd or bat, change it to cmd to be able to execute it via cmd.exe
    if (Test-Path -Path $ScriptPath -PathType Leaf) {
        # file is present, check extenstion and try to change it if not correct
        $ScriptItem = Get-Item -Path $ScriptPath -Force
        if ($ScriptItem.Extension -notin (".cmd",".bat")) {
            Write-SPOTLog "The extension of the provided CMD script file is not correct. Trying to change it to cmd." -DBG $true
            try {
                $NewScriptItem = Rename-Item -Path $ScriptItem.FullName -NewName "$($ScriptItem.BaseName).cmd" -Confirm:$false -Force -PassThru
            }
            catch {
                Write-SPOTLog "ERROR while trying to change the script extension to cmd: $_."
                throw "Execute-CMDScript: error changing script extension!"
            }
            # change the ScriptPath parameter variable to the new file path
            $ScriptPath = $NewScriptItem.FullName
        }
    }
    else {
        # file does not exist
        Write-SPOTLog "ERROR: The cmd file to be executed was not detected in ""$ScriptPath"". Cannot continue."
        throw "Execute-CMDScript: script file missing!"
    }
    
    ######################
    # transform the input pairs array into a hashtable, if provided
    if ($InputData) {
        $InputDataPairs = @{}
        $InputData | % {$InputDataPairs[($_ -split "%_%")[0]] = ($_ -split "%_%")[1]}
    }
    
    ######################
    # prepare the process starting options
    $CurrentPath = (Get-Location).Path
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "cmd.exe"
    $psi.Arguments = "/c cd $CurrentPath && @echo off && $ScriptPath $ScriptParameters 2>&1"
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    ######################
    # start the process
    Write-SPOTLog "INFO: Starting the cmd process." -DBG $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $StartTime = Get-Date
    $process.Start() | Out-Null

    ######################
    # initialize output parsing objects
    $readTask = $null
    $buffer = New-Object char[] 8192
    $IntOutput = ""
    $_spot_CMDOutput = ""
    $inc = 0

    ######################
    # start the reading 
    $readTask = $process.StandardOutput.ReadAsync($buffer, 0, $buffer.Length)
    $readTask.Wait(50) | Out-Null
    $OkToRead = $false

    ######################
    # main while loop
    while (-not $process.HasExited) {
        $LastLine = $null

        ######################
        # check for timeout 
        if (((Get-Date) - $StartTime).Seconds -gt $Timeout) {
            Write-SPOTLog "ERROR: Timeout of ""$Timeout"" seconds reached. Killing the process, returning the output so far then false for failure."
            $process.Kill()
            $_spot_CMDOutput += $IntOutput
            $_spot_CMDOutput = $_spot_CMDOutput -split '\r?\n'
            throw "Execute-CMDScript: overall timeout reached without completion!"
        }

        ######################
        # start new read operation only if the previous one finished
        if ($OkToRead) {
            $readTask = $process.StandardOutput.ReadAsync($buffer, 0, $buffer.Length)
        }

        ######################
        # check the read status (either from earlier in this iteration or from a previous iteration)
        if ($readTask.IsCompleted) {
            # signal it is ok to start a new read on the next iteration
            $OkToRead = $true
            # reset the increment to 0 as the read is completed in this iteration
            $inc = 0
            $count = $readTask.Result
            if ($count -gt 0) {
                # the read task got something; adding it to the output variable
                $IntOutput += -join $buffer[0..($count-1)]
            }
        }
        else {
            # read task did not finish; signal to the next iteration not to start another read until this one finishes
            $OkToRead = $false
            # use the increment to anticipate input prompts only if inputs have been provided
            if ($InputData) {
                if ($inc -gt 7) {
                    # read task is not ready but this was the case for the last 7 iterations, maybe the script waits for input
                
                    ######################
                    # establish the most viable last line
                    if (($IntOutput -split '\r?\n').Count -eq 0) {
                        $LastLine = ""
                    }
                    elseif (($IntOutput -split '\r?\n').Count -eq 1) {
                        $LastLine = ($IntOutput -split '\r?\n')[0]
                    }
                    else {
                        if (($IntOutput -split '\r?\n')[($IntOutput -split '\r?\n').Count-1]) {
                                $LastLine = ($IntOutput -split '\r?\n')[($IntOutput -split '\r?\n').Count-1]
                            }
                        else {
                                $LastLine = ($IntOutput -split '\r?\n')[($IntOutput -split '\r?\n').Count-2]
                            }
                    }

                    ######################
                    # after 7 retries and no completion of the read task, check the last prompt for an expect match
                    if ($LastLine) {
                        foreach ($i in $($InputDataPairs.Keys)) {
                            if ($LastLine -like "*$i*") {
                                Write-SPOTLog "INFO: Match found. Last line is ""$LastLine"". Sending the associated input ""$($InputDataPairs[$i])""." -DBG $true
                                $process.StandardInput.WriteLine($InputDataPairs[$i])
                                # insert the written input as well in the output variable, to simulate the visual experience of the cmd console (newline char included)
                                $IntOutput += $InputDataPairs[$i]+"`n"
                                $_spot_CMDOutput += $IntOutput
                                # reinitialize the output variable after a written value to avoid interpreting it as a last line again
                                $IntOutput = ""
                                # reset the increment
                                $inc = 0
                                break
                            }
                        }
                    }
                    $readTask.Wait(50) | Out-Null
                }
                else {
                    # recent read task not finished; wait a little, increment then go to the next iteration
                    $readTask.Wait(300) | Out-Null
                    $inc++
                }
            }
            else {
                # recent read task not finished; wait a little
                $readTask.Wait(50) | Out-Null
            }
        }
    }

    ######################
    # after cmd exited, continue to read all that remains in the output stream (there should be no more prompts for input)
    Write-SPOTLog "INFO: Process finished gracefully. Continuing with read until finishing the existing stream." -DBG $true

    ######################
    # complete any outstanding reads from the above while loop
    if ($readTask.IsCompleted -and $OkToRead -eq $false) {
        $count = $readTask.Result
        if ($count -gt 0) {
            # the read task got something; adding it to the output variable
            $IntOutput += -join $buffer[0..($count-1)]
        }
    }

    ######################
    while (!$process.StandardOutput.EndOfStream){
        $readTask = $process.StandardOutput.ReadAsync($buffer, 0, $buffer.Length)
        if ($readTask.IsCompleted) {
            $count = $readTask.Result
            if ($count -gt 0) {
                $IntOutput += -join $buffer[0..($count-1)]
            }
        }
        else {
            # (debug purpose only)
            Write-SPOTLog "WARNING: Read task stuck even after process closed! Should not be the case." -DBG $true
        }
    }

    ######################
    $_spot_CMDOutput += $IntOutput
    $_spot_CMDOutput = $_spot_CMDOutput -split '\r?\n'
 
    ######################
    if ($NewScriptItem) {
        # this means the script extension was changed at the beginning of the script/function; changing it back
        Write-SPOTLog "INFO: The extension of the provided script file was modified to cmd. Trying to change it back." -DBG $true
        try {
            Rename-Item -Path $NewScriptItem.FullName -NewName "$($NewScriptItem.BaseName)$($ScriptItem.Extension)" -Confirm:$false -Force
        }
        catch {
            Write-SPOTLog "WARNING: could not change the script extension back to the original." -DBG $true
        }
    }

    ######################
    $_spot_ExitCode = $process.ExitCode
    Write-SPOTLog "Finished function Execute-CMDScript. Exit code was: $_spot_ExitCode. Script output below.`n###########################################"
    #### WARNING!!! #### the full output may contain secrets and they will appear in the logs.
    $_spot_CMDOutput

    ######################
    #  honor the exit code of the cmd script
    if ($_spot_ExitCode -ne 0) {
        throw "Execute-CMDScript: non-zero ExitCode!"
    }

} # end of Execute-CMDScript function

######################################################################################################################
function Execute-BashScript {
<#
.SYNOPSIS
Executes a Bash script with parameters and input data on a remote Linux computer.

.DESCRIPTION
Executes a Bash script on a remote Linux computer, over SSH, with the parameters provided.
If input data is also provided, it monitors the output and sends the input value when the output line is matching the prompt match string.
After the output string matching, there must be 2 seconds of no other output received to be considered a prompt for a value.
The initial prompt is detected automatically and there is a 10 seconds timeout for it,
The script must exist on the target computer or must be specified also locally, in order to be copied over before execution.
The $_spot_BashOutput variable contains the output, including the sent commands and the initial output.
It depends on the SPOT functions Write-SPOTLog, Test-SPOTTCPPort, Get-SPOTSshNetPath, Upload-FileSFTP and New-SPOTSSHSession. 

.PARAMETER TargetIP
Specifies the remote computer IP Address or hostname.

.PARAMETER Port
Specifies the port to be used, in case it is different from the default

.PARAMETER RemoteScriptPath
Specifies the path to the bash script (from the remote computer; linux path).

.PARAMETER ScriptParameters
Specifies the parameters to be used for the bash script.

.PARAMETER InputData
Specifies the input data to be used for the bash script input requests (on each array element split input prompt match string and value to be provided by %_%).

.PARAMETER LocalScriptPath
Specifies the path to the bash script (from the local computer; windows path; can be RFI; if not used, it is assumed the script is already present on the remote computer).

.PARAMETER Timeout
Specifies the overall timeout of the bash script execution, in seconds.

.PARAMETER Credential
Specifies the credential to connect to the remote system.

.PARAMETER TrustedHostsFilePath
Specifies the file path for a SPOT Trusted Hosts csv file to be used for SSH key validation.
If this parameter is not specified or empty, the SSH key validation is not enabled.

.PARAMETER SshNetPath
Specifies the local path to the Renci.SSHNet.dll file.

.INPUTS
None. You can't pipe objects to Execute-BashScript.

.OUTPUTS
System.String. Execute-BashScript may return only logging output. 

.EXAMPLE
PS> Execute-BashScript -TargetIP "192.168.0.2" -LocalScriptPath "C:\temp\test.sh" -RemoteScriptPath "/root/test.sh" -ScriptParameters "Par1 Par2" -InputData "username%_%john","age%_%25" -Timeout 180 -Credential $PSCredential
In this example the local script "C:\temp\test.sh" is uploaded to "192.168.0.2" in the path "/root/test.sh" and executed there with the parameters "Par1 Par2".
If an output line contains the string "username" and waits around 1.5 seconds, the value "john" is provided. The same happens for the string "age" with the value "25".
The overall script execution stops if more than 180 seconds pass.

.EXAMPLE
PS> Execute-BashScript -TargetIP "192.168.0.2" -RemoteScriptPath "/root/test.sh" -InputData "username%_%john" -Timeout 60 -Credential $PSCredential
In this example the script "/root/test.sh" from "192.168.0.2" is executed without parameters.
If an output line contains the string "username" and waits around 1.5 seconds, the value "john" is provided.
The overall script execution stops if more than 60 seconds pass.
#>

    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the remote computer IP Address or hostname
        $TargetIP,
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int]
        # the port to be used, in case it is different from the default
        $Port = 22,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the path to the bash script (from the remote computer; linux path)
        $RemoteScriptPath, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the parameters to be used for the bash script
        $ScriptParameters, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string[]]
        # the input data to be used for the bash script input requests (on each array element split input prompt match string and value to be provided by %_%)
        $InputData, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the path to the bash script (from the local computer; windows path; can be RFI; if not used, it is assumed the script is already present on the remote computer)
        $LocalScriptPath, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [int]
        # the overall timeout of the bash script execution, in seconds
        $Timeout, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.Management.Automation.PSCredential]
        # the credential to connect to the remote computer
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

    ######################
    Write-SPOTLog "Starting function Execute-BashScript with the parameters: TargetIP ""$TargetIP"", Port ""$Port"", RemoteScriptPath ""$RemoteScriptPath"", ScriptParameters ""$ScriptParameters"", InputData ""$InputData"", LocalScriptPath ""$LocalScriptPath"" and Timeout ""$Timeout""."

    ######################
    # get the local script file, if it was defined
    if ($LocalScriptPath) {
        if (Test-Path -Path $LocalScriptPath -PathType Leaf) {
            $_spot_LocalScriptItem = Get-Item -Path $LocalScriptPath -Force
        }
        else {
            Write-SPOTLog "ERROR: The local script file was not found. Cannot continue."
            throw "Execute-BashScript: script file missing!"
        }
    }
    
    ######################
    # test the availability of the TCP port on the remote computer
    $_spot_TCPTestResult = Test-SPOTTCPPort -TargetIP $TargetIP -TCPPort $Port
    if (!($_spot_TCPTestResult.TcpTestSucceeded)) {
        Write-SPOTLog "ERROR: The connectivity to the SSH port for host $TargetIP is not successfull. Ping test result was: $($_spot_TCPTestResult.PingSucceeded)."
        throw "Execute-BashScript: SSH port unreachable!"
    }

    #################################
    # test/detect the local Renci.SSHNet.dll file
    $SshNetPath = Get-SPOTSshNetPath -SshNetPath $SshNetPath
    if (!$SshNetPath) {
        Write-SPOTLog "ERROR: The SshNetPath was not provided/determined/detected. Cannot continue."
        throw "Execute-BashScript: SshNetPath not provided/determined/detected!"
    }
    
    #################################
    # if the local script has been defined, copy this file over to the target IP using SFTP
    if ($LocalScriptPath) {
        Write-SPOTLog "INFO: Uploading the local script file ""$($_spot_LocalScriptItem.FullName)"" to the target computer ""$($TargetIP)""." -DBG $true
        Upload-FileSFTP -TargetIP $TargetIP -Port $Port -RemotePath $RemoteScriptPath -LocalPath $_spot_LocalScriptItem.FullName -Credential $Credential -TrustedHostsFilePath $TrustedHostsFilePath -OutputFlag $false -SshNetPath $SshNetPath
    }

    #################################
    # create a SSH Session to the target IP
    $_spot_SSHSession = New-SPOTSSHSession -TargetIP $TargetIP -Port $Port -Credential $Credential -SshNetPath $SshNetPath -TrustedHostsFilePath $TrustedHostsFilePath -ErrorAction SilentlyContinue
    if ($_spot_SSHSession.IsConnected -ne $true) {
        Write-SPOTLog "ERROR: the SSH Session could not be established. Cannot continue."
        throw "Execute-BashScript: SFTP Session not established!"
    }

    #################################
    # create a SSH Shell Stream suitable for advanced output processing
    try {
        # use a large buffer to sustain waiting times in output processing, in case of large and fast output
        $_spot_SSHStream = $_spot_SSHSession.CreateShellStream('dumb', '250', '24', '800', '600', '32768')
    }
    catch {
        Write-SPOTLog "ERROR: while creating the SSH Shell Stream: $_."
        $_spot_SSHSession.Disconnect()
        $_spot_SSHSession.Dispose()
        throw "Execute-BashScript: error creating the SSHStream!"
    }
    
    ######################
    # process the remote path
    $_spot_RemotePath = (Split-Path -Path $RemoteScriptPath -Parent).Replace('\','/')
    $_spot_RemoteName = Split-Path -Path $RemoteScriptPath -Leaf


    ######################
    # transform the input pairs array into a hashtable, if provided
    if ($InputData) {
        $_spot_InputDataPairs = @{}
        $InputData | % {$_spot_InputDataPairs[($_ -split "%_%")[0]] = ($_ -split "%_%")[1]}
    }

    $_spot_BashOutput = ""
    ######################
    # wait for the prompt to start properly, with an empty read buffer
    $_spot_InitialOutput = ""
    Start-Sleep -Seconds 5
    $_spot_InitialOutput = $_spot_SSHStream.Read()
    if (!$_spot_InitialOutput) {
        # nothing read in the first 5 seconds, waiting another 5 seconds and then giving up
        Write-SPOTLog "INFO: Shell prompt taking longer than 5 seconds! Waiting 5 more seconds." -DBG $true
        Start-Sleep -Seconds 5
        $_spot_InitialOutput = $_spot_SSHStream.Read()
        if (!$_spot_InitialOutput) {
            # nothing read in the first 10 seconds, something must be wrong, stopping the execution
            Write-SPOTLog "ERROR: Timed out waiting for any shell prompt. Cannot continue."
            $_spot_SSHStream.Dispose()
            $_spot_SSHSession.Disconnect()
            $_spot_SSHSession.Dispose()
            throw "Execute-BashScript: timeout waiting for shell prompt!"
        }
    }
    Write-SPOTLog "INFO: Shell prompt detected!" -DBG $true
    $_spot_BashOutput += $_spot_InitialOutput

    ################################################
    # set the script as executable
    $_spot_SSHStream.WriteLine("cd $_spot_RemotePath; chmod +x ./$_spot_RemoteName && echo true || echo false")
    Start-Sleep -Milliseconds 200
    $_spot_SetExecOutput = $_spot_SSHStream.Read()
    $_spot_BashOutput += $_spot_SetExecOutput
    # check the result of last command
    $_spot_SetExecOutput = $_spot_SetExecOutput -split '\r?\n'
    if ($_spot_SetExecOutput.Count -gt 1) {
        if ($_spot_SetExecOutput[1] -ne $true) {
            Write-SPOTLog "ERROR: the file could not be set as executable. Output: ""$_spot_SetExecOutput"". Cannot continue."
            $_spot_SSHStream.Dispose()
            $_spot_SSHSession.Disconnect()
            $_spot_SSHSession.Dispose()
            throw "Execute-BashScript: error setting file executable!"
        }
    }
    else {
        Write-SPOTLog "ERROR: the file could not be set as executable. Output: ""$_spot_SetExecOutput"". Cannot continue."
        $_spot_SSHStream.Dispose()
        $_spot_SSHSession.Disconnect()
        $_spot_SSHSession.Dispose()
        throw "Execute-BashScript: error setting file executable!"
    }

    ################################################
    # define the exit override function
    $_spot_SSHStream.WriteLine("exit() { local status=`${1:-`$?}; echo ""SPOT Intercepted exit with code: `$status""; return `$status; }")
    Start-Sleep -Milliseconds 50
    # no point in capturing this in the output variable
    $_spot_SSHStream.Read() | Out-Null

    ################################################
    # run the script file remotely
    $_spot_SSHStream.WriteLine("_spot_sFlag=""_spot_BSF_""")
    Start-Sleep -Milliseconds 50
    $_spot_SSHStream.Read() | Out-Null
    # $StartTime = Get-Date
    $_spot_ScriptTimeout = $Timeout
    $_spot_ExpectString = [regex]"($(($_spot_InputDataPairs.Keys + "_spot_BSF_") -join "|"))"
    # Write-SPOTLog "INFO: ExpectString is: $ExpectString."
    $_spot_SSHStream.WriteLine(". $_spot_RemoteName $ScriptParameters; _spot_status=`$?; echo ""`$_spot_sFlag""")

    # start to expect the input data, if it was defined, or the end of the script
    while ($true) {
        $_spot_StartTime = Get-Date
        $_spot_found = $null
        $_spot_ExtraOutput = $null
        $_spot_LastLine = $null
        $_spot_LastLine2 = $null
        $_spot_StopTime = $null
        $_spot_found = $_spot_SSHStream.Expect($_spot_ExpectString,(New-TimeSpan -Seconds $_spot_ScriptTimeout))
        if ($_spot_found) {
            $_spot_StopTime = Get-Date
            # get any extra output after the 2 second threshold to make sure this is not a false positive (read meanwhile in order not to loose potential content from the buffer)
            Start-Sleep -Milliseconds 500
            $_spot_ExtraOutput += $_spot_SSHStream.Read()
            Start-Sleep -Milliseconds 500
            $_spot_ExtraOutput += $_spot_SSHStream.Read()
            Start-Sleep -Milliseconds 500
            $_spot_ExtraOutput += $_spot_SSHStream.Read()
            Start-Sleep -Milliseconds 500
            $_spot_ExtraOutput += $_spot_SSHStream.Read()
            # get the last line detected
            $_spot_BashOutput += $_spot_found
            $_spot_BashOutput += $_spot_ExtraOutput
            $_spot_found = $_spot_found -split '\r?\n'
            $_spot_ExtraOutput = $_spot_ExtraOutput -split '\r?\n'
            $_spot_LastLine = $_spot_found[$_spot_found.Count-1]
            # establish if this is really a stop for input or just a random match stop
            if ($_spot_LastLine -like "*_spot_BSF_*") {
                # end of script reached; exit the while loop
                Write-SPOTLog "INFO: Match found. Last line is ""$_spot_LastLine"". Script completed." -DBG $true
                break
            }
            elseif ($_spot_ExtraOutput.Count -gt 1) {
                # Write-SPOTLog "INFO: False positive encountered. ExtraOutput is ""$_spot_ExtraOutput"". Checking it now." -DBG $true
                # the extra output suggests it was a random match; check the last line also for this output part (if there are matches in other lines, they are for sure false positives)
                $_spot_LastLine2 = $_spot_ExtraOutput[$_spot_ExtraOutput.Count-1]
                if ($_spot_LastLine2 -like "*_spot_BSF_*") {
                    # end of script reached; exit the while loop
                    Write-SPOTLog "INFO: Match found. Last line is ""$_spot_LastLine2"". Script completed." -DBG $true
                    break
                }
                elseif ($_spot_LastLine2 -match $_spot_ExpectString) {
                    foreach ($_spot_i in $($_spot_InputDataPairs.Keys)) {
                        if ($_spot_LastLine2 -like "*$_spot_i*") {
                            Write-SPOTLog "INFO: Match found. Last line is ""$_spot_LastLine2"". Sending the associated input ""$($_spot_InputDataPairs[$_spot_i])""." -DBG $true
                            $_spot_SSHStream.WriteLine($_spot_InputDataPairs[$_spot_i])
                            # stop the foreach
                            break
                        }
                    }
                    # manage the ScriptTimeout
                    if ($_spot_ScriptTimeout -gt ($_spot_StopTime - $_spot_StartTime).Seconds) {
                        $_spot_ScriptTimeout -= ($_spot_StopTime - $_spot_StartTime).Seconds
                        # go back to the beginning of the while loop
                        continue
                    }
                    else {
                        # not enough timeout remaining but not finished; abort the runbook step
                        $_spot_BashOutput = $_spot_BashOutput -split '\r?\n'
                        Write-SPOTLog "ERROR: timeout reached while waiting for input data or end of the script. Current output: $_spot_BashOutput."
                        $_spot_SSHStream.Dispose()
                        $_spot_SSHSession.Disconnect()
                        $_spot_SSHSession.Dispose()
                        throw "Execute-BashScript: overall timeout reached without completion!"
                    }
                }
                else {
                    # no match in the extra output; manage the ScriptTimeout
                    if ($_spot_ScriptTimeout -gt ($_spot_StopTime - $_spot_StartTime).Seconds) {
                        $_spot_ScriptTimeout -= ($_spot_StopTime - $_spot_StartTime).Seconds
                        # go back to the beginning of the while loop
                        continue
                    }
                    else {
                        # not enough timeout remaining but not finished; abort the runbook step
                        $_spot_BashOutput = $_spot_BashOutput -split '\r?\n'
                        Write-SPOTLog "ERROR: timeout reached while waiting for input data or end of the script. Current output: $_spot_BashOutput."
                        $_spot_SSHStream.Dispose()
                        $_spot_SSHSession.Disconnect()
                        $_spot_SSHSession.Dispose()
                        throw "Execute-BashScript: overall timeout reached without completion!"
                    }
                }
            }
            else {
                # the extra output suggests this is a wait for input; send the matching output
                foreach ($_spot_i in $($_spot_InputDataPairs.Keys)) {
                    if ($_spot_LastLine -like "*$_spot_i*") {
                        Write-SPOTLog "INFO: Match found. Last line is ""$_spot_LastLine"". Sending the associated input ""$($_spot_InputDataPairs[$_spot_i])""." -DBG $true
                        $_spot_SSHStream.WriteLine($_spot_InputDataPairs[$_spot_i])
                        # stop the foreach
                        break
                    }
                }
                # manage the ScriptTimeout
                if ($_spot_ScriptTimeout -gt ($_spot_StopTime - $_spot_StartTime).Seconds) {
                    $_spot_ScriptTimeout -= ($_spot_StopTime - $_spot_StartTime).Seconds
                    # go back to the beginning of the while loop
                    continue
                }
                else {
                    # not enough timeout remaining but not finished; abort the runbook step
                    $_spot_BashOutput = $_spot_BashOutput -split '\r?\n'
                    Write-SPOTLog "ERROR: timeout reached while waiting for input data or end of the script. Current output: $_spot_BashOutput."
                    $_spot_SSHStream.Dispose()
                    $_spot_SSHSession.Disconnect()
                    $_spot_SSHSession.Dispose()
                    throw "Execute-BashScript: overall timeout reached without completion!"
                }
            }
        }
        else {
            # timout reached and no end flag detected; read whatever is found in the buffer now
            $_spot_BashOutput += $_spot_SSHStream.Read()
            # abort the runbook step
            $_spot_BashOutput = $_spot_BashOutput -split '\r?\n'
            Write-SPOTLog "ERROR: timeout reached while waiting for input data or end of the script. Current output: $_spot_BashOutput."
            $_spot_SSHStream.Dispose()
            $_spot_SSHSession.Disconnect()
            $_spot_SSHSession.Dispose()
            throw "Execute-BashScript: overall timeout reached without completion!"
        }
    }
    
    
    $_spot_BashOutput = $_spot_BashOutput -split '\r?\n'

    ######################
    # capture any variables to publish
    foreach ($_spot_VTP in $_spot_VTPs) {
        # try to avoid powershell step variables that already have values (risk of overwriting them) or spot internal variables
        if (($_spot_VTP.VarName -notlike "*_spot_*") -and (!(Get-Variable -Name $_spot_VTP.VarName -ErrorAction SilentlyContinue -ValueOnly))) {
            # Write-SPOTLog "INFO: Processing variable $($VTP.VarName)." -DBG $true
            $_spot_VTPOutput = ""
            $_spot_SSHStream.WriteLine("_spot_vFlag=""_spot_BVF_""")
            Start-Sleep -Milliseconds 50
            $_spot_SSHStream.Read() | Out-Null
            $_spot_SSHStream.WriteLine("echo ""`$$($_spot_VTP.VarName)""; echo ""`$_spot_vFlag""")           
            $_spot_found = $_spot_SSHStream.Expect("_spot_BVF_",(New-TimeSpan -Seconds 5))
            if ($_spot_found) {
                # read through to the end flag OK
                $_spot_VTPOutput += $_spot_found
            }
            else {
                # timout reached and no end flag detected; read whatever is found in the buffer now
                $_spot_VTPOutput += $_spot_SSHStream.Read()
                # abort reading current bash variable
                Write-SPOTLog "WARNING: failed to get the bash variable $($_spot_VTP.VarName). Current output: $_spot_VTPOutput." 
                continue
            }
            $_spot_SSHStream.Read() | Out-Null
            $_spot_VTPOutput = $_spot_VTPOutput -split '\r?\n'

            if ($_spot_VTPOutput.Count -gt 2) {
                New-Variable -Name $_spot_VTP.VarName -Value $_spot_VTPOutput[1..($_spot_VTPOutput.Count-2)]
            }
            else {
                # abort reading current bash variable
                Write-SPOTLog "WARNING: failed to get the bash variable $($_spot_VTP.VarName). Current output: $_spot_VTPOutput." 
                continue
            }
        }
    }

    ######################
    # return the bash script exit code and exit
    $_spot_SSHStream.WriteLine("echo ""`$_spot_status""; builtin exit")
    Start-Sleep -Milliseconds 100
    if ($_spot_SSHStream.DataAvailable) {
        $_spot_ExitOutput = $_spot_SSHStream.Read()
        $_spot_ExitOutput = $_spot_ExitOutput -split '\r?\n'
        if ($_spot_ExitOutput.Count -gt 1) {
            # get the bash script exit code using first method
            for ($_spot_i = ($_spot_ExitOutput.Count - 1); $_spot_i -gt 0; $_spot_i--){
                if ($_spot_ExitOutput[$_spot_i].Trim() -eq "logout") {
                    $_spot_ExitCode = $_spot_ExitOutput[$_spot_i-1].Trim()
                    break
                }
            }
            if (!$_spot_ExitCode) {
                # first method failed; get the ExitCode using the second method
                $_spot_ExitCode = $_spot_ExitOutput[1].Trim()
            }
        }
        else {
            Write-SPOTLog "WARNING: The ExitOutput is too short to determine the ExitCode. Defaulting it to 1." -DBG $true
            $_spot_ExitCode = 1
        }
    }
    else {
        Write-SPOTLog "WARNING: No ExitOutput found. Defaulting the ExitCode to 1." -DBG $true
        $_spot_ExitCode = 1
    }
    $_spot_BashOutput += $_spot_ExitOutput

    ######################
    # sessions cleanup
    $_spot_SSHStream.Dispose()
    $_spot_SSHSession.Disconnect()
    $_spot_SSHSession.Dispose()
    
    ######################
    Write-SPOTLog "Finished function Execute-BashScript. Exit code was: $_spot_ExitCode. Script output below.`n###########################################"
    #### WARNING!!! #### the full output may contain secrets and they will appear in the logs.
    $_spot_BashOutput

    ######################
    # honor the exit code of the bash script
    if ($_spot_ExitCode -ne 0) { 
        throw "Execute-BashScript: non-zero ExitCode!"
    }

} # end of Execute-BashScript function

######################################################################################################################
function Execute-SSHScript {
<#
.SYNOPSIS
Executes a SSH script on a remote device.

.DESCRIPTION
Connects to a remote device over SSH and executes a series of commands loaded from a local script file.
Before executing the commands from the local script file, each line is checked for $OV, $SV or $PV references and they get replaced, in string only mode.
Any secrets replaced in the commands may be visible in the log files.
When executed inside SPOT locally, the $SecVars parameter is not needed as the $SVars built-in variable is available. Neither is the $SshNetPath parameter needed as it is detected.
When executed inside SPOT remotely, the $SecVars parameter is needed as the $SVars built-in variable is not normally available. The same goes for the $SshNetPath parameter.
To reference the entire set of $SVars for the $SecVars parameter in remote executions, the syntax "$SV:." can be used in the command parameter part in the SPOT runbook file.
To reference the SshNet tool for the $SshNetPath parameter in remote executions, the syntax "$RFO:SSHNET" can be used in the command parameter part in the SPOT runbook file.
Each line may contain a prompt matching string at the beginning, split with "%_%" from the actual command. This is for the prompt after the command has been executed.
The Timeout parameter is for lines without prompt matching string, to move on to reading the output after a command has been sent.
The ExpectTimeout parameter is for lines with prompt matching string, to move on to reading the output after a command has been sent and no prompt match has been made.
The initial prompt is considered any output read at the beginning after a 5 seconds wait time.
The $_spot_FullOutput variable contains the full output, including the sent commands and the initial output.
The $_spot_CmdOutputOnly variable contains only the command outputs from all lines.
The main purpose for this function is to be a step function and not really a helper function.
It depends on the SPOT functions Write-SPOTLog, Test-SPOTTCPPort, Get-SPOTSshNetPath, New-SPOTSSHSession and Replace-SPOTLineVars.

.PARAMETER TargetIP
Specifies the target IP Address or hostname on which to execute the SSH script.

.PARAMETER Port
Specifies the port to be used, in case it is different from the default

.PARAMETER ScriptPath
Specifies the path to the SSH script to be executed line by line.

.PARAMETER Timeout
Specifies the number of seconds to wait between the commands are send and the output is read.

.PARAMETER ExpectTimeout
Specifies the number of seconds to wait for the prompt expect to match.

.PARAMETER Credential
Specifies the SSH credential to be used for remote authentication.

.PARAMETER TrustedHostsFilePath
Specifies the file path for a SPOT Trusted Hosts csv file to be used for SSH key validation.
If this parameter is not specified or empty, the SSH key validation is not enabled.

.PARAMETER SshNetPath
Specifies the local path to the Renci.SSHNet.dll file.

.PARAMETER SecVars
Specifies the collection of secrets from the Vault, for replacement inside script purposes.

.INPUTS
None. You can't pipe objects to Execute-SSHScript.

.OUTPUTS
System.String. Execute-SSHScript may return only logging output. 

.EXAMPLE
PS> Execute-SSHScript -TargetIP "192.168.0.2" -ScriptPath "C:\temp\test.txt" -Timeout 10 -ExpectTimeout 20 -Credential $PSCredential -SshNetPath "C:\Program Files\WindowsPowerShell\Modules\SPOT\tools\SshNet\Renci.SshNet.dll" -SecVars $SecretVariables
In this example the local script "C:\temp\test.txt" is executed line by line on the target device "192.168.0.2" over SSH.
Any references to $OV, $SV or $PV inside the script are replaced by the function.
After each line without prompt matching string, the function will wait 10 seconds for reading the output.
After each line with prompt matching string, if no match is found, the function will stop waiting for the expected prompt after 20 seconds and start to read the output.
The path to the SshNet tool and the $SecVars are specified, as it should when executing remotely inside SPOT.

.EXAMPLE
PS> Execute-SSHScript -TargetIP "192.168.0.2" -ScriptPath "C:\temp\test.txt" -Timeout 10 -ExpectTimeout 20 -Credential $PSCredential
In this example the local script "C:\temp\test.txt" is executed line by line on the target device "192.168.0.2" over SSH.
Any references to $OV, $SV or $PV inside the script are replaced by the function.
After each line without prompt matching string, the function will wait 10 seconds for reading the output.
After each line with prompt matching string, if no match is found, the function will stop waiting for the expected prompt after 20 seconds and start to read the output.
The path to the SshNet tool and the $SecVars are not specified, as it should when executing locally inside SPOT.
#>

    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the target IP Address or hostname on which to execute the SSH script
        $TargetIP,
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int]
        # the port to be used, in case it is different from the default
        $Port = 22,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the path to the SSH script to be executed line by line
        $ScriptPath, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [System.Management.Automation.PSCredential]
        # the SSH credential to be used for remote authentication
        $Credential,
        [Parameter(Mandatory=$false)]
        [AllowNull()]
        [string]
        # the path to the TrustedHosts file
        $TrustedHostsFilePath,
        [Parameter(Mandatory=$false)]
        [string]
        # the local path to the Renci.SSHNet.dll file
        $SshNetPath, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int]
        # the number of seconds to wait between the commands are send and the output is read
        $Timeout = 5, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int]
        # the number of seconds to wait for the prompt expect to match
        $ExpectTimeout = 30, 
        [Parameter(Mandatory=$false)]
        [hashtable]
        # the collection of secrets from the Vault, for replacement inside script purposes
        $SecVars 
        )
    
    # the scripts called by this function should contain on each line to be executed with prompt expect the separation string %_% followed by the expected prompt, or relevant part of the prompt
    # that should not be matched easily by usual command outputs
    # if the separation string is not found on a line, it is assumed that the line is to be executed with the specified timeout
    
    ######################
    Write-SPOTLog "Starting function Execute-SSHScript with the parameters: TargetIP $TargetIP, ScriptPath $ScriptPath, Timeout $Timeout and ExpectTimeout $ExpectTimeout."

    ######################
    # testing script path
    if (!(Test-Path -Path $ScriptPath -PathType Leaf)) {
        Write-SPOTLog "ERROR: No script file detected at the specified location $ScriptPath. Exiting."
        throw "Execute-SSHScript: script file missing!"
    }

    ######################
    # testing the availability of the TCP port on the remote computer
    $TCPTestResult = Test-SPOTTCPPort -TargetIP $TargetIP -TCPPort $Port
    if (!($TCPTestResult.TcpTestSucceeded)) {
        Write-SPOTLog "ERROR: The connectivity to the SSH port for host $TargetIP is not successfull. Ping test result was: $($TCPTestResult.PingSucceeded)."
        throw "Execute-SSHScript: SSH port unreachable!"
    }

    ######################
    # handling the SVars now
    if (!$SVars) {
        # the builtin SVars variable is not available; check if it was made available using the function parameter SecVars
        if (!$SecVars) {
            # SecVars are not available either; cannot substitute secrets inside the SSH script
            Write-SPOTLog "WARNING: SVars are not available in this execution. If the SSH script needs `$SV: replacements, they will fail." -DBG $true
        }
        else {
            # SecVars are available; working with them
            $SVars = $SecVars
        }
    }

    #################################
    # test/detect the local Renci.SSHNet.dll file
    $SshNetPath = Get-SPOTSshNetPath -SshNetPath $SshNetPath
    if (!$SshNetPath) {
        Write-SPOTLog "ERROR: The SshNetPath was not provided/determined/detected. Cannot continue."
        throw "Execute-SSHScript: SshNetPath not provided/determined/detected!"
    }

    #################################
    # create a SSH Session to the target IP
    $SSHSession = New-SPOTSSHSession -TargetIP $TargetIP -Port $Port -Credential $Credential -TrustedHostsFilePath $TrustedHostsFilePath -SshNetPath $SshNetPath
    if ($SSHSession -eq $false) {
        Write-SPOTLog "ERROR: the SSH Session could not be established. Cannot continue."
        throw "Execute-SSHScript: SSH Session not established!"
    }

    #################################
    # create a SSH Shell Stream suitable for advanced output processing
    try {
        $SSHStream = $SSHSession.CreateShellStream('dumb', '250', '24', '800', '600', '32768')
    }
    catch {
        Write-SPOTLog "ERROR: while creating the SSH Shell Stream: $_."
        $SSHSession.Disconnect()
        $SSHSession.Dispose()
        throw "Execute-SSHScript: error creating the SSHStream!"
    }

    ######################
    # load the script content
    $Script = Get-Content -Path $ScriptPath
    
    ######################
    $NewScript = @()
    # replacing any variables defined in the script content
    foreach ($line in $Script) { 
        # check for empty lines and skip them
        if ($line.Trim() -eq "") {
            continue
        }
        # replace any $PV or $SV or $OV variables here
        $tmp = $null
        $tmp = Replace-SPOTLineVars -line $line
        if ($tmp -ne $false) {
            $line = $tmp
        }
        else {
            Write-SPOTLog "ERROR: while replacing variables for line: ""$line""."
            $SSHStream.Dispose()
            $SSHSession.Disconnect()
            $SSHSession.Dispose()
            throw "Execute-SSHScript: error during variable replacement!"
        }
        $NewScript += $line 
    }
    
    # Write-SPOTLog "INFO: Changed ssh script: $NewScript." -DBG $true
    ######################
    # execution code
    $_spot_FullOutput = @()
    $_spot_CmdOutputOnly = @()
    # initialize the session by clearing the stream buffer from the initial prompt (cannot be more precise here as the target may not be a linux computer)
    Start-Sleep -Seconds 5
    # saving initial prompt, so not adding it to the COO
    while ($SSHStream.DataAvailable) {
        $_spot_FullOutput += $SSHStream.Read() -split '\r?\n'
    }

    ######################
    # starting to process the script lines
    foreach ($i in $NewScript) {
        $LineOutput = $null
        $found = $null
        $CommandSet = $i -split "%_%"
        if ($CommandSet.Count -eq 1) {
            #### WARNING!!! #### the current line may contain secrets and if the Debug setting is on, they will appear in the logs.
            Write-SPOTLog "Executing current command line ""$i"" with timeout ""$Timeout""." -DBG $true
            $SSHStream.WriteLine($i)
            # get the command itself (one line) and put it in the full output
            $_spot_FullOutput += $SSHStream.ReadLine()+"`n"
            # wait the timeout
            Start-Sleep -Seconds $Timeout
            # get the command output
            while ($SSHStream.DataAvailable) {
                $LineOutput += $SSHStream.Read()
            }
            # wait a little then get the output again, just in case of a small output pause
            Start-Sleep -Milliseconds 200
            while ($SSHStream.DataAvailable) {
                $LineOutput += $SSHStream.Read()
            }
            # put the command output in the full output and in the COO 
            $_spot_FullOutput += $LineOutput -split '\r?\n'
            # put only the output in the COO, avoiding the last line which should be the prompt
            if ($LineOutput.Count -gt 1) {
                $_spot_CmdOutputOnly += $LineOutput[0 .. ($LineOutput.Count-2)]
            }
        }
        elseif ($CommandSet.Count -eq 2) {
            #### WARNING!!! #### the current line may contain secrets and if the Debug setting is on, they will appear in the logs.
            Write-SPOTLog "Executing current command line ""$($CommandSet[1])"" with expect string ""$($CommandSet[0])"" and expect timeout ""$ExpectTimeout""." -DBG $true
            $SSHStream.WriteLine($CommandSet[1])
            # get the command itself (one line) and put it in the full output (not also in COO as this is the command)
            $_spot_FullOutput += $SSHStream.ReadLine()+"`n"
            # start with the expect 
            $found = $SSHStream.Expect($CommandSet[0],(New-TimeSpan -Seconds $ExpectTimeout))
	
            if ($found) {
                Write-SPOTLog "Expect string ""$($CommandSet[0])"" found." -DBG $true
                # finish the line with the matched string (if data available)
                while ($SSHStream.DataAvailable) {
                    $found += $SSHStream.Read()
                }
                # wait a little then get the output again, just in case of a small output pause
                Start-Sleep -Milliseconds 200
                while ($SSHStream.DataAvailable) {
                    $found += $SSHStream.Read()
                }
                $found = $found -split '\r?\n'
                # insert the output until the matched string line in both output variables
                $_spot_FullOutput += $found
                # put only the output in the COO, avoiding the last line which should be the prompt
                if ($found.Count -gt 1) {
                    $_spot_CmdOutputOnly += $found[0 .. ($found.Count-2)]
                }
            }
            else {
                Write-SPOTLog 'WARNING: Expect timeout reached without achieving a match.'
                # get the output so far
                while ($SSHStream.DataAvailable) {
                    $LineOutput += $SSHStream.Read()
                }
                # wait a little then get the output again, just in case of a small output pause
                Start-Sleep -Milliseconds 200
                while ($SSHStream.DataAvailable) {
                    $LineOutput += $SSHStream.Read()
                }
                $LineOutput = $LineOutput -split '\r?\n'
                # put the command output in the full output and in the COO 
                $_spot_FullOutput += $LineOutput
                # put only the output in the COO, avoiding the last line which should be the prompt
                if ($LineOutput.Count -gt 1) {
                    $_spot_CmdOutputOnly += $LineOutput[0 .. ($LineOutput.Count-2)]
                }
            }
        }
        else {
            #### WARNING!!! #### the current line may contain secrets and if the text formatting is wrong they will appear in the logs.
            Write-SPOTLog "ERROR: Bad text formatting encountered for the current line: ""$i"". It will not be executed."
            continue
        }
    }

    ######################
    # close all sessions
    $SSHStream.Dispose()
    $SSHSession.Disconnect()
    $SSHSession.Dispose()
    
    ######################
    Write-SPOTLog "Finished function Execute-SSHScript. Script output below.`n###########################################"
    #### WARNING!!! #### the full output may contain secrets and they will appear in the logs.
    $_spot_FullOutput

} # end of Execute-SSHScript function

######################################################################################################################
function Execute-TelnetScript {
<#
.SYNOPSIS
Executes a Telnet script on a remote device.

.DESCRIPTION
Connects to a remote device over Telnet and executes a series of commands loaded from a local script file.
Before executing the commands from the local script file, each line is checked for $Cred, $OV, $SV or $PV references and they get replaced, in string only mode.
For Telnet the authentication is performed during script execution so the username and password must be referenced inside the script with $Cred:Username and $Cred:Password.
These will be replaced with the credential elements from the $Credential function parameter.
Any secrets replaced in the commands may be visible in the log files.
When executed inside SPOT locally, the $SecVars parameter is not needed as the $SVars built-in variable is available.
When executed inside SPOT remotely, the $SecVars parameter is needed as the $SVars built-in variable is not normally available.
To reference the entire set of $SVars for the $SecVars parameter in remote executions, the syntax "$SV:." can be used in the command parameter part in the SPOT runbook file.
Each line may contain a prompt matching string at the beginning, split with "%_%" from the actual command. This is for the prompt after the command has been executed.
The Timeout parameter is for lines without prompt matching string, to move on to reading the output after a command has been sent.
The ExpectTimeout parameter is for lines with prompt matching string, to move on to reading the output after a command has been sent and no prompt match has been made.
The initial prompt is considered any output read at the beginning after a 5 seconds wait time.
The $_spot_FullOutput variable contains the full output, including the sent commands and the initial output.
The $_spot_CmdOutputOnly variable contains only the command outputs from all lines.
The main purpose for this function is to be a step function and not really a helper function.
It depends on the SPOT functions Write-SPOTLog, Test-SPOTTCPPort, Replace-SPOTLineCred and Replace-SPOTLineVars.

.PARAMETER TargetIP
Specifies the target IP Address or hostname on which to execute the Telnet script.

.PARAMETER ScriptPath
Specifies the path to the Telnet script to be executed line by line.

.PARAMETER Port
Specifies the telnet port to be used, in case it is different from the default.

.PARAMETER Timeout
Specifies the number of seconds to wait between the commands are send and the output is read.

.PARAMETER ExpectTimeout
Specifies the number of seconds to wait for the prompt expect to match.

.PARAMETER Credential
Specifies the Telnet credential to be used for remote authentication.

.PARAMETER SecVars
Specifies the collection of secrets from the Vault, for replacement inside script purposes.

.INPUTS
None. You can't pipe objects to Execute-TelnetScript.

.OUTPUTS
System.String. Execute-TelnetScript may return only logging output. 

.EXAMPLE
PS> Execute-TelnetScript -TargetIP "192.168.0.2" -ScriptPath "C:\temp\test.txt" -Timeout 10 -ExpectTimeout 20 -Credential $PSCredential -SecVars $SecretVariables
In this example the local script "C:\temp\test.txt" is executed line by line on the target device "192.168.0.2" over Telnet.
Any references to $Cred, $OV, $SV or $PV inside the script are replaced by the function.
After each line without prompt matching string, the function will wait 10 seconds for reading the output.
After each line with prompt matching string, if no match is found, the function will stop waiting for the expected prompt after 20 seconds and start to read the output.
The path to the $SecVars is specified, as it should when executing remotely inside SPOT.

.EXAMPLE
PS> Execute-TelnetScript -TargetIP "192.168.0.2" -ScriptPath "C:\temp\test.txt" -Timeout 10 -ExpectTimeout 20 -Credential $PSCredential
In this example the local script "C:\temp\test.txt" is executed line by line on the target device "192.168.0.2" over Telnet.
Any references to $Cred, $OV, $SV or $PV inside the script are replaced by the function.
After each line without prompt matching string, the function will wait 10 seconds for reading the output.
After each line with prompt matching string, if no match is found, the function will stop waiting for the expected prompt after 20 seconds and start to read the output.
The path to the $SecVars is not specified, as it should when executing locally inside SPOT.
#>

    Param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the target IP Address or hostname on which to execute the Telnet script 
        $TargetIP, 
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        # the path to the Telnet script to be executed line by line
        $ScriptPath, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [System.Management.Automation.PSCredential]
        # the Telnet credential to be used for remote authentication
        $Credential, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int]
        # the telnet port to be used, in case it is different from the default
        $Port = 23, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int]
        # the number of seconds to wait between the commands are send and the output is read
        $Timeout = 5, 
        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int]
        # the number of seconds to wait for the prompt expect to match
        $ExpectTimeout = 30, 
        [Parameter(Mandatory=$false)]
        [hashtable]
        # the collection of secrets from the Vault, for replacement inside script purposes
        $SecVars 
        )


    ######################
    Write-SPOTLog "Starting function Execute-TelnetScript with the parameters: TargetIP $TargetIP, ScriptPath $ScriptPath and Timeout $Timeout."

    ######################
    # testing the availability of the desired TCP port on the remote computer
    $TCPTestResult = Test-SPOTTCPPort -TargetIP $TargetIP -TCPPort $Port
    if (!($TCPTestResult.TcpTestSucceeded)) {
        Write-SPOTLog "ERROR: The connectivity to the Telnet port $Port for host $TargetIP is not successfull. Ping test result was: $($TCPTestResult.PingSucceeded)."
        throw "Execute-TelnetScript: Telnet port unreachable!"
    }

    ######################
    # testing script path
    if (!(Test-Path -Path $ScriptPath -PathType Leaf)) {
        Write-SPOTLog "ERROR: No script file detected at the specified location $ScriptPath. Exiting."
        throw "Execute-TelnetScript: script file missing!"
    }
    
    ######################
    # handling the SVars now
    if (!$SVars) {
        # the builtin SVars variable is not available; check if it was made available using the function parameter SecVars
        if (!$SecVars) {
            # SecVars are not available either; cannot substitute secrets inside the Telnet script
            Write-SPOTLog "WARNING: SVars are not available in this execution. If the Telnet script needs `$SV: replacements, they will fail."
        }
        else {
            # SecVars are available; working with them
            $SVars = $SecVars
        }
    }

    ######################
    # loading the script content
    $Script = Get-Content -Path $ScriptPath
    $NewScript = @()
    # replacing any variables defined in the script content
    foreach ($line in $Script) { 
        
        # check for empty lines and skip them
        if ($line.Trim() -eq "") {
            continue
        }

        # replace line Creds here 
        $tmp = $null
        $tmp = Replace-SPOTLineCred -line $line -Credential $Credential
        if ($tmp -ne $false) {
            $line = $tmp
        }
        else {
            Write-SPOTLog "ERROR: while replacing credentials for line: ""$line"" ."
            throw "Execute-TelnetScript: error during variable replacement!"
        }

        # replace any $PV or $SV or $OV variables here
        $tmp = $null
        $tmp = Replace-SPOTLineVars -line $line
        if ($tmp -ne $false) {
            $line = $tmp
        }
        else {
            Write-SPOTLog "ERROR: while replacing variables for line: ""$line"" ."
            throw "Execute-TelnetScript: error during variable replacement!"
        }
        $NewScript += $line 
    }

    # Write-SPOTLog "Changed telnet script: $NewScript." -DBG $true
    ######################
    # code execution
    $_spot_FullOutput = @()
    $_spot_CmdOutputOnly = @()

    # connect / create session
    $TelnetSession = New-SPOTTelnetSession -TargetIP $TargetIP -Port $Port -ErrorAction Stop

    if ($TelnetSession.Connected) {
        ################################
        # set large buffer size to handle potential large output
        $TelnetSession.ReadBufferSize = [int]32768
        # get initial output
        $InitialOutput = $null
        # wait for the prompt
        Start-Sleep -Seconds 5
        while ($TelnetSession.Available -gt 0) {
            try {
                $InitialOutput += $TelnetSession.ReadOutput()
            }
            catch {
                Write-SPOTLog "ERROR: while getting initial telnet output: $_."
            }
        }
        # save the initial output
        $_spot_FullOutput += $InitialOutput -split '\r?\n'

        ################################
        # execute the telnet script line by line
        if ($TelnetSession.Connected) {
            foreach ($i in $NewScript) {
                # process only lines with content in them
                if (($i -replace '\s+', '') -ne "") {
                    $LineOutput = $null
                    $CommandSet = $i -split "%_%"
                    if ($CommandSet.Count -eq 1){
                        #### WARNING!!! #### the current line may contain secrets and if the Debug setting is on, they will appear in the logs.
                        Write-SPOTLog "Executing current command line ""$i"" with timeout ""$Timeout""." -DBG $true
                        # send the command
                        $TelnetSession.WriteLine($i) | Out-Null
                        # wait the timeout
                        Start-Sleep -Seconds $Timeout
                        # get the output
                        while ($TelnetSession.Available -gt 0) {
                            $LineOutput += $TelnetSession.ReadOutput()
                        }
                        # wait a little then get the output again, just in case of a small output pause
                        Start-Sleep -Milliseconds 200
                        while ($TelnetSession.Available -gt 0) {
                            $LineOutput += $TelnetSession.ReadOutput()
                        }
                        # process the output received for the current line
                        if ($LineOutput) {
                            $LineOutput = $LineOutput -split '\r?\n'
                            if ($LineOutput[0].Trim() -eq $i.Trim()) {
                                # Write-SPOTLog "INFO: First line from output is the sent command, as expected." -Output $false -DBG $true
                                $_spot_CmdOutputOnly += $LineOutput[1..($LineOutput.Count-2)]
                            }
                            else {
                                Write-SPOTLog "WARNING: First line from line output is NOT the sent command, as expected." -DBG $true
                                Write-SPOTLog " > First line from line output : $($LineOutput[0].Trim())." -DBG $true
                                Write-SPOTLog " > Sent command                : $($i.Trim())." -DBG $true
                                $_spot_CmdOutputOnly += $LineOutput[0..($LineOutput.Count-2)]
                            }
                            # add the line output and keep the commands on the same line as the previous prompt
                            $_spot_FullOutput[$_spot_FullOutput.Count-1] += $LineOutput[0]
                            $_spot_FullOutput += $LineOutput[1..($LineOutput.Count-1)]
                        }
                        else {
                            #### WARNING!!! #### the current line may contain secrets and if the Debug setting is on, they will appear in the logs.
                            Write-SPOTLog "WARNING: For current command line ""$i"" there was no output available within the timeout." -DBG $true
                        }
                    }
                    elseif ($CommandSet.Count -eq 2) {
                        #### WARNING!!! #### the current line may contain secrets and if the Debug setting is on, they will appear in the logs.
                        Write-SPOTLog "Executing current command line ""$($CommandSet[1])"" with expect string ""$($CommandSet[0])"" and expect timeout ""$ExpectTimeout""." -DBG $true
                        # send the command
                        $TelnetSession.WriteLine($CommandSet[1]) | Out-Null
                        # start with the expect
                        $StartTime = Get-Date
                        while ([math]::floor(((Get-Date) - $StartTime).TotalSeconds) -lt $ExpectTimeout) {
                            $InterOutput = $null
                            # wait between attempts
                            Start-Sleep -Seconds 1
                            if ($TelnetSession.Available -gt 0) {
                                try {
                                    $InterOutput = $TelnetSession.ReadOutput()
                                }
                                catch {
                                    Write-SPOTLog "ERROR: while getting intermediary telnet output: $_."
                                }
                                if ($InterOutput) {
                                    # Write-SPOTLog "INFO: Intermediary Output detected: $InterOutput." -Output $false -DBG $true
                                    # check for the expect string
                                    if ($InterOutput -notlike "*$($CommandSet[0])*") {
                                        $LineOutput += $InterOutput
                                    }
                                    else {
                                        Write-SPOTLog "INFO: ExpectString ""$($CommandSet[0])"" found!" -DBG $true
                                        # get the entire pending output
                                        while ($TelnetSession.Available -gt 0) {
                                            $InterOutput += $TelnetSession.ReadOutput()
                                        }
                                        Start-Sleep -Milliseconds 200
                                        while ($TelnetSession.Available -gt 0) {
                                            $InterOutput += $TelnetSession.ReadOutput()
                                        }
                                        # process the line output
                                        $LineOutput += $InterOutput
                                        # now the entire line output is available; splitting it
                                        $LineOutput = $LineOutput -split '\r?\n'
                                        # add the line output and keep the commands on the same line as the previous prompt
                                        $_spot_FullOutput[$_spot_FullOutput.Count-1] += $LineOutput[0]
                                        $_spot_FullOutput += $LineOutput[1..($LineOutput.Count-1)]

                                        if ($LineOutput.Count -ge 3) {
                                            # handle first line output
                                            if ($LineOutput[0].Trim() -eq $CommandSet[1].Trim() ) {
                                                # Write-SPOTLog "INFO: First line from the line output is the sent command, as expected." -Output $false -DBG $true
                                                $COOFirstLine = 1
                                            }
                                            else {
                                                Write-SPOTLog "WARNING: First line from the line output is NOT the sent command, as expected. Including it in the CommandOutputsOnly." -DBG $true
                                                $COOFirstLine = 0
                                            }
                                            # handle last line output
                                            if ($LineOutput[($LineOutput.Count-1)].Trim() -eq $CommandSet[0].Trim()) {
                                                # Write-SPOTLog "INFO: The expect string was detected at the last line, as expected." -Output $false -DBG $true
                                                $_spot_CmdOutputOnly += $LineOutput[$COOFirstLine..($LineOutput.Count-2)]
                                            }
                                            else {
                                                Write-SPOTLog "WARNING: The expect string was detected, but not at the last line, as expected!" -DBG $true
                                                Write-SPOTLog " > Check the full outputs and adapt the Telnet script for future executions!" -DBG $true
                                                Write-SPOTLog " > Currently the entire detected output will be included in the CommandOutputsOnly." -DBG $true
                                                $_spot_CmdOutputOnly += $LineOutput[$COOFirstLine..($LineOutput.Count-1)]
                                            }
                                        }
                                        else {
                                            Write-SPOTLog "WARNING: Not enough output lines detected to include any command output!" -DBG $true
                                        }
                                        # breaking now as the expect string was found, last line or not
                                        break
                                    }
                                }
                            }
                        }
                    }
                    else {
                        #### WARNING!!! #### the current line may contain secrets and if the text formatting is wrong they will appear in the logs.
                        Write-SPOTLog "ERROR: Bad text formatting encountered for the current line: ""$i"". It will not be executed."
                        continue
                    }
                }
            }
        }
        else {
            Write-SPOTLog "ERROR: The TelnetSession is no longer connected for the telnet script to execute. Cannot continue."
            throw "Execute-TelnetScript: telnet connection lost!"
        }
        
        ################################
        # close the telnet session at the end
        $TelnetSession.RemoveSession()
    }
    else {
        Write-SPOTLog "ERROR: The TelnetSession did not connect. Cannot continue."
        throw "Execute-TelnetScript: telnet session not established!"
    }
    
    ######################
    Write-SPOTLog "Finished function Execute-TelnetScript. Script output below.`n###########################################"
    #### WARNING!!! #### the full output may contain secrets and they will appear in the logs.
    $_spot_FullOutput

} # end of Execute-TelnetScript function
