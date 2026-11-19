#!/bin/bash
# Builds release binaries, signs them with the virtualization entitlement and assembles
# dist/AltVM.app (SwiftUI app with the `avm` CLI embedded) plus dist/avm.
#   SIGN_IDENTITY="Developer ID Application: …" ./scripts/build.sh   (default: ad-hoc "-")
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="${SIGN_IDENTITY:--}"
ENT=Resources/avm.entitlements
VERSION="${VERSION:-1.0.0}"

./scripts/embed-agent.sh
swift build -c release --product avm
swift build -c release --product AltVM
BIN=$(swift build -c release --show-bin-path)

rm -rf dist && mkdir -p dist
APP=dist/AltVM.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/AltVM" "$APP/Contents/MacOS/AltVM"
cp "$BIN/avm" "$APP/Contents/MacOS/avm"
cp "$BIN/avm" dist/avm
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"

codesign -f -s "$IDENTITY" --options runtime --entitlements "$ENT" dist/avm
codesign -f -s "$IDENTITY" --options runtime --entitlements "$ENT" "$APP/Contents/MacOS/avm"
codesign -f -s "$IDENTITY" --options runtime --entitlements "$ENT" "$APP"
codesign --verify --strict "$APP" && echo "built and signed: $APP and dist/avm"
