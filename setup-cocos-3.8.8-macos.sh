#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
TAG="3.8.8"
NDK="28.2.13676358"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fL --retry 3 \
  "https://github.com/chuankuancao-png/cocos/releases/download/$TAG/libs.zip" \
  -o "$TMP/libs.zip"
unzip -oq "$TMP/libs.zip" -d "$ROOT"

export ROOT NDK
python3 <<'PY'
import os, re
from pathlib import Path

root = Path(os.environ["ROOT"])
ndk = os.environ["NDK"]

def read(p): return p.read_text(encoding="utf-8")
def write(p, s): p.write_text(s, encoding="utf-8")

def bounds(text, name):
    m = re.search(rf"(?m)^[ \t]*{re.escape(name)}[ \t]*\{{", text)
    if not m: return None
    opening = text.index("{", m.start())
    depth = 0
    for i in range(opening, len(text)):
        if text[i] == "{": depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0: return m.start(), i
    raise RuntimeError(f"Unclosed {name} block")

def set_ndk(path):
    text = read(path)
    pos = bounds(text, "android")
    if not pos: return
    start, end = pos
    opening = text.index("{", start)
    body = text[opening + 1:end]
    line = f'\n    ndkVersion "{ndk}"'
    if re.search(r"(?m)^\s*ndkVersion\s+", body):
        body = re.sub(r"(?m)^\s*ndkVersion\s+[^\n]*", line, body, count=1)
    else:
        body = line + body
    write(path, text[:opening + 1] + body + text[end:])

def comment_all(path, name):
    text = read(path)
    while True:
        pos = bounds(text, name)
        if not pos: break
        start, end = pos
        block = "\n".join(
            ("// " + line) if line.strip() else line
            for line in text[start:end + 1].splitlines()
        )
        text = text[:start] + block + text[end + 1:]
    write(path, text)

gradles = []
for candidate in list(root.rglob("*.gradle")) + list(root.rglob("*.gradle.kts")):
    if not candidate.is_file():
        continue
    relative_parts = candidate.relative_to(root).parts
    if relative_parts and relative_parts[0] in {".gradle", "build"}:
        continue
    gradles.append(candidate)
for path in gradles:
    text = read(path)
    if path.name == "build.gradle" and path.parent == root:
        text = re.sub(r"com\.android\.tools\.build:gradle:[0-9.]+",
                      "com.android.tools.build:gradle:8.13.2", text)
    text = re.sub(r"(?m)^(?!\s*//)(\s*implementation\s+fileTree\([^\n]*cocos[^\n]*\).*)$",
                  r"// \1", text)
    text = re.sub(r"(?m)^(?!\s*//)(\s*implementation\s+project\([^\n]*libcocos[^\n]*\).*)$",
                  r"// \1", text)
    write(path, text)
    set_ndk(path)
    comment_all(path, "externalNativeBuild")

wrapper = root / "gradle/wrapper/gradle-wrapper.properties"
if wrapper.exists():
    write(wrapper, re.sub(r"gradle-[0-9.]+-(?:all|bin)\.zip",
                          "gradle-8.13-bin.zip", read(wrapper)))

props = root / "gradle.properties"
if props.exists():
    text = read(props)
    for key, value in {
        "PROP_MIN_SDK_VERSION": "24",
        "PROP_COMPILE_SDK_VERSION": "37",
        "PROP_TARGET_SDK_VERSION": "37",
        "RES_PATH": str(root / "build/google-play"),
        "NATIVE_DIR": str(root / "native/engine/google-play"),
    }.items():
        pattern = rf"(?m)^\s*{re.escape(key)}\s*=.*$"
        line = f"{key}={value}"
        text = re.sub(pattern, line, text) if re.search(pattern, text) else text + f"\n{line}"
    write(props, text)

settings = root / "settings.gradle"
if settings.exists():
    text = read(settings)
    text = re.sub(r"(?m)^\s*include\s+['\"]:libcocos(?:2dx)?['\"]\s*,\s*['\"]:instantapp['\"]\s*$",
                  "include ':instantapp'", text)
    text = re.sub(r"(?m)^\s*include\s+['\"]:libcocos(?:2dx)?['\"]\s*$", "", text)
    text = re.sub(r"(?m)^\s*project\(['\"]:libcocos(?:2dx)?['\"]\)\.projectDir\s*=.*(?:\n|$)", "", text)
    write(settings, text)

for manifest in root.rglob("AndroidManifest.xml"):
    text = read(manifest)
    if "com.android.vending.BILLING" not in text:
        text = re.sub(r'(<manifest\b[^>]*)(>)',
                      r'\1 xmlns:tools="http://schemas.android.com/tools"\2', text, count=1)
        text = re.sub(r'(<manifest\b[^>]*>)',
                      r'\1\n    <uses-permission android:name="com.android.vending.BILLING" tools:node="remove"/>',
                      text, count=1)
        write(manifest, text)

local = root / "local.properties"
text = read(local)
match = re.search(r"(?m)^\s*sdk\.dir\s*=\s*(.+?)\s*$", text)
if not match: raise RuntimeError("sdk.dir missing in local.properties")
sdk = match.group(1).strip().replace("\\:", ":").replace("\\\\", "\\")
ndk_dir = f"{sdk}/ndk/{ndk}"
text = re.sub(r"(?m)^\s*ndk\.dir\s*=.*(?:\n|$)", "", text)
write(local, text.rstrip() + f"\nndk.dir={ndk_dir}\n")
(root / ".sdk-dir.tmp").write_text(sdk, encoding="utf-8")
PY

SDK="$(cat "$ROOT/.sdk-dir.tmp")"
rm -f "$ROOT/.sdk-dir.tmp"
NDK_DIR="$SDK/ndk/$NDK"
if [[ ! -f "$NDK_DIR/source.properties" ]]; then
  for sdkmanager in \
    "$SDK/cmdline-tools/latest/bin/sdkmanager" \
    "$SDK/cmdline-tools/bin/sdkmanager" \
    "$SDK/tools/bin/sdkmanager"; do
    [[ -x "$sdkmanager" ]] && break
  done
  [[ -x "${sdkmanager:-}" ]] || { echo "sdkmanager not found under $SDK" >&2; exit 1; }
  "$sdkmanager" "ndk;$NDK"
fi

echo "Cocos Creator 3.8.8 setup complete. Run: ./gradlew clean assembleRelease"
