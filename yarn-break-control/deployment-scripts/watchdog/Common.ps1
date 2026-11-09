# Windows PowerShell 2.0 / .NET 2.0 compatible. No application COM or serial access.
Set-StrictMode -Version 2.0

function Read-LocalPath([string]$Value, [string]$Name, [bool]$Executable) {
    if ($Value -notmatch '^[A-Za-z]:[\\/]' -or $Value.Substring(2).Contains(':')) {
        throw "$Name must be an absolute local drive path."
    }
    $full = [IO.Path]::GetFullPath($Value)
    if ($Executable -and [IO.Path]::GetExtension($full) -ine '.exe') {
        throw "$Name must identify an EXE file."
    }
    return $full
}

function Read-WatchdogConfig($Path) {
    $settings = New-Object Xml.XmlReaderSettings
    $settings.ProhibitDtd = $true
    $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create([string]$Path, $settings)
    try {
        $xml = New-Object Xml.XmlDocument
        $xml.XmlResolver = $null
        $xml.Load($reader)
    } finally { $reader.Close() }
    if ($xml.DocumentElement.Name -ne 'Watchdog') { throw 'Expected Watchdog configuration.' }
    $values = @{}
    foreach ($node in $xml.DocumentElement.ChildNodes) {
        if ($node.NodeType -ne [Xml.XmlNodeType]::Element) { continue }
        if ($values.ContainsKey($node.Name)) { throw ('Repeated setting: ' + $node.Name) }
        $values[$node.Name] = [string]$node.InnerText
    }
    $result = @{}
    $result.TargetPath = Read-LocalPath ([string]$values['TargetPath']) 'TargetPath' $true
    if ([IO.Path]::GetFileName($result.TargetPath) -ine 'nilit.exe') {
        throw 'This watchdog supervises NILIT only. TargetPath must identify nilit.exe.'
    }
    $vuniqPath = [string]$values['VuniqPath']
    if ([string]::IsNullOrEmpty($vuniqPath)) { $vuniqPath = 'C:\Vuniq50\bin\Vuniq.exe' }
    $result.VuniqPath = Read-LocalPath $vuniqPath 'VuniqPath' $true
    if ([IO.Path]::GetFileName($result.VuniqPath) -ine 'Vuniq.exe' -or
        $result.VuniqPath -ieq $result.TargetPath) {
        throw 'VuniqPath must identify the separate Vuniq.exe used by NILIT.'
    }
    $result.Arguments = [string]$values['Arguments']
    if ($result.Arguments.IndexOf([char]0) -ge 0) { throw 'Invalid Arguments.' }
    if ([string]::IsNullOrEmpty([string]$values['WorkingDirectory'])) {
        $result.WorkingDirectory = [IO.Path]::GetDirectoryName($result.TargetPath)
    } else {
        $result.WorkingDirectory = Read-LocalPath ([string]$values.WorkingDirectory) 'WorkingDirectory' $false
    }
    $defaults = @{ CheckSeconds=5; TargetGraceSeconds=60; HangSeconds=60;
        RecoveryDelaySeconds=20;
        MaxStartsPerWindow=3; RestartWindowMinutes=15 }
    $upper = @{ CheckSeconds=300; TargetGraceSeconds=3600; HangSeconds=3600;
        RecoveryDelaySeconds=3600;
        MaxStartsPerWindow=100; RestartWindowMinutes=1440 }
    foreach ($key in $defaults.Keys) {
        $value = [int]$defaults[$key]
        if ($values.ContainsKey($key)) {
            if (-not [int]::TryParse([string]$values[$key], [ref]$value)) { throw "Invalid $key." }
        }
        $minimum = 1
        if ($key -eq 'MaxStartsPerWindow') { $minimum = 0 }
        if ($value -lt $minimum -or $value -gt [int]$upper[$key]) { throw "Invalid $key." }
        $result[$key] = $value
    }
    $result.RestartHung = $true
    if ($values.ContainsKey('RestartHung')) { $result.RestartHung = [bool]::Parse($values.RestartHung) }
    return $result
}

function New-WatchdogState {
    return @{ Attempts=@(); HungIdentity=''; HungSince=[long]0; LastObservedTicks=[long]0;
        FutureStartIdentity=''; FutureStartSince=[long]0 }
}

function Read-WatchdogState($Path) {
    $settings = New-Object Xml.XmlReaderSettings
    $settings.ProhibitDtd = $true
    $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create([string]$Path, $settings)
    try {
        $document = New-Object Xml.XmlDocument
        $document.XmlResolver = $null
        $document.Load($reader)
    } finally { $reader.Close() }
    if ($document.DocumentElement.Name -ne 'WatchdogState' -or
        $document.DocumentElement.GetAttribute('version') -ne '1') {
        throw 'Invalid watchdog state schema.'
    }
    $state = New-WatchdogState
    foreach ($node in $document.SelectNodes('/WatchdogState/Attempt')) {
        $ticks = [long]$node.InnerText
        if ($ticks -le 0 -or $ticks -gt [datetime]::MaxValue.Ticks) { throw 'Invalid attempt date.' }
        $state.Attempts += $ticks
        if ($state.Attempts.Count -gt 10000) { throw 'Too many restart records.' }
    }
    $last = $document.DocumentElement.GetAttribute('lastObservedTicks')
    if (-not [string]::IsNullOrEmpty($last)) {
        $state.LastObservedTicks = [long]$last
        if ($state.LastObservedTicks -lt 0 -or $state.LastObservedTicks -gt [datetime]::MaxValue.Ticks) {
            throw 'Invalid observation date.'
        }
    }
    # A fresh supervisor must observe an entire new hang interval before a kill.
    return $state
}

function Write-WatchdogState($State, $Path) {
    $document = New-Object Xml.XmlDocument
    $document.LoadXml('<WatchdogState version="1"/>')
    $document.DocumentElement.SetAttribute('lastObservedTicks', [string]$State.LastObservedTicks)
    foreach ($ticks in $State.Attempts) {
        $node = $document.CreateElement('Attempt')
        $node.InnerText = [string]$ticks
        [void]$document.DocumentElement.AppendChild($node)
    }
    $temporary = $Path + '.tmp'
    $document.Save($temporary)
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, ($Path + '.previous')) }
    else { [IO.File]::Move($temporary, $Path) }
}

function Reset-HangObservation($State) {
    $State.HungIdentity = ''; $State.HungSince = [long]0
}

function Get-WatchdogDecision($Config, $State, $Observation, [datetime]$Now) {
    # Clock rollback preserves the number of recent attempts, but anchors any
    # future attempt to now so the limiter can recover after one normal window.
    $clockAdjusted = ([long]$State.LastObservedTicks -gt $Now.Ticks)
    $cutoff = $Now.AddMinutes(-$Config.RestartWindowMinutes).Ticks
    $attempts = @()
    foreach ($record in $State.Attempts) {
        $ticks = [long]$record
        if ($ticks -gt $Now.Ticks) { $ticks = $Now.Ticks; $clockAdjusted = $true }
        if ($ticks -gt $cutoff) { $attempts += $ticks }
    }
    # Keep room for the next reservation. The newest records preserve every
    # supported positive quota (<=100); unlimited retries never grow forever.
    if ($attempts.Count -ge 10000) { $attempts = @($attempts | Sort-Object | Select-Object -Last 9999) }
    $State.Attempts = $attempts
    $State.LastObservedTicks = $Now.Ticks
    if ($clockAdjusted) {
        Reset-HangObservation $State
        $State.FutureStartIdentity = ''; $State.FutureStartSince = [long]0
    }
    $action = 'Wait'; $reason = ''
    $target = $Observation.Target
    $startup = $false
    if ($null -ne $target) {
        if ($target.Started -gt $Now) {
            if ($State.FutureStartIdentity -ne $target.Identity -or $State.FutureStartSince -eq 0) {
                $State.FutureStartIdentity = $target.Identity
                $State.FutureStartSince = $Now.Ticks
            }
            $startup = (($Now.Ticks - [long]$State.FutureStartSince) -lt
                [timespan]::FromSeconds($Config.TargetGraceSeconds).Ticks)
        } else {
            $startup = (($Now - $target.Started).TotalSeconds -lt $Config.TargetGraceSeconds)
            $State.FutureStartIdentity = ''; $State.FutureStartSince = [long]0
        }
    } else { $State.FutureStartIdentity = ''; $State.FutureStartSince = [long]0 }

    if ($Observation.Paused) { $reason = 'Maintenance pause.' }
    elseif ($Observation.Error) { $reason = 'Inspection blocked: ' + $Observation.Error }
    elseif ($null -eq $target) { $action = 'Start'; $reason = ('NILIT is absent; recovery waits ' + $Config.RecoveryDelaySeconds + ' seconds, preserves Vuniq, then starts NILIT after the independent connector is ready.') }
    elseif ($Observation.ContainsKey('EngineChanged') -and $Observation.EngineChanged) {
        $action = 'Restart'; $reason = 'Vuniq engine was replaced; restart NILIT to discard its old connector.'
    }
    elseif ($startup) { $reason = 'NILIT startup grace.' }
    elseif ($target.Health -eq 'Hung') {
        if ($State.HungIdentity -ne $target.Identity -or $State.HungSince -eq 0) {
            $State.HungIdentity = $target.Identity; $State.HungSince = $Now.Ticks
        }
        if ($Config.RestartHung -and
            ($Now.Ticks - [long]$State.HungSince) -ge [timespan]::FromSeconds($Config.HangSeconds).Ticks) {
            $action = 'Restart'; $reason = 'NILIT window repeatedly timed out.'
        } else { $reason = 'NILIT window timed out; observing before restart.' }
    }
    elseif ($target.Health -eq 'Responsive') {
        $action = 'Observe'; $reason = 'NILIT windows respond (not a data heartbeat).'
    }
    else { $reason = 'NILIT exists, but its window health is unknown.' }

    if ($null -eq $target -or $Observation.Paused -or $Observation.Error -or $startup -or
        $target.Health -ne 'Hung') { Reset-HangObservation $State }
    if (($action -eq 'Start' -or $action -eq 'Restart') -and $Config.MaxStartsPerWindow -gt 0 -and
        $State.Attempts.Count -ge $Config.MaxStartsPerWindow) {
        $action = 'Wait'; $reason = 'Restart rate limit; retry after the rolling window clears.'
    }
    return @{ Action=$action; Reason=$reason; ClockAdjusted=$clockAdjusted }
}

function Initialize-WindowProbe {
    if ('NILITGHWatchdog.Native' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
namespace NILITGHWatchdog {
    public static class Native {
        private delegate bool EnumProc(IntPtr hwnd, IntPtr data);
        [DllImport("user32.dll", SetLastError=true)]
        private static extern bool EnumWindows(EnumProc callback, IntPtr data);
        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll", SetLastError=true)]
        private static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint message,
            UIntPtr wparam, IntPtr lparam, uint flags, uint timeout, out UIntPtr result);
        [DllImport("kernel32.dll")]
        private static extern void SetLastError(uint error);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern uint GetLongPathName(string shortPath, StringBuilder longPath, uint capacity);
        public static string CanonicalPath(string path) {
            StringBuilder buffer = new StringBuilder(32768);
            uint count = GetLongPathName(path, buffer, (uint)buffer.Capacity);
            if (count == 0 || count >= buffer.Capacity)
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(),
                    "Cannot verify the full executable path.");
            return buffer.ToString();
        }
        public static string Check(int processId) {
            List<IntPtr> windows = new List<IntPtr>();
            bool enumerated = EnumWindows(delegate(IntPtr hwnd, IntPtr data) {
                uint owner; GetWindowThreadProcessId(hwnd, out owner);
                if (owner == (uint)processId) windows.Add(hwnd);
                return windows.Count <= 30;
            }, IntPtr.Zero);
            if (!enumerated || windows.Count == 0 || windows.Count > 30) return "Unknown";
            bool uncertain = false;
            Stopwatch elapsed = Stopwatch.StartNew();
            foreach (IntPtr hwnd in windows) {
                uint owner; GetWindowThreadProcessId(hwnd, out owner);
                if (owner != (uint)processId) { uncertain = true; continue; }
                long remaining = 2000 - elapsed.ElapsedMilliseconds;
                if (remaining <= 0) return "Unknown";
                UIntPtr result;
                SetLastError(0);
                // WM_NULL; no messages that change application state. The whole
                // sequence has a two-second budget, including hidden windows.
                IntPtr ok = SendMessageTimeout(hwnd, 0, UIntPtr.Zero, IntPtr.Zero,
                    0x0001 | 0x0020, (uint)remaining, out result);
                if (ok == IntPtr.Zero) {
                    int error = Marshal.GetLastWin32Error();
                    if (error == 1460) return "Hung";
                    uncertain = true;
                }
            }
            return uncertain ? "Unknown" : "Responsive";
        }
        public static string DescribeWindows(int processId) {
            int total=0, visible=0;
            bool ok=EnumWindows(delegate(IntPtr hwnd,IntPtr data) {
                uint owner; GetWindowThreadProcessId(hwnd,out owner);
                if(owner==(uint)processId) { total++; if(IsWindowVisible(hwnd)) visible++; }
                return total<=1000;
            },IntPtr.Zero);
            return "total="+total+"; visible="+visible+"; enumOK="+ok+"; originalProbeLimit=30";
        }
    }
}

'@
}

function Get-CanonicalPath([string]$Path) {
    Initialize-WindowProbe
    return [NILITGHWatchdog.Native]::CanonicalPath([IO.Path]::GetFullPath($Path))
}

function Get-ExactProcess($ExePath, [int]$Session, [bool]$ProbeWindow = $true, [string]$DisplayName = 'NILIT') {
    $expected = Get-CanonicalPath $ExePath
    $name = [IO.Path]::GetFileNameWithoutExtension($ExePath)
    $processes = @([Diagnostics.Process]::GetProcessesByName($name))
    $matches = @()
    try {
        foreach ($process in $processes) {
            try {
                if ($process.HasExited) { continue }
                $handle = $process.Handle
                $path = [string]$process.MainModule.FileName
                if ([string]::IsNullOrEmpty($path)) { throw "Cannot verify path of process $($process.Id)." }
                $actual = Get-CanonicalPath $path
                if ($actual -ine $expected) { continue }
                if ($process.SessionId -ne $Session) {
                    throw ("Configured " + $DisplayName + " belongs to another session; automatic action blocked.")
                }
                $started = $process.StartTime.ToUniversalTime()
                $matches += @{ Pid=$process.Id; Started=$started;
                    Identity=([string]$process.Id + ':' + [string]$started.Ticks);
                    Path=$actual; Process=$process }
            } catch {
                # An exited process cannot hold the configured application open.
                # Permission failures on an existing process remain blocking.
                if ($process.HasExited) { continue }
                throw
            }
        }
        if ($matches.Count -eq 0) { return $null }
        if ($matches.Count -ne 1) { throw ('Multiple configured ' + $DisplayName + ' instances; automatic action blocked.') }
        $match = $matches[0]
        $health = 'NotProbed'
        if ($ProbeWindow) { $health = [NILITGHWatchdog.Native]::Check($match.Pid) }
        if ($match.Process.HasExited) { return $null }
        return @{ Pid=$match.Pid; Started=$match.Started; Identity=$match.Identity;
            Path=$match.Path; Health=$health }
    } finally { foreach ($process in $processes) { $process.Dispose() } }
}

function Get-WatchdogObservation($Config, [int]$Session, [bool]$Paused) {
    $result = @{ Paused=$Paused; Error=''; Target=$null }
    if ($Paused) { return $result }
    try {
        if (-not [IO.File]::Exists($Config.TargetPath)) { throw ('Executable missing: ' + $Config.TargetPath) }
        if (-not [IO.Directory]::Exists($Config.WorkingDirectory)) { throw 'Working directory is missing.' }
        foreach ($path in @($Config.TargetPath, $Config.WorkingDirectory)) {
            $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($path))
            if ($drive.DriveType -eq [IO.DriveType]::Network) { throw 'Network drive targets are not supported.' }
        }
        $result.Target = Get-ExactProcess $Config.TargetPath $Session
    } catch { $result.Error = $_.Exception.Message }
    return $result
}

# Read-only check of the independently running x86 keeper and its exact engine identity.
function Get-KeeperObservation($Config, [int]$Session, [string]$Root, [string]$ConfigPath) {
    $result = @{ Ready=$false; Reason='Keeper is absent.'; Process=$null; Engine=$null; LastChangeTicks=[long]0; ReadTicks=[long]0; Value=''; RawState=''; ReadStatus='NotChecked'; WindowDetail='NotChecked' }
    $helper = Join-Path $Root 'VuniqKeeper132.exe'
    $result.Process = Get-ExactProcess $helper $Session $false 'Vuniq keeper'
    foreach ($p in @([Diagnostics.Process]::GetProcessesByName('VuniqKeeper131')) + @([Diagnostics.Process]::GetProcessesByName('VuniqKeeper132')) + @([Diagnostics.Process]::GetProcessesByName('VuniqKeeper'))) {
        try {
            if ($p.HasExited) { continue }
            if ((Get-CanonicalPath $p.MainModule.FileName) -ine (Get-CanonicalPath $helper)) {
                throw 'A keeper from another package is running. Stop that keeper before changing package folders.'
            }
        } finally { $p.Dispose() }
    }
    if ($null -eq $result.Process) { return $result }
    $status = Join-Path $Root 'runtime\keeper.xml'
    if (-not [IO.File]::Exists($status)) { $result.Reason='Keeper started; status is not available yet.'; return $result }
    $settings = New-Object Xml.XmlReaderSettings
    $settings.ProhibitDtd=$true; $settings.XmlResolver=$null
    $stream=[IO.File]::Open($status,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $reader=$null
    try { $reader=[Xml.XmlReader]::Create($stream,$settings); $doc=New-Object Xml.XmlDocument; $doc.XmlResolver=$null; $doc.Load($reader) }
    finally { if ($null -ne $reader) { $reader.Close() }; $stream.Close() }
    $node=$doc.DocumentElement
    if ($node.Name -cne 'Keeper' -or $node.GetAttribute('version') -cne '1') { throw 'Invalid keeper status schema.' }
    if ([int]$node.GetAttribute('pid') -ne $result.Process.Pid -or
        [long]$node.GetAttribute('startedTicks') -ne $result.Process.Started.Ticks -or
        [int]$node.GetAttribute('session') -ne $Session -or
        (Get-CanonicalPath $node.GetAttribute('enginePath')) -ine (Get-CanonicalPath $Config.VuniqPath) -or
        (Get-CanonicalPath $node.GetAttribute('configPath')) -ine (Get-CanonicalPath $ConfigPath)) {
        $result.Reason='Keeper status does not match the running process/configuration.'; return $result
    }
    $age=([datetime]::UtcNow.Ticks-[long]$node.GetAttribute('updatedTicks'))/[timespan]::TicksPerSecond
    if ($age -lt 0 -or $age -gt 15) { $result.Reason='Keeper status is stale; no automatic NILIT action.'; return $result }
    $result.Reason=$node.GetAttribute('phase')+': '+$node.GetAttribute('message')
    if ($node.GetAttribute('phase') -cne 'Ready') { return $result }
    if ($node.GetAttribute('comReply') -cne 'OK') { $result.Reason='No confirmed COM reply in keeper status.'; return $result }
    $result.LastChangeTicks=[long]$node.GetAttribute('valueChangedTicks')
    $result.ReadTicks=[long]$node.GetAttribute('comReplyTicks')
    $readAge=([datetime]::UtcNow.Ticks-$result.ReadTicks)/[timespan]::TicksPerSecond
    if ($readAge -lt 0 -or $readAge -gt 15) { $result.Reason='COM reply is stale.'; return $result }
    $result.Value=$node.GetAttribute('value'); $result.RawState=$node.GetAttribute('rawState'); $result.ReadStatus=$node.GetAttribute('readStatus'); $result.WindowDetail=$node.GetAttribute('windowDetail')
    $engine=Get-ExactProcess $Config.VuniqPath $Session $true 'Vuniq'
    if ($null -eq $engine -or $engine.Pid -ne [int]$node.GetAttribute('enginePid') -or
        $engine.Started.Ticks -ne [long]$node.GetAttribute('engineStartedTicks')) {
        $result.Reason='Vuniq is not the same engine held by the keeper.'; return $result
    }
    $result.Engine=$engine; $result.Ready=$true
    return $result
}

function Get-NilitActivity($Keeper, $Target, [datetime]$Now) {
    if ($null -eq $Target) { return 'NOT RUNNING - NILIT process is absent.' }
    if (-not $Keeper.Ready) { return 'NOT VERIFIED - COM response is not confirmed.' }
    if ($Keeper.ReadStatus -ne 'NumericValue') { return 'NOT VERIFIED - COM replies, but the internal timer has no numeric value.' }
    $changeAge=($Now.Ticks-$Keeper.LastChangeTicks)/[timespan]::TicksPerSecond
    if ($Keeper.LastChangeTicks -ge $Target.Started.Ticks -and $changeAge -ge 0 -and $changeAge -le 180) {
        return ('OUTPUT CHANGE OBSERVED - internal timer 99;1;N111='+$Keeper.Value+'; change '+[int]$changeAge+'s ago. This is output evidence, not a verified NILIT heartbeat, PLC freshness or SAP delivery.')
    }
    return ('WAITING FOR OUTPUT CHANGE - NILIT exists; internal timer 99;1;N111='+$Keeper.Value+'. Observe for about 2 minutes; activity is not confirmed yet.')
}
