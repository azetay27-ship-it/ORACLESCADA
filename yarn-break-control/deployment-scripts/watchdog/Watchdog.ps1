#requires -Version 2.0
param([switch]$CheckOnly, [switch]$Once, [string]$ConfigPath = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'Common.ps1')
if ($ConfigPath -eq '') { $ConfigPath = Join-Path $root 'config.xml' }
$originalConfigText = [IO.File]::ReadAllText($ConfigPath)
$config = Read-WatchdogConfig $ConfigPath
$session = [Diagnostics.Process]::GetCurrentProcess().SessionId
if ($session -eq 0) { throw 'Use the logged-on operator session, not SYSTEM/session 0.' }
Initialize-WindowProbe
$pausePath = Join-Path $root 'PAUSED'
$stopPath = Join-Path $root 'STOP'
$dataDir = Join-Path $root 'runtime'
$statePath = Join-Path $dataDir 'state.xml'
$logPath = Join-Path $dataDir 'watchdog.log'

if ($CheckOnly) {
    $checkState = New-WatchdogState
    if ([IO.File]::Exists($statePath)) { $checkState = Read-WatchdogState $statePath }
    $observation = Get-WatchdogObservation $config $session ([IO.File]::Exists($pausePath) -or [IO.File]::Exists($stopPath))
    $decision = Get-WatchdogDecision $config $checkState $observation ([datetime]::UtcNow)
    $keeper = Get-KeeperObservation $config $session $root $ConfigPath
    if (-not $keeper.Ready -and ($decision.Action -eq 'Start' -or $decision.Action -eq 'Restart')) { $decision.Action='Wait'; $decision.Reason='Independent connector not ready: '+$keeper.Reason }
    Write-Output ('Action: ' + $decision.Action + '; ' + $decision.Reason)
    Write-Output ('Target: ' + $config.TargetPath)
    Write-Output ('Arguments: ' + $config.Arguments)
    Write-Output ('Working directory: ' + $config.WorkingDirectory)
    Write-Output ('Recovery delay: ' + $config.RecoveryDelaySeconds + ' seconds of continuous NILIT absence')
    if ($config.MaxStartsPerWindow -eq 0) {
        Write-Output 'Recovery attempts: UNLIMITED (NILIT, keeper launch and connector activation); existing delays still apply.'
    } else {
        Write-Output ('Recovery attempts: ' + $config.MaxStartsPerWindow + ' per ' + $config.RestartWindowMinutes + ' minutes (each recovery budget).')
    }
    Write-Output ('Vuniq preserved during recovery: ' + $config.VuniqPath)
    Write-Output ('Independent connector: ' + $keeper.Reason)
    if ($keeper.Ready) {
        Write-Output ('COM read: OK; address=99;1;N111; value='+$keeper.Value+'; raw state='+$keeper.RawState)
        Write-Output ('Vuniq window: '+$keeper.Engine.Health+'; '+$keeper.WindowDetail+' (reported separately from COM response)')
    }
    Write-Output ('NILIT activity: '+ (Get-NilitActivity $keeper $observation.Target ([datetime]::UtcNow)))
    if ($null -ne $observation.Target) { Write-Output ('PID: ' + $observation.Target.Pid + '; window: ' + $observation.Target.Health) }
    Write-Output 'Check only: no application started or stopped. Window response does not verify live data or successful communication.'
    if ($observation.Error) { exit 1 }
    exit 0
}

if ([IO.File]::Exists($stopPath)) { exit 0 }
[void][IO.Directory]::CreateDirectory($dataDir)
$canonicalTarget = Get-CanonicalPath $config.TargetPath
$hasher = [Security.Cryptography.SHA256]::Create()
try { $key = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonicalTarget.ToLowerInvariant()))).Replace('-', '') }
# HashAlgorithm.Dispose is an explicit interface method on .NET 2.0.
# Clear is public on both the Win7/PowerShell 2 and later runtimes.
finally { $hasher.Clear() }
$mutex = New-Object Threading.Mutex -ArgumentList $false, ('Global\NILITGHWatchdog-' + $key)
try { $acquired = $mutex.WaitOne(0, $false) }
catch [Threading.AbandonedMutexException] { $acquired = $true }
if (-not $acquired) { $mutex.Close(); exit 0 }
$lock = $null

function Write-WatchdogLog([string]$Message) {
    if ([IO.File]::Exists($logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 1048576) {
        $old = $logPath + '.1'
        if ([IO.File]::Exists($old)) { [IO.File]::Delete($old) }
        [IO.File]::Move($logPath, $old)
    }
    [IO.File]::AppendAllText($logPath, ([datetime]::Now.ToString('s') + ' ' + $Message + [Environment]::NewLine))
}

function Assert-RecoveryAllowed([bool]$RequireNilitAbsent = $true) {
    if ([IO.File]::Exists($pausePath) -or [IO.File]::Exists($stopPath)) {
        throw 'Recovery cancelled: maintenance pause/stop requested.'
    }
    if ([IO.File]::ReadAllText($ConfigPath) -cne $originalConfigText) {
        throw 'Recovery cancelled: configuration changed.'
    }
    if ($RequireNilitAbsent) {
        $current = Get-WatchdogObservation $config $session $false
        if ($current.Error) { throw ('Recovery cancelled: ' + $current.Error) }
        if ($null -ne $current.Target) { throw 'Recovery cancelled: NILIT returned; no additional application action.' }
    }
}

function Add-RecoveryAttempt([bool]$RequireNilitAbsent = $true) {
    # Re-evaluate time and rate limits immediately before the first mutation.
    # Already-reserved recovery operations do not enter this helper again.
    $current = Get-LinkedObservation ([IO.File]::Exists($pausePath) -or [IO.File]::Exists($stopPath))
    $currentDecision = Get-WatchdogDecision $config $state $current ([datetime]::UtcNow)
    $expectedAction = 'Start'
    if (-not $RequireNilitAbsent) { $expectedAction = 'Restart' }
    if ($currentDecision.Action -ne $expectedAction) { throw ('Recovery no longer permitted: ' + $currentDecision.Reason) }
    Assert-RecoveryAllowed $RequireNilitAbsent
    $state.Attempts = @($state.Attempts) + @([datetime]::UtcNow.Ticks)
    Write-WatchdogState $state $statePath
}

function Save-EngineBinding([string]$TargetIdentity, [string]$EngineIdentity) {
    $bindingPath=Join-Path $dataDir 'binding.xml'
    $document=New-Object Xml.XmlDocument
    $document.LoadXml('<Binding/>')
    $document.DocumentElement.SetAttribute('target',$TargetIdentity)
    $document.DocumentElement.SetAttribute('engine',$EngineIdentity)
    $temp=$bindingPath+'.tmp'; $document.Save($temp)
    if ([IO.File]::Exists($bindingPath)) { [IO.File]::Replace($temp,$bindingPath,$bindingPath+'.previous') }
    else { [IO.File]::Move($temp,$bindingPath) }
}

function Get-LinkedObservation([bool]$Paused) {
    $observation = Get-WatchdogObservation $config $session $Paused
    if ($Paused -or $observation.Error -or $null -eq $observation.Target) { return $observation }
    $keeper = Assert-KeeperReady
    $bindingPath = Join-Path $dataDir 'binding.xml'
    $document = New-Object Xml.XmlDocument
    $document.XmlResolver=$null
    if ([IO.File]::Exists($bindingPath)) {
        $settings=New-Object Xml.XmlReaderSettings; $settings.ProhibitDtd=$true; $settings.XmlResolver=$null
        $reader=[Xml.XmlReader]::Create($bindingPath,$settings)
        try { $document.Load($reader) } finally { $reader.Close() }
        if ($document.DocumentElement.Name -cne 'Binding') { throw 'Invalid engine binding record.' }
        $oldTarget=$document.DocumentElement.GetAttribute('target')
        $oldEngine=$document.DocumentElement.GetAttribute('engine')
        if ($oldTarget -eq $observation.Target.Identity) {
            $observation.EngineChanged=($oldEngine -ne $keeper.Engine.Identity)
            return $observation
        }
    }
    # A newly observed NILIT is associated with the currently retained engine.
    # Existing identical NILIT identity is never silently re-associated after engine loss.
    Save-EngineBinding $observation.Target.Identity $keeper.Engine.Identity
    $observation.EngineChanged=$false
    return $observation
}

function Assert-KeeperReady {
    $keeper = Get-KeeperObservation $config $session $root $ConfigPath
    if (-not $keeper.Ready) { throw ('NILIT recovery deferred: ' + $keeper.Reason) }
    return $keeper
}

function Ensure-Keeper {
    $keeper = Get-KeeperObservation $config $session $root $ConfigPath
    if ($null -ne $keeper.Process) { return $keeper }
    if ([IO.File]::Exists((Join-Path $root 'KEEPER_STOP'))) { throw 'Keeper is stopped for maintenance; use Resume.cmd.' }
    # Reuse the persisted, rollback-aware limiter implementation for keeper starts.
    $keeperStatePath = Join-Path $dataDir 'keeper-launch-state.xml'
    $keeperState = New-WatchdogState
    if ([IO.File]::Exists($keeperStatePath)) { $keeperState = Read-WatchdogState $keeperStatePath }
    $keeperDecision = Get-WatchdogDecision $config $keeperState @{Paused=$false;Error='';Target=$null} ([datetime]::UtcNow)
    if ($keeperDecision.Action -ne 'Start') { throw 'Keeper launch rate limit; waiting for the rolling window.' }
    Assert-RecoveryAllowed $false
    if ($null -ne (Get-KeeperObservation $config $session $root $ConfigPath).Process) { return Get-KeeperObservation $config $session $root $ConfigPath }
    $keeperState.Attempts = @($keeperState.Attempts) + @([datetime]::UtcNow.Ticks)
    Write-WatchdogState $keeperState $keeperStatePath
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $root 'VuniqKeeper132.exe'
    $info.Arguments = '--config "' + $ConfigPath + '"'
    $info.WorkingDirectory = $root; $info.UseShellExecute = $false
    $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    Assert-RecoveryAllowed $false
    $child = [Diagnostics.Process]::Start($info)
    try { Write-WatchdogLog ('Started independent Vuniq keeper PID=' + $child.Id + '; one internal timer is read; no writes.') } finally { $child.Dispose() }
    return Get-KeeperObservation $config $session $root $ConfigPath
}

function Assert-HeldProcess($Process, $Snapshot, [string]$ExpectedPath) {
    if ($Process.HasExited -or $Process.StartTime.ToUniversalTime().Ticks -ne $Snapshot.Started.Ticks) {
        throw 'Recovery cancelled: process creation identity changed or process exited.'
    }
    if ((Get-CanonicalPath $Process.MainModule.FileName) -ine $ExpectedPath -or $Process.SessionId -ne $session) {
        throw 'Recovery cancelled: final process path/session verification failed.'
    }
}

function Invoke-NilitRecovery($Decision, $Observation) {
    $attemptReserved = $false
    $heldKeeper = Assert-KeeperReady
    if ($Decision.Action -eq 'Restart') {
        Assert-RecoveryAllowed $false
        $process = [Diagnostics.Process]::GetProcessById([int]$Observation.Target.Pid)
        try {
            $heldHandle = $process.Handle
            Assert-HeldProcess $process $Observation.Target $canonicalTarget
            $engineChanged = ($Observation.ContainsKey('EngineChanged') -and $Observation.EngineChanged)
            if ($engineChanged) {
                $linked = Get-LinkedObservation $false
                if (-not $linked.EngineChanged -or $linked.Target.Identity -ne $Observation.Target.Identity) { throw 'Engine/target binding changed; reconnect deferred.' }
            } elseif ([NILITGHWatchdog.Native]::Check($process.Id) -ne 'Hung') { throw 'Window no longer confirmed hung; restart cancelled.' }
            Assert-RecoveryAllowed $false
            Add-RecoveryAttempt $false
            $attemptReserved = $true
            Assert-RecoveryAllowed $false
            Assert-HeldProcess $process $Observation.Target $canonicalTarget
            Write-WatchdogLog ('Stopping NILIT PID=' + $process.Id + '; reason=' + $Decision.Reason + '; Vuniq is preserved.')
            $process.Kill()
            $exitWait = [Diagnostics.Stopwatch]::StartNew()
            while (-not $process.HasExited -and $exitWait.ElapsedMilliseconds -lt 5000) {
                Assert-RecoveryAllowed $false
                Start-Sleep -Milliseconds 100
            }
            if (-not $process.HasExited) { throw 'NILIT did not exit; recovery cancelled.' }
        } finally { $process.Dispose() }
    }

    Assert-RecoveryAllowed
    Write-WatchdogLog ('Recovery delay started: ' + $config.RecoveryDelaySeconds + ' seconds of continuous NILIT absence.')
    $delay = [Diagnostics.Stopwatch]::StartNew()
    $lastAbsenceObservation = [long]0
    while ($delay.Elapsed.TotalSeconds -lt $config.RecoveryDelaySeconds) {
        Assert-RecoveryAllowed
        if ($delay.ElapsedMilliseconds - $lastAbsenceObservation -gt 5000) { throw 'Recovery cancelled: gap in continuous NILIT absence observation.' }
        $lastAbsenceObservation = $delay.ElapsedMilliseconds
        Start-Sleep -Milliseconds 200
    }
    Assert-RecoveryAllowed
    if ($delay.ElapsedMilliseconds - $lastAbsenceObservation -gt 5000) { throw 'Recovery cancelled: gap in continuous NILIT absence observation.' }
    $currentKeeper = Assert-KeeperReady
    if ($currentKeeper.Engine.Identity -ne $heldKeeper.Engine.Identity) { throw 'Engine changed during NILIT delay; recovery deferred.' }
    if (-not $attemptReserved) { Add-RecoveryAttempt; $attemptReserved = $true }
    Assert-RecoveryAllowed
    $currentKeeper = Assert-KeeperReady
    if ($currentKeeper.Engine.Identity -ne $heldKeeper.Engine.Identity) { throw 'Engine changed before NILIT launch.' }
    # Only NILIT is launched here. The keeper and Vuniq remain untouched.
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $config.TargetPath
    $startInfo.Arguments = $config.Arguments
    $startInfo.WorkingDirectory = $config.WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Normal
    $child = [Diagnostics.Process]::Start($startInfo)
    try {
        $newIdentity=[string]$child.Id+':'+[string]$child.StartTime.ToUniversalTime().Ticks
        Save-EngineBinding $newIdentity $heldKeeper.Engine.Identity
        Write-WatchdogLog ('Started NILIT PID=' + $child.Id + '; existing Vuniq preserved, engine=' + $heldKeeper.Engine.Identity)
    } finally { $child.Dispose() }
    $state.HungIdentity = ''; $state.HungSince = [long]0
}

try {
    $lock = [IO.File]::Open((Join-Path $dataDir 'watchdog.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $state = New-WatchdogState
    if ([IO.File]::Exists($statePath)) { $state = Read-WatchdogState $statePath }
    # A gap in supervision cannot count as continuous evidence of a hung UI.
    $state.HungIdentity = ''; $state.HungSince = [long]0
    $lastMessage = ''
    $lastProbe = [datetime]::UtcNow
    Write-WatchdogLog ('Watchdog started. Session=' + $session + '; Target=' + $canonicalTarget + '; Args=' + $config.Arguments + '; WorkingDirectory=' + $config.WorkingDirectory)
    if ($config.MaxStartsPerWindow -eq 0) { Write-WatchdogLog 'Recovery attempts: UNLIMITED; configured recovery delay and readiness checks remain active.' }
    do {
        if ([IO.File]::Exists($stopPath)) { Write-WatchdogLog 'Stop requested; monitor exits without closing NILIT.'; break }
        try {
            if ([IO.File]::ReadAllText($ConfigPath) -cne $originalConfigText) {
                Write-WatchdogLog 'Configuration changed; monitor exits. Installed scheduled task reloads it on the next trigger.'
                break
            }
            if (-not [IO.File]::Exists($pausePath)) {
                $keeper = Ensure-Keeper
                if (-not $keeper.Ready) { throw ('Waiting for independent Vuniq connector: ' + $keeper.Reason) }
            }
            $now = [datetime]::UtcNow
            $gap = ($now - $lastProbe).TotalSeconds
            if ($gap -lt 0 -or $gap -gt (2 * $config.CheckSeconds + 15)) { $state.HungIdentity = ''; $state.HungSince = [long]0 }
            $lastProbe = $now
            $observation = Get-LinkedObservation ([IO.File]::Exists($pausePath))
            $decision = Get-WatchdogDecision $config $state $observation $now
            if ($decision.ContainsKey('ClockAdjusted') -and $decision.ClockAdjusted) { Write-WatchdogLog 'Backward clock change handled; restart attempts retained and hang evidence reset.' }
            $message = $decision.Action + ': ' + $decision.Reason
            if ($message -ne $lastMessage) { Write-WatchdogLog $message; $lastMessage = $message }
            if ($decision.Action -eq 'Start' -or $decision.Action -eq 'Restart') {
                $fresh = Get-LinkedObservation ([IO.File]::Exists($pausePath) -or [IO.File]::Exists($stopPath))
                $confirmed = Get-WatchdogDecision $config $state $fresh ([datetime]::UtcNow)
                if ($confirmed.Action -ne $decision.Action) { throw 'Observation changed; action deferred.' }
                if ($decision.Action -eq 'Restart' -and $fresh.Target.Identity -ne $observation.Target.Identity) { throw 'Target identity changed; restart deferred.' }
                Invoke-NilitRecovery $decision $fresh
            }
            Write-WatchdogState $state $statePath
        } catch {
            Reset-HangObservation $state
            $message = 'ERROR: ' + $_.Exception.Message
            if ($message -ne $lastMessage) { Write-WatchdogLog $message; $lastMessage = $message }
        }
        if (-not $Once) { Start-Sleep -Seconds $config.CheckSeconds }
    } while (-not $Once)
} catch {
    Write-WatchdogLog ('FATAL: ' + $_.Exception.Message)
    throw
} finally {
    if ($null -ne $lock) { $lock.Dispose() }
    $mutex.ReleaseMutex(); $mutex.Close()
}
