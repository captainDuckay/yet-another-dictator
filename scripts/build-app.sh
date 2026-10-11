#!/usr/bin/env bash
# Builds build/Dictator.app: release binary + the pinned model manifest, signed with hardened runtime.
# The model itself is not bundled; the app downloads and verifies it on first launch (ADR 0004).
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh   (default: ad-hoc "-")
#     With a real identity the signature gets a secure timestamp, as notarization requires.
#   VERSION=1.2.3 scripts/build-app.sh   (overrides CFBundleShortVersionString; default: Info.plist)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/build/Dictator.app"
identity="${SIGN_IDENTITY:--}"

swift build --package-path "$root" -c release --arch arm64
bin="$(swift build --package-path "$root" -c release --arch arm64 --show-bin-path)"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Dictator" "$app/Contents/MacOS/Dictator"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
if [[ -n "${VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$app/Contents/Info.plist"
fi
# Shown in the What's New window; bundled so it works offline.
cp "$root/CHANGELOG.md" "$app/Contents/Resources/CHANGELOG.md"
cp "$root/LICENSE" "$app/Contents/Resources/LICENSE"
cp "$root/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
iconutil --convert icns "$root/Resources/AppIcon.iconset" --output "$app/Contents/Resources/AppIcon.icns"
# The manifest is the trust anchor for the download: sealed by the app's signature, never fetched.
cp "$root/scripts/model-manifest.txt" "$app/Contents/Resources/model-manifest.txt"

# Only the app itself is signed: the executable is statically linked (no frameworks, dylibs or
# helpers), so --deep isn't needed. The downloaded model lives outside the app and is verified by hash.
if [[ "$identity" == "-" ]]; then timestamp="--timestamp=none"; else timestamp="--timestamp"; fi
codesign --force --options runtime "$timestamp" \
    --entitlements "$root/Resources/Dictator.entitlements" \
    --sign "$identity" "$app"
codesign --verify --strict --deep "$app"

echo "✓ Built $app"
