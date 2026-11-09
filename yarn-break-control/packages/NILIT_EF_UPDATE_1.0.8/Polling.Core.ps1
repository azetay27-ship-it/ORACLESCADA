#requires -Version 2.0

$script:recordKeys = @('Schema','Sequence','BackupId','CreatedUtc','TargetDirectory','Status','OriginalMainSha256','OriginalExporterExists','OriginalExporterSha256','InstalledMainSha256','InstalledExporterSha256')

function Get-Hash {
    param([string] $Path)
    $stream = $null
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-', '').ToUpperInvariant()
    }
    finally {
        if ($null -ne $stream) { $stream.Close() }
        $algorithm.Clear()
    }
}

function Assert-PlainFile {
    param([string] $Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw ('Expected an ordinary file: ' + $Path) }
}

function Copy-Verified {
    param([string] $Source, [string] $Destination, [string] $ExpectedHash)
    Assert-PlainFile $Source
    $inputStream = $null
    $outputStream = $null
    try {
        $inputStream = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $outputStream = New-Object IO.FileStream($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 65536, [IO.FileOptions]::WriteThrough)
        $buffer = New-Object byte[] 65536
        while (($count = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) { $outputStream.Write($buffer, 0, $count) }
        $outputStream.Flush()
    }
    finally {
        if ($null -ne $outputStream) { $outputStream.Close() }
        if ($null -ne $inputStream) { $inputStream.Close() }
    }
    if ((Get-Hash $Destination) -ne $ExpectedHash) { throw ('Copied file hash mismatch: ' + $Destination) }
}

function Read-Record {
    param([string] $BackupDirectory, [string] $Target)
    $path = Join-Path $BackupDirectory 'deployment-record.txt'
    Assert-PlainFile $path
    $record = @{}
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        $cut = $line.IndexOf('=')
        if ($cut -le 0) { throw ('Invalid backup record: ' + $path) }
        $key = $line.Substring(0, $cut)
        if (-not ($recordKeys -contains $key) -or $record.ContainsKey($key)) { throw ('Unknown or duplicate backup field: ' + $path) }
        $record[$key] = $line.Substring($cut + 1)
    }
    if ($record.Count -ne $recordKeys.Count -or $record['Schema'] -ne 'NILIT-EF-DEPLOY-2') { throw ('Unsupported backup record: ' + $path) }
    if ($record['Sequence'] -notmatch '^[1-9][0-9]{0,17}$') { throw 'Invalid backup sequence.' }
    if ($record['BackupId'] -notmatch '^[0-9a-fA-F]{32}$') { throw 'Invalid backup identifier.' }
    if (-not [string]::Equals($record['TargetDirectory'], $Target, [StringComparison]::OrdinalIgnoreCase)) { throw 'Backup target does not match TargetDirectory.' }
    if (@('Prepared', 'Installed', 'Restored', 'RolledBack') -notcontains $record['Status']) { throw 'Unknown backup status.' }
    foreach ($key in @('OriginalMainSha256', 'InstalledMainSha256', 'InstalledExporterSha256')) {
        if ($record[$key] -notmatch '^[0-9A-Fa-f]{64}$') { throw ('Invalid recorded hash: ' + $key) }
    }
    if ($record['OriginalExporterExists'] -ne '0' -and $record['OriginalExporterExists'] -ne '1') { throw 'Invalid original-exporter flag.' }
    if ($record['OriginalExporterExists'] -eq '1') {
        if ($record['OriginalExporterSha256'] -notmatch '^[0-9A-Fa-f]{64}$') { throw 'Invalid original exporter hash.' }
    }
    elseif ($record['OriginalExporterSha256'] -ne '-') { throw 'Unexpected original exporter hash.' }
    return $record
}

function Get-LatestBackup {
    param([string] $Target)
    $latest = $null
    $sequences = @{}
    foreach ($item in @(Get-ChildItem -LiteralPath $Target -Force)) {
        if ($item.Name -notlike 'nilit-backup-*') { continue }
        if (-not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw ('Backup path is not an ordinary directory: ' + $item.FullName) }
        $path = Join-Path $item.FullName 'deployment-record.txt'
        if (-not [IO.File]::Exists($path)) { continue }
        $record = Read-Record $item.FullName $Target
        $sequence = [Int64]::Parse($record['Sequence'], [Globalization.CultureInfo]::InvariantCulture)
        if ($sequences.ContainsKey($sequence)) { throw 'Duplicate backup sequence; preserve all backup folders for review.' }
        $sequences[$sequence] = $true
        if ($null -eq $latest -or $sequence -gt $latest.Sequence) {
            $latest = New-Object PSObject -Property @{ Directory = $item.FullName; Record = $record; Sequence = $sequence }
        }
    }
    return $latest
}

function Assert-CFPlainPath([string]$Path, [bool]$Directory) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full.Length -lt 4 -or $full.Substring(1,2) -ne ':\') { throw 'A local absolute Windows path is required.' }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ([bool]$item.PSIsContainer -ne $Directory) { throw ('Unexpected file/directory: ' + $full) }
    $check = $item
    while ($null -ne $check) {
        if (($check.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw ('Linked path refused: ' + $check.FullName) }
        if ($check -is [IO.DirectoryInfo]) { $check = $check.Parent } else { $check = $check.Directory }
    }
    return $full
}

function Read-CFXML([string]$Path) {
    $null = Assert-CFPlainPath $Path $false
    $document = New-Object Xml.XmlDocument
    $document.XmlResolver = $null
    $settings = New-Object Xml.XmlReaderSettings
    $settings.ProhibitDtd = $true; $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create($Path,$settings)
    try { $document.Load($reader) } finally { $reader.Close() }
    return ,$document
}

$script:pollingIds=@('TargetMain','TargetExporter','PackageMain','PackageExporter','CounterHashes','PackageHashes')
$script:pollingOldHashes=@{
    TargetMain='B86D52A929270532E64685860CA84101AEA4299D83E2183CC10C1E236855C99A';
    TargetExporter='B86D52A929270532E64685860CA84101AEA4299D83E2183CC10C1E236855C99A';
    PackageMain='B86D52A929270532E64685860CA84101AEA4299D83E2183CC10C1E236855C99A';
    PackageExporter='B86D52A929270532E64685860CA84101AEA4299D83E2183CC10C1E236855C99A';
    CounterHashes='24DE6E880B04ED37BE39EC731D2B6070BF2AD55C17BC6FA9A0CAB7D0F84B5410';
    PackageHashes='5CE5DA99005D6DD65202C34A9DFF10D4A05F868E4BD8F5ECDC9D5863EABC0F28'
}

function Read-CFManifest([string]$FixRoot) {
    $doc=Read-CFXML (Join-Path $FixRoot 'polling-manifest.xml')
    if($doc.DocumentElement.Name -cne 'PollingUpdate' -or $doc.PollingUpdate.Id -cne 'NILIT-EF-Polling-1.0.8'){throw 'Wrong polling update manifest.'}
    if($doc.PollingUpdate.IdentitySHA256 -cne '78C98F0F84223249094BE73C656D058D5AE8606236EEA94B385CC0FCC444326B'){throw 'Wrong task identity helper.'}
    if((Get-Hash (Join-Path $FixRoot 'TaskIdentity.ps1')) -cne $doc.PollingUpdate.IdentitySHA256){throw 'Damaged task identity helper.'}
    $payloads=@{TargetMain='nilit.exe';TargetExporter='nilit-export.exe';PackageMain='nilit.exe';PackageExporter='nilit-export.exe';CounterHashes='counter-SHA256SUMS.txt';PackageHashes='package-SHA256SUMS.txt'}
    $files=@{}
    foreach($node in $doc.SelectNodes('/PollingUpdate/File')) {
        $id=[string]$node.Id
        if(-not $payloads.ContainsKey($id) -or $files.ContainsKey($id) -or $node.Payload -cne $payloads[$id]){throw 'Unexpected or duplicate update file.'}
        foreach($field in @('OldSHA256','NewSHA256')){if([string]$node.GetAttribute($field) -cnotmatch '^[0-9A-F]{64}$'){throw 'Invalid update hash.'}}
        if($node.OldSHA256 -cne $script:pollingOldHashes[$id]){throw 'Only the verified 1.0.7 runtime and its hash lists can be upgraded.'}
        if($node.OldSHA256 -ceq $node.NewSHA256){throw 'Update payload must differ from 1.0.7.'}
        $payload=Join-Path (Join-Path $FixRoot 'payload') $payloads[$id];$null=Assert-CFPlainPath $payload $false
        if((Get-Hash $payload) -cne $node.NewSHA256){throw ('Damaged update payload: '+$id)}
        $files[$id]=$node
    }
    if($files.Count -ne 6){throw 'Incomplete update payload.'}
    foreach($id in @('TargetExporter','PackageMain','PackageExporter')){if($files[$id].NewSHA256 -cne $files.TargetMain.NewSHA256){throw 'Both executable pairs must be identical.'}}
    return $files
}

function Get-CFContext {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    if($identity.IsSystem -or [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0){throw 'Use the original signed-in HMI operator account.'}
    $scheduler=New-Object -ComObject 'Schedule.Service';$scheduler.Connect()
    $task=$scheduler.GetFolder('\').GetTask('NILIT EF Watchdog')
    return Assert-CFTask $task $identity.User.Value $identity.Name
}

function Assert-CFTask($Task,[string]$Sid,[string]$Name) {
    if($Task.Path -cne '\NILIT EF Watchdog'){throw 'Unexpected watchdog task identity.'}
    $def=$Task.Definition
    if($def.RegistrationInfo.Source -cne 'NILIT.EF.Watchdog.v2'){throw 'The existing task is not owned by the EF package.'}
    Assert-TaskPrincipal $def.Principal $Sid $Name
    if($def.Actions.Count -ne 1){throw 'Unexpected task actions.'}
    $action=$def.Actions.Item(1)
    if($action.Type -ne 0){throw 'Unexpected task action type.'}
    $watch=Assert-CFPlainPath ([string]$action.WorkingDirectory) $true
    if([IO.Path]::GetFileName($watch) -ine 'watchdog'){throw 'Unexpected installed watchdog folder.'}
    $args='-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+(Join-Path $watch 'Watchdog.ps1')+'"'
    $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if($action.Path -ine $ps -or $action.Arguments -ine $args){throw 'The task action does not match the EF package.'}
    $null=Assert-CFPlainPath (Join-Path $watch 'Watchdog.ps1') $false
    $operator=Join-Path $watch 'operator.sid';$null=Assert-CFPlainPath $operator $false
    if([IO.File]::ReadAllText($operator).Trim() -cne $Sid){throw 'Prepared operator SID differs from the signed-in user.'}
    $config=Read-CFXML (Join-Path $watch 'config.xml')
    if($config.DocumentElement.Name -cne 'Watchdog' -or $config.Watchdog.TargetPath -ine 'C:\Vuniq50\VB E_L\nilit.exe' -or $config.Watchdog.WorkingDirectory -ine 'C:\Vuniq50\VB E_L' -or $config.Watchdog.VuniqPath -ine 'C:\Vuniq50\bin\Vuniq.exe' -or $config.Watchdog.MaxStartsPerWindow -ne '0'){throw 'The watchdog configuration is not the approved EF configuration.'}
    $root=Assert-CFPlainPath (Split-Path -Parent $watch) $true
    $null=Assert-CFPlainPath (Join-Path $root 'counter') $true
    $null=Assert-CFPlainPath (Join-Path $root 'Activate-EF.ps1') $false
    return New-Object PSObject -Property @{WatchRoot=$watch;PackageRoot=$root;Target='C:\Vuniq50\VB E_L';Sid=$Sid;User=$Name}
}

function Assert-CFReady($Context) {
    $fresh=Get-CFContext
    foreach($name in @('WatchRoot','PackageRoot','Target','Sid')){if($fresh.$name -ine $Context.$name){throw 'Installation identity changed during this update.'}}
    $null=Assert-CFPlainPath $Context.Target $true
    $null=Assert-CFPlainPath (Join-Path $Context.WatchRoot 'PAUSED') $false
    $running=@(Get-Process -ErrorAction Stop|Where-Object{$_.ProcessName -ieq 'nilit' -or $_.ProcessName -ieq 'nilit-export'})
    if($running.Count -ne 0){throw 'Run existing 07-Pause, close NILIT and wait for nilit-export to finish, then retry. No application was stopped.'}
}

function Get-CFDestinations($Context) {
    return @{
        TargetMain=(Join-Path $Context.Target 'nilit.exe');TargetExporter=(Join-Path $Context.Target 'nilit-export.exe');
        PackageMain=(Join-Path $Context.PackageRoot 'counter\nilit.exe');PackageExporter=(Join-Path $Context.PackageRoot 'counter\nilit-export.exe');
        CounterHashes=(Join-Path $Context.PackageRoot 'counter\SHA256SUMS.txt');PackageHashes=(Join-Path $Context.PackageRoot 'SHA256SUMS.txt')
    }
}

function Assert-CFOriginals($Latest) {
    $null=Assert-CFPlainPath $Latest.Directory $true
    foreach($pair in @(@('original-nilit.exe','OriginalMainSha256'),@('original-nilit-export.exe','OriginalExporterSha256'))) {
        if($pair[0] -eq 'original-nilit-export.exe' -and $Latest.Record.OriginalExporterExists -eq '0'){continue}
        $p=Join-Path $Latest.Directory $pair[0];$null=Assert-CFPlainPath $p $false
        if((Get-Hash $p) -ine $Latest.Record[$pair[1]]){throw 'The original rollback backup is missing or changed.'}
    }
}

function Set-CFJournal([string]$Directory,[string]$Status) {
    $path=Join-Path $Directory 'status.txt'
    if([IO.File]::Exists($path)){$null=Assert-CFPlainPath $path $false}
    [IO.File]::WriteAllText($path,$Status,[Text.Encoding]::ASCII)
}

function Commit-CFFile([string]$Stage,[string]$Destination,[string]$Prior){[IO.File]::Replace($Stage,$Destination,$Prior)}

function Get-PollingJournals($Context) {
    $journals=@()
    foreach($item in @(Get-ChildItem -LiteralPath $Context.Target -Force)) {
        if($item.Name -notlike 'nilit-polling108-update-*'){continue}
        $null=Assert-CFPlainPath $item.FullName $true
        $statusPath=Join-Path $item.FullName 'status.txt';$null=Assert-CFPlainPath $statusPath $false
        $status=[IO.File]::ReadAllText($statusPath).Trim()
        if(@('Prepared','Committed','RollbackStarted','RolledBack') -notcontains $status){throw ('Unknown update journal; preserve '+$item.FullName)}
        $journals+=New-Object PSObject -Property @{Directory=$item.FullName;Status=$status}
    }
    return $journals
}

function Get-PollingState($Context,$Files,[bool]$AllowIncomplete=$false) {
    $active=@(Get-PollingJournals $Context|Where-Object{$_.Status -ne 'RolledBack'})
    if($active.Count -gt 1){throw 'Multiple active polling updates; preserve all backups for review.'}
    if(-not $AllowIncomplete -and $active.Count -eq 1 -and $active[0].Status -ne 'Committed'){throw ('Incomplete update: run 03-Rollback while paused. Backup: '+$active[0].Directory)}
    $dest=Get-CFDestinations $Context;$old=0;$new=0
    foreach($id in $script:pollingIds) {
        $null=Assert-CFPlainPath $dest[$id] $false;$hash=Get-Hash $dest[$id]
        if($hash -ceq $Files[$id].OldSHA256){$old++}
        elseif($hash -ceq $Files[$id].NewSHA256){$new++}
        else{throw ('Unknown or edited file; preserved: '+$dest[$id])}
    }
    $latest=Get-LatestBackup $Context.Target
    if($null -eq $latest -or $latest.Record.Status -cne 'Installed'){throw 'Installed EF deployment record required. Do not run the original installer again.'}
    Assert-CFOriginals $latest
    if($old -eq 6){$version='1.0.7';$hash=[string]$Files.TargetMain.OldSHA256}
    elseif($new -eq 6){$version='1.0.8';$hash=[string]$Files.TargetMain.NewSHA256}
    else{throw 'Mixed runtime or manifest versions. Keep supervision paused and run 03-Rollback.'}
    if($latest.Record.InstalledMainSha256 -cne $hash -or $latest.Record.InstalledExporterSha256 -cne $hash){throw 'Deployment record does not match the installed version.'}
    return $version
}

function Get-PollingRollbackEntries($Context,$Files,[string]$Backup) {
    $map=Join-Path $Backup 'files.txt';$null=Assert-CFPlainPath $map $false
    $latest=Get-LatestBackup $Context.Target
    if($null -eq $latest -or $latest.Record.Status -cne 'Installed'){throw 'Installed EF deployment record required.'}
    Assert-CFOriginals $latest
    $dest=Get-CFDestinations $Context;$dest['Record']=Join-Path $latest.Directory 'deployment-record.txt'
    $entries=@();$seen=@{}
    foreach($line in [IO.File]::ReadAllLines($map)) {
        $p=$line.Split('|');if($p.Count -ne 4){throw 'Invalid rollback map.'}
        $id=$p[0]
        if(-not $dest.ContainsKey($id) -or $seen.ContainsKey($id) -or $p[1] -ine $dest[$id]){throw 'Unexpected rollback destination.'}
        $seen[$id]=$true
        foreach($hash in @($p[2],$p[3])){if($hash -cnotmatch '^[0-9A-F]{64}$'){throw 'Invalid rollback hash.'}}
        if($id -ne 'Record' -and ($p[2] -cne $Files[$id].OldSHA256 -or $p[3] -cne $Files[$id].NewSHA256)){throw 'Rollback map differs from this release.'}
        $null=Assert-CFPlainPath $dest[$id] $false;$current=Get-Hash $dest[$id]
        if($current -cne $p[2] -and $current -cne $p[3]){throw ('Destination changed after update; current contents preserved: '+$dest[$id])}
        $before=Join-Path $Backup ($id+'.before')
        if([IO.File]::Exists($before)){$null=Assert-CFPlainPath $before $false;if((Get-Hash $before) -cne $p[2]){throw ('Changed rollback backup: '+$id)}}
        elseif($current -cne $p[2]){throw ('Missing backup for changed file: '+$id)}
        $entries+=New-Object PSObject -Property @{Id=$id;Path=$dest[$id];OldHash=$p[2];NewHash=$p[3];Before=$before}
    }
    if($entries.Count -ne 7){throw 'Incomplete rollback map.'}
    $recordEntry=@($entries|Where-Object{$_.Id -eq 'Record'})[0]
    $beforeRecord=$recordEntry.Before
    if(-not [IO.File]::Exists($beforeRecord)){$beforeRecord=$recordEntry.Path}
    $oldText=[IO.File]::ReadAllText($beforeRecord)
    foreach($key in @('InstalledMainSha256','InstalledExporterSha256')) {
        if([regex]::Matches($oldText,('(?m)^'+$key+'='+$Files.TargetMain.OldSHA256+'\r?$')).Count -ne 1){throw 'Previous deployment record has unexpected binary hashes.'}
    }
    $newText=[regex]::Replace($oldText,'(?m)^InstalledMainSha256=[^\r\n]*',('InstalledMainSha256='+$Files.TargetMain.NewSHA256))
    $newText=[regex]::Replace($newText,'(?m)^InstalledExporterSha256=[^\r\n]*',('InstalledExporterSha256='+$Files.TargetExporter.NewSHA256))
    $planned=Join-Path $Backup 'new-deployment-record.txt';$null=Assert-CFPlainPath $planned $false
    if((Get-Hash $planned) -cne $recordEntry.NewHash -or [IO.File]::ReadAllText($planned) -cne $newText){throw 'Rollback deployment record differs from the exact two-field update.'}
    return $entries
}

function Restore-PollingTransaction($Context,$Files,[string]$Backup) {
    $entries=@(Get-PollingRollbackEntries $Context $Files $Backup);$stages=@()
    try {
        Assert-CFReady $Context;Set-CFJournal $Backup 'RollbackStarted'
        for($i=$entries.Count-1;$i -ge 0;$i--) {
            $entry=$entries[$i];Assert-CFReady $Context
            $null=Assert-CFPlainPath $entry.Path $false;$current=Get-Hash $entry.Path
            if($current -ceq $entry.OldHash){continue}
            if($current -cne $entry.NewHash){throw 'Destination changed during rollback; current contents preserved.'}
            $stage=Join-Path (Split-Path -Parent $entry.Path) ('.nilit-polling106-restore-'+[Guid]::NewGuid().ToString('N')+'.tmp');$stages+=$stage
            Copy-Verified $entry.Before $stage $entry.OldHash
            Commit-CFFile $stage $entry.Path (Join-Path $Backup ($entry.Id+'.rollback-'+[Guid]::NewGuid().ToString('N')))
            if((Get-Hash $entry.Path) -cne $entry.OldHash){throw 'Restored file verification failed.'}
        }
        if((Get-PollingState $Context $Files $true) -ne '1.0.7'){throw 'Final rollback verification failed.'}
        Assert-CFReady $Context;Set-CFJournal $Backup 'RolledBack'
    } finally {foreach($stage in $stages){if([IO.File]::Exists($stage)){$null=Assert-CFPlainPath $stage $false;[IO.File]::Delete($stage)}}}
}

function Invoke-PollingUpdate([string]$FixRoot,$Context,$Files) {
    Assert-CFReady $Context
    $lock=$null;$backup='';$stages=@();$mapReady=$false
    try {
        $lockPath=Join-Path $Context.Target '.nilit-deploy.lock'
        if(Test-Path -LiteralPath $lockPath){$null=Assert-CFPlainPath $lockPath $false}
        $lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $state=Get-PollingState $Context $Files
        if($state -eq '1.0.8'){return 'Already applied and verified. No runtime or manifest changed.'}
        if(@(Get-PollingJournals $Context|Where-Object{$_.Status -ne 'RolledBack'}).Count -ne 0){throw 'Active journal with old runtime; preserve it and use 03-Rollback.'}
        $latest=Get-LatestBackup $Context.Target;$recordPath=Join-Path $latest.Directory 'deployment-record.txt'
        $backup=Join-Path $Context.Target ('nilit-polling108-update-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'-'+[Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($backup);Set-CFJournal $backup 'Prepared'
        $dest=Get-CFDestinations $Context;$entries=@()
        foreach($id in $script:pollingIds){$entries+=New-Object PSObject -Property @{Id=$id;Path=$dest[$id];OldHash=[string]$Files[$id].OldSHA256;NewHash=[string]$Files[$id].NewSHA256;Source=(Join-Path (Join-Path $FixRoot 'payload') ([string]$Files[$id].Payload))}}
        $oldRecordHash=Get-Hash $recordPath;$text=[IO.File]::ReadAllText($recordPath)
        $text=[regex]::Replace($text,'(?m)^InstalledMainSha256=[^\r\n]*',('InstalledMainSha256='+$Files.TargetMain.NewSHA256))
        $text=[regex]::Replace($text,'(?m)^InstalledExporterSha256=[^\r\n]*',('InstalledExporterSha256='+$Files.TargetExporter.NewSHA256))
        $newRecord=Join-Path $backup 'new-deployment-record.txt';[IO.File]::WriteAllText($newRecord,$text,(New-Object Text.UTF8Encoding($false)))
        $entries+=New-Object PSObject -Property @{Id='Record';Path=$recordPath;OldHash=$oldRecordHash;NewHash=(Get-Hash $newRecord);Source=$newRecord}
        $map=@();foreach($entry in $entries){$map+=($entry.Id+'|'+$entry.Path+'|'+$entry.OldHash+'|'+$entry.NewHash)}
        [IO.File]::WriteAllLines((Join-Path $backup 'files.txt'),[string[]]$map,[Text.Encoding]::UTF8);$mapReady=$true
        foreach($entry in $entries) {
            Copy-Verified $entry.Path (Join-Path $backup ($entry.Id+'.before')) $entry.OldHash
            $stage=Join-Path (Split-Path -Parent $entry.Path) ('.nilit-polling108-update-'+[Guid]::NewGuid().ToString('N')+'.tmp');$stages+=$stage
            Copy-Verified $entry.Source $stage $entry.NewHash
            $entry|Add-Member -MemberType NoteProperty -Name Stage -Value $stage
        }
        foreach($entry in $entries) {
            Assert-CFReady $Context;Assert-CFOriginals $latest
            $null=Assert-CFPlainPath $entry.Path $false
            if((Get-Hash $entry.Path) -cne $entry.OldHash){throw ('Destination changed during update: '+$entry.Path)}
            Commit-CFFile $entry.Stage $entry.Path (Join-Path $backup ($entry.Id+'.replaced'))
        }
        if((Get-PollingState $Context $Files $true) -ne '1.0.8'){throw 'Final update verification failed.'}
        Assert-CFReady $Context;Set-CFJournal $backup 'Committed'
        return ('Runtime 1.0.8 installed and verified. Immediate-previous backup: '+$backup+'. Original rollback remains '+$latest.Directory)
    } catch {
        $reason=$_.Exception.Message
        if($backup -ne '') {
            try {
                if($mapReady){Restore-PollingTransaction $Context $Files $backup}
                else{Assert-CFReady $Context;Set-CFJournal $backup 'RolledBack'}
                $reason+='; file changes rolled back.'
            } catch {$reason+='; rollback needs attention: '+$_.Exception.Message}
            $reason+=' Backup: '+$backup
        }
        throw $reason
    } finally {
        try{foreach($stage in $stages){if([IO.File]::Exists($stage)){$null=Assert-CFPlainPath $stage $false;[IO.File]::Delete($stage)}}}
        finally{if($null -ne $lock){$lock.Close()}}
    }
}

function Invoke-PollingRollback($Context,$Files) {
    Assert-CFReady $Context;$lock=$null
    try {
        $lockPath=Join-Path $Context.Target '.nilit-deploy.lock'
        if(Test-Path -LiteralPath $lockPath){$null=Assert-CFPlainPath $lockPath $false}
        $lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $active=@(Get-PollingJournals $Context|Where-Object{$_.Status -ne 'RolledBack'})
        if($active.Count -gt 1){throw 'Multiple active polling updates; preserve all backups for review.'}
        if($active.Count -eq 0) {
            if((Get-PollingState $Context $Files) -eq '1.0.7'){return 'Already at verified 1.0.7. No file changed.'}
            throw 'No update backup available; no file changed.'
        }
        $backup=$active[0].Directory
        $map=Join-Path $backup 'files.txt'
        if(-not [IO.File]::Exists($map)) {
            if($active[0].Status -ne 'Prepared' -or (Get-PollingState $Context $Files $true) -ne '1.0.7'){throw 'Missing rollback map; preserve all files for review.'}
            Set-CFJournal $backup 'RolledBack'
        } else {Restore-PollingTransaction $Context $Files $backup}
        return ('Runtime 1.0.7, both executable pairs, both hash lists and deployment record restored. Current MAIN/settings/history/outbox preserved. Backup: '+$backup)
    } finally {if($null -ne $lock){$lock.Close()}}
}

