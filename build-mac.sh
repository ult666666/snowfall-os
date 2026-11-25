#!/bin/bash
set -euo pipefail
shopt -s nullglob
project="$(cd "$(dirname "$0")" && pwd)"
destination="${1:-$project/build}"
mkdir -p "$destination"
destination="$(cd "$destination" && pwd)"
bundle="$destination/Snowfall OS.app"
if [[ -e "$bundle" ]]; then
    existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$existing_id" != com.snowfallos.desktop ]]; then
        echo "The destination already contains a different app named Snowfall OS.app." >&2
        exit 1
    fi
fi
stage="$(mktemp -d "$destination/.SnowfallOS.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/new/Snowfall OS.app"
resources="$app/Contents/Resources"
mkdir -p "$app/Contents/MacOS" "$resources/Desktop"
cp "$project/macos/Info.plist" "$app/Contents/Info.plist"
cp "$project/macos/Cabin.icns" "$resources/"
test -f "$project/index.html"
cp "$project"/*.html "$project"/*.css "$project"/*.js "$resources/Desktop/"
cp -R "$project/assets" "$resources/Desktop/"

# WebKit applies cross-origin font checks even to neighboring file:// URLs.
# Embed these small assets in the Mac stylesheet to keep the pixel type offline.
xcrun python3 - "$resources/Desktop" <<'PY'
import base64
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
stylesheet = root / "desktop.css"
def embed(match):
    path = root / match.group(2)
    encoded = base64.b64encode(path.read_bytes()).decode("ascii")
    return f'url("data:font/{path.suffix[1:]};base64,{encoded}")'

pattern = r'''url\((['"]?)(assets/fonts/[^'")]+\.(?:ttf|woff2))\1\)'''
stylesheet.write_text(re.sub(pattern, embed, stylesheet.read_text()))
index = root / "index.html"
index.write_text(re.sub(r'<link\b[^>]*\bas="font"[^>]*>\s*', '', index.read_text()))
PY

sdk="$(xcrun --sdk macosx --show-sdk-path)"
for arch in arm64 x86_64; do
    xcrun swiftc -O -sdk "$sdk" -target "$arch-apple-macos12.0" \
        "$project/macos/main.swift" -o "$stage/$arch"
done
xcrun lipo -create "$stage/arm64" "$stage/x86_64" -output "$app/Contents/MacOS/SnowfallOS"
/usr/bin/codesign --force --sign - --identifier com.snowfallos.desktop "$app"
/usr/bin/codesign --verify --strict --all-architectures "$app"
if [[ -e "$bundle" ]]; then mv "$bundle" "$stage/previous.app"; fi
if ! mv "$app" "$bundle"; then
    if [[ -e "$stage/previous.app" ]]; then mv "$stage/previous.app" "$bundle"; fi
    exit 1
fi
echo "$bundle"
