#!/usr/bin/env bash
set -euo pipefail
ROOT="$(pwd)"
HELPER="$(mktemp)"
trap 'rm -f "$HELPER"' EXIT
curl -fsSL "https://raw.githubusercontent.com/chuankuancao-png/cocos/main/setup-cocos-creator-2.4.13-macos.sh" -o "$HELPER"
sed -i '' 's/RELEASE_TAG="2.4.13"/RELEASE_TAG="3.8.8"/; s/ASSET_NAME="lib.zip"/ASSET_NAME="libs.zip"/' "$HELPER"
bash "$HELPER"

python3 - "$ROOT" <<'PY'
import re, sys
from pathlib import Path
root = Path(sys.argv[1])
for p in root.rglob("AndroidManifest.xml"):
    s = p.read_text(encoding="utf-8")
    if "com.android.vending.BILLING" not in s:
        s = re.sub(r'(<manifest\b[^>]*)(>)', r'\1 xmlns:tools="http://schemas.android.com/tools"\2', s, count=1)
        s = re.sub(r'(<manifest\b[^>]*>)', r'\1\n    <uses-permission android:name="com.android.vending.BILLING" tools:node="remove"/>', s, count=1)
        p.write_text(s, encoding="utf-8")
p = root / "gradle.properties"
s = p.read_text(encoding="utf-8")
values = {"RES_PATH": str(root/"build/google-play"), "NATIVE_DIR": str(root/"native/engine/google-play")}
for k, v in values.items():
    s = re.sub(rf"(?m)^\s*{re.escape(k)}\s*=.*$", f"{k}={v}", s) if re.search(rf"(?m)^\s*{re.escape(k)}\s*=.*$", s) else s + f"\n{k}={v}"
p.write_text(s, encoding="utf-8")
PY
echo "Cocos Creator 3.8.8 setup complete."
