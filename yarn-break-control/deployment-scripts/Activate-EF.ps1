#requires -Version 2.0
$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$watchRoot = Join-Path $packageRoot 'watchdog'
$counterRoot = Join-Path $packageRoot 'counter'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Get-ActivationHash([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-', '') }
    finally { $stream.Close(); $hash.Clear() }
}

try {
    & $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $packageRoot 'deploy\Preflight-EF.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'EF preflight failed; supervision was not resumed.' }
    . (Join-Path $watchRoot 'Common.ps1')
    $configPath = Join-Path $watchRoot 'config.xml'
    $config = Read-WatchdogConfig $configPath
    $hashes = @{}
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $counterRoot 'SHA256SUMS.txt'))) {
        if ($line -match '^([A-Fa-f0-9]{64})[ \t]+\*?(.+?)\s*$') {
            $name = $matches[2]
            if ($name -ieq 'nilit.exe' -or $name -ieq 'nilit-export.exe') {
                if ($hashes.ContainsKey($name)) { throw 'Duplicate counter hash entry.' }
                $hashes[$name] = $matches[1]
            }
        }
    }
    foreach ($name in @('nilit.exe', 'nilit-export.exe')) {
        if (-not $hashes.ContainsKey($name)) { throw ('Missing counter hash: ' + $name) }
        $source = Join-Path $counterRoot $name
        $installed = Join-Path $config.WorkingDirectory $name
        if (-not [IO.File]::Exists($installed) -or (Get-ActivationHash $installed) -ine $hashes[$name] -or (Get-ActivationHash $source) -ine $hashes[$name]) {
            throw ('The installed ' + $name + ' does not match this EF release. Complete step 03 first; nothing was started.')
        }
    }
    $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $keeper = Get-KeeperObservation $config $session $watchRoot $configPath
    if (-not $keeper.Ready) { throw ('Keeper is not ready; supervision remains unchanged: ' + $keeper.Reason) }
    & $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $watchRoot 'Resume.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Resume did not complete. Run step 05 and retain its output; do not close Vuniq.' }
    Write-Host 'EF counter files verified; supervision resumed.'
    Write-Host 'The monitor will launch NILIT after its recovery delay when NILIT is absent.'
    Write-Host 'Allow about 20-25 seconds plus connector initialization, then run step 05.'
    Write-Host 'Observe both E and F. First installation starts the new counters at zero.'
    exit 0
} catch {
    Write-Error ('Activation stopped: ' + $_.Exception.Message) -ErrorAction Continue
    exit 1
}
