#!/bin/bash
# Build Mesh for macOS and Android and publish both update assets.
# Commit and push to main first. Each device needs a GitHub token the first time.
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

if [[ -z "${JAVA_HOME:-}" || ! -x "${JAVA_HOME}/bin/java" ]]; then
  if /usr/libexec/java_home >/dev/null 2>&1; then
    export JAVA_HOME="$(/usr/libexec/java_home)"
  fi
fi
if [[ ! -x "${JAVA_HOME:-}/bin/java" ]]; then
  echo "The Android update needs a JDK. Install Android Studio or set JAVA_HOME." >&2
  exit 1
fi

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
if [[ ! -f "$ROOT/android/local.properties" ]]; then
  printf 'sdk.dir=%s\n' "$SDK" > "$ROOT/android/local.properties"
fi
"$ROOT/android/gradlew" -p "$ROOT/android" :app:assembleRelease
BUILT_APK="$ROOT/android/app/build/outputs/apk/release/app-release.apk"
if [[ ! -f "$BUILT_APK" ]]; then
  echo "Gradle did not produce $BUILT_APK." >&2
  exit 1
fi
APK="$(mktemp -d)/Mesh.apk"
cp "$BUILT_APK" "$APK"

TAG="mesh-$COMMIT"
if gh release view "$TAG" --repo mschrock89/mesh >/dev/null 2>&1; then
  gh release upload "$TAG" "$APK" --repo mschrock89/mesh --clobber
  echo "Added the Android update to existing release $TAG."
  exit 0
fi

gh release create "$TAG" "$ZIP" "$APK" \
  --repo mschrock89/mesh \
  --target main \
  --title "Mesh ${COMMIT:0:7}" \
  --notes "Installed from Mesh with Check for Updates."

echo "Published Mesh ${COMMIT:0:7}. Macs and Androids can use Check for Updates."
