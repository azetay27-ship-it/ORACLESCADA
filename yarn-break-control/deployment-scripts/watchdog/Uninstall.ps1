#requires -Version 2.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$taskName = 'NILIT EF Watchdog'
$taskSource = 'NILIT.EF.Watchdog.v2'
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path

try {
    . (Join-Path $scriptDirectory 'Common.ps1')
    . (Join-Path $scriptDirectory 'TaskIdentity.ps1')
    $scriptDirectory = Get-CanonicalPath $scriptDirectory
    $scheduler = New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    $folder = $scheduler.GetFolder('\')
    $registeredTask = $null
    try { $registeredTask = $folder.GetTask($taskName) }
    catch {
        $exception = $_.Exception
        while ($null -ne $exception.InnerException) { $exception = $exception.InnerException }
        $errorCode = [System.Runtime.InteropServices.Marshal]::GetHRForException($exception)
        if ($errorCode -ne -2147024894 -and $errorCode -ne -2147024893) { throw }
    }
    if ($null -ne $registeredTask) {
        $definition = $registeredTask.Definition
        if ($definition.RegistrationInfo.Source -cne $taskSource) {
            throw 'The existing task is not owned by this package. It was not changed.'
        }
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        Assert-TaskPrincipal $definition.Principal $identity.User.Value $identity.Name
        if ($definition.Actions.Count -ne 1 -or $definition.Actions.Item(1).Type -ne 0) {
            throw 'The existing task has unexpected actions. It was not changed.'
        }
        $action = $definition.Actions.Item(1)
        if ([string]::IsNullOrEmpty($action.WorkingDirectory) -or
            (Get-CanonicalPath $action.WorkingDirectory) -ine $scriptDirectory -or
            $action.Arguments -notlike '*-File *Watchdog.ps1*') {
            throw 'Run Uninstall.cmd from the folder used by the installed watchdog.'
        }
    }
    [System.IO.File]::WriteAllText((Join-Path $scriptDirectory 'PAUSED'), 'Paused by uninstall at ' + [DateTime]::UtcNow.ToString('o'))
    [System.IO.File]::WriteAllText((Join-Path $scriptDirectory 'STOP'), 'Stop monitor requested by uninstall at ' + [DateTime]::UtcNow.ToString('o'))
    if ($null -ne $registeredTask) {
        $registeredTask.Enabled = $false
        $folder.DeleteTask($taskName, 0)
        Write-Host 'The owned NILIT EF Watchdog task was disabled and removed.'
    }
    else { Write-Host 'The scheduled task is already absent.' }
    Write-Host 'The monitor will exit after its current check. NILIT was not stopped.'
    Write-Host 'The independent Vuniq keeper is LEFT RUNNING so Vuniq can remain open. Use StopKeeper.cmd to release it before deleting this folder.'
    Write-Host 'Keep PAUSED and STOP in place. Install.cmd is required to reinstall supervision.'
    exit 0
}
catch {
    Write-Error ('Uninstall failed: ' + $_.Exception.Message) -ErrorAction Continue
    exit 1
}
