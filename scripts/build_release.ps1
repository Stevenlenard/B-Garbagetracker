# Release build for the Mapbox containment (Windows PowerShell 5.1).
#
#   powershell -ExecutionPolicy Bypass -File scripts\build_release.ps1 -Platform web -CheckOnly
#   powershell -ExecutionPolicy Bypass -File scripts\build_release.ps1 -Platform web
#   powershell -ExecutionPolicy Bypass -File scripts\build_release.ps1 -Platform android
#
# Reads config\mapbox.<platform>.local.json (git-ignored), refuses unsafe values, builds, then
# checks the output: no Matrix endpoint, no old-account token, the new token present. The token
# itself is never printed. Output goes to deploy_prep\out\ (git-ignored). Nothing is uploaded.
param(
    [Parameter(Mandatory = $true)][ValidateSet('web', 'android')][string]$Platform,
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$BlockedAccounts = @('prince6703')
# Authorized destination account (account names are not secrets). The name inside a token only
# shows which account issued it, not its scopes, URL restrictions or validity.
$ExpectedAccount = 'joven-2323'
# Signer of the APK currently hosted at /app-release.apk (installed devices accept updates only
# from the same key): this machine's debug keystore.
$ExpectedSignerSha256 = '7b8a1cf51a63047748711231ffd7f1352ea59d9fab9cc67936132d58f077c0ad'

function Fail([string]$msg) { Write-Host "BLOCKED: $msg" -ForegroundColor Red; exit 1 }

function Get-TokenAccount([string]$token) {
    $parts = $token.Split('.')
    if ($parts.Length -lt 2) { return $null }
    $b = $parts[1].Replace('-', '+').Replace('_', '/')
    while ($b.Length % 4) { $b += '=' }
    try {
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b)) | ConvertFrom-Json
        return [string]$json.u
    } catch { return $null }
}

# ---- 1. configuration ------------------------------------------------------------------
$cfgPath = Join-Path $root "config\mapbox.$Platform.local.json"
if (-not (Test-Path $cfgPath)) {
    Fail ("missing config\mapbox.$Platform.local.json. Copy config\mapbox.$Platform.example.json and fill in:`n" +
          "  MAPBOX_TOKEN_PLATFORM  = '$Platform' (or 'shared' for a one-token trial account)`n" +
          "  MAPBOX_ACCESS_TOKEN    = public pk. token of the DESTINATION account`n" +
          "  MAPBOX_MATRIX_ENABLED  = 'false'`n  MAPBOX_DIRECTIONS_ENABLED = 'false'")
}
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
$problems = @()
$label = [string]$cfg.MAPBOX_TOKEN_PLATFORM
if (@($Platform, 'shared') -notcontains $label) { $problems += "MAPBOX_TOKEN_PLATFORM must be '$Platform' or 'shared' (is '$label')" }
$token = ([string]$cfg.MAPBOX_ACCESS_TOKEN).Trim()
$account = $null
if (-not $token.StartsWith('pk.') -or $token.Length -le 20 -or $token -match 'REPLACE') {
    $problems += 'MAPBOX_ACCESS_TOKEN must be a real public pk. token (placeholder or sk. token found)'
} else {
    $account = Get-TokenAccount $token
    if ($BlockedAccounts -contains $account) { $problems += "MAPBOX_ACCESS_TOKEN belongs to the OLD account '$account'" }
    elseif ($account -ne $ExpectedAccount) { $problems += "MAPBOX_ACCESS_TOKEN was issued by account '$account', expected '$ExpectedAccount'" }
}
if ([string]$cfg.MAPBOX_MATRIX_ENABLED -ne 'false') { $problems += "MAPBOX_MATRIX_ENABLED must be 'false'" }
if ([string]$cfg.MAPBOX_DIRECTIONS_ENABLED -ne 'false') { $problems += "MAPBOX_DIRECTIONS_ENABLED must be 'false'" }
foreach ($p in $cfg.PSObject.Properties) {
    if ([string]$p.Value -match 'sk\.ey') { $problems += "secret token found in $($p.Name)" }
}
$otherPlatform = if ($Platform -eq 'web') { 'android' } else { 'web' }
$otherPath = Join-Path $root "config\mapbox.$otherPlatform.local.json"
if ($label -ne 'shared' -and (Test-Path $otherPath)) {
    $otherToken = ([string](Get-Content $otherPath -Raw | ConvertFrom-Json).MAPBOX_ACCESS_TOKEN).Trim()
    if ($otherToken -eq $token) { $problems += "web and android files contain the SAME token; use Capstone Web and Capstone Android separately (or label both 'shared')" }
}
if ($problems.Count) { Fail ("config\mapbox.$Platform.local.json:`n  - " + ($problems -join "`n  - ")) }
Write-Host "Config OK: platform=$label, destination account=$account, Matrix=false, Directions=false"
if ($CheckOnly) { exit 0 }

$outDir = Join-Path $root 'deploy_prep\out'
New-Item -ItemType Directory -Force $outDir | Out-Null
$version = ((Select-String -Path pubspec.yaml -Pattern '^version:\s*(.+)$').Matches[0].Groups[1].Value).Trim()

function Test-Artifact([string]$text, [string]$what) {
    $bad = @()
    if ($text.Contains('directions-matrix')) { $bad += 'Matrix endpoint present' }
    if ($text.Contains('CARD_BUILD')) { $bad += 'old build-time optimization trigger present' }
    if ($text.Contains('eyJ1IjoicHJpbmNlNjcwMy')) { $bad += 'old-account token present' }
    if (-not $text.Contains($token)) { $bad += 'configured token not found (build did not use the config)' }
    if ($bad.Count) { Fail ("$what check failed: " + ($bad -join '; ')) }
    Write-Host "$what check OK: no Matrix endpoint, no old token, new token embedded"
}

# ---- 2. build + verify -----------------------------------------------------------------
if ($Platform -eq 'web') {
    & flutter build web --release "--dart-define-from-file=$cfgPath"
    if ($LASTEXITCODE -ne 0) { Fail 'flutter build web failed' }
    Test-Artifact ([IO.File]::ReadAllText((Join-Path $root 'build\web\main.dart.js'))) 'main.dart.js'

    # Package = Flutter app files only. .htaccess and .well-known stay as they are on the server
    # (review build\web\.htaccess separately before replacing the live one).
    $pkg = Join-Path $outDir "web_$version"
    if (Test-Path $pkg) { Remove-Item -Recurse -Force $pkg }
    Copy-Item -Recurse (Join-Path $root 'build\web') $pkg
    Remove-Item -Force (Join-Path $pkg '.htaccess') -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force (Join-Path $pkg '.well-known') -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $root 'build\web\.htaccess') (Join-Path $outDir 'htaccess.proposed.txt') -Force
    $zip = "$pkg.zip"
    if (Test-Path $zip) { Remove-Item -Force $zip }
    # Not Compress-Archive: Windows PowerShell 5.1 writes "assets\x" entry names, which Linux
    # hosts (Hostinger) do not extract as folders. Entries use "/" separators.
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
    try {
        Get-ChildItem -Path $pkg -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($pkg.Length + 1).Replace('\', '/')
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $_.FullName, $rel)
        }
    } finally { $archive.Dispose() }
    if ((& { Add-Type -AssemblyName System.IO.Compression.FileSystem; [IO.Compression.ZipFile]::OpenRead($zip) } | ForEach-Object { $n = @($_.Entries | Where-Object { $_.FullName.Contains('\') }).Count; $_.Dispose(); $n }) -gt 0) {
        Fail 'web package contains backslash entry names'
    }
    Write-Host "Web package: $zip"
} else {
    & flutter build apk --release "--dart-define-from-file=$cfgPath"
    if ($LASTEXITCODE -ne 0) { Fail 'flutter build apk failed' }
    $apk = Join-Path $root 'build\app\outputs\flutter-apk\app-release.apk'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($apk)
    try {
        $entry = $z.Entries | Where-Object { $_.FullName -eq 'lib/arm64-v8a/libapp.so' }
        $ms = New-Object IO.MemoryStream
        $s = $entry.Open(); $s.CopyTo($ms); $s.Close()
        Test-Artifact ([Text.Encoding]::GetEncoding(28591).GetString($ms.ToArray())) 'libapp.so (arm64)'
    } finally { $z.Dispose() }

    $bt = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Android\Sdk\build-tools') | Sort-Object Name | Select-Object -Last 1
    $certs = & (Join-Path $bt.FullName 'apksigner.bat') verify --print-certs $apk
    $sha = (($certs | Select-String 'SHA-256 digest: (\w+)').Matches[0].Groups[1].Value)
    $badging = & (Join-Path $bt.FullName 'aapt.exe') dump badging $apk | Select-Object -First 1
    Write-Host $badging
    if ($sha -ne $ExpectedSignerSha256) {
        Write-Host "WARNING: signer $sha differs from the hosted APK's signer; installed apps will NOT update in place." -ForegroundColor Yellow
    } else {
        Write-Host 'Signer matches the hosted APK: installed copies can update in place.'
    }
    Copy-Item $apk (Join-Path $outDir "app-release-$version.apk") -Force
    Write-Host "APK: $(Join-Path $outDir "app-release-$version.apk")"
}
