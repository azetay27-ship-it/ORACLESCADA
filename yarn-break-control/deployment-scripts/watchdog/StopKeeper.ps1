#requires -Version 2.0
# Explicit maintenance action. Never triggered by NILIT closure, Pause or Uninstall.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
try {
    . (Join-Path $root 'Common.ps1')
    $session=[Diagnostics.Process]::GetCurrentProcess().SessionId
    $keeper=Get-ExactProcess (Join-Path $root 'VuniqKeeper132.exe') $session $false 'Vuniq keeper'
    [IO.File]::WriteAllText((Join-Path $root 'PAUSED'),'Maintenance: stop independent keeper.')
    [IO.File]::WriteAllText((Join-Path $root 'KEEPER_STOP'),'Explicit keeper stop requested.')
    Write-Host 'NILIT supervision paused. Releasing the independent connector; no Vuniq close/kill command is sent.'
    Write-Host 'If it is the last COM client, Vuniq MAY exit according to its own server lifetime policy.'
    if ($null -ne $keeper) {
        $wait=[Diagnostics.Stopwatch]::StartNew()
        do {
            Start-Sleep -Milliseconds 200
            $current=Get-ExactProcess (Join-Path $root 'VuniqKeeper132.exe') $session $false 'Vuniq keeper'
        } while ($null -ne $current -and $wait.Elapsed.TotalSeconds -lt 20)
        if ($null -ne $current) { throw 'Keeper still running (possibly blocked in COM). It was not force-stopped; do not delete this folder yet.' }
    }
    Write-Host 'Keeper is absent. NILIT was left untouched. Resume.cmd clears this maintenance stop.'
    exit 0
} catch { Write-Error $_.Exception.Message -ErrorAction Continue; exit 1 }
