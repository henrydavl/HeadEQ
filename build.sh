#!/bin/bash
# Builds HeadEQ, signs it, installs it to ~/Applications and launches it.
#   ./build.sh            test, build, install, launch
#   ./build.sh --no-run   test, build and install only
# Override the signing identity with SIGN_IDENTITY="..." ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="HeadEQ"
BUNDLE_ID="com.henrydavidlie.HeadEQ"
DEFAULT_IDENTITY="Apple Development: Henry David Lie (L8SU36HHL3)"
BUNDLE="build/$APP_NAME.app"
INSTALL="$HOME/Applications/$APP_NAME.app"

swift test --quiet
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"

# A stable identity keeps the System Audio Recording grant across rebuilds; ad-hoc changes it each build.
IDENTITY="${SIGN_IDENTITY:-$DEFAULT_IDENTITY}"
if [ "$IDENTITY" != "-" ] && ! security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
    echo "warning: signing identity '$IDENTITY' not found, signing ad-hoc (audio capture permission will ask again after each build)"
    IDENTITY="-"
fi
codesign --force --options runtime --sign "$IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$BUNDLE"
codesign --verify --strict "$BUNDLE"
echo "signed with: $IDENTITY"

pkill -x "$APP_NAME" 2>/dev/null && sleep 0.5 || true
mkdir -p "$HOME/Applications"
rm -rf "$INSTALL"
ditto "$BUNDLE" "$INSTALL"
echo "installed: $INSTALL"

if [ "${1:-}" != "--no-run" ]; then
    open "$INSTALL"
fi
