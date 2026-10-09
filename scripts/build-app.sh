#!/usr/bin/env bash
# Builds build/Dictator.app: release binary + bundled, verified model, signed with hardened runtime.
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh   (default: ad-hoc "-")
#   VERSION=1.2.3 scripts/build-app.sh   (overrides CFBundleShortVersionString; default: Info.plist)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/build/Dictator.app"
identity="${SIGN_IDENTITY:--}"

"$root/scripts/fetch-model.sh"

swift build --package-path "$root" -c release --arch arm64
bin="$(swift build --package-path "$root" -c release --arch arm64 --show-bin-path)"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Dictator" "$app/Contents/MacOS/Dictator"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
if [[ -n "${VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$app/Contents/Info.plist"
fi
iconutil --convert icns "$root/Resources/AppIcon.iconset" --output "$app/Contents/Resources/AppIcon.icns"
# Hidden files (e.g. partial downloads) are excluded.
rsync -a --exclude '.*' "$root/Model/" "$app/Contents/Resources/Model/"

codesign --force --options runtime --timestamp=none \
    --entitlements "$root/Resources/Dictator.entitlements" \
    --sign "$identity" "$app"
codesign --verify --strict --deep "$app"

echo "✓ Built $app"
