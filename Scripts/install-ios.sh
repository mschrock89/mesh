#!/bin/bash
# Install Mesh on a connected iPhone or iPad.
# Usage: Scripts/install-ios.sh [device name or identifier]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ $# -lt 1 ]]; then
  echo "Connected devices:"
  xcrun devicectl list devices
  echo
  echo "Pass a device name or identifier: Scripts/install-ios.sh \"Mitchell's iPhone\""
  exit 1
fi

DEVICE="$1"
xcodebuild \
  -project Mesh.xcodeproj \
  -scheme "Mesh iOS" \
  -configuration Debug \
  -destination "generic/platform=iOS" \
  -allowProvisioningUpdates \
  -derivedDataPath build/ios \
  build

APP="$ROOT/build/ios/Build/Products/Debug-iphoneos/Mesh.app"
xcrun devicectl device install app --device "$DEVICE" "$APP"
echo "Installed Mesh. Open it on the device and allow Local Network access."
