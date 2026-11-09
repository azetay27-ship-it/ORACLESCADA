#requires -Version 2.0
param([string]$PackageDirectory = '', [switch]$FunctionsOnly)
# Read-only discovery. Writes only its own report; never starts/stops applications,
# invokes package scripts, changes tasks, clears flags or modifies configuration.
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:packageRoots = @{}
$script:runtimeDirectories = @{}
$script:configFiles = @{}
$script:visitedFolders = 0
$script:matchedTasks = 0
$script:sourceBytes = 0
$script:writer = $null

function Write-Audit([string]$Text) { $script:writer.WriteLine($Text); $script:writer.Flush() }
function Test-MonitorArguments([string]$Arguments) {
    return ($Arguments -match '(?i)watchdog[^\s"]*\.ps1' -and
        $Arguments -notmatch '(?i)Collect-Watchdog-Audit\.ps1')
}
function Get-LocalAuditPath([string]$Path) {
    if ([string]::IsNullOrEmpty($Path)) { return '' }
    if ($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path.Substring(2).Contains(':')) { return '' }
    try {
        $full = [IO.Path]::GetFullPath($Path)
        if ($full.Length -gt 3) { $full = $full.TrimEnd([char[]]@('\','/')) }
        return $full
    } catch { return '' }
}
function Add-PackageRoot([string]$Path) {
    $full = Get-LocalAuditPath $Path
    if ($full -eq '' -or -not [IO.Directory]::Exists($full)) { return }
    $script:packageRoots[$full.ToLowerInvariant()] = $full
}
function Add-RootsFromArguments([string]$Arguments) {
    foreach ($option in @('File','ConfigPath','RunDirectory')) {
        $pattern = '(?i)(?:^|\s)-' + $option + '\s+(?:"([^"\r\n]+)"|([^\s"]+))'
        $match = [regex]::Match($Arguments, $pattern)
        if (-not $match.Success) { continue }
        $path = $match.Groups[1].Value
        if ($path -eq '') { $path = $match.Groups[2].Value }
        $path = Get-LocalAuditPath $path
        if ($path -eq '') { continue }
        Add-PackageRoot ([IO.Path]::GetDirectoryName($path))
        if ($option -eq 'RunDirectory') { $script:runtimeDirectories[$path.ToLowerInvariant()] = $path }
        if ($option -eq 'ConfigPath') { $script:configFiles[$path.ToLowerInvariant()] = $path }
    }
}
function Read-XmlSafely([string]$Path) {
    $settings = New-Object Xml.XmlReaderSettings
    $settings.ProhibitDtd = $true
    $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create($Path, $settings)
    try {
        $doc = New-Object Xml.XmlDocument
        $doc.XmlResolver = $null
        $doc.Load($reader)
        return ,$doc
    } finally { $reader.Close() }
}
function Get-AuditHash([string]$Path) {
    $hasher = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { return [BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-','') }
    # .NET 2.0 exposes HashAlgorithm.Dispose explicitly through IDisposable;
    # PowerShell 2 cannot call it directly. Clear() is public in that runtime.
    finally { $stream.Dispose(); $hasher.Clear() }
}
function Write-BinaryIdentity([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return }
    try {
        $info = New-Object IO.FileInfo -ArgumentList $Path
        $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        Write-Audit ('EXECUTABLE_IDENTITY ' + $Path + ' bytes=' + $info.Length + ' version=' + $version.FileVersion + ' modified_utc=' + $info.LastWriteTimeUtc.ToString('o'))
        if ($info.Length -le 33554432) { Write-Audit ('EXECUTABLE_SHA256 ' + (Get-AuditHash $Path)) }
        else { Write-Audit 'EXECUTABLE_HASH_SKIPPED: file exceeds 32 MiB limit.' }
    } catch { Write-Audit ('EXECUTABLE_READ_ERROR ' + $Path + ': ' + $_.Exception.Message) }
}
function Write-VuniqRegistration {
    # Read both explicit registry layouts as well as the process's merged view.
    # No CreateObject/COM activation of Vuniq. Works without RegistryView/.NET 4.
    foreach ($hive in @('HKCR','HKCU','HKLM')) {
        $base = [Microsoft.Win32.Registry]::ClassesRoot
        $prefixes = @('')
        if ($hive -eq 'HKCU') { $base=[Microsoft.Win32.Registry]::CurrentUser; $prefixes=@('Software\Classes\','Software\Classes\Wow6432Node\') }
        if ($hive -eq 'HKLM') { $base=[Microsoft.Win32.Registry]::LocalMachine; $prefixes=@('Software\Classes\','Software\Classes\Wow6432Node\') }
        foreach ($prefix in $prefixes) {
            $keyPath=$prefix+'Vuniq.VuniqConnector\CLSID'
            $key=$null
            try {
                $key=$base.OpenSubKey($keyPath)
                if ($null -eq $key) { Write-Audit ('VUNIQ_COM_KEY '+$hive+'\'+$keyPath+' absent'); continue }
                $clsid=[string]$key.GetValue('')
                Write-Audit ('VUNIQ_COM_KEY '+$hive+'\'+$keyPath+'='+$clsid)
                if ($clsid -notmatch '^\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}$') { Write-Audit 'VUNIQ_COM_INVALID_CLSID'; continue }
                # ProgID can be shared while CLSID registration has a separate
                # 32-bit layout. Inspect each available CLSID layout for this ID.
                foreach ($serverPrefix in $prefixes) {
                    $serverPath=$serverPrefix+'CLSID\'+$clsid+'\LocalServer32'
                    $server=$null
                    try {
                        $server=$base.OpenSubKey($serverPath)
                        if ($null -eq $server) { Write-Audit ('VUNIQ_COM_SERVER '+$hive+'\'+$serverPath+' absent') }
                        else { Write-Audit ('VUNIQ_COM_SERVER '+$hive+'\'+$serverPath+'='+[string]$server.GetValue('')) }
                    } finally { if ($null -ne $server) { $server.Close() } }
                }
            } catch { Write-Audit ('VUNIQ_COM_READ_ERROR '+$hive+'\'+$keyPath+': '+$_.Exception.Message) }
            finally { if ($null -ne $key) { $key.Close() } }
        }
    }
}
function Write-AuditFile([string]$Path, [bool]$IsSource = $false) {
    if (-not [IO.File]::Exists($Path)) { return }
    try {
        $info = New-Object IO.FileInfo -ArgumentList $Path
        Write-Audit ('FILE ' + $Path + ' bytes=' + $info.Length + ' modified_utc=' + $info.LastWriteTimeUtc.ToString('o'))
        if ($info.Length -gt 2097152) { Write-Audit 'SKIPPED: file exceeds 2 MiB read limit.'; return }
        # A fingerprint failure must not prevent collection of the source/log.
        try { Write-Audit ('SHA256 ' + (Get-AuditHash $Path)) }
        catch { Write-Audit ('HASH_ERROR ' + $_.Exception.Message) }
        if ($IsSource -and ($info.Length -gt 98304 -or $script:sourceBytes + $info.Length -gt 786432)) {
            Write-Audit 'SOURCE OMITTED: size budget exceeded.'; return
        }
        if ($IsSource) { $script:sourceBytes += $info.Length }
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $reader = New-Object IO.StreamReader -ArgumentList $stream
            try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        } finally { $stream.Dispose() }
        $rows = @($text -split '\r?\n')
        if ([IO.Path]::GetFileName($Path) -like '*.log*' -and $rows.Count -gt 100) {
            Write-Audit 'LAST 100 LOG LINES:'
            $rows = @($rows | Select-Object -Last 100)
        }
        foreach ($row in $rows) { Write-Audit $row }
        Write-Audit ('END_FILE ' + $Path)
    } catch { Write-Audit ('FILE_READ_ERROR ' + $Path + ': ' + $_.Exception.Message) }
}
function Write-PackageAudit([string]$Root) {
    Write-Audit ('PACKAGE_DIRECTORY ' + $Root)
    try {
        foreach ($info in @(Get-ChildItem -LiteralPath $Root -ErrorAction Stop | Where-Object { -not $_.PSIsContainer } | Select-Object -First 100)) {
            Write-Audit ('PACKAGE_FILE ' + $info.Name + ' bytes=' + $info.Length + ' modified_utc=' + $info.LastWriteTimeUtc.ToString('o'))
        }
    } catch { Write-Audit ('PACKAGE_LIST_ERROR ' + $_.Exception.Message) }
    foreach ($file in @('config.xml','config.json','PACKAGE_ID.txt','VERSION.txt')) {
        Write-AuditFile (Join-Path $Root $file)
    }
    foreach ($file in @('PAUSED','STOP','KEEPER_STOP','data\PAUSE.flag','data\STOP.flag','data\LOCKOUT.flag','data\RESET.flag')) {
        $path = Join-Path $Root $file
        Write-Audit ('FLAG ' + $path + ' exists=' + [IO.File]::Exists($path))
        Write-AuditFile $path
    }
    foreach ($file in @('runtime\binding.xml','runtime\binding.xml.previous','runtime\keeper.xml','runtime\keeper.log','runtime\keeper-attempts.xml','runtime\keeper-launch-state.xml','runtime\state.xml','runtime\state.xml.previous','data\attempts.xml','data\status.txt','data\watchdog.pid','runtime\watchdog.log','runtime\watchdog.log.1','data\watchdog.log','data\watchdog.log.1')) {
        Write-AuditFile (Join-Path $Root $file)
    }
    Write-BinaryIdentity (Join-Path $Root 'VuniqKeeper.exe')
    Write-BinaryIdentity (Join-Path $Root 'VuniqKeeper131.exe')
    Write-BinaryIdentity (Join-Path $Root 'VuniqKeeper132.exe')
    $cfgPath = Join-Path $Root 'config.xml'
    if ([IO.File]::Exists($cfgPath)) {
        try {
            $doc = Read-XmlSafely $cfgPath
            foreach ($name in @('TargetPath','ExecutablePath','VuniqPath','WorkingDirectory')) {
                $node = $doc.SelectSingleNode('/Watchdog/' + $name)
                if ($null -eq $node -or $node.InnerText -eq '') { continue }
                $path = [string]$node.InnerText
                Write-Audit ('CONFIG_PATH ' + $name + '=' + $path + ' file_exists=' + [IO.File]::Exists($path) + ' directory_exists=' + [IO.Directory]::Exists($path))
                if ($name -ne 'WorkingDirectory') { Write-BinaryIdentity $path }
            }
        } catch { Write-Audit ('CONFIG_XML_ERROR ' + $_.Exception.Message) }
    }
    # Include the installed scripts as data so V2 can be compared with our source.
    foreach ($file in @('Watchdog.ps1','Common.ps1','Watchdog.Core.ps1','Install.ps1','Setup.ps1','Resume.ps1','Pause.ps1','Control.ps1','Task.Definition.ps1','Check.ps1','Status.ps1','Uninstall.ps1','StopKeeper.ps1','VuniqKeeper.exe.config','VuniqKeeper131.exe.config','VuniqKeeper132.exe.config','Install.cmd','Setup.cmd','Resume.cmd','Pause.cmd','Check.cmd','Status.cmd','Uninstall.cmd','StopKeeper.cmd')) {
        Write-AuditFile (Join-Path $Root $file) $true
    }
}
function Write-RuntimeAudit([string]$Directory) {
    Write-Audit ('EXPLICIT_RUNTIME_DIRECTORY ' + $Directory + ' exists=' + [IO.Directory]::Exists($Directory))
    foreach ($file in @('PAUSE.flag','STOP.flag','LOCKOUT.flag','RESET.flag','PAUSED','STOP')) {
        $path = Join-Path $Directory $file
        Write-Audit ('FLAG ' + $path + ' exists=' + [IO.File]::Exists($path))
        Write-AuditFile $path
    }
    foreach ($file in @('attempts.xml','state.xml','state.xml.previous','status.txt','watchdog.pid','watchdog.log','watchdog.log.1')) {
        Write-AuditFile (Join-Path $Directory $file)
    }
}
function Inspect-Task($Task) {
    try {
        $definition = $Task.Definition
        $actionMatches = $false
        for ($i=1; $i -le $definition.Actions.Count; $i++) {
            $action = $definition.Actions.Item($i)
            if ($action.Type -eq 0 -and (Test-MonitorArguments ([string]$action.Arguments))) { $actionMatches=$true }
        }
        if ([string]$Task.Name -notmatch '(?i)nilit|vuniq|watchdog' -and -not $actionMatches) { return }
        $script:matchedTasks++
        Write-Audit ('TASK ' + $Task.Path + ' enabled=' + $Task.Enabled + ' state=' + $Task.State)
        Write-Audit ('TASK_LAST_RESULT decimal=' + $Task.LastTaskResult + ' hex=0x' + (([long]$Task.LastTaskResult -band [long]4294967295).ToString('X8')))
        Write-Audit ('TASK_LAST_RUN ' + $Task.LastRunTime + ' next_run=' + $Task.NextRunTime)
        Write-Audit ('TASK_SOURCE ' + $definition.RegistrationInfo.Source)
        Write-Audit ('TASK_OPERATOR ' + $definition.Principal.UserId + ' logon_type=' + $definition.Principal.LogonType + ' run_level=' + $definition.Principal.RunLevel)
        Write-Audit ('TASK_POLICY instances=' + $definition.Settings.MultipleInstances + ' execution_limit=' + $definition.Settings.ExecutionTimeLimit + ' allow_demand=' + $definition.Settings.AllowDemandStart + ' restart_count=' + $definition.Settings.RestartCount + ' restart_interval=' + $definition.Settings.RestartInterval)
        for ($i=1; $i -le $definition.Actions.Count; $i++) {
            $action = $definition.Actions.Item($i)
            if ($action.Type -ne 0) { Write-Audit ('TASK_ACTION type=' + $action.Type); continue }
            Write-Audit ('TASK_ACTION executable=' + $action.Path + ' file_exists=' + [IO.File]::Exists([string]$action.Path))
            Write-Audit ('TASK_ARGUMENTS ' + $action.Arguments)
            Write-Audit ('TASK_START_IN ' + $action.WorkingDirectory)
            if ($actionMatches) {
                Add-PackageRoot ([string]$action.WorkingDirectory)
                Add-RootsFromArguments ([string]$action.Arguments)
            }
        }
        # The task XML contains the complete triggers and launch policy, no stored password.
        Write-Audit 'TASK_XML_BEGIN'
        Write-Audit ([string]$definition.XmlText)
        Write-Audit 'TASK_XML_END'
    } catch { Write-Audit ('TASK_READ_ERROR ' + $_.Exception.Message) }
}
function Inspect-TaskFolder($Folder) {
    $script:visitedFolders++
    if ($script:visitedFolders -gt 100) { Write-Audit 'TASK_FOLDER_LIMIT'; return }
    try {
        $tasks = $Folder.GetTasks(1)
        for ($i=1; $i -le $tasks.Count; $i++) { Inspect-Task ($tasks.Item($i)) }
    } catch { Write-Audit ('TASK_FOLDER_READ_ERROR ' + $Folder.Path + ': ' + $_.Exception.Message) }
    try {
        $folders = $Folder.GetFolders(0)
        for ($i=1; $i -le $folders.Count; $i++) { Inspect-TaskFolder ($folders.Item($i)) }
    } catch { Write-Audit ('SUBFOLDER_READ_ERROR ' + $_.Exception.Message) }
}
if ($FunctionsOnly) { return }

$reportDirectory = Join-Path $toolRoot 'reports'
[void][IO.Directory]::CreateDirectory($reportDirectory)
$report = Join-Path $reportDirectory ('EF-watchdog-audit-' + [datetime]::Now.ToString('yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.txt')
$script:writer = New-Object IO.StreamWriter -ArgumentList $report,$false,(New-Object Text.UTF8Encoding -ArgumentList $true)
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal -ArgumentList $identity
    Write-Audit ('AUDIT_START collector_version=1.3.1-independent machine=' + $env:COMPUTERNAME + ' os=' + [Environment]::OSVersion.Version + ' powershell=' + $PSVersionTable.PSVersion + ' clr=' + [Environment]::Version + ' bits=' + ([IntPtr]::Size*8) + ' session=' + [Diagnostics.Process]::GetCurrentProcess().SessionId)
    Write-Audit ('UTC=' + [datetime]::UtcNow.ToString('o') + ' local=' + [datetime]::Now.ToString('o'))
    Write-Audit ('ACCOUNT=' + $identity.Name + ' elevated=' + $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
    Write-Audit 'READ_ONLY: no task run/stop/register/delete, no app activation/termination, no configuration or flag changes.'
    Write-VuniqRegistration
    try {
        $scheduler=New-Object -ComObject 'Schedule.Service'
        $scheduler.Connect()
        Inspect-TaskFolder ($scheduler.GetFolder('\'))
        Write-Audit ('MATCHED_TASKS ' + $script:matchedTasks)
    } catch { Write-Audit ('TASK_SCHEDULER_UNAVAILABLE ' + $_.Exception.Message) }
    try {
        $processes = @(Get-WmiObject -Class Win32_Process -Filter "Name='nilit.exe' OR Name='Vuniq.exe' OR Name='VuniqKeeper.exe' OR Name='VuniqKeeper131.exe' OR Name='VuniqKeeper132.exe' OR Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop)
        foreach ($proc in $processes) {
            if ($proc.Name -match '^(?i:powershell|pwsh)\.exe$' -and -not (Test-MonitorArguments ([string]$proc.CommandLine))) { continue }
            Write-Audit ('PROCESS name=' + $proc.Name + ' pid=' + $proc.ProcessId + ' parent_pid=' + $proc.ParentProcessId + ' session=' + $proc.SessionId + ' created=' + $proc.CreationDate + ' executable=' + $proc.ExecutablePath)
            if ($proc.Name -match '^(?i:powershell|pwsh)\.exe$') {
                Write-Audit ('MONITOR_COMMAND ' + $proc.CommandLine)
                Add-RootsFromArguments ([string]$proc.CommandLine)
            }
        }
    } catch { Write-Audit ('PROCESS_WMI_UNAVAILABLE ' + $_.Exception.Message) }
    Add-PackageRoot $PackageDirectory
    if ($env:ProgramData) {
        $known = Join-Path $env:ProgramData 'NilitWatchdog'
        if ([IO.File]::Exists((Join-Path $known 'Watchdog.ps1'))) { Add-PackageRoot $known }
    }
    Write-Audit ('PACKAGE_DIRECTORIES ' + $script:packageRoots.Count)
    foreach ($root in @($script:packageRoots.Values | Sort-Object)) { Write-PackageAudit $root }
    foreach ($configFile in @($script:configFiles.Values | Sort-Object)) {
        Write-Audit ('EXPLICIT_CONFIG ' + $configFile + ' exists=' + [IO.File]::Exists($configFile))
        Write-AuditFile $configFile
    }
    foreach ($directory in @($script:runtimeDirectories.Values | Sort-Object)) { Write-RuntimeAudit $directory }
    if ($script:packageRoots.Count -eq 0) { Write-Audit 'No installed package directory could be discovered. Task/process access errors above may explain this.' }
    Write-Audit 'AUDIT_END'
} finally { $script:writer.Dispose(); $script:writer=$null }
Write-Output ('Report saved: ' + $report)
Write-Output 'Send this TXT report. No apps or monitoring settings were changed.'
