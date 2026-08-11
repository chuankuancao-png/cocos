#!/usr/bin/env bash
# Cocos Creator 3.8.8 Android 打包脚本（macOS）
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
# 使用方式：在项目根目录执行 ./package_android_3.8.8.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
[[ "$(pwd)" == "$ROOT" ]] || { echo "请在项目根目录执行：$ROOT" >&2; exit 2; }
SKIP_DOWNLOAD=false
NO_BUILD=false
for arg in "$@"; do
  case "$arg" in
    --skip-download) SKIP_DOWNLOAD=true ;;
    --no-build) NO_BUILD=true ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

replace() {
  # 对项目配置文件执行幂等文本替换，脚本重复运行不会重复修改。
  OLD="$1" NEW="$2" perl -0pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$3"
}

comment_blocks() {
  # 注释 app 和 instantapp 中全部 externalNativeBuild 块，改用预编译 AAR。
  perl - "$1" <<'PERL'
use strict;
use warnings;
my ($file) = @ARGV;
local $/;
open my $fh, '<', $file or die "$file: $!\n";
my @lines = split /(?<=\n)/, <$fh>;
close $fh;
my @out;
for (my $i = 0; $i < @lines;) {
    if ($lines[$i] =~ /^\s*externalNativeBuild\s*\{/) {
        my $depth = 0;
        my $start = $i;
        do {
            $depth += ($lines[$i] =~ tr/{/{/) - ($lines[$i] =~ tr/}/}/);
            $i++;
            die "$file: externalNativeBuild block is not closed\n" if $i > @lines && $depth != 0;
        } while ($depth != 0);
        for my $line (@lines[$start .. $i - 1]) {
            $line =~ s/^(\s*)(\S)/$1\/\/ $2/;
            push @out, $line;
        }
    } else {
        push @out, $lines[$i++];
    }
}
open my $out, '>', $file or die "$file: $!\n";
print {$out} @out;
close $out;
PERL
}

replace "com.android.tools.build:gradle:8.10.1" "com.android.tools.build:gradle:8.13.2" "$ROOT/build/android/proj/build.gradle"
replace "com.android.tools.build:gradle:8.10.1" "com.android.tools.build:gradle:8.13.2" "$ROOT/native/engine/android/build.gradle"
replace "gradle-8.11.1-bin.zip" "gradle-8.13-bin.zip" "$ROOT/build/android/proj/gradle/wrapper/gradle-wrapper.properties"
# Release AAR 的最低系统版本是 Android API 24，不能继续使用 API 21。
replace "PROP_MIN_SDK_VERSION=21" "PROP_MIN_SDK_VERSION=24" "$ROOT/build/android/proj/gradle.properties"
replace "PROP_COMPILE_SDK_VERSION=36" "PROP_COMPILE_SDK_VERSION=37" "$ROOT/build/android/proj/gradle.properties"
replace "PROP_TARGET_SDK_VERSION=36" "PROP_TARGET_SDK_VERSION=37" "$ROOT/build/android/proj/gradle.properties"

# R8 会检查 Cocos 重打包 okhttp 引用的可选依赖；这些依赖不是运行必需项。
proguard="$ROOT/native/engine/android/app/proguard-rules.pro"
if ! grep -qF 'javax.annotation.**' "$proguard"; then
  printf '\n# Optional dependencies referenced by the Cocos-shaded okhttp implementation.\n-dontwarn javax.annotation.**\n-dontwarn org.codehaus.mojo.animal_sniffer.**\n-dontwarn org.conscrypt.**\n' >> "$proguard"
fi

for file in "$ROOT/native/engine/android/app/build.gradle" "$ROOT/native/engine/android/instantapp/build.gradle"; do
  # 停用 libcocos 工程、旧 native 构建链和 Cocos 引擎目录中的重复 Java JAR。
  perl -0pi -e 's/^([ \t]*)ndkVersion\s+PROP_NDK_VERSION/$1ndkVersion "28.2.13676358"/mg; s/^([ \t]*)(implementation project\('\''\:libcocos'\''\))/$1\/\/ $2/mg; s/^([ \t]*)(implementation fileTree\(dir: "\$\{COCOS_ENGINE_PATH\}\/cocos\/platform\/android\/java\/libs", include: \['\''\*\.jar'\''\]\))/$1\/\/ $2/mg' "$file"
  comment_blocks "$file"
done
perl -0pi -e 's/^([ \t]*)(implementation project\('\''\:libcocos'\''\))/$1\/\/ $2/mg; s/(android \{\n)/$1    ndkVersion "28.2.13676358"\n/ if ! /ndkVersion "28\.2\.13676358"/' "$ROOT/build/android/proj/libservice/build.gradle"

perl -0pi -e 's/^include .*$/include '\'':libservice'\'', '\'':app'\''/m; s/^(\s*)(project\('\'':libcocos'\''\)\.projectDir)/$1\/\/ $2/m' "$ROOT/build/android/proj/settings.gradle"

ROOT="$ROOT" perl -0pi -e 's/^RES_PATH=.*$/RES_PATH=$ENV{ROOT}\/build\/android/m; s/^NATIVE_DIR=.*$/NATIVE_DIR=$ENV{ROOT}\/native\/engine\/android/m' "$ROOT/build/android/proj/gradle.properties"

perl -0pi -e 's/xmlns:android="http:\/\/schemas\.android\.com\/apk\/res\/android"/xmlns:android="http:\/\/schemas\.android\.com\/apk\/res\/android" xmlns:tools="http:\/\/schemas\.android\.com\/tools"/ if ! /xmlns:tools=/; s{(  <uses-permission android:name="android\.permission\.INTERNET"/>)}{  <uses-permission android:name="com.android.vending.BILLING" tools:name="remove"\/>\n$1} if ! /com\.android\.vending\.BILLING/' "$ROOT/native/engine/android/app/AndroidManifest.xml"

# tools:name is corrected to tools:node for the manifest directive.
perl -0pi -e 's/android:name="com\.android\.vending\.BILLING" tools:name="remove"/android:name="com.android.vending.BILLING" tools:node="remove"/' "$ROOT/native/engine/android/app/AndroidManifest.xml"

if [[ "$SKIP_DOWNLOAD" == false ]]; then
  api="https://api.github.com/repos/chuankuancao-png/cocos/releases/tags/3.8.8"
  asset_url="$(curl -fsSL -A cocos-android-packager "$api" | perl -0777 -ne 'while (/"browser_download_url"\s*:\s*"([^" ]+\.(?:zip|tar|gz|tgz))"/g) { print "$1\n"; exit }')"
  [[ -n "$asset_url" ]] || { echo "3.8.8 Release 没有找到 ZIP/TAR 资源" >&2; exit 1; }
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  archive="$tmp/archive"; curl -fL --retry 3 "$asset_url" -o "$archive"
  # 清空旧资源，保证 app/libs 只保留本次 3.8.8 Release 的内容。
  libs="$ROOT/native/engine/android/app/libs"; mkdir -p "$libs"
  find "$libs" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  mkdir "$tmp/extract"
  if unzip -q "$archive" -d "$tmp/extract"; then :; else tar -xf "$archive" -C "$tmp/extract"; fi
  source_dir="$(find "$tmp/extract" -type d -name libs -print -quit)"
  [[ -n "$source_dir" ]] || source_dir="$tmp/extract"
  shopt -s dotglob
  mv "$source_dir"/* "$libs"/
  shopt -u dotglob
  # Gradle 会从这些目录加载本地依赖，删除会与 libcocos-release.aar 重复的 JAR。
  for dependency_dir in "$libs" "$ROOT/native/engine/android/libs" "$ROOT/build/android/proj/libservice/libs"; do
    if [[ -d "$dependency_dir" ]]; then
      find "$dependency_dir" -maxdepth 1 -type f \( \
        -name 'com.android.vending.expansion.zipfile.jar' -o \
        -name 'game-sdk.jar' -o \
        -name 'okhttp-*.jar' -o \
        -name 'okio-*.jar' \
      \) -print -delete
    fi
  done
fi

install_android_components() {
  # 根据 local.properties 的 sdk.dir 检查并安装构建所需的 SDK、Build Tools 和 NDK。
  # 使用 sdk_root 和 channel=1，确保能发现 Android 37 / Android 17 的新频道资源。
  local sdk_dir sdkmanager
  sdk_dir="$(sed -n 's/^sdk\.dir=//p' "$ROOT/build/android/proj/local.properties" | head -n 1 | sed 's/\\://g; s#\\\\#\\#g')"
  [[ -n "$sdk_dir" ]] || { echo "local.properties 中未找到 sdk.dir" >&2; exit 1; }
  sdkmanager="$(command -v sdkmanager || true)"
  for candidate in "$sdk_dir/cmdline-tools/latest/bin/sdkmanager" "$sdk_dir/cmdline-tools/bin/sdkmanager" "$sdk_dir/tools/bin/sdkmanager"; do
    if [[ -x "$candidate" ]]; then sdkmanager="$candidate"; break; fi
  done
  [[ -n "$sdkmanager" ]] || { echo "未找到 sdkmanager: $sdk_dir" >&2; exit 1; }
  if [[ ! -d "$sdk_dir/platforms/android-37" ]]; then
    echo "Installing missing Android component: platforms;android-37"
    yes | "$sdkmanager" --sdk_root="$sdk_dir" --channel=1 "platforms;android-37"
  fi
  if [[ ! -d "$sdk_dir/build-tools/37.0.0" ]]; then
    echo "Installing missing Android component: build-tools;37.0.0"
    yes | "$sdkmanager" --sdk_root="$sdk_dir" --channel=1 "build-tools;37.0.0"
  fi
  if [[ ! -f "$sdk_dir/ndk/28.2.13676358/source.properties" ]]; then
    echo "Installing missing Android component: ndk;28.2.13676358"
    yes | "$sdkmanager" --sdk_root="$sdk_dir" --channel=0 "ndk;28.2.13676358"
  fi
}

if [[ "$NO_BUILD" == false ]]; then
  install_android_components
  # 使用 Gradle Wrapper 构建 Release APK/AAB。
  (cd "$ROOT/build/android/proj" && ./gradlew assembleRelease)
fi
