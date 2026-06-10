#!/usr/bin/env bash
#
# package-app.sh — produce a distributable, notarized Seminarly.dmg.
#
# Pipeline: xcodegen → archive (Release, hardened runtime, Developer ID) →
# export signed .app → build .dmg (drag-to-Applications) → notarize → staple → verify.
#
# Run from the repo root:  ./scripts/package-app.sh
#
# Prerequisites (one-time):
#   1. A "Developer ID Application" certificate in your login keychain.
#   2. A notarytool keychain profile (default name: seminarly-notary), created with:
#        xcrun notarytool store-credentials seminarly-notary \
#          --apple-id "<your-apple-id-email>" --team-id ZPW87426K2
#      (it will prompt for an app-specific password from appleid.apple.com)
#
set -euo pipefail

# Always run from the repo root (this script lives in <root>/scripts/).
cd "$(dirname "$0")/.."

SCHEME="Seminarly"
PROJECT="Seminarly.xcodeproj"
CONFIG="Release"
APP_NAME="Seminarly"
TEAM_ID="ZPW87426K2"
SIGN_ID="Developer ID Application"
NOTARY_PROFILE="${NOTARY_PROFILE:-seminarly-notary}"

BUILD_DIR="build/dist"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/$APP_NAME.app"
DMG_STAGE="$BUILD_DIR/dmg-stage"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
OPTS_PLIST="$BUILD_DIR/ExportOptions.plist"

note() { printf "\n▸ %s\n" "$*"; }

# --- preflight ---------------------------------------------------------------
if ! security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
  echo "✗ No '$SIGN_ID' certificate in the keychain. Create one in Xcode → Settings → Accounts → Manage Certificates." >&2
  exit 1
fi
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "✗ notarytool profile '$NOTARY_PROFILE' not found. Create it with:" >&2
  echo "    xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <id> --team-id $TEAM_ID" >&2
  exit 1
fi

note "Regenerating Xcode project"
xcodegen generate

note "Archiving ($CONFIG, hardened runtime, Developer ID)"
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
xcodebuild archive \
  -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
  -archivePath "$ARCHIVE" -destination 'generic/platform=macOS' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_ID" DEVELOPMENT_TEAM="$TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES -quiet

note "Exporting signed .app"
cat > "$OPTS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$SIGN_ID</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" -exportOptionsPlist "$OPTS_PLIST" -quiet

note "Building styled DMG (dmgbuild — headless, no Finder/AppleScript)"
DMGVENV="$PWD/.dmgvenv"
if [ ! -x "$DMGVENV/bin/dmgbuild" ]; then
  python3 -m venv "$DMGVENV"
  "$DMGVENV/bin/pip" install --quiet --upgrade pip dmgbuild pillow
fi
rm -f "$DMG_PATH"
"$DMGVENV/bin/dmgbuild" -s scripts/dmg-settings.py \
  -D app="$PWD/$APP_PATH" -D bg="$PWD/scripts/dmg-assets/background.png" \
  "$APP_NAME" "$DMG_PATH"

note "Notarizing (a few minutes — Apple inspects the app inside)"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

note "Stapling the ticket"
xcrun stapler staple "$DMG_PATH"

note "Verifying"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type open --context context:primary-signature -v "$DMG_PATH" || true
xcrun stapler validate "$DMG_PATH"

SIZE=$(du -h "$DMG_PATH" | cut -f1)
note "Done → $DMG_PATH ($SIZE)"
echo "Next: gh release create vX.Y.Z -R daniellee-ux/Seminarly-AI \"$DMG_PATH\" --title ... --notes ..."
