#!/usr/bin/env bash
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
  OLD="$1" NEW="$2" perl -0pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$3"
}

comment_blocks() {
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

for file in "$ROOT/native/engine/android/app/build.gradle" "$ROOT/native/engine/android/instantapp/build.gradle"; do
  perl -0pi -e 's/^([ \t]*)ndkVersion\s+PROP_NDK_VERSION/$1ndkVersion "28.2.13676358"/mg; s/^([ \t]*)(implementation project\('\''\:libcocos'\''\))/$1\/\/ $2/mg' "$file"
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
  libs="$ROOT/native/engine/android/app/libs"; mkdir -p "$libs"
  find "$libs" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  mkdir "$tmp/extract"
  if unzip -q "$archive" -d "$tmp/extract"; then :; else tar -xf "$archive" -C "$tmp/extract"; fi
  source_dir="$(find "$tmp/extract" -type d -name libs -print -quit)"
  [[ -n "$source_dir" ]] || source_dir="$tmp/extract"
  shopt -s dotglob
  mv "$source_dir"/* "$libs"/
  shopt -u dotglob
  if [[ -f "$libs/libcocos-release.aar" ]]; then
    rm -f "$libs/com.android.vending.expansion.zipfile.jar" "$libs/game-sdk.jar" "$libs"/okhttp-*.jar "$libs"/okio-*.jar
  fi
fi

if [[ "$NO_BUILD" == false ]]; then
  (cd "$ROOT/build/android/proj" && ./gradlew assembleRelease)
fi
