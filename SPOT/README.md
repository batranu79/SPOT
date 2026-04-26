# SPOT Description

SPOT stands for **Simple PowerShell Orchestration Tool**. It was developed to make orchestration simpler, mainly for system administrators and developers
that use PowerShell in their work. It allows the users to focus on creating their scripts and functions for the tasks they need to accomplish, instead of
developing a lot of extra code for the sole purpose of managing things like remote execution, execution sequences, execution parallelization, artefacts
collection and other similar topics. 

# What to expect from SPOT

Unlike many other orchestration tools, *SPOT does not offer a vast collection of scripts/functions/methods to perform various orchestration tasks* (e.g.
installing or configuring a specific service). I believe PowerShell already offers that and the available configuration granularity is a good thing. It
provides options to accommodate various requirements from various users and any attempts to simplify this is, at the end of the day, a reduction of that
flexibility. So the users are responsible for creating the building blocks of their orchestrations, like scripts or functions to install and configure
operating systems, services, applications and others. SPOT only takes care about arranging, transporting and executing these building blocks.

Like the name suggests, *SPOT is simple, focused on executing a collection of user made scripts or functions in a configurable sequence*. There is no
associated SPOT database or service for persistence of data. It all starts when the execution of a SPOT sequence starts and it all ends when that execution
is finished. The only things that remains at the end are some variables in the hosting PowerShell process and the SPOT log files, or artefacts, collected in
a central folder.

One of the big advantages of using SPOT is to *avoid the hassle of remote execution in PowerShell*. There are built-in methods for this, like the PSSession
related ones, and they are used also inside SPOT, but the associated requirements and the security measures put in place make them hard to manage: the
PSRemoting may not be enabled on the target computer, the required ports may not be open, some GPO policy may block special remote logons, etc. SPOT does not
bypass such security measures, it just provides a collection of methods for remote execution that allows most users to find a working method. And what is more
interesting, all these methods offer mostly the same experience/options.

Another big "selling point" for SPOT is that *it provides a lot of flexibility for the execution sequence*. Again, of course there are built-in methods for this
in PowerShell that allow with ease the execution of a script after another, or the execution in parallel. SPOT supplements this with things like parallelization
of different scripts/functions, execution sequence nesting, control of the execution sequence not only based on error, etc.

For security reasons, *SPOT offers secret management based on vaults*, but in a simple way for the user. The user scripts or functions does not have to access
the secrets with special vault related commands, they can be instead just referenced as parameters or even referenced directly inside these scripts or functions.

Non-interactive command line execution is great and SPOT operates like this without any issues. While executing in command line, it does provide an overall
progress update but other than that, you cannot interact with the execution. There is also a *GUI execution mode available in SPOT* and besides a more relevant
visual representation of the progress, it does provide the option to stop and resume the execution sequence.

# Use case scenarios for SPOT

There are mainly two scenarios for which SPOT has been designed and developed: *orchestration* in general (deployment or operational) and *CI/CD pipelines*.
As SPOT is an orchestration tool for PowerShell, it can only orchestrate PowerShell scripts or functions directly. However, these payload PowerShell scripts or
functions can perform tasks remotely, on other platforms and operating systems. Even if SPOT does not provide a vast collection of such pre-made orchestration
building blocks, it does provide a limited set. Some of them are pretty powerful and flexible. With these functions available, SPOT can perform, by itself,
orchestration on remote *Linux environments*, *network appliances* and others, via protocols like *SSH* and *Telnet* (initial provisioning).

# SPOT Documentation

A QuickStart Guide and a more detailed Manual for SPOT can be found here: https://github.com/batranu79/SPOT/docs

# THIRD-PARTY

This module depends on external PowerShell modules and tools, which may be installed separately and are subject to their own licenses.  
Below is a technical list of all potential dependencies for this project:  
- microsoft.powershell.secretmanagement (required dependency)
- microsoft.powershell.secretstore (required dependency)
- powershell-yaml (required dependency)
- posh-ssh / ssh.net (optional dependency)
- PsExec (optional dependency)
- Notepad++ (optional dependency)