$ErrorActionPreference = 'Stop'
# Cocos Creator 3.8.8 Android Windows PowerShell
#
# 
# 1.  Android Gradle Plugin  Gradle Wrapper
# 2. 
# 3.  Release  libcocos-release.aar libcocos  JAR
# 4.  libcocos-release.aar  game-sdkokhttpokio  JAR
# 5.  Android  API 24 libcocos-release.aar  API 24
# 6.  R8  okhttp 
# 7.  Android 37Build Tools 37.0.0  NDK 28.2.13676358
# 8.  3.8.8 Release  app/libs assembleRelease
#
#  .\package_android_3.8.8.ps1
$Root = (Resolve-Path (Join-Path $PSScriptRoot '.')).Path
if ((Resolve-Path (Get-Location)).Path -ne $Root) { throw "$Root" }

function Replace-Text([string]$Path, [string]$Old, [string]$New) {
    # 
    $text = Get-Content -Raw -LiteralPath $Path
    $text = $text.Replace($Old, $New)
    Set-Content -LiteralPath $Path -Value $text -NoNewline
}

function Expand-Zip([string]$Archive, [string]$Destination) {
    # Windows PowerShell 5.1  Expand-Archive  .NET  ZIP 
    # Windows 10/11  tar.exe  Android Command-line Tools 
    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if ($tar) {
        & $tar.Source -xf $Archive -C $Destination
        if ($LASTEXITCODE -ne 0) { throw "tar.exe : $Archive" }
        return
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Archive, $Destination)
}

function Use-Java21 {
    #  JDK 21 Android Studio JBR 
    $javaHome = Join-Path $env:LOCALAPPDATA "Android\jdk-21"
    $javaExe = Join-Path $javaHome "bin\java.exe"
    if (-not (Test-Path $javaExe)) {
        $javaTemp = Join-Path $env:TEMP ('j21' + ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        $javaZip = Join-Path $javaTemp 'jdk21.zip'
        $javaExtract = Join-Path $javaTemp 'extract'
        New-Item -ItemType Directory -Path $javaExtract -Force | Out-Null
        $javaApi = 'https://api.adoptium.net/v3/assets/latest/21/hotspot?architecture=x64&image_type=jdk&os=windows&vendor=eclipse'
        $javaPackage = (Invoke-RestMethod -Uri $javaApi -Headers @{ 'User-Agent' = 'cocos-android-packager' })[0].binary.package.link
        Write-Host 'JDK 21 not found; downloading Eclipse Temurin JDK 21...'
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) { & curl.exe -fL --retry 3 --output $javaZip $javaPackage } else { Invoke-WebRequest $javaPackage -OutFile $javaZip }
        Expand-Zip $javaZip $javaExtract
        $javaRoot = Get-ChildItem $javaExtract -Directory | Select-Object -First 1
        New-Item -ItemType Directory -Path $javaHome -Force | Out-Null
        Copy-Item (Join-Path $javaRoot.FullName '*') $javaHome -Recurse -Force
        Remove-Item $javaTemp -Recurse -Force
    }
    if (-not (Test-Path $javaExe)) { throw 'JDK 21  java.exe' }
    $env:JAVA_HOME = $javaHome
    $javaBin = Join-Path $javaHome "bin"
    $env:Path = "$javaBin;$env:Path"
    Write-Host "Using JDK 21: $javaHome"
}

function Comment-ExternalNativeBuild([string]$Path) {
    #  app  instantapp  externalNativeBuild  AAR
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
Replace-Text "$Root/build/android/proj/gradle.properties" 'PROP_MIN_SDK_VERSION=21' 'PROP_MIN_SDK_VERSION=24'
Replace-Text "$Root/build/android/proj/gradle.properties" 'PROP_COMPILE_SDK_VERSION=36' 'PROP_COMPILE_SDK_VERSION=37'
Replace-Text "$Root/build/android/proj/gradle.properties" 'PROP_TARGET_SDK_VERSION=36' 'PROP_TARGET_SDK_VERSION=37'
# Release AAR  Android API 24 API 21

# R8  Cocos  okhttp 
$proguard = "$Root/native/engine/android/app/proguard-rules.pro"
$proguardText = Get-Content -Raw -LiteralPath $proguard
if ($proguardText -notmatch 'javax\.annotation\.\*\*') { Add-Content -LiteralPath $proguard -Value "`r`n# Optional dependencies referenced by the Cocos-shaded okhttp implementation.`r`n-dontwarn javax.annotation.**`r`n-dontwarn org.codehaus.mojo.animal_sniffer.**`r`n-dontwarn org.conscrypt.**`r`n" }

foreach ($file in @("$Root/native/engine/android/app/build.gradle", "$Root/native/engine/android/instantapp/build.gradle")) {
    #  libcocos  native  Cocos  Java JAR
    $text = Get-Content -Raw -LiteralPath $file
    $text = [regex]::Replace($text, '(?m)^([ \t]*)ndkVersion\s+PROP_NDK_VERSION', '$1ndkVersion "28.2.13676358"')
    $text = [regex]::Replace($text, "(?m)^([ \t]*)(implementation project\(':libcocos'\))", '$1// $2')
    $text = [regex]::Replace($text, '(?m)^([ \t]*)(implementation fileTree\(dir: "\$\{COCOS_ENGINE_PATH\}/cocos/platform/android/java/libs", include: \[''\*\.jar''\]\))', '$1// $2')
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
    if (-not $asset) { throw '3.8.8 Release  ZIP/TAR ' }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('cocos-3.8.8-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $archive = Join-Path $tmp $asset.name
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        & curl.exe -fL --retry 3 --output $archive $asset.browser_download_url
    } else {
        Invoke-WebRequest $asset.browser_download_url -OutFile $archive
    }
    #  app/libs  3.8.8 Release 
    $libs = "$Root/native/engine/android/app/libs"; New-Item -ItemType Directory -Force -Path $libs | Out-Null
    Get-ChildItem $libs -Force | Remove-Item -Recurse -Force
    $extract = Join-Path $tmp 'extract'; New-Item -ItemType Directory -Path $extract | Out-Null
    if ($asset.name -match '\.zip$') { Expand-Zip $archive $extract } else { tar -xf $archive -C $extract }
    $source = Get-ChildItem $extract -Directory -Recurse | Where-Object Name -eq 'libs' | Select-Object -First 1
    if (-not $source) { $source = Get-Item $extract }
    Copy-Item "$($source.FullName)\*" $libs -Recurse -Force
    # Gradle  libcocos-release.aar  JAR
    foreach ($dependencyDir in @($libs, "$Root/native/engine/android/libs", "$Root/build/android/proj/libservice/libs")) {
        if (Test-Path $dependencyDir) {
            Get-ChildItem $dependencyDir -File | Where-Object { $_.Name -in @('com.android.vending.expansion.zipfile.jar', 'game-sdk.jar') -or $_.Name -like 'okhttp-*.jar' -or $_.Name -like 'okio-*.jar' } | ForEach-Object { Write-Host ": $($_.Name)"; Remove-Item $_.FullName -Force }
        }
    }
    Remove-Item $tmp -Recurse -Force
}

function Install-AndroidComponents {
    #  local.properties  sdk.dir  SDKBuild Tools  NDK
    #  sdk_root  channel=1 Android 37 / Android 17 
    $localProperties = "$Root/build/android/proj/local.properties"
    $sdkLine = Get-Content $localProperties | Where-Object { $_ -match '^sdk\.dir=' } | Select-Object -First 1
    if (-not $sdkLine) { throw 'local.properties  sdk.dir' }
    $sdkDir = ($sdkLine -replace '^sdk\.dir=', '').Replace('\:', ':').Replace('\\', '\')
    $sdkManagerPath = (Get-Command sdkmanager.bat -ErrorAction SilentlyContinue).Source
    if (-not $sdkManagerPath) { $sdkManagerPath = (Get-Command sdkmanager -ErrorAction SilentlyContinue).Source }
    if (-not $sdkManagerPath) {
        foreach ($candidate in @("$sdkDir/cmdline-tools/latest/bin/sdkmanager.bat", "$sdkDir/cmdline-tools/bin/sdkmanager.bat", "$sdkDir/tools/bin/sdkmanager.bat")) {
            if (Test-Path $candidate) { $sdkManagerPath = (Resolve-Path $candidate).Path; break }
        }
    }
    if (-not $sdkManagerPath) {
        $searchRoots = @(
            "$sdkDir/cmdline-tools",
            "$env:ANDROID_HOME/cmdline-tools",
            "$env:ANDROID_SDK_ROOT/cmdline-tools",
            "$env:LOCALAPPDATA/Android/Sdk/cmdline-tools",
            "$env:ProgramFiles/Android/Android Studio",
            "$env:ProgramFiles/Android/Android Studio/bin"
        ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
        foreach ($searchRoot in $searchRoots) {
            $found = Get-ChildItem $searchRoot -Recurse -File -Include 'sdkmanager.bat', 'sdkmanager.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $sdkManagerPath = $found.FullName; break }
        }
    }
    if (-not $sdkManagerPath) {
        # Android SDK Command-line Tools  Windows 
        $toolsVersion = '15859902'
        $toolsUrl = "https://dl.google.com/android/repository/commandlinetools-win-${toolsVersion}_latest.zip"
        #  tar.exe  Windows 
        $toolsTemp = Join-Path $env:TEMP ('a' + ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        $toolsZip = Join-Path $toolsTemp 'commandlinetools.zip'
        $toolsExtract = Join-Path $toolsTemp 'extract'
        New-Item -ItemType Directory -Path $toolsExtract -Force | Out-Null
        Write-Host 'Android SDK Command-line Tools not found; downloading official tools...'
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            & curl.exe -fL --retry 3 --output $toolsZip $toolsUrl
        } else {
            Invoke-WebRequest $toolsUrl -OutFile $toolsZip
        }
        Expand-Zip $toolsZip $toolsExtract
        $latestDir = "$sdkDir/cmdline-tools/latest"
        New-Item -ItemType Directory -Path $latestDir -Force | Out-Null
        Copy-Item "$(Join-Path $toolsExtract 'cmdline-tools')\*" $latestDir -Recurse -Force
        Remove-Item $toolsTemp -Recurse -Force
        $sdkManagerPath = "$latestDir/bin/sdkmanager.bat"
    }
    if (-not $sdkManagerPath) { throw " sdkmanager Android Command-line Tools: $sdkDir" }
    $platform37 = "$sdkDir/platforms/android-37"
    $platform370 = "$sdkDir/platforms/android-37.0"
    if (-not (Test-Path $platform37) -and -not (Test-Path $platform370)) {
        Write-Host 'Installing missing Android component: platforms;android-37'
        & $sdkManagerPath ("--sdk_root=$sdkDir") '--channel=1' 'platforms;android-37'
        if ($LASTEXITCODE -ne 0 -and -not (Test-Path $platform37)) {
            Write-Host 'Trying alternate Android platform package: platforms;android-37.0'
            & $sdkManagerPath ("--sdk_root=$sdkDir") '--channel=1' 'platforms;android-37.0'
        }
    }
    if (-not (Test-Path $platform37) -and (Test-Path $platform370)) {
        Write-Host 'Creating Gradle-compatible Android platform alias: android-37'
        Copy-Item $platform370 $platform37 -Recurse -Force
    }
    if (-not (Test-Path $platform37)) {
        throw 'Android platform 37 was not installed or found.'
    }
    if (-not (Test-Path "$sdkDir/build-tools/37.0.0")) { Write-Host 'Installing missing Android component: build-tools;37.0.0'; & $sdkManagerPath ("--sdk_root=$sdkDir") '--channel=1' 'build-tools;37.0.0' }
    if (-not (Test-Path "$sdkDir/ndk/28.2.13676358/source.properties")) { Write-Host 'Installing missing Android component: ndk;28.2.13676358'; & $sdkManagerPath ("--sdk_root=$sdkDir") '--channel=0' 'ndk;28.2.13676358' }
}

if ($args -notcontains '--no-build') {
    Use-Java21
    Install-AndroidComponents
    #  Gradle Wrapper  Release APK/AAB
    Push-Location "$Root/build/android/proj"; try { & .\gradlew.bat assembleRelease } finally { Pop-Location }
}
