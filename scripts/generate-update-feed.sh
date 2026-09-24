#!/usr/bin/env bash
# Build signed per-architecture feeds and deltas, without publishing or modifying
# previous release artifacts. Keep output/update-history for the next invocation.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/package-architecture.sh
source scripts/lib/sparkle-tools.sh
[ "$#" -eq 3 ] || { echo 'Usage: generate-update-feed.sh OUTPUT ARCH APP_PATH' >&2; exit 1; }
OUTPUT="$1"; VARIANT="$2"; APP_PATH="$3"
case "$VARIANT" in arm64|x86_64) ;; *) echo 'Feeds require a native architecture.' >&2; exit 1 ;; esac
resolve_sparkle_tools
ACCOUNT="${SPARKLE_ACCOUNT:-ai.seminarly.updates}"
PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" --account "$ACCOUNT" -p)"
EMBEDDED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP_PATH/Contents/Info.plist")"
[ "$PUBLIC_KEY" = "$EMBEDDED_KEY" ] || { echo 'Sparkle signing key does not match the app.' >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
DMG_NAME="$(package_dmg_name "$VARIANT")"
HISTORY="$OUTPUT/update-history/$VARIANT"
mkdir -p "$HISTORY"
if [ -n "${SPARKLE_PREVIOUS_DIR:-}" ]; then
  [ -d "$SPARKLE_PREVIOUS_DIR/$VARIANT" ] || { echo "Missing previous $VARIANT history." >&2; exit 1; }
  ditto "$SPARKLE_PREVIOUS_DIR/$VARIANT" "$HISTORY"
fi
NEW_ARCHIVE="$HISTORY/Seminarly-$VERSION-$BUILD-$VARIANT.dmg"
[ ! -e "$NEW_ARCHIVE" ] || { echo 'Build already exists in history. Increment CFBundleVersion before releasing.' >&2; exit 1; }
cp "$OUTPUT/$DMG_NAME" "$NEW_ARCHIVE"
PREFIX="https://github.com/daniellee-ux/Seminarly-AI/releases/download/v$VERSION/"
"$SPARKLE_BIN/generate_appcast" --account "$ACCOUNT" --versions "$BUILD" --maximum-deltas 3 \
  --delta-compression lzma --download-url-prefix "$PREFIX" \
  --link 'https://github.com/daniellee-ux/Seminarly-AI/releases/latest' \
  -o "$HISTORY/appcast.xml" "$HISTORY"
# Sparkle names delta files after the app, not the CPU. Namespace public filenames
# so ARM and Intel deltas never collide in GitHub's flat release-asset namespace.
python3 scripts/publish-update-feed.py "$HISTORY/appcast.xml" "$OUTPUT" "$VARIANT" "$PREFIX" "$DMG_NAME"
"$SPARKLE_BIN/sign_update" --account "$ACCOUNT" "$OUTPUT/appcast-$VARIANT.xml"
"$SPARKLE_BIN/sign_update" --account "$ACCOUNT" --verify "$OUTPUT/appcast-$VARIANT.xml"
python3 scripts/verify-update-assets.py "$OUTPUT/appcast-$VARIANT.xml" "$OUTPUT" "$PREFIX" "$SPARKLE_BIN" "$ACCOUNT"
echo "Prepared signed $VARIANT feed. Preserve $OUTPUT/update-history for the next release."
