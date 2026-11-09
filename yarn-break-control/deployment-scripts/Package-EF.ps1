# Preparation-machine packaging only; does not install or run the product.
#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$DeploymentValidation,
      [Parameter(Mandatory=$true)][string]$ActivationValidation)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$counter = Join-Path $root 'counter'
$cv = Get-Content -LiteralPath (Join-Path $counter 'validation.json') -Raw | ConvertFrom-Json
if ($cv.Status -ne 'PassedLocalFixtures' -or $cv.TotalActualChecks -ne 825 -or $cv.ProductionTestHooksEnabled) { throw 'Unexpected counter validation.' }
$build = Get-Content -LiteralPath $cv.BuildManifest -Raw | ConvertFrom-Json
if ($build.Status -ne 'Succeeded') { throw 'Production build required.' }
$activation = Get-Content -LiteralPath $ActivationValidation -Raw | ConvertFrom-Json
if ($activation.Status -ne 'Passed' -or $activation.ActivationSourceSHA256 -ne (Get-FileHash -LiteralPath (Join-Path $root 'Activate-EF.ps1') -Algorithm SHA256).Hash) { throw 'Activation validation is missing or stale.' }
$deployment = Get-Content -LiteralPath $DeploymentValidation -Raw | ConvertFrom-Json
if ($deployment.Status -ne 'PassedLocalFixtures' -or $deployment.TotalActualChecks -ne 441) { throw 'Unexpected deployment validation.' }
foreach ($inputFile in $deployment.Files) {
    if ((Get-FileHash -LiteralPath (Join-Path $root $inputFile.Path) -Algorithm SHA256).Hash -ne $inputFile.SHA256) { throw ('Deployment validation is stale: '+$inputFile.Path) }
}
$name = 'NILIT-EF-Control2-v1.0.1-test'
$package = Join-Path $root ('packages\' + $name)
$zip = Join-Path (Split-Path -Parent $root) ($name + '.zip')
if ((Test-Path -LiteralPath $package) -or (Test-Path -LiteralPath $zip)) { throw 'Published package paths already exist; do not overwrite a release.' }
foreach ($dir in @('','counter','counter\src','counter\tests','counter\tests\acceptance','watchdog','deploy','validation','validation-tests','deployment-validation')) {
    $destination = $package
    if ($dir) { $destination = Join-Path $package $dir }
    $null = New-Item -ItemType Directory -Path $destination -Force
}
foreach ($exe in $build.Executables) {
    if ((Get-FileHash -LiteralPath $exe.Path -Algorithm SHA256).Hash -ne $exe.Sha256) { throw ('Built binary changed: '+$exe.Name) }
    Copy-Item -LiteralPath $exe.Path -Destination (Join-Path $package ('counter\'+$exe.Name))
}
$stage = Join-Path (Split-Path -Parent $cv.BuildManifest) 'src'
foreach ($source in $build.Source) {
    $path = Join-Path $stage $source.Name
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $source.StagedSha256) { throw ('Staged source changed: '+$source.Name) }
    Copy-Item -LiteralPath $path -Destination (Join-Path $package ('counter\src\'+$source.Name))
}
Copy-Item -LiteralPath (Join-Path $counter 'Build.ps1') -Destination (Join-Path $package 'counter')
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $counter 'tests') -File) {
    if ($file.Extension -in '.bas','.cls','.vbp','.ps1','.txt') { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $package 'counter\tests') }
}
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $counter 'tests\acceptance') -File) {
    if ($file.Extension -in '.bas','.cls','.vbp') { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $package 'counter\tests\acceptance') }
}
foreach ($test in $cv.Tests) {
    $path = Join-Path $counter $test.Evidence
    Copy-Item -LiteralPath $path -Destination (Join-Path $package ('validation\counter-'+$test.Name+[IO.Path]::GetExtension($path)))
}
Copy-Item -LiteralPath (Join-Path $counter 'validation.json') -Destination (Join-Path $package 'validation\counter-validation.json')
Copy-Item -LiteralPath $cv.BuildManifest -Destination (Join-Path $package 'validation\counter-build.json')
Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $cv.BuildManifest) 'compiler.log') -Destination (Join-Path $package 'validation\counter-compiler.log')
foreach ($component in @('watchdog','deploy')) {
    $sourceRoot = Join-Path $root $component
    foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File) {
        $relative = $file.FullName.Substring($sourceRoot.Length+1)
        if ($relative -match '(^|\\)(runtime|tests|validation-runs|build-runs)(\\|$)' -or $file.Name -in 'PAUSED','STOP','KEEPER_STOP','operator.sid','SHA256SUMS.txt') { throw ('Unexpected runtime state or generated manifest in component: '+$relative) }
        $destination = Join-Path $package ($component+'\'+$relative)
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force
        Copy-Item -LiteralPath $file.FullName -Destination $destination
    }
}
foreach ($file in Get-ChildItem -LiteralPath $root -File -Filter '*.cmd') { Copy-Item -LiteralPath $file.FullName -Destination $package }
Copy-Item -LiteralPath (Join-Path $root 'Activate-EF.ps1') -Destination $package
$readme = [IO.File]::ReadAllText((Join-Path $root 'START-HERE-he.txt'), [Text.Encoding]::UTF8)
[IO.File]::WriteAllText((Join-Path $package 'START-HERE-he.txt'), ($readme -replace '\r?\n', "`r`n"), (New-Object Text.UTF8Encoding($true)))
Copy-Item -LiteralPath $DeploymentValidation -Destination (Join-Path $package 'validation\deployment.json')
Copy-Item -LiteralPath $ActivationValidation -Destination (Join-Path $package 'validation\activation.json')
foreach ($test in $deployment.Tests) {
    Copy-Item -LiteralPath (Join-Path $root $test.Evidence) -Destination (Join-Path $package ('validation\deploy-'+$test.Name+'.txt'))
}
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'deployment-validation') -File -Filter '*.ps1') {
    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $package 'deployment-validation')
}
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'validation-tests') -File) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $package 'validation-tests') }
$counterHashes = @('nilit.exe','nilit-export.exe') | ForEach-Object { (Get-FileHash -LiteralPath (Join-Path $package ('counter\'+$_)) -Algorithm SHA256).Hash+'  '+$_ }
[IO.File]::WriteAllLines((Join-Path $package 'counter\SHA256SUMS.txt'), $counterHashes, [Text.Encoding]::ASCII)
$metadata = [ordered]@{
    Product='NILIT EF Control 2'; Version='1.0.1-ef-test'; PreparedUtc=[DateTime]::UtcNow.ToString('o');
    CounterChecks=$cv.TotalActualChecks; DeploymentChecks=$deployment.TotalActualChecks; ActivationCases=$activation.Cases.Count;
    DeploymentValidation='validation\deployment.json';
    Target='C:\Vuniq50\VB E_L\nilit.exe'; Project='C:\Vuniq50\Barmag';
    VuniqExpected='C:\Vuniq50\bin\Vuniq.exe'; VuniqVersionExpected='5.9.2.9';
    Lines=@('E','F'); FirstWatchdogInstallation=$true; CurrentMachineInstalled=$false; FieldInstalled=$false;
    LiveCOMSerialOrSAPTested=$false; FirstInstallationStartsAtZero=$true;
    StateFolder='%LOCALAPPDATA%\NILITLegacyCounter\EF-v1'; ExistingSAPInterfacePreserved=$true
}
[IO.File]::WriteAllText((Join-Path $package 'PACKAGE.json'), ($metadata | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
$hashes = @(Get-ChildItem -LiteralPath $package -Recurse -File | Sort-Object FullName | ForEach-Object {
    (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash+'  '+$_.FullName.Substring($package.Length+1)
})
[IO.File]::WriteAllLines((Join-Path $package 'SHA256SUMS.txt'), $hashes, [Text.Encoding]::ASCII)
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($package,$zip,[IO.Compression.CompressionLevel]::Optimal,$false)
$archive = [IO.Compression.ZipFile]::OpenRead($zip)
try {
    $entries = @($archive.Entries | Where-Object { -not $_.FullName.EndsWith('/') })
    if ($entries.Count -ne $hashes.Count+1) { throw 'Archive inventory differs from package.' }
    foreach ($entry in $entries) {
        $stream = $entry.Open(); $sha = [Security.Cryptography.SHA256]::Create()
        try { $actual = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','') }
        finally { $stream.Dispose(); $sha.Dispose() }
        if ($actual -ne (Get-FileHash -LiteralPath (Join-Path $package ($entry.FullName.Replace('/','\'))) -Algorithm SHA256).Hash) { throw ('Archive content mismatch: '+$entry.FullName) }
    }
} finally { $archive.Dispose() }
$zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
[IO.File]::WriteAllText(($zip+'.sha256.txt'),($zipHash+'  '+[IO.Path]::GetFileName($zip)+"`r`n"),[Text.Encoding]::ASCII)
$result = [ordered]@{ Package=$package; Zip=$zip; SHA256=$zipHash; Files=$hashes.Count+1; Bytes=(Get-Item -LiteralPath $zip).Length; EveryArchiveEntryVerified=$true }
[IO.File]::WriteAllText((Join-Path $root 'package-result.json'),($result | ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
$result | ConvertTo-Json
