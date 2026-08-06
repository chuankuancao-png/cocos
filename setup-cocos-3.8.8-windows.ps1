param([string]$Repo="chuankuancao-png/cocos",[string]$Tag="3.8.8",[string]$Ndk="28.2.13676358")
$ErrorActionPreference="Stop";$Root=(Get-Location).Path
function R($p){[IO.File]::ReadAllText($p)}
function W($p,$s){[IO.File]::WriteAllText($p,$s,(New-Object Text.UTF8Encoding($false)))}
function Block($s,$name){
 $m=[regex]::Match($s,"(?m)^[ \t]*$name[ \t]*\{");if(!$m){return $null};$o=$s.IndexOf('{',$m.Index);$d=0
 for($i=$o;$i-lt$s.Length;$i++){if($s[$i]-eq'{'){$d++}elseif($s[$i]-eq'}'){$d--;if($d-eq0){return @($m.Index,$i)}}};throw "Unclosed $name"
}
function SetNdk($p){
 $s=R $p;$b=Block $s "android";if(!$b){return};$o=$s.IndexOf('{',$b[0]);$body=$s.Substring($o+1,$b[1]-$o-1);$line=[Environment]::NewLine+"    ndkVersion "+[char]34+$Ndk+[char]34
 if($body-match '(?m)^\s*ndkVersion\s+'){$body=[regex]::Replace($body,'(?m)^\s*ndkVersion\s+[^\r\n]+',$line,1)}else{$body=$line+$body};W $p ($s.Substring(0,$o+1)+$body+$s.Substring($b[1]))
}
function CommentAll($p,$name){
 $s=R $p
 while($true){$b=Block $s $name;if(!$b){break};$part=$s.Substring($b[0],$b[1]-$b[0]+1);$part=(($part-split "\r?\n"|%{if($_.Trim()){"// "+$_}else{$_}})-join [Environment]::NewLine);$s=$s.Substring(0,$b[0])+$part+$s.Substring($b[1]+1)}
 W $p $s
}
$api="https://api.github.com/repos/$Repo/releases/tags/$Tag";$r=Invoke-RestMethod $api -Headers @{"User-Agent"="cocos-setup"};$a=$r.assets|?{$_.name-eq"libs.zip"}|select -First 1;if(!$a){throw "libs.zip not found"}
$tmp="$env:TEMP\cocos-$Tag.zip";Invoke-WebRequest $a.browser_download_url -OutFile $tmp;$ex="$env:TEMP\cocos-$Tag-extract";if(Test-Path $ex){Remove-Item $ex -Recurse -Force};Expand-Archive $tmp $ex -Force;Copy-Item "$ex\*" $Root -Recurse -Force
$rootGradle="$Root\build.gradle";if(Test-Path $rootGradle){$s=R $rootGradle;W $rootGradle ([regex]::Replace($s,'com\.android\.tools\.build:gradle:[0-9.]+','com.android.tools.build:gradle:8.13.2'))}
$wrap="$Root\gradle\wrapper\gradle-wrapper.properties";if(Test-Path $wrap){$s=R $wrap;W $wrap ([regex]::Replace($s,'gradle-[0-9.]+-(all|bin)\.zip','gradle-8.13-bin.zip'))}
foreach($p in Get-ChildItem $Root -Recurse -Include "*.gradle","*.gradle.kts" -File){
 $s=R $p.FullName;$s=[regex]::Replace($s,'(?m)^(?!\s*//)(\s*implementation\s+fileTree\([^\r\n]*cocos[^\r\n]*\).*)$','// $1');$s=[regex]::Replace($s,'(?m)^(?!\s*//)(\s*implementation\s+project\([^\r\n]*libcocos[^\r\n]*\).*)$','// $1');W $p.FullName $s;SetNdk $p.FullName;CommentAll $p.FullName "externalNativeBuild"}
$gp="$Root\gradle.properties";if(Test-Path $gp){$s=R $gp;$vals=@{"PROP_MIN_SDK_VERSION"="24";"PROP_COMPILE_SDK_VERSION"="37";"PROP_TARGET_SDK_VERSION"="37";"RES_PATH"=(("$Root\build\google-play").Replace('\','/'));"NATIVE_DIR"=(("$Root\native\engine\google-play").Replace('\','/'))};foreach($x in $vals.GetEnumerator()){$q="(?m)^\s*"+$x.Key+"\s*=.*$";$v="$($x.Key)=$($x.Value)";if($s-match$q){$s=[regex]::Replace($s,$q,$v)}else{$s+=[Environment]::NewLine+$v}};W $gp $s}
$sp="$Root\settings.gradle";if(Test-Path $sp){$s=R $sp;$s=[regex]::Replace($s,'(?m)^\s*include\s+["\x27]:libcocos(?:2dx)?["\x27]\s*,\s*["\x27]:instantapp["\x27]\s*$',"include ':instantapp'");$s=[regex]::Replace($s,'(?m)^\s*include\s+["\x27]:libcocos(?:2dx)?["\x27]\s*$',"");$s=[regex]::Replace($s,'(?m)^\s*project\(["\x27]:libcocos(?:2dx)?["\x27]\)\.projectDir\s*=.*(?:\r?\n|$)',"");W $sp $s}
foreach($m in Get-ChildItem $Root -Recurse -Filter AndroidManifest.xml -File){$p=$m.FullName;$s=R $p;if($s-notmatch "com.android.vending.BILLING"){$s=$s-replace '(<manifest\b[^>]*)(>)','$1 xmlns:tools="http://schemas.android.com/tools"$2';$s=$s-replace '(<manifest\b[^>]*>)','$1'+[Environment]::NewLine+'    <uses-permission android:name="com.android.vending.BILLING" tools:node="remove"/>'};W $p $s}
$lp="$Root\local.properties";$s=R $lp;$m=[regex]::Match($s,'(?m)^\s*sdk\.dir\s*=\s*(.+?)\s*$');if(!$m){throw "sdk.dir missing"};$sdk=$m.Groups[1].Value.Trim().Replace('\:',':').Replace('\\','\');$ndk="$sdk\ndk\$Ndk";$s=[regex]::Replace($s,'(?m)^\s*ndk\.dir\s*=.*(?:\r?\n|$)','');W $lp ($s.TrimEnd()+[Environment]::NewLine+"ndk.dir="+$ndk.Replace('\','\\').Replace(':','\:')+[Environment]::NewLine)
if(!(Test-Path "$ndk\source.properties")){$sm=@("$sdk\cmdline-tools\latest\bin\sdkmanager.bat","$sdk\cmdline-tools\bin\sdkmanager.bat","$sdk\tools\bin\sdkmanager.bat")|?{Test-Path $_}|select -First 1;if(!$sm){throw "sdkmanager.bat not found"};&$sm "ndk;$Ndk";if($LASTEXITCODE-ne0){throw "NDK install failed"}}
Write-Host "Cocos Creator 3.8.8 setup complete."

