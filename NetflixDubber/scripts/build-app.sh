#!/usr/bin/env bash
# Builds "Netflix Dubber.app" from the Swift package and ad-hoc signs it.
# Usage: scripts/build-app.sh [release|debug]
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/Netflix Dubber.app"

swift build -c "$CONFIG" --product NetflixDubber
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/NetflixDubber" "$APP/Contents/MacOS/NetflixDubber"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# SwiftPM resource bundles from dependencies.
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
  cp -R "$bundle" "$APP/Contents/Resources/"
done
# Dynamic frameworks from binary targets, if any.
for framework in "$BIN_DIR"/*.framework; do
  cp -R "$framework" "$APP/Contents/Frameworks/"
done
if compgen -G "$APP/Contents/Frameworks/*.framework" > /dev/null; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/NetflixDubber" 2>/dev/null || true
fi
rmdir "$APP/Contents/Frameworks" 2>/dev/null || true

# Ad-hoc signature: enough to run locally and for macOS to remember the
# "System Audio Recording" permission. No hardened runtime, no sandbox.
codesign --force --deep --sign - "$APP"

echo "Built: $APP"
