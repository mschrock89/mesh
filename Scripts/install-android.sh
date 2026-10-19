#!/bin/bash
# Install Mesh on a connected Android phone or tablet.
# On the tablet: Settings → About tablet → Software information → tap Build number
# seven times, then Settings → Developer options → USB debugging.
# Usage: Scripts/install-android.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/android"

if [[ -z "${JAVA_HOME:-}" || ! -x "${JAVA_HOME}/bin/java" ]]; then
  if /usr/libexec/java_home >/dev/null 2>&1; then
    export JAVA_HOME="$(/usr/libexec/java_home)"
  elif [[ -x "/tmp/mesh-tools/jdk/Contents/Home/bin/java" ]]; then
    export JAVA_HOME="/tmp/mesh-tools/jdk/Contents/Home"
  fi
fi
if [[ ! -x "${JAVA_HOME:-}/bin/java" ]]; then
  echo "Mesh needs a JDK. Install Android Studio, or point JAVA_HOME at a JDK 17."
  exit 1
fi

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
if [[ ! -f local.properties ]]; then
  printf 'sdk.dir=%s\n' "$SDK" > local.properties
fi
if [[ -x "$SDK/platform-tools/adb" ]]; then
  export PATH="$SDK/platform-tools:$PATH"
fi

./gradlew :app:installRelease
echo "Installed Mesh. Open it on the tablet and keep it on the same Wi-Fi as the Mac."
