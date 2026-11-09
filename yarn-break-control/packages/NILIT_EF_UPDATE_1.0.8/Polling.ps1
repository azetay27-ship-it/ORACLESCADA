#requires -Version 2.0
param([ValidateSet('Check','Apply','Rollback')][string]$Mode='Check')
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$report=Join-Path $root ('EF-Polling-'+$Mode+'-'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)+'.txt')
function Report([string]$Text){Write-Host $Text;[IO.File]::AppendAllText($report,$Text+[Environment]::NewLine,[Text.Encoding]::UTF8)}
try {
    Report ('NILIT EF runtime 1.0.7 to 1.0.8 - '+$Mode)
    . (Join-Path $root 'Polling.Core.ps1')
    $files=Read-CFManifest $root
    . (Join-Path $root 'TaskIdentity.ps1')
    $context=Get-CFContext
    Report ('Operator: '+$context.User)
    Report ('Existing EF package: '+$context.PackageRoot)
    Report ('Counter target: '+$context.Target)
    if($Mode -eq 'Check') {
        Report ('Verified installed version: '+(Get-PollingState $context $files))
        Report 'CHECK passed. No field file, task or application changed.'
        Report 'Before Apply/Rollback: existing 07-Pause; close NILIT; wait for nilit-export to finish. Vuniq may remain open.'
    } else {
        Assert-CFReady $context
        if($Mode -eq 'Apply'){Report (Invoke-PollingUpdate $root $context $files)}
        else{Report (Invoke-PollingRollback $context $files)}
        Report 'Resume from the EXISTING package: watchdog\Resume.cmd, then 05-Status.cmd.'
        Report 'Resume requests the installed monitor and removes KEEPER_STOP. The monitor can start a missing Keeper before NILIT recovery; confirm readiness in 05-Status.cmd.'
        Report 'Current MAIN, definitions/settings, watchdog registration, saved counters/history and SAP outbox were preserved.'
    }
    Report ('Report: '+$report);exit 0
} catch {
    Report ('STOPPED: '+$_.Exception.Message)
    Report 'Keep supervision paused if an update began. Preserve this report and every backup. Use 03-Rollback only while NILIT/exporter are absent.'
    Report ('Report: '+$report);exit 1
}
