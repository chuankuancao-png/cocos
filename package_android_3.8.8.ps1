$ErrorActionPreference = 'Stop'
# Cocos Creator 3.8.8 Android 打包脚本（Windows PowerShell）
#
# 项目需要完成的处理：
# 1. 升级 Android Gradle Plugin 和 Gradle Wrapper。
# 2. 把工程路径改成当前项目根目录，避免依赖其他电脑的绝对路径。
# 3. 使用 Release 包提供的 libcocos-release.aar，停用旧的 libcocos 工程和外部重复 JAR。
# 4. 清理与 libcocos-release.aar 重复的 game-sdk、okhttp、okio 等 JAR。
# 5. 将最低 Android 版本调整为 API 24，因为 libcocos-release.aar 要求 API 24。
# 6. 增加 R8 对 okhttp 可选依赖的忽略规则。
# 7. 检查并自动安装 Android 37、Build Tools 37.0.0 和 NDK 28.2.13676358。
# 8. 下载 3.8.8 Release 资源到 app/libs，并执行 assembleRelease。
#
# 使用方式：在项目根目录执行 .\package_android_3.8.8.ps1
$Root = (Resolve-Path (Join-Path $PSScriptRoot '.')).Path
if ((Resolve-Path (Get-Location)).Path -ne $Root) { throw "请在项目根目录执行：$Root" }

function Replace-Text([string]$Path, [string]$Old, [string]$New) {
    # 对项目配置文件执行幂等文本替换，脚本重复运行不会重复修改。
    $text = Get-Content -Raw -LiteralPath $Path
    $text = $text.Replace($Old, $New)
    Set-Content -LiteralPath $Path -Value $text -NoNewline
}

function Comment-ExternalNativeBuild([string]$Path) {
    # 注释 app 和 instantapp 中全部 externalNativeBuild 块，改用预编译 AAR。
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
# Release AAR 的最低系统版本是 Android API 24，不能继续使用 API 21。

# R8 会检查 Cocos 重打包 okhttp 引用的可选依赖；这些依赖不是运行必需项。
$proguard = "$Root/native/engine/android/app/proguard-rules.pro"
$proguardText = Get-Content -Raw -LiteralPath $proguard
if ($proguardText -notmatch 'javax\.annotation\.\*\*') { Add-Content -LiteralPath $proguard -Value "`r`n# Optional dependencies referenced by the Cocos-shaded okhttp implementation.`r`n-dontwarn javax.annotation.**`r`n-dontwarn org.codehaus.mojo.animal_sniffer.**`r`n-dontwarn org.conscrypt.**`r`n" }

foreach ($file in @("$Root/native/engine/android/app/build.gradle", "$Root/native/engine/android/instantapp/build.gradle")) {
    # 停用 libcocos 工程、旧 native 构建链和 Cocos 引擎目录中的重复 Java JAR。
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
    if (-not $asset) { throw '3.8.8 Release 没有找到 ZIP/TAR 资源' }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('cocos-3.8.8-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $archive = Join-Path $tmp $asset.name
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        & curl.exe -fL --retry 3 --output $archive $asset.browser_download_url
    } else {
        Invoke-WebRequest $asset.browser_download_url -OutFile $archive
    }
    # 清空旧资源，保证 app/libs 只保留本次 3.8.8 Release 的内容。
    $libs = "$Root/native/engine/android/app/libs"; New-Item -ItemType Directory -Force -Path $libs | Out-Null
    Get-ChildItem $libs -Force | Remove-Item -Recurse -Force
    $extract = Join-Path $tmp 'extract'; New-Item -ItemType Directory -Path $extract | Out-Null
    if ($asset.name -match '\.zip$') { Expand-Archive $archive -DestinationPath $extract } else { tar -xf $archive -C $extract }
    $source = Get-ChildItem $extract -Directory -Recurse | Where-Object Name -eq 'libs' | Select-Object -First 1
    if (-not $source) { $source = Get-Item $extract }
    Copy-Item "$($source.FullName)\*" $libs -Recurse -Force
    # Gradle 会从这些目录加载本地依赖，删除会与 libcocos-release.aar 重复的 JAR。
    foreach ($dependencyDir in @($libs, "$Root/native/engine/android/libs", "$Root/build/android/proj/libservice/libs")) {
        if (Test-Path $dependencyDir) {
            Get-ChildItem $dependencyDir -File | Where-Object { $_.Name -in @('com.android.vending.expansion.zipfile.jar', 'game-sdk.jar') -or $_.Name -like 'okhttp-*.jar' -or $_.Name -like 'okio-*.jar' } | ForEach-Object { Write-Host "删除重复依赖: $($_.Name)"; Remove-Item $_.FullName -Force }
        }
    }
    Remove-Item $tmp -Recurse -Force
}

function Install-AndroidComponents {
    # 根据 local.properties 的 sdk.dir 检查并安装构建所需的 SDK、Build Tools 和 NDK。
    # 使用 sdk_root 和 channel=1，确保能发现 Android 37 / Android 17 的新频道资源。
    $localProperties = "$Root/build/android/proj/local.properties"
    $sdkLine = Get-Content $localProperties | Where-Object { $_ -match '^sdk\.dir=' } | Select-Object -First 1
    if (-not $sdkLine) { throw 'local.properties 中未找到 sdk.dir' }
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
        # Android SDK Command-line Tools 未安装时，自动下载官方 Windows 工具包。
        $toolsVersion = '15859902'
        $toolsUrl = "https://dl.google.com/android/repository/commandlinetools-win-${toolsVersion}_latest.zip"
        $toolsTemp = Join-Path ([System.IO.Path]::GetTempPath()) ('android-cmdline-tools-' + [guid]::NewGuid())
        $toolsZip = Join-Path $toolsTemp 'commandlinetools.zip'
        $toolsExtract = Join-Path $toolsTemp 'extract'
        New-Item -ItemType Directory -Path $toolsExtract -Force | Out-Null
        Write-Host 'Android SDK Command-line Tools not found; downloading official tools...'
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            & curl.exe -fL --retry 3 --output $toolsZip $toolsUrl
        } else {
            Invoke-WebRequest $toolsUrl -OutFile $toolsZip
        }
        Expand-Archive $toolsZip -DestinationPath $toolsExtract -Force
        $latestDir = "$sdkDir/cmdline-tools/latest"
        New-Item -ItemType Directory -Path $latestDir -Force | Out-Null
        Copy-Item "$(Join-Path $toolsExtract 'cmdline-tools')\*" $latestDir -Recurse -Force
        Remove-Item $toolsTemp -Recurse -Force
        $sdkManagerPath = "$latestDir/bin/sdkmanager.bat"
    }
    if (-not $sdkManagerPath) { throw "未找到 sdkmanager，请先安装 Android Command-line Tools: $sdkDir" }
    if (-not (Test-Path "$sdkDir/platforms/android-37.0")) {
        Write-Host 'Installing missing Android component: platforms;android-37.0'
        & $sdkManagerPath ("--sdk_root=$sdkDir") '--channel=1' 'platforms;android-37.0'
    }
    if (-not (Test-Path "$sdkDir/build-tools/37.0.0")) { Write-Host 'Installing missing Android component: build-tools;37.0.0'; & $sdkManagerPath ("--sdk_root=$sdkDir") '--channel=1' 'build-tools;37.0.0' }
    if (-not (Test-Path "$sdkDir/ndk/28.2.13676358/source.properties")) { Write-Host 'Installing missing Android component: ndk;28.2.13676358'; & $sdkManagerPath ("--sdk_root=$sdkDir") '--channel=0' 'ndk;28.2.13676358' }
}

if ($args -notcontains '--no-build') {
    Install-AndroidComponents
    # 使用 Gradle Wrapper 构建 Release APK/AAB。
    Push-Location "$Root/build/android/proj"; try { & .\gradlew.bat assembleRelease } finally { Pop-Location }
}
