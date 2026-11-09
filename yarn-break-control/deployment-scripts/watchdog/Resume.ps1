#requires -Version 2.0
$ErrorActionPreference = 'Stop'
$taskName = 'NILIT EF Watchdog'
$taskSource = 'NILIT.EF.Watchdog.v2'

function Get-ExistingTask($Folder, [string]$Name) {
    try { return $Folder.GetTask($Name) }
    catch {
        $exception = $_.Exception
        while ($null -ne $exception.InnerException) { $exception = $exception.InnerException }
        $errorCode = [System.Runtime.InteropServices.Marshal]::GetHRForException($exception)
        if ($errorCode -eq -2147024894 -or $errorCode -eq -2147024893) { return $null }
        throw
    }
}

try {
    $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    . (Join-Path $scriptDirectory 'Common.ps1')
    . (Join-Path $scriptDirectory 'TaskIdentity.ps1')
    $scriptDirectory = Get-CanonicalPath $scriptDirectory
    if (Test-Path -LiteralPath (Join-Path $scriptDirectory 'STOP')) {
        throw 'This watchdog was uninstalled. Run Install.cmd first, then Resume.cmd.'
    }
    $scheduler = New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    $folder = $scheduler.GetFolder('\')
    $registeredTask = Get-ExistingTask $folder $taskName
    if ($null -eq $registeredTask) { throw 'NILIT EF Watchdog is not installed. Run Install.cmd first.' }
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
        throw 'Run Resume.cmd from the folder used by the installed NILIT watchdog.'
    }
    $legacySources = @{
        'NILIT GH Watchdog' = 'NILIT.GH.Watchdog.v1'
        'Vuniq GH Watchdog' = 'NILIT.Vuniq.GH.Watchdog.v1'
        'NILIT Watchdog' = 'NILIT.YarnBreak.Watchdog.v1'
    }
    foreach ($legacyName in $legacySources.Keys) {
        $legacyTask = Get-ExistingTask $folder $legacyName
        if ($null -eq $legacyTask) { continue }
        if ($legacyTask.Definition.RegistrationInfo.Source -cne $legacySources[$legacyName]) { continue }
        if ($legacyTask.Enabled -or $legacyTask.State -eq 4) {
            throw ('An older monitor is still installed: "' + $legacyName + '". Run Uninstall.cmd from its original folder first, then Resume.cmd here. The old task was not changed.')
        }
    }
    if (-not $registeredTask.Enabled) { $registeredTask.Enabled = $true }
    [System.IO.File]::Delete((Join-Path $scriptDirectory 'PAUSED'))
    [System.IO.File]::Delete((Join-Path $scriptDirectory 'KEEPER_STOP'))
    try { $runningTask = $registeredTask.Run($null) }
    catch {
        throw ('Pause was removed, but the NILIT monitor start request failed: ' + $_.Exception.Message + '. The installed task remains enabled and will retry on its next scheduled trigger.')
    }
    Write-Host 'NILIT supervision resumed. Start requested for the installed hidden monitor now.'
    Write-Host 'If already running, the same monitor continues; no second task instance is started.'
    Write-Host 'For NILIT recovery, the monitor waits and restarts NILIT only. Vuniq and its independent keeper are preserved.'
    Write-Host 'The independent x86 keeper holds one empty connector and can activate Vuniq when absent; it never closes Vuniq.'
    exit 0
}
catch {
    Write-Error ('Resume failed: ' + $_.Exception.Message) -ErrorAction Continue
    exit 1
}
