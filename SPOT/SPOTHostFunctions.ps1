# SPOT Built-in Host Functions 
# v1.0 - 26.04.2026 - initial version
# 
#
# 
######################################################################################################################
function Write-Host {
    [CmdletBinding()]
    param(
        # Main "Object" parameter - implicit and collects all unnamed args
        [Parameter(
            Position = 0,
            ValueFromRemainingArguments = $true
        )]
        [Object[]] $Object,

        # Foreground color
        [string] $ForegroundColor,

        # Background color
        [string] $BackgroundColor,

        # Do not write a newline
        [switch] $NoNewline
    )

    # Build parameter hashtable to pass to Write-Host internally
    $OutString = "$(Get-Date -Format "yyyy-MM-dd HH:mm:ss") :: HOST"
    $text = ($Object -join " ")
    if ($ForegroundColor) { $OutString += ">FG:$ForegroundColor" }
    if ($BackgroundColor) { $OutString += ">BG:$BackgroundColor" }
    $OutString += " >> $text"

    Write-Output $OutString
} # end of Write-Host function

######################################################################################################################
function Write-Warning {
    [CmdletBinding()]
    param(
        # Main "Message" parameter - implicit and collects all unnamed args
        [Parameter(
            Position = 0,
            ValueFromRemainingArguments = $true
        )]
        [string] $Message
    )

    # Build parameter hashtable to pass to Write-Host internally
    $OutString = "$(Get-Date -Format "yyyy-MM-dd HH:mm:ss") :: WARNING"
    $text = ($Message -join " ")
    $OutString += " >> $text"

    if ($WarningPreference -eq 'Continue') {
        Write-Output $OutString
    }
} # end of Write-Warning function

######################################################################################################################
function Write-Verbose {
    [CmdletBinding()]
    param(
        # Main "Message" parameter - implicit and collects all unnamed args
        [Parameter(
            Position = 0,
            ValueFromRemainingArguments = $true
        )]
        [string] $Message
    )

    # Build parameter hashtable to pass to Write-Host internally
    $OutString = "$(Get-Date -Format "yyyy-MM-dd HH:mm:ss") :: VERBOSE"
    $text = ($Message -join " ")
    $OutString += " >> $text"

    if (($VerbosePreference -eq 'Continue') -or ($PSBoundParameters.ContainsKey('Verbose'))) {
        Write-Output $OutString
    }
} # end of Write-Verbose function

######################################################################################################################
function Write-Debug {
    [CmdletBinding()]
    param(
        # Main "Message" parameter - implicit and collects all unnamed args
        [Parameter(
            Position = 0,
            ValueFromRemainingArguments = $true
        )]
        [string] $Message
    )

    # Build parameter hashtable to pass to Write-Host internally
    $OutString = "$(Get-Date -Format "yyyy-MM-dd HH:mm:ss") :: DEBUG"
    $text = ($Message -join " ")
    $OutString += " >> $text"

    if (($DebugPreference -eq 'Continue') -or ($PSBoundParameters.ContainsKey('Debug'))) {
        Write-Output $OutString
    }
} # end of Write-Debug function

######################################################################################################################
function exit {
    param(
        [int]$_spot_ExitCode = 0
    )

    Write-Output "SPOT Intercepted 'exit' with code: $_spot_ExitCode"
    if ($_spot_ExitCode -ne 0) {
        throw "exit_intercept: non-zero ExitCode!"
    }
    else {
        return
    }
    
} # end of exit function

######################################################################################################################
