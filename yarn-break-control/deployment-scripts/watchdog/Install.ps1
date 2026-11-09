#requires -Version 2.0
[CmdletBinding()]
param(
    [string]$TargetPath,
    [string]$VuniqPath,
    [string]$Arguments,
    [string]$WorkingDirectory,
    [switch]$RunElevated,
    [switch]$Preview
)

$ErrorActionPreference = 'Stop'
$taskName = 'NILIT EF Watchdog'
$taskSource = 'NILIT.EF.Watchdog.v2'
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptDirectory 'config.xml'
$watchdogPath = Join-Path $scriptDirectory 'Watchdog.ps1'
$validationPath = $null
$temporaryConfig = $null

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

function Assert-OwnedTask($Task, [string]$Directory) {
    if ($null -eq $Task) { return }
    $definition = $Task.Definition
    if ($definition.RegistrationInfo.Source -cne $taskSource) {
        throw ('A task named "' + $taskName + '" exists and is not owned by this package. It was not changed.')
    }
    Assert-TaskPrincipal $definition.Principal $userSid $identity.Name
    if ($definition.Actions.Count -ne 1 -or $definition.Actions.Item(1).Type -ne 0) {
        throw 'The existing task has unexpected actions. It was not changed.'
    }
    $action = $definition.Actions.Item(1)
    if ([string]::IsNullOrEmpty($action.WorkingDirectory) -or
        (Get-CanonicalPath $action.WorkingDirectory) -ine (Get-CanonicalPath $Directory)) {
        throw 'A watchdog is installed from another folder. Pause and uninstall that copy first.'
    }
    if ($action.Arguments -notlike '*-File *Watchdog.ps1*') {
        throw 'The existing task does not contain the expected watchdog action. It was not changed.'
    }
}

function Assert-NoLegacyMonitor($Folder) {
    $legacySources = @{
        'NILIT GH Watchdog' = 'NILIT.GH.Watchdog.v1'
        'Vuniq GH Watchdog' = 'NILIT.Vuniq.GH.Watchdog.v1'
        'NILIT Watchdog' = 'NILIT.YarnBreak.Watchdog.v1'
    }
    foreach ($legacyName in $legacySources.Keys) {
        $legacyTask = Get-ExistingTask $Folder $legacyName
        if ($null -eq $legacyTask) { continue }
        if ($legacyTask.Definition.RegistrationInfo.Source -cne $legacySources[$legacyName]) { continue }
        if ($legacyTask.Enabled -or $legacyTask.State -eq 4) {
            $oldDirectory = ''
            if ($legacyTask.Definition.Actions.Count -eq 1) {
                $oldDirectory = [string]$legacyTask.Definition.Actions.Item(1).WorkingDirectory
            }
            throw ('An older monitor is still installed: "' + $legacyName + '". Run Uninstall.cmd from its original folder first: ' + $oldDirectory + '. Then run this Install.cmd again. The old task was not changed.')
        }
    }
}

try {
    if (-not [System.IO.Path]::IsPathRooted($scriptDirectory) -or $scriptDirectory.StartsWith('\\')) {
        throw 'Copy the complete package to a permanent local folder before installing.'
    }
    if (-not (Test-Path -LiteralPath $watchdogPath -PathType Leaf)) {
        throw 'Watchdog.ps1 is missing. Keep the complete package together.'
    }
    foreach ($required in @('VuniqKeeper132.exe','VuniqKeeper132.exe.config')) { if (-not [IO.File]::Exists((Join-Path $scriptDirectory $required))) { throw ('Missing package file: ' + $required) } }
    . (Join-Path $scriptDirectory 'Common.ps1')
    . (Join-Path $scriptDirectory 'TaskIdentity.ps1')
    $scriptDirectory = Get-CanonicalPath $scriptDirectory
    $configPath = Join-Path $scriptDirectory 'config.xml'
    $watchdogPath = Join-Path $scriptDirectory 'Watchdog.ps1'
    $originalConfig = [System.IO.File]::ReadAllBytes($configPath)
    $document = New-Object System.Xml.XmlDocument
    $document.PreserveWhitespace = $true
    $document.XmlResolver = $null
    $xmlSettings = New-Object System.Xml.XmlReaderSettings
    $xmlSettings.ProhibitDtd = $true
    $xmlSettings.XmlResolver = $null
    $configReader = [System.Xml.XmlReader]::Create($configPath, $xmlSettings)
    try { $document.Load($configReader) }
    finally { $configReader.Close() }
    foreach ($key in @('TargetPath', 'VuniqPath', 'Arguments', 'WorkingDirectory')) {
        $node = $document.SelectSingleNode('/Watchdog/' + $key)
        if ($null -eq $node) { throw ('config.xml is missing Watchdog/' + $key + '.') }
        if ($PSBoundParameters.ContainsKey($key)) { $node.InnerText = [string]$PSBoundParameters[$key] }
    }

    # Validate the prospective configuration without changing config.xml, including in Preview.
    $validationPath = Join-Path $scriptDirectory ('validate.' + [Guid]::NewGuid().ToString('N') + '.xml')
    $document.Save($validationPath)
    $config = Read-WatchdogConfig $validationPath
    $target = Get-Item -LiteralPath $config.TargetPath -ErrorAction Stop
    if ($target.PSIsContainer -or [System.IO.Path]::GetExtension($target.FullName) -ine '.exe') {
        throw 'TargetPath must point to an existing local .exe file.'
    }
    $working = Get-Item -LiteralPath $config.WorkingDirectory -ErrorAction Stop
    if (-not $working.PSIsContainer) { throw 'WorkingDirectory must point to an existing local folder.' }
    $TargetPath = Get-CanonicalPath $target.FullName
    $vuniq = Get-Item -LiteralPath $config.VuniqPath -ErrorAction Stop
    if ($vuniq.PSIsContainer -or [System.IO.Path]::GetExtension($vuniq.FullName) -ine '.exe') {
        throw 'VuniqPath must point to an existing local .exe file.'
    }
    $VuniqPath = Get-CanonicalPath $vuniq.FullName
    if ($VuniqPath -ieq $TargetPath) {
        throw 'VuniqPath and the NILIT TargetPath must identify different executables.'
    }
    $WorkingDirectory = Get-CanonicalPath $working.FullName
    $Arguments = [string]$config.Arguments
    $document.SelectSingleNode('/Watchdog/TargetPath').InnerText = $TargetPath
    $document.SelectSingleNode('/Watchdog/VuniqPath').InnerText = $VuniqPath
    $document.SelectSingleNode('/Watchdog/WorkingDirectory').InnerText = $WorkingDirectory
    [System.IO.File]::Delete($validationPath)
    $validationPath = $null

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $userSid = $identity.User.Value
    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellPath -PathType Leaf)) {
        throw 'Windows PowerShell was not found in the expected Windows directory.'
    }
    $scheduler = New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    $definition = $scheduler.NewTask(0)
    $definition.RegistrationInfo.Author = $identity.Name
    $definition.RegistrationInfo.Source = $taskSource
    $definition.RegistrationInfo.Description = 'Keeps an independent read-only Vuniq connector alive and recovers NILIT after its configured delay. NILIT recovery never closes Vuniq.'
    $definition.Principal.Id = 'Operator'
    $definition.Principal.UserId = $userSid
    $definition.Principal.LogonType = 3
    $definition.Principal.RunLevel = 0
    if ($RunElevated) { $definition.Principal.RunLevel = 1 }
    $settings = $definition.Settings
    $settings.Compatibility = 2
    $settings.Enabled = $true
    $settings.Hidden = $true
    $settings.MultipleInstances = 2
    $settings.ExecutionTimeLimit = 'PT0S'
    $settings.DisallowStartIfOnBatteries = $false
    $settings.StopIfGoingOnBatteries = $false
    $settings.RunOnlyIfIdle = $false
    $settings.IdleSettings.StopOnIdleEnd = $false
    $settings.IdleSettings.RestartOnIdle = $false
    $settings.RunOnlyIfNetworkAvailable = $false
    $settings.StartWhenAvailable = $true
    $settings.AllowDemandStart = $true
    $settings.RestartCount = 3
    $settings.RestartInterval = 'PT1M'

    $logonTrigger = $definition.Triggers.Create(9)
    $logonTrigger.Id = 'OperatorLogon'
    $logonTrigger.UserId = $userSid
    $logonTrigger.Delay = 'PT30S'
    $logonTrigger.Enabled = $true
    $timerTrigger = $definition.Triggers.Create(1)
    $timerTrigger.Id = 'MonitorRecovery'
    $timerTrigger.StartBoundary = [DateTime]::Now.AddMinutes(1).ToString("yyyy-MM-dd'T'HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
    $timerTrigger.Enabled = $true
    $timerTrigger.Repetition.Interval = 'PT1M'
    $timerTrigger.Repetition.StopAtDurationEnd = $false
    $action = $definition.Actions.Create(0)
    $action.Path = $powershellPath
    $action.Arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $watchdogPath + '"'
    $action.WorkingDirectory = $scriptDirectory

    if ($Preview) {
        $previewPath = Join-Path $scriptDirectory 'Task.preview.xml'
        $previewDocument = New-Object System.Xml.XmlDocument
        $previewDocument.LoadXml($definition.XmlText)
        $previewDocument.Save($previewPath)
        Write-Host ('Preview written: ' + $previewPath)
        Write-Host ('Operator: ' + $identity.Name + ' (' + $userSid + ')')
        Write-Host ('NILIT: ' + $TargetPath)
        Write-Host ('Vuniq preserved during NILIT recovery: ' + $VuniqPath)
        Write-Host ('Arguments: ' + $Arguments)
        Write-Host ('Working directory: ' + $WorkingDirectory)
        Write-Host 'No task was registered or run. config.xml and pause/stop markers were not changed.'
        exit 0
    }

    $folder = $scheduler.GetFolder('\')
    Assert-NoLegacyMonitor $folder
    $existingTask = Get-ExistingTask $folder $taskName
    Assert-OwnedTask $existingTask $scriptDirectory
    $temporaryConfig = Join-Path $scriptDirectory ('config.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $configSaved = $false
    try {
        $document.Save($temporaryConfig)
        [System.IO.File]::Replace($temporaryConfig, $configPath, ($configPath + '.previous'))
        $temporaryConfig = $null
        $configSaved = $true
        $registeredTask = $folder.RegisterTaskDefinition($taskName, $definition, 6, $userSid, $null, 3, $null)
    }
    catch {
        if ($configSaved) { [System.IO.File]::WriteAllBytes($configPath, $originalConfig) }
        throw
    }
    # The uninstaller leaves STOP in place; clear it only after successful registration.
    [System.IO.File]::Delete((Join-Path $scriptDirectory 'STOP'))
    [System.IO.File]::Delete((Join-Path $scriptDirectory 'KEEPER_STOP'))
    try { $runningTask = $registeredTask.Run($null) }
    catch {
        throw ('The NILIT watchdog task was installed, but its immediate start request failed: ' + $_.Exception.Message + '. Run Resume.cmd to retry; the task also retries on its next scheduled trigger.')
    }
    Write-Host ('Installed task: ' + $registeredTask.Path)
    Write-Host ('Operator: ' + $identity.Name)
    Write-Host ('NILIT: ' + $TargetPath)
    Write-Host ('Vuniq preserved during NILIT recovery: ' + $VuniqPath)
    Write-Host 'Keep this complete package in its current permanent local folder.'
    Write-Host 'Start requested for the hidden NILIT monitor now; repeated requests do not create a second task instance.'
    Write-Host 'For NILIT recovery, the monitor waits and restarts NILIT only. Vuniq and its independent keeper are preserved.'
    Write-Host 'The independent x86 keeper holds one read-only internal counter connector and can activate Vuniq when absent; it never closes Vuniq.'
    Write-Host 'An existing monitor exits on configuration changes; the scheduler reloads it within about one minute.'
    if (Test-Path -LiteralPath (Join-Path $scriptDirectory 'PAUSED')) {
        Write-Host 'Supervision is PAUSED. Run Resume.cmd when ready.'
    }
    exit 0
}
catch {
    Write-Error ('Installation failed: ' + $_.Exception.Message) -ErrorAction Continue
    exit 1
}
finally {
    if ($null -ne $validationPath -and [System.IO.File]::Exists($validationPath)) { [System.IO.File]::Delete($validationPath) }
    if ($null -ne $temporaryConfig -and [System.IO.File]::Exists($temporaryConfig)) { [System.IO.File]::Delete($temporaryConfig) }
}
