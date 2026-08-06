$ErrorActionPreference = "Stop"
$root = (Get-Location).Path
$helper = Join-Path $env:TEMP "setup-cocos-3.8.8-base.ps1"
Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/chuankuancao-png/cocos/main/setup-cocos-creator-2.4.13.ps1" -OutFile $helper
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $helper -ReleaseTag "3.8.8" -AssetName "libs.zip"

$manifestFiles = Get-ChildItem $root -Recurse -Filter AndroidManifest.xml -File
foreach ($file in $manifestFiles) {
    $text = [IO.File]::ReadAllText($file.FullName)
    if ($text -notmatch "com.android.vending.BILLING") {
        $text = $text -replace '(<manifest\b[^>]*)(>)', '$1 xmlns:tools="http://schemas.android.com/tools"$2'
        $text = $text -replace '(<manifest\b[^>]*>)', '$1' + [Environment]::NewLine + '    <uses-permission android:name="com.android.vending.BILLING" tools:node="remove"/>'
        [IO.File]::WriteAllText($file.FullName, $text, (New-Object Text.UTF8Encoding($false)))
    }
}

$properties = Join-Path $root "gradle.properties"
$text = [IO.File]::ReadAllText($properties)
$base = ($root -replace '\','/')
$values = @{
    "RES_PATH" = "$base/build/google-play"
    "NATIVE_DIR" = "$base/native/engine/google-play"
}
foreach ($item in $values.GetEnumerator()) {
    $pattern = "(?m)^\s*" + $item.Key + "\s*=.*$"
    $line = "$($item.Key)=$($item.Value)"
    if ($text -match $pattern) { $text = [regex]::Replace($text, $pattern, $line) }
    else { $text += [Environment]::NewLine + $line }
}
[IO.File]::WriteAllText($properties, $text, (New-Object Text.UTF8Encoding($false)))
Write-Host "Cocos Creator 3.8.8 setup complete."
