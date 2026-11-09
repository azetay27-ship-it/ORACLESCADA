#requires -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$taskName = 'NILIT EF Watchdog'
$taskSource = 'NILIT.EF.Watchdog.v2'
Write-Host 'NILIT EF Watchdog v1.3.2-test - independent Vuniq check'
Write-Host ('Package folder: ' + $root)

try {
    . (Join-Path $root 'Common.ps1')
    $scheduler = New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    $folder = $scheduler.GetFolder('\')
    $registeredTask = $null
    try { $registeredTask = $folder.GetTask($taskName) }
    catch {
        $exception = $_.Exception
        while ($null -ne $exception.InnerException) { $exception = $exception.InnerException }
        $errorCode = [Runtime.InteropServices.Marshal]::GetHRForException($exception)
        if ($errorCode -ne -2147024894 -and $errorCode -ne -2147024893) { throw }
    }
    if ($null -eq $registeredTask) {
        Write-Host 'Scheduled task: NOT INSTALLED. Install.cmd registers and starts supervision.'
    } else {
        $definition = $registeredTask.Definition
        $stateNames = @('Unknown','Disabled','Queued','Ready','Running')
        $taskState = [int]$registeredTask.State
        $stateLabel = [string]$taskState
        if ($taskState -ge 0 -and $taskState -lt $stateNames.Count) { $stateLabel = $stateNames[$taskState] }
        Write-Host ('Scheduled task: ' + $registeredTask.Path + '; Enabled=' + $registeredTask.Enabled + '; State=' + $stateLabel)
        Write-Host ('Last task result: ' + $registeredTask.LastTaskResult + '; Last run: ' + $registeredTask.LastRunTime)
        Write-Host ('Task operator: ' + $definition.Principal.UserId)
        if ($definition.RegistrationInfo.Source -cne $taskSource -or $definition.Actions.Count -ne 1) {
            Write-Host 'Task ownership does not match this package. Check the installed copy.'
        } else {
            $action = $definition.Actions.Item(1)
            Write-Host ('Installed folder: ' + $action.WorkingDirectory)
            if ((Get-CanonicalPath $action.WorkingDirectory) -ine (Get-CanonicalPath $root)) {
                Write-Host 'This is a different package folder from the installed watchdog.'
            }
        }
    }
} catch {
    Write-Host ('Scheduled task status unavailable: ' + $_.Exception.Message)
}

$logPath = Join-Path $root 'runtime\watchdog.log'
if ([IO.File]::Exists($logPath)) {
    Write-Host 'Recent monitor log:'
    try { Get-Content -LiteralPath $logPath | Select-Object -Last 12 | ForEach-Object { Write-Host $_ } }
    catch { Write-Host ('Cannot read monitor log: ' + $_.Exception.Message) }
} else { Write-Host 'Monitor log: not created yet.' }

$keeperLog=Join-Path $root 'runtime\keeper.log'
if ([IO.File]::Exists($keeperLog)) {
    Write-Host 'Recent independent connector log:'
    try { Get-Content -LiteralPath $keeperLog | Select-Object -Last 8 | ForEach-Object { Write-Host $_ } }
    catch { Write-Host ('Cannot read keeper log: '+$_.Exception.Message) }
}

Write-Host 'Current application check (does not start or stop NILIT):'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
& $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'Watchdog.ps1') -CheckOnly
exit $LASTEXITCODE
