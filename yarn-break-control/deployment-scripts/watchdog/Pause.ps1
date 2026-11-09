#requires -Version 2.0
$ErrorActionPreference = 'Stop'
try {
    $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    [System.IO.File]::WriteAllText((Join-Path $scriptDirectory 'PAUSED'), 'Paused at ' + [DateTime]::UtcNow.ToString('o'))
    Write-Host 'Supervision paused. Allow the current monitor check to finish.'
    Write-Host 'NILIT and the independent Vuniq keeper were not stopped. Run Resume.cmd to resume supervision.'
    exit 0
}
catch {
    Write-Error ('Pause failed: ' + $_.Exception.Message) -ErrorAction Continue
    exit 1
}
