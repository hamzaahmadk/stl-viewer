#!/bin/bash
# Regenerates Resources/AppIcon.icns from tools/make_icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

swiftc -O tools/make_icon.swift -o "$STAGE/make_icon"
"$STAGE/make_icon" "$STAGE/AppIcon.iconset"

mkdir -p Resources
iconutil -c icns "$STAGE/AppIcon.iconset" -o Resources/AppIcon.icns
echo "Wrote $PWD/Resources/AppIcon.icns"
