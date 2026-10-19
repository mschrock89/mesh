#!/bin/bash
# Produce a Developer ID signed and Apple-notarized disk image that can be
# emailed to another Mac without a Gatekeeper warning.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEAM_ID="${MESH_TEAM_ID:-L8G6NP7YZV}"
NOTARY_PROFILE="${MESH_NOTARY_PROFILE:-mesh-notary}"
IDENTITY="${MESH_SIGNING_IDENTITY:-Developer ID Application}"
DERIVED_DATA="${MESH_DERIVED_DATA:-$ROOT/build/distribution}"
OUTPUT="${1:-$ROOT/build/Mesh.dmg}"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<EOF
Usage: $(basename "$0") [output.dmg]

Builds, signs, notarizes, and staples a shareable Mesh disk image.

Required one-time setup:
  1. In Xcode > Settings > Accounts > Manage Certificates, create a
     "Developer ID Application" certificate for team $TEAM_ID.
  2. Create an app-specific password at https://appleid.apple.com.
  3. Save notarization credentials in Keychain:

     xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
       --apple-id "YOUR_APPLE_ID" \\
       --team-id "$TEAM_ID" \\
       --password "YOUR_APP_SPECIFIC_PASSWORD"

Optional environment variables:
  MESH_TEAM_ID             Apple developer team (default: $TEAM_ID)
  MESH_NOTARY_PROFILE      notarytool Keychain profile (default: $NOTARY_PROFILE)
  MESH_SIGNING_IDENTITY    exact Developer ID identity or SHA-1
  MESH_DERIVED_DATA        Xcode build directory
EOF
  exit 0
fi

if ! security find-identity -v -p codesigning |
  grep -F '"Developer ID Application:' >/dev/null; then
  cat >&2 <<EOF
No Developer ID Application certificate is installed.

In Xcode > Settings > Accounts, select team $TEAM_ID, open Manage
Certificates, and add "Developer ID Application". This requires an active
Apple Developer Program membership. Then run this script again.
EOF
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
rm -rf "$DERIVED_DATA"

xcodebuild \
  -project "$ROOT/Mesh.xcodeproj" \
  -scheme Mesh \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  build

APP="$DERIVED_DATA/Build/Products/Release/Mesh.app"
if [[ ! -d "$APP" ]]; then
  echo "Xcode did not produce $APP" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Mesh.app"
ln -s /Applications "$STAGE/Applications"

UNNOTARIZED="$WORK/Mesh.dmg"
hdiutil create \
  -volname Mesh \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$UNNOTARIZED"

echo "Submitting Mesh to Apple for notarization…"
NOTARY_RESULT="$WORK/notary-result.json"
xcrun notarytool submit "$UNNOTARIZED" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait \
  --output-format json >"$NOTARY_RESULT"
cat "$NOTARY_RESULT"

NOTARY_STATUS="$(plutil -extract status raw -o - "$NOTARY_RESULT")"
if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
  NOTARY_ID="$(plutil -extract id raw -o - "$NOTARY_RESULT")"
  xcrun notarytool log "$NOTARY_ID" --keychain-profile "$NOTARY_PROFILE" || true
  echo "Apple rejected the notarization submission." >&2
  exit 1
fi

xcrun stapler staple "$UNNOTARIZED"
xcrun stapler validate "$UNNOTARIZED"
spctl --assess --type open --context context:primary-signature --verbose=2 "$UNNOTARIZED"

ditto "$UNNOTARIZED" "$OUTPUT"
echo "Shareable copy created at: $OUTPUT"
