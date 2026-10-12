#!/bin/bash
# Build Mesh and publish it for the Check for Updates button.
# Commit and push to main first. Each Mac needs a GitHub token the first time.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit or stash changes before publishing. The update is tagged with the current commit."
  exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" ]]; then
  echo "Publish from main. This checkout is $BRANCH."
  exit 1
fi

git fetch origin main
LOCAL="$(git rev-parse HEAD)"
REMOTE="$(git rev-parse origin/main)"
if [[ "$LOCAL" != "$REMOTE" ]]; then
  echo "Push this commit to origin/main before publishing."
  exit 1
fi

xcodebuild -project Mesh.xcodeproj -scheme Mesh -configuration Release -destination 'platform=macOS' -derivedDataPath build build

APP="$ROOT/build/Build/Products/Release/Mesh.app"
COMMIT="$(/usr/libexec/PlistBuddy -c 'Print :MeshCommit' "$APP/Contents/Info.plist")"
if ! [[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Build was not stamped with a commit ($COMMIT)."
  exit 1
fi
if [[ "$COMMIT" != "$LOCAL" ]]; then
  echo "Built app is stamped $COMMIT but HEAD is $LOCAL."
  exit 1
fi

ZIP="$(mktemp -d)/Mesh.app.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

if gh release view "$COMMIT" --repo mschrock89/mesh >/dev/null 2>&1; then
  echo "Release $COMMIT is already published."
  exit 0
fi

gh release create "$COMMIT" "$ZIP" \
  --repo mschrock89/mesh \
  --target main \
  --title "Mesh ${COMMIT:0:7}" \
  --notes "Installed from the Mesh menu bar with Check for Updates."

echo "Published Mesh ${COMMIT:0:7}. Other Macs can use Check for Updates."
