#!/bin/bash
# Assembles DevCleaner.app around the SwiftPM binary.
#
# Local builds are ad-hoc signed. Release builds can use a Developer ID identity and,
# when a notary keychain profile is supplied, are submitted and stapled as well.
#
# SwiftPM builds a bare executable. MenuBarExtra needs LSUIElement, and SMAppService
# needs a bundle identifier, and neither exists outside a bundle — so the bundle is
# assembled here rather than being a thing Xcode would have done.
#
# Usage: Scripts/make-app.sh [debug|release]   (default: release)
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/DevCleaner.app"
ARCHIVE="$ROOT/build/DevCleaner.zip"
VERSION="${DEVCLEANER_VERSION:-1.0.0}"
BUILD_NUMBER="${DEVCLEANER_BUILD_NUMBER:-1}"
SIGN_IDENTITY="${DEVCLEANER_SIGN_IDENTITY:--}"
NOTARY_PROFILE="${DEVCLEANER_NOTARY_PROFILE:-}"

if [[ "$CONFIGURATION" != "debug" && "$CONFIGURATION" != "release" ]]; then
    echo "Configuration must be debug or release." >&2
    exit 64
fi

if [[ -n "$NOTARY_PROFILE" && "$SIGN_IDENTITY" == "-" ]]; then
    echo "Notarization requires DEVCLEANER_SIGN_IDENTITY." >&2
    exit 64
fi

swift build -c "$CONFIGURATION" --product DevCleanerApp
BIN_PATH="$(swift build -c "$CONFIGURATION" --product DevCleanerApp --show-bin-path)"
BINARY="$BIN_PATH/DevCleanerApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Named DevCleaner inside the bundle, matching CFBundleExecutable. The product is
# DevCleanerApp because SwiftPM will not let a target and a product share a name here.
cp "$BINARY" "$APP/Contents/MacOS/DevCleaner"
cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The Dock icon, rendered fresh each build: a regular app without one shows the
# generic terminal-and-pencil tile. make-icon.swift draws the 1024 master; sips and
# iconutil turn it into the icns that CFBundleIconFile names.
MASTER="$ROOT/build/AppIcon-1024.png"
ICONSET="$ROOT/build/AppIcon.iconset"
swift "$ROOT/Scripts/make-icon.swift" "$MASTER"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$MASTER" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" > /dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" "$MASTER" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" > /dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - --timestamp=none "$APP"
else
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

rm -f "$ARCHIVE"
ditto -c -k --keepParent "$APP" "$ARCHIVE"

if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    rm -f "$ARCHIVE"
    ditto -c -k --keepParent "$APP" "$ARCHIVE"
    spctl --assess --type execute --verbose=2 "$APP"
fi

echo "Built $APP"
echo "Archived $ARCHIVE"
