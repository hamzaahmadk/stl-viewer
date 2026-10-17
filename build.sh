#!/bin/bash
# Builds "STL Viewer.app". Needs only the Xcode command line tools.
#
#   ./build.sh            build next to this script
#   ./build.sh --install  build and put it in /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP="STL Viewer.app"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Build and sign in a scratch folder. This project may live in an iCloud / File Provider folder,
# which keeps attaching Finder metadata to the bundle and makes codesign fail.
mkdir -p "$STAGE/$APP/Contents/MacOS" "$STAGE/$APP/Contents/Resources"
swiftc -O -swift-version 5 \
    -target "$(uname -m)-apple-macos13.0" \
    Sources/*.swift \
    -o "$STAGE/$APP/Contents/MacOS/STLViewer"
cp Info.plist "$STAGE/$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$STAGE/$APP/Contents/Resources/AppIcon.icns" # regenerate with tools/make_icon.sh
codesign --force --sign - "$STAGE/$APP"
codesign --verify --deep --strict "$STAGE/$APP" # checked here, before the copy, where nothing adds metadata

if [[ "${1:-}" == "--install" ]]; then DEST="/Applications"; else DEST="$PWD"; fi
rm -rf "$DEST/$APP"
ditto --noextattr --noqtn "$STAGE/$APP" "$DEST/$APP"

# Tell Launch Services about the .stl association.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/$APP"

echo "Built: $DEST/$APP"
