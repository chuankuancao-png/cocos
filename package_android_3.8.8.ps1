$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '.')).Path
if ((Resolve-Path (Get-Location)).Path -ne $Root) { throw "请在项目根目录执行：$Root" }

function Replace-Text([string]$Path, [string]$Old, [string]$New) {
    $text = Get-Content -Raw -LiteralPath $Path
    $text = $text.Replace($Old, $New)
    Set-Content -LiteralPath $Path -Value $text -NoNewline
}

function Comment-ExternalNativeBuild([string]$Path) {
    $lines = [System.IO.File]::ReadAllLines($Path)
    $out = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $lines.Count;) {
        if ($lines[$i] -match '^\s*externalNativeBuild\s*\{') {
            $start = $i; $depth = 0
            do { $depth += ([regex]::Matches($lines[$i], '\{')).Count - ([regex]::Matches($lines[$i], '\}')).Count; $i++ } while ($depth -ne 0 -and $i -lt $lines.Count)
            if ($depth -ne 0) { throw "externalNativeBuild block is not closed: $Path" }
            for ($j = $start; $j -lt $i; $j++) { if ($lines[$j].Trim()) { $out.Add(($lines[$j] -replace '^([ \t]*)', '$1// ')) } else { $out.Add($lines[$j]) } }
        } else { $out.Add($lines[$i]); $i++ }
    }
    [System.IO.File]::WriteAllLines($Path, $out)
}

Replace-Text "$Root/build/android/proj/build.gradle" 'com.android.tools.build:gradle:8.10.1' 'com.android.tools.build:gradle:8.13.2'
Replace-Text "$Root/native/engine/android/build.gradle" 'com.android.tools.build:gradle:8.10.1' 'com.android.tools.build:gradle:8.13.2'
Replace-Text "$Root/build/android/proj/gradle/wrapper/gradle-wrapper.properties" 'gradle-8.11.1-bin.zip' 'gradle-8.13-bin.zip'

foreach ($file in @("$Root/native/engine/android/app/build.gradle", "$Root/native/engine/android/instantapp/build.gradle")) {
    $text = Get-Content -Raw -LiteralPath $file
    $text = [regex]::Replace($text, '(?m)^([ \t]*)ndkVersion\s+PROP_NDK_VERSION', '$1ndkVersion "28.2.13676358"')
    $text = [regex]::Replace($text, "(?m)^([ \t]*)(implementation project\(':libcocos'\))", '$1// $2')
    Set-Content -LiteralPath $file -Value $text -NoNewline
    Comment-ExternalNativeBuild $file
}
$lib = "$Root/build/android/proj/libservice/build.gradle"
$text = Get-Content -Raw -LiteralPath $lib
$text = [regex]::Replace($text, "(?m)^([ \t]*)(implementation project\(':libcocos'\))", '$1// $2')
if ($text -notmatch 'ndkVersion "28\.2\.13676358"') { $marker = 'android {' + [Environment]::NewLine; $insert = 'android {' + [Environment]::NewLine + '    ndkVersion "28.2.13676358"' + [Environment]::NewLine; $text = $text.Replace($marker, $insert) }
Set-Content -LiteralPath $lib -Value $text -NoNewline

$settings = "$Root/build/android/proj/settings.gradle"
$text = Get-Content -Raw -LiteralPath $settings
$text = [regex]::Replace($text, '(?m)^include .*$', "include ':libservice', ':app'")
$text = [regex]::Replace($text, "(?m)^([ \t]*)(project\(':libcocos'\)\.projectDir)", '$1// $2')
Set-Content -LiteralPath $settings -Value $text -NoNewline

$properties = "$Root/build/android/proj/gradle.properties"
$text = Get-Content -Raw -LiteralPath $properties
$rootWin = $Root.Replace('/', '\').Replace('\', '\\')
$text = [regex]::Replace($text, '(?m)^RES_PATH=.*$', "RES_PATH=$rootWin\\build\\android")
$text = [regex]::Replace($text, '(?m)^NATIVE_DIR=.*$', "NATIVE_DIR=$rootWin\\native\\engine\\android")
Set-Content -LiteralPath $properties -Value $text -NoNewline

$manifest = "$Root/native/engine/android/app/AndroidManifest.xml"
$text = Get-Content -Raw -LiteralPath $manifest
if ($text -notmatch 'xmlns:tools=') { $text = $text.Replace('xmlns:android="http://schemas.android.com/apk/res/android"', 'xmlns:android="http://schemas.android.com/apk/res/android" xmlns:tools="http://schemas.android.com/tools"') }
if ($text -notmatch 'com.android.vending.BILLING') { $marker = '  <uses-permission android:name="android.permission.INTERNET"/>'; $permission = '  <uses-permission android:name="com.android.vending.BILLING" tools:node="remove"/>'; $text = $text.Replace($marker, $permission + [Environment]::NewLine + $marker) }
Set-Content -LiteralPath $manifest -Value $text -NoNewline

if ($args -notcontains '--skip-download') {
    $release = Invoke-RestMethod 'https://api.github.com/repos/chuankuancao-png/cocos/releases/tags/3.8.8' -Headers @{ 'User-Agent' = 'cocos-android-packager' }
    $asset = $release.assets | Where-Object { $_.name -match '\.(zip|tar|gz|tgz)$' } | Sort-Object @{Expression={ if ($_.name -match 'android|lib') { 0 } else { 1 } }}, name | Select-Object -First 1
    if (-not $asset) { throw '3.8.8 Release 没有找到 ZIP/TAR 资源' }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('cocos-3.8.8-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $archive = Join-Path $tmp $asset.name; Invoke-WebRequest $asset.browser_download_url -OutFile $archive
    $libs = "$Root/native/engine/android/app/libs"; New-Item -ItemType Directory -Force -Path $libs | Out-Null
    Get-ChildItem $libs -Force | Remove-Item -Recurse -Force
    $extract = Join-Path $tmp 'extract'; New-Item -ItemType Directory -Path $extract | Out-Null
    if ($asset.name -match '\.zip$') { Expand-Archive $archive -DestinationPath $extract } else { tar -xf $archive -C $extract }
    $source = Get-ChildItem $extract -Directory -Recurse | Where-Object Name -eq 'libs' | Select-Object -First 1
    if (-not $source) { $source = Get-Item $extract }
    Copy-Item "$($source.FullName)\*" $libs -Recurse -Force
    Remove-Item $tmp -Recurse -Force
}

if ($args -notcontains '--no-build') { Push-Location "$Root/build/android/proj"; try { & .\gradlew.bat assembleRelease } finally { Pop-Location } }
