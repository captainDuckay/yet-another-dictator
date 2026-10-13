#!/usr/bin/env bash
# Builds build/Dictator.app: release binary, the unsandboxed updater, and the pinned model manifest,
# signed with hardened runtime.
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
xpc="$app/Contents/XPCServices/DictatorUpdater.xpc"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$xpc/Contents/MacOS"
cp "$bin/Dictator" "$app/Contents/MacOS/Dictator"
cp "$bin/DictatorUpdater" "$xpc/Contents/MacOS/DictatorUpdater"
cp "$root/Resources/DictatorUpdater.plist" "$xpc/Contents/Info.plist"
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

# Sign inside out. The updater XPC is unsandboxed (no entitlements) so it can replace the app;
# the app itself stays sandboxed. --deep is not used.
if [[ "$identity" == "-" ]]; then timestamp="--timestamp=none"; else timestamp="--timestamp"; fi
codesign --force --options runtime "$timestamp" --sign "$identity" "$xpc"
codesign --force --options runtime "$timestamp" \
    --entitlements "$root/Resources/Dictator.entitlements" \
    --sign "$identity" "$app"
codesign --verify --strict --deep "$app"
codesign --verify --strict "$xpc"
app_entitlements="$(codesign -d --entitlements - "$app" 2>/dev/null || true)"
xpc_entitlements="$(codesign -d --entitlements - "$xpc" 2>/dev/null || true)"
xpc_identity="$(codesign -d -v "$xpc" 2>&1 || true)"
if ! grep -q 'com.apple.security.app-sandbox' <<<"$app_entitlements"; then
    echo "Dictator.app must stay sandboxed" >&2
    exit 1
fi
if grep -q 'com.apple.security.app-sandbox' <<<"$xpc_entitlements"; then
    echo "DictatorUpdater.xpc must not be sandboxed" >&2
    exit 1
fi
if ! grep -q 'Identifier=com.captainduckay.dictator.updater' <<<"$xpc_identity"; then
    echo "DictatorUpdater.xpc has the wrong identifier" >&2
    exit 1
fi

echo "✓ Built $app"
