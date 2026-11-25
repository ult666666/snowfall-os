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

sdk="$(xcrun --sdk macosx --show-sdk-path)"
build_arch() {
    local arch="$1"
    xcrun swiftc -parse-as-library -Osize -whole-module-optimization -Xlinker -dead_strip -sdk "$sdk" -target "$arch-apple-macos12.0" \
        "$project"/macos/*.swift -o "$stage/$arch"
    xcrun strip -x "$stage/$arch"
}
build_arch arm64 &
arm_pid=$!
build_arch x86_64 &
intel_pid=$!
failed=0
wait "$arm_pid" || failed=1
wait "$intel_pid" || failed=1
if (( failed )); then exit 1; fi
xcrun lipo -create "$stage/arm64" "$stage/x86_64" -output "$app/Contents/MacOS/SnowfallOS"
/usr/bin/codesign --force --sign - --identifier com.snowfallos.desktop "$app"
/usr/bin/codesign --verify --strict --all-architectures "$app"
if [[ -e "$bundle" ]]; then mv "$bundle" "$stage/previous.app"; fi
if ! mv "$app" "$bundle"; then
    if [[ -e "$stage/previous.app" ]]; then mv "$stage/previous.app" "$bundle"; fi
    exit 1
fi
echo "$bundle"
