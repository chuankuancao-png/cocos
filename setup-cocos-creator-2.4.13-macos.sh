#!/usr/bin/env bash
set -euo pipefail

REPOSITORY="chuankuancao-png/cocos"
RELEASE_TAG="2.4.13"
ASSET_NAME="libs.zip"
NDK_VERSION="28.2.13676358"
PROJECT_ROOT="$(pwd)"
APP_DIR="$PROJECT_ROOT/app"
TMP_DIR="$(mktemp -d)"
ZIP_PATH="$TMP_DIR/$ASSET_NAME"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

required_files=(
  "build.gradle"
  "gradle/wrapper/gradle-wrapper.properties"
  "gradle.properties"
  "local.properties"
  "settings.gradle"
  "app/build.gradle"
  "instantapp/build.gradle"
)

for file in "${required_files[@]}"; do
  if [[ ! -f "$PROJECT_ROOT/$file" ]]; then
    echo "Required file not found: $PROJECT_ROOT/$file" >&2
    exit 1
  fi
done

echo "Downloading $ASSET_NAME"
curl -fL --retry 3 \
  "https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG/$ASSET_NAME" \
  -o "$ZIP_PATH"

mkdir -p "$APP_DIR"
unzip -oq "$ZIP_PATH" -d "$APP_DIR"
echo "Extracted $ASSET_NAME into $APP_DIR"

export PROJECT_ROOT NDK_VERSION

python3 <<'PY'
import os
import re
from pathlib import Path

root = Path(os.environ["PROJECT_ROOT"])
ndk_version = os.environ["NDK_VERSION"]

def read(path):
    return path.read_text(encoding="utf-8")

def write(path, text):
    path.write_text(text, encoding="utf-8")

def android_block(text):
    match = re.search(r"(?m)^[ \t]*android[ \t]*\{", text)
    if not match:
        raise RuntimeError("Could not find an android { block")
    open_at = text.index("{", match.start())
    depth = 0
    for i in range(open_at, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return open_at, i
    raise RuntimeError("Could not find the end of the android { block")

def set_ndk_version(path):
    text = read(path)
    open_at, close_at = android_block(text)
    body = text[open_at + 1:close_at]
    line = f'\n    ndkVersion "{ndk_version}"'
    if re.search(r"(?m)^\s*ndkVersion\s+", body):
        body = re.sub(r"(?m)^\s*ndkVersion\s+[^\r\n]*", line, body, count=1)
    else:
        body = line + body
    write(path, text[:open_at + 1] + body + text[close_at:])

def comment_all_blocks(path, name):
    text = read(path)
    count = 0
    pattern = re.compile(rf"(?m)^[ \t]*{re.escape(name)}[ \t]*\{{")
    while True:
        match = pattern.search(text)
        if not match:
            break
        open_at = text.index("{", match.start())
        depth = 0
        close_at = None
        for i in range(open_at, len(text)):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    close_at = i
                    break
        if close_at is None:
            raise RuntimeError(f"Could not find the end of {name} in {path}")
        block = text[match.start():close_at + 1]
        block = "\n".join(
            line if not line.strip() else "// " + line
            for line in block.splitlines()
        )
        text = text[:match.start()] + block + text[close_at + 1:]
        count += 1
    write(path, text)
    print(f"Commented {count} {name} block(s): {path}")

# 2. Android Gradle Plugin.
path = root / "build.gradle"
write(path, re.sub(r"com\.android\.tools\.build:gradle:[0-9.]+",
                   "com.android.tools.build:gradle:8.13.2", read(path)))

# 3. Gradle wrapper.
path = root / "gradle/wrapper/gradle-wrapper.properties"
write(path, re.sub(r"gradle-[0-9.]+-(?:all|bin)\.zip",
                   "gradle-8.13-bin.zip", read(path)))

# 4-5. NDK version.
set_ndk_version(root / "app/build.gradle")
set_ndk_version(root / "instantapp/build.gradle")

# 6. SDK properties.
path = root / "gradle.properties"
text = read(path)
for key, value in {
    "PROP_MIN_SDK_VERSION": "24",
    "PROP_COMPILE_SDK_VERSION": "37",
    "PROP_TARGET_SDK_VERSION": "37",
}.items():
    pattern = rf"(?m)^\s*{re.escape(key)}\s*=.*$"
    replacement = f"{key}={value}"
    if re.search(pattern, text):
        text = re.sub(pattern, replacement, text)
    else:
        text += f"\n{replacement}"
write(path, text)

# 7. Keep instantapp and remove the external libcocos2dx Gradle project.
path = root / "settings.gradle"
text = read(path)
text = re.sub(r"(?m)^\s*include\s+['\"]:libcocos2dx['\"]\s*,\s*['\"]:instantapp['\"]\s*$",
              "include ':instantapp'", text)
text = re.sub(r"(?m)^\s*include\s+['\"]:libcocos2dx['\"]\s*$", "", text)
text = re.sub(r"(?m)^\s*project\(['\"]:libcocos2dx['\"]\)\.projectDir\s*=.*(?:\n|$)", "", text)
write(path, text)

# 8. Disable old local libcocos2dx dependencies in both modules.
for relative in ("app/build.gradle", "instantapp/build.gradle"):
    path = root / relative
    text = read(path)
    text = re.sub(r"(?m)^(?!\s*//)(\s*implementation\s+fileTree\([^\n]*cocos2d-x[^\n]*\).*)$",
                  r"// \1", text)
    text = re.sub(r"(?m)^(?!\s*//)(\s*implementation\s+project\(['\"]:libcocos2dx['\"]\).*)$",
                  r"// \1", text)
    write(path, text)

# 9. Disable every externalNativeBuild block.
comment_all_blocks(root / "app/build.gradle", "externalNativeBuild")
comment_all_blocks(root / "instantapp/build.gradle", "externalNativeBuild")

# 10. Update ndk.dir using sdk.dir from local.properties.
path = root / "local.properties"
text = read(path)
match = re.search(r"(?m)^\s*sdk\.dir\s*=\s*(.+?)\s*$", text)
if not match:
    raise RuntimeError("sdk.dir was not found in local.properties")
sdk_dir = match.group(1).strip().replace("\\:", ":").replace("\\\\", "\\")
ndk_dir = f"{sdk_dir}/ndk/{ndk_version}"
text = re.sub(r"(?m)^\s*ndk\.dir\s*=.*(?:\n|$)", "", text)
write(path, text.rstrip() + f"\nndk.dir={ndk_dir}\n")
Path(os.environ["PROJECT_ROOT"] + "/.cocos-sdk-dir").write_text(sdk_dir, encoding="utf-8")
PY

SDK_DIR="$(cat "$PROJECT_ROOT/.cocos-sdk-dir")"
rm -f "$PROJECT_ROOT/.cocos-sdk-dir"
NDK_DIR="$SDK_DIR/ndk/$NDK_VERSION"

if [[ ! -f "$NDK_DIR/source.properties" ]]; then
  SDKMANAGER=""
  for candidate in \
    "$SDK_DIR/cmdline-tools/latest/bin/sdkmanager" \
    "$SDK_DIR/cmdline-tools/bin/sdkmanager" \
    "$SDK_DIR/tools/bin/sdkmanager"; do
    if [[ -x "$candidate" ]]; then
      SDKMANAGER="$candidate"
      break
    fi
  done
  if [[ -z "$SDKMANAGER" ]]; then
    echo "sdkmanager was not found under sdk.dir: $SDK_DIR" >&2
    exit 1
  fi
  echo "Installing NDK $NDK_VERSION"
  "$SDKMANAGER" "ndk;$NDK_VERSION"
fi

echo "Setup complete. Run: ./gradlew clean assembleRelease"
