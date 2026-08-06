param(
    [string]$Repository = "chuankuancao-png/cocos",
    [string]$ReleaseTag = "2.4.13",
    [string]$AssetName = "libs.zip",
    [string]$NdkVersion = "28.2.13676358"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Get-Location).Path
$AppDir = Join-Path $ProjectRoot "app"
$TempZip = Join-Path $env:TEMP "cocos-$ReleaseTag-$AssetName"
$TempExtract = Join-Path $env:TEMP "cocos-$ReleaseTag-extracted"

function Read-Text([string]$Path) {
    return [System.IO.File]::ReadAllText($Path)
}

function Write-Text([string]$Path, [string]$Text) {
    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Require-File([string]$Path) {
    if (!(Test-Path $Path -PathType Leaf)) {
        throw "Required file not found: $Path"
    }
}

function Find-AndroidBlock([string]$Text) {
    $Match = [regex]::Match($Text, '(?m)^[ \t]*android[ \t]*\{')
    if (!$Match.Success) {
        throw "Could not find an android { block."
    }

    $Open = $Text.IndexOf('{', $Match.Index)
    $Depth = 0
    $Close = -1
    for ($i = $Open; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq '{') { $Depth++ }
        elseif ($Text[$i] -eq '}') {
            $Depth--
            if ($Depth -eq 0) {
                $Close = $i
                break
            }
        }
    }

    if ($Close -lt 0) {
        throw "Could not find the end of the android { block."
    }

    return @{ Start = $Match.Index; Open = $Open; Close = $Close }
}

function Set-NdkVersion([string]$Path, [string]$Version) {
    $Text = Read-Text $Path
    $Block = Find-AndroidBlock $Text
    $Before = $Text.Substring(0, $Block.Open + 1)
    $Body = $Text.Substring($Block.Open + 1, $Block.Close - $Block.Open - 1)
    $After = $Text.Substring($Block.Close)

    $NdkLine = "`r`n    ndkVersion " + [char]34 + $Version + [char]34
    if ($Body -match '(?m)^\s*ndkVersion\s+') {
        $Body = [regex]::Replace($Body, '(?m)^\s*ndkVersion\s+[^\r\n]+', $NdkLine)
    } else {
        $Body = $NdkLine + $Body
    }

    Write-Text $Path ($Before + $Body + $After)
    Write-Host "Updated ndkVersion: $Path"
}

function Comment-Block([string]$Path, [string]$BlockName) {
    $Text = Read-Text $Path
    $Count = 0

    while ($true) {
        $Match = [regex]::Match($Text, "(?m)^[ \t]*$BlockName[ \t]*\{")
        if (!$Match.Success) {
            break
        }

        $Open = $Text.IndexOf('{', $Match.Index)
        $Depth = 0
        $Close = -1
        for ($i = $Open; $i -lt $Text.Length; $i++) {
            if ($Text[$i] -eq '{') { $Depth++ }
            elseif ($Text[$i] -eq '}') {
                $Depth--
                if ($Depth -eq 0) {
                    $Close = $i
                    break
                }
            }
        }

        if ($Close -lt 0) {
            throw "Could not find the end of $BlockName in $Path"
        }

        $BlockText = $Text.Substring($Match.Index, $Close - $Match.Index + 1)
        $Commented = (($BlockText -split "`r?`n") | ForEach-Object {
            if ($_.Trim().Length -eq 0) { $_ } else { "// " + $_ }
        }) -join "`r`n"

        $Text = $Text.Substring(0, $Match.Index) + $Commented + $Text.Substring($Close + 1)
        $Count++
    }

    Write-Text $Path $Text
    Write-Host "Commented $Count $BlockName block(s): $Path"
}

function Escape-LocalPropertyPath([string]$Path) {
    return $Path.Replace('\', '\\').Replace(':', '\:')
}

function Unescape-LocalPropertyPath([string]$Path) {
    return $Path.Trim().Replace('\:', ':').Replace('\\', '\')
}

Require-File (Join-Path $ProjectRoot "build.gradle")
Require-File (Join-Path $ProjectRoot "gradle\wrapper\gradle-wrapper.properties")
Require-File (Join-Path $ProjectRoot "gradle.properties")
Require-File (Join-Path $ProjectRoot "local.properties")
Require-File (Join-Path $ProjectRoot "settings.gradle")
Require-File (Join-Path $ProjectRoot "app\build.gradle")
Require-File (Join-Path $ProjectRoot "instantapp\build.gradle")

# 1. Download and extract the lib.zip asset from the GitHub Release.
$ReleaseApi = "https://api.github.com/repos/$Repository/releases/tags/$ReleaseTag"
$Release = Invoke-RestMethod -Uri $ReleaseApi -Headers @{ "User-Agent" = "cocos-android-setup" }
$Asset = $Release.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
if ($null -eq $Asset) {
    throw "Release asset not found: $AssetName ($ReleaseApi)"
}

Write-Host "Downloading $($Asset.name)"
Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $TempZip
if (Test-Path $TempExtract) { Remove-Item $TempExtract -Recurse -Force }
New-Item -ItemType Directory -Path $TempExtract -Force | Out-Null
Expand-Archive -Path $TempZip -DestinationPath $TempExtract -Force
New-Item -ItemType Directory -Path $AppDir -Force | Out-Null
Copy-Item (Join-Path $TempExtract "*") $AppDir -Recurse -Force
Write-Host "Extracted $AssetName into $AppDir"

# 2. Upgrade Android Gradle Plugin.
$RootBuildGradle = Join-Path $ProjectRoot "build.gradle"
$Text = Read-Text $RootBuildGradle
$Text = [regex]::Replace($Text, "com\.android\.tools\.build:gradle:[0-9.]+", "com.android.tools.build:gradle:8.13.2")
Write-Text $RootBuildGradle $Text

# 3. Use the Gradle 8.13 binary distribution.
$WrapperPath = Join-Path $ProjectRoot "gradle\wrapper\gradle-wrapper.properties"
$Text = Read-Text $WrapperPath
$Text = [regex]::Replace($Text, "gradle-[0-9.]+-(all|bin)\.zip", "gradle-8.13-bin.zip")
Write-Text $WrapperPath $Text

# 4-5. Set the NDK version in both Android modules.
Set-NdkVersion (Join-Path $ProjectRoot "app\build.gradle") $NdkVersion
Set-NdkVersion (Join-Path $ProjectRoot "instantapp\build.gradle") $NdkVersion

# 6. Normalize SDK properties.
$GradlePropertiesPath = Join-Path $ProjectRoot "gradle.properties"
$Text = Read-Text $GradlePropertiesPath
foreach ($Setting in @{
    "PROP_MIN_SDK_VERSION" = "24"
    "PROP_COMPILE_SDK_VERSION" = "37"
    "PROP_TARGET_SDK_VERSION" = "37"
}.GetEnumerator()) {
    $Pattern = "(?m)^\s*" + [regex]::Escape($Setting.Key) + "\s*=.*$"
    if ($Text -match $Pattern) {
        $Text = [regex]::Replace($Text, $Pattern, "$($Setting.Key)=$($Setting.Value)")
    } else {
        $Text += "`r`n$($Setting.Key)=$($Setting.Value)"
    }
}
Write-Text $GradlePropertiesPath $Text

# 7. Remove the external libcocos2dx Gradle project and retain instantapp.
$SettingsPath = Join-Path $ProjectRoot "settings.gradle"
$Text = Read-Text $SettingsPath
$Text = [regex]::Replace($Text, '(?m)^\s*include\s+["\x27]:libcocos2dx["\x27]\s*,\s*["\x27]:instantapp["\x27]\s*$', "include ':instantapp'")
$Text = [regex]::Replace($Text, '(?m)^\s*include\s+["\x27]:libcocos2dx["\x27]\s*$', "")
$Text = [regex]::Replace($Text, '(?m)^\s*project\(["\x27]:libcocos2dx["\x27]\)\.projectDir\s*=.*(?:\r?\n|$)', "")
Write-Text $SettingsPath $Text

# 8. Disable the old local Java library and Gradle project dependency.
foreach ($GradlePath in @(
    (Join-Path $ProjectRoot "app\build.gradle"),
    (Join-Path $ProjectRoot "instantapp\build.gradle")
)) {
    $Text = Read-Text $GradlePath
    $Text = [regex]::Replace($Text, "(?m)^(?!\s*//)(\s*implementation\s+fileTree\([^\r\n]*cocos2d-x[^\r\n]*\).*)$", "// `$1")
    $Text = [regex]::Replace($Text, '(?m)^(?!\s*//)(\s*implementation\s+project\(["\x27]:libcocos2dx["\x27]\).*)$', "// `$1")
    Write-Text $GradlePath $Text
}

# 9. Disable externalNativeBuild blocks. Native sources are supplied by lib.zip.
Comment-Block (Join-Path $ProjectRoot "app\build.gradle") "externalNativeBuild"
Comment-Block (Join-Path $ProjectRoot "instantapp\build.gradle") "externalNativeBuild"

# 10. Read sdk.dir and write the corresponding ndk.dir.
$LocalPropertiesPath = Join-Path $ProjectRoot "local.properties"
$LocalText = Read-Text $LocalPropertiesPath
$SdkMatch = [regex]::Match($LocalText, "(?m)^\s*sdk\.dir\s*=\s*(.+?)\s*$")
if (!$SdkMatch.Success) {
    throw "sdk.dir was not found in $LocalPropertiesPath"
}
$SdkDir = Unescape-LocalPropertyPath $SdkMatch.Groups[1].Value
$NdkDir = Join-Path $SdkDir "ndk\$NdkVersion"
$EscapedNdkDir = Escape-LocalPropertyPath $NdkDir
$LocalText = [regex]::Replace($LocalText, "(?m)^\s*ndk\.dir\s*=.*(?:\r?\n|$)", "")
$LocalText = $LocalText.TrimEnd() + "`r`nndk.dir=$EscapedNdkDir`r`n"
Write-Text $LocalPropertiesPath $LocalText

# 11. Install the requested NDK through the SDK manager if necessary.
if (!(Test-Path (Join-Path $NdkDir "source.properties"))) {
    $SdkManager = @(
        (Join-Path $SdkDir "cmdline-tools\latest\bin\sdkmanager.bat"),
        (Join-Path $SdkDir "cmdline-tools\bin\sdkmanager.bat"),
        (Join-Path $SdkDir "tools\bin\sdkmanager.bat")
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($null -eq $SdkManager) {
        throw "sdkmanager.bat was not found under sdk.dir: $SdkDir"
    }

    Write-Host "Installing NDK $NdkVersion"
    & $SdkManager "ndk;$NdkVersion"
    if ($LASTEXITCODE -ne 0) {
        throw "sdkmanager failed to install NDK $NdkVersion"
    }
}

Write-Host "Setup complete. Run: .\gradlew clean assembleRelease"
