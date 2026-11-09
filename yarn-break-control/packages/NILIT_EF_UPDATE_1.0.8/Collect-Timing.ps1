#requires -Version 2.0
[CmdletBinding()]
param([string]$SourceDirectory = '')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$collectorMaximumBytes = 1048576
$collectorNames = @('poll-performance.csv', 'poll-performance.previous.csv')
$collectorRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$collectorReport = ''

function Assert-CollectorPlainPath {
    param([string]$Path, [bool]$Directory)
    if ([string]::IsNullOrEmpty($Path) -or $Path.Length -lt 4 -or $Path.Substring(1,2) -ne ':\' -or $Path.IndexOf([char]0) -ge 0) {
        throw 'An absolute local Windows path is required.'
    }
    $collectorFull = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $collectorItem = Get-Item -LiteralPath $collectorFull -Force -ErrorAction Stop
    if ([bool]$collectorItem.PSIsContainer -ne $Directory) { throw ('Unexpected file/directory: ' + $collectorFull) }
    $collectorCheck = $collectorItem
    while ($null -ne $collectorCheck) {
        if (($collectorCheck.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw ('Linked paths are refused: ' + $collectorCheck.FullName)
        }
        if ($collectorCheck -is [IO.DirectoryInfo]) { $collectorCheck = $collectorCheck.Parent }
        else { $collectorCheck = $collectorCheck.Directory }
    }
    return $collectorFull
}

function Write-CollectorReport {
    param([string]$Text)
    Write-Host $Text
    if ($collectorReport.Length -gt 0) {
        [IO.File]::AppendAllText($collectorReport, $Text + [Environment]::NewLine, [Text.Encoding]::UTF8)
    }
}

function Copy-CollectorBoundedFile {
    param([string]$Source, [string]$Destination)
    $null = Assert-CollectorPlainPath $Source $false
    $collectorInput = $null
    $collectorOutput = $null
    $collectorAlgorithm = $null
    try {
        # Read sharing permits the existing counter to keep appending or rotating.
        $collectorShare = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $collectorInput = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, $collectorShare)
        $null = Assert-CollectorPlainPath $Source $false
        $collectorLength = $collectorInput.Length
        if ($collectorLength -gt $collectorMaximumBytes) { throw ('Timing file exceeds 1 MiB; collection refused: ' + $Source) }
        $collectorOutput = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $collectorBuffer = New-Object byte[] 65536
        $collectorRemaining = $collectorLength
        while ($collectorRemaining -gt 0) {
            $collectorRequest = [int][Math]::Min([Int64]$collectorBuffer.Length, $collectorRemaining)
            $collectorRead = $collectorInput.Read($collectorBuffer, 0, $collectorRequest)
            if ($collectorRead -le 0) { throw ('Timing file shortened during collection: ' + $Source) }
            $collectorOutput.Write($collectorBuffer, 0, $collectorRead)
            $collectorRemaining = $collectorRemaining - $collectorRead
        }
        $collectorOutput.Close(); $collectorOutput = $null
        $collectorInput.Close(); $collectorInput = $null
        $null = Assert-CollectorPlainPath $Destination $false
        $collectorInput = [IO.File]::Open($Destination, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        if ($collectorInput.Length -ne $collectorLength -or $collectorInput.Length -gt $collectorMaximumBytes) { throw 'Copied timing file size changed.' }
        $collectorAlgorithm = [Security.Cryptography.SHA256]::Create()
        $collectorHash = [BitConverter]::ToString($collectorAlgorithm.ComputeHash($collectorInput)).Replace('-', '')
        return New-Object PSObject -Property @{ Bytes = $collectorLength; SHA256 = $collectorHash }
    }
    finally {
        if ($null -ne $collectorOutput) { $collectorOutput.Close() }
        if ($null -ne $collectorInput) { $collectorInput.Close() }
        if ($null -ne $collectorAlgorithm) { $collectorAlgorithm.Clear() }
    }
}

try {
    $collectorRoot = Assert-CollectorPlainPath $collectorRoot $true
    $collectorReports = Join-Path $collectorRoot 'reports'
    if (-not (Test-Path -LiteralPath $collectorReports)) { $null = New-Item -ItemType Directory -Path $collectorReports }
    $collectorReports = Assert-CollectorPlainPath $collectorReports $true
    $collectorId = 'timing-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N')
    $collectorDestination = Join-Path $collectorReports $collectorId
    $null = New-Item -ItemType Directory -Path $collectorDestination -ErrorAction Stop
    $collectorDestination = Assert-CollectorPlainPath $collectorDestination $true
    $collectorReport = Join-Path $collectorDestination 'timing-report.txt'
    $collectorNewReport = [IO.File]::Open($collectorReport, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $collectorNewReport.Close()
    Write-CollectorReport 'NILIT EF 1.0.5 - local phase timing collection'
    Write-CollectorReport ('Collected UTC: ' + [DateTime]::UtcNow.ToString('o'))
    if ([string]::IsNullOrEmpty($SourceDirectory)) {
        if ([string]::IsNullOrEmpty($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is unavailable for this Windows account.' }
        $SourceDirectory = Join-Path $env:LOCALAPPDATA 'NILITLegacyCounter\EF-v1'
    }
    $SourceDirectory = Assert-CollectorPlainPath $SourceDirectory $true
    Write-CollectorReport ('Source: ' + $SourceDirectory)
    Write-CollectorReport 'Scope: the two known timing CSV files only; maximum 1 MiB per file.'
    $collectorCopied = 0
    foreach ($collectorName in $collectorNames) {
        $collectorSource = Join-Path $SourceDirectory $collectorName
        if (-not (Test-Path -LiteralPath $collectorSource)) {
            Write-CollectorReport ('Missing: ' + $collectorName)
            continue
        }
        $collectorCopy = Copy-CollectorBoundedFile $collectorSource (Join-Path $collectorDestination $collectorName)
        $collectorCopied = $collectorCopied + 1
        Write-CollectorReport ('Copied: ' + $collectorName + '; bytes=' + $collectorCopy.Bytes + '; SHA256=' + $collectorCopy.SHA256)
    }
    Write-CollectorReport ('CSV files collected: ' + $collectorCopied)
    Write-CollectorReport 'The source files were opened for reading only. No application, task, counter state, outbox, PLC or SAP operation was requested.'
    Write-CollectorReport 'Let NILIT run for 10-15 minutes before collecting timing. Send the collected CSV files and timing-report.txt from this report folder.'
    Write-CollectorReport ('Report folder: ' + $collectorDestination)
    if ($collectorCopied -eq 0) {
        Write-CollectorReport 'NO TIMING FILES: check that version 1.0.5 has run under the original HMI operator account, then collect again.'
        exit 2
    }
    Write-CollectorReport 'COLLECTION passed.'
    exit 0
}
catch {
    $collectorFailure = $_.Exception.Message
    if ($collectorFailure.Length -gt 1024) { $collectorFailure = $collectorFailure.Substring(0,1024) }
    Write-CollectorReport ('COLLECTION STOPPED: ' + $collectorFailure)
    if ($collectorReport.Length -gt 0) { Write-CollectorReport ('Report: ' + $collectorReport) }
    exit 1
}
