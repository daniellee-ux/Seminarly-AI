#!/usr/bin/env bash
#
# package-app.sh — produce native, compressed, notarized Seminarly installers.
#
# Pipeline: xcodegen → archive (Release, hardened runtime, Developer ID) →
# export signed .app → build + Developer-ID sign .dmg (drag-to-Applications) →
# notarize → staple → verify.
#
# The archive also builds + embeds the bundled `seminarly-cli` (a target dependency
# of the app) into Contents/Helpers, code-signed with hardened runtime alongside the
# app — so it is notarized for free. No separate CLI build step is needed.
#
# Run from the repo root: ./scripts/package-app.sh [--arch arm64|x86_64|universal|all]
# Default: both native installers plus Seminarly.dmg for older update clients.
# Each invocation uses a fresh output directory; prior releases are never removed.
#
# Prerequisites (one-time):
#   1. A "Developer ID Application" certificate in your login keychain.
#   2. Notary credentials — EITHER (preferred, fully headless):
#        an App Store Connect API key, via NOTARY_KEY / NOTARY_KEY_ID / NOTARY_ISSUER
#        env vars, or auto-discovered from the `asc` CLI store (~/.asc, active account);
#      OR a notarytool keychain profile (default: seminarly-notary):
#        xcrun notarytool store-credentials seminarly-notary \
#          --apple-id "<your-apple-id-email>" --team-id <your-team-id>
#      Note: keychain-profile notarization can fail from non-interactive shells (the
#      credential's keychain is session-bound); the API key avoids that entirely.
#
set -euo pipefail

# Always run from the repo root (this script lives in <root>/scripts/).
cd "$(dirname "$0")/.."
# shellcheck source=lib/signing-identity.sh
source scripts/lib/signing-identity.sh
source scripts/lib/package-architecture.sh

PACKAGE_TARGET=all
if [ "$#" -eq 1 ] && [ "$1" = --runtime-only ]; then
  PACKAGE_TARGET=runtime
elif [ "$#" -eq 1 ] && { [ "$1" = --help ] || [ "$1" = -h ]; }; then
  echo 'Usage: scripts/package-app.sh [--arch arm64|x86_64|universal|all]'
  echo 'Default: native Apple Silicon + Intel installers, and a universal legacy update asset.'
  echo 'Use --runtime-only with CHATGPT_RUNTIME_RELEASE_TAG to prepare signed first-use components.'
  exit 0
elif [ "$#" -eq 2 ] && [ "$1" = --arch ]; then
  PACKAGE_TARGET="$2"
elif [ "$#" -ne 0 ]; then
  echo 'Usage: scripts/package-app.sh [--arch arm64|x86_64|universal|all]' >&2
  exit 1
fi
case "$PACKAGE_TARGET" in
  runtime) PACKAGE_VARIANTS=() ;;
  all) PACKAGE_VARIANTS=(arm64 x86_64 universal) ;;
  arm64|x86_64|universal) PACKAGE_VARIANTS=("$PACKAGE_TARGET") ;;
  *) echo "Unsupported package architecture: $PACKAGE_TARGET" >&2; exit 1 ;;
esac

SCHEME="Seminarly"
PROJECT="Seminarly.xcodeproj"
CONFIG="Release"
APP_NAME="Seminarly"
SIGN_ID_NAME="Developer ID Application"
NOTARY_PROFILE="${NOTARY_PROFILE:-seminarly-notary}"

# Capture once, then resolve both the team and the exact identity from the same
# snapshot. Piping `security` into an early-exiting grep can SIGPIPE the writer;
# under pipefail that turns a successful match into an intermittent failure.
if ! IDENTITIES="$(LC_ALL=C security find-identity -v -p codesigning 2>/dev/null)"; then
  echo "✗ Could not query code-signing identities from the keychain." >&2
  exit 1
fi

# Team ID: $DEVELOPMENT_TEAM if set, else auto-detected from your Developer ID cert
# (nothing hardcoded — bring your own signing identity).
if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
  TEAM_ID="$DEVELOPMENT_TEAM"
elif ! TEAM_ID="$(resolve_developer_id_application_team "$IDENTITIES")"; then
  exit 1
fi

# --- notary auth: App Store Connect API key (headless), else keychain profile ----
# Honour explicit env vars first; otherwise auto-discover from the `asc` CLI store.
ASC_DIR="${ASC_DIR:-$HOME/.asc}"
NOTARY_KEY="${NOTARY_KEY:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER="${NOTARY_ISSUER:-}"
if [ -z "$NOTARY_KEY_ID" ] && [ -f "$ASC_DIR/credentials.json" ]; then
  eval "$(ASC_DIR="$ASC_DIR" python3 - <<'PY' 2>/dev/null || true
import json, os
d = json.load(open(os.path.join(os.environ["ASC_DIR"], "credentials.json")))
a = d.get("accounts")
acct = a.get(d.get("active")) if isinstance(a, dict) else None
if acct:
    kid, iss = acct.get("keyID", ""), acct.get("issuerID", "")
    p8 = os.path.join(os.environ["ASC_DIR"], "AuthKey_%s.p8" % kid)
    print("NOTARY_KEY_ID=%r" % kid)
    print("NOTARY_ISSUER=%r" % iss)
    if os.path.exists(p8):
        print("NOTARY_KEY=%r" % p8)
PY
)"
fi
if [ -n "$NOTARY_KEY" ] && [ -n "$NOTARY_KEY_ID" ] && [ -n "$NOTARY_ISSUER" ]; then
  USE_API_KEY=true
else
  USE_API_KEY=false
fi

note() { printf "\n▸ %s\n" "$*"; }

# --- preflight ---------------------------------------------------------------
if ! SIGN_CERT_HASH="$(resolve_developer_id_application_hash "$TEAM_ID" "$IDENTITIES")"; then
  echo "  Create or remove certificates in Xcode → Settings → Accounts → Manage Certificates." >&2
  exit 1
fi
echo "▸ Signing identity: $SIGN_ID_NAME (Team $TEAM_ID, exact certificate selected)"
if [ "$USE_API_KEY" = true ]; then
  echo "▸ Notary auth: App Store Connect API key ($NOTARY_KEY_ID, headless)"
elif xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "▸ Notary auth: keychain profile '$NOTARY_PROFILE'"
else
  echo "✗ No notary credentials. Provide an App Store Connect API key (~/.asc, or" >&2
  echo "  NOTARY_KEY / NOTARY_KEY_ID / NOTARY_ISSUER), or create a keychain profile:" >&2
  echo "    xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <id> --team-id $TEAM_ID" >&2
  exit 1
fi

note "Regenerating Xcode project"
xcodegen generate

mkdir -p build/packages
PACKAGE_OUTPUT="$(mktemp -d "$PWD/build/packages/release.XXXXXX")"
PACKAGE_ARTIFACTS=()

notarize_path() {
  if [ "$USE_API_KEY" = true ]; then
    xcrun notarytool submit "$1" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  else
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
  fi
}

if [ "$PACKAGE_TARGET" = runtime ]; then
  source scripts/lib/package-chatgpt-runtime.sh
  package_chatgpt_runtime "$PACKAGE_OUTPUT" "${CHATGPT_RUNTIME_RELEASE_TAG:?Set the future release tag, e.g. v0.1.12}" "$TEAM_ID" "$SIGN_CERT_HASH"
  exit 0
fi

source scripts/lib/sparkle-tools.sh
resolve_sparkle_tools
export SPARKLE_BIN
# Fail before expensive builds if this machine cannot sign updates for this app.
SPARKLE_PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" --account "${SPARKLE_ACCOUNT:-ai.seminarly.updates}" -p)"
[ "$SPARKLE_PUBLIC_KEY" = "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Sources/Info.plist)" ] || {
  echo 'Sparkle signing key does not match Sources/Info.plist.' >&2; exit 1;
}
# Stage pinned optional downloads alongside the installers. For the first release
# supply CHATGPT_COMPONENT_DIR from --runtime-only; later releases can fetch the
# exact immutable assets already published. Never silently re-sign/re-pin them.
python3 scripts/stage-runtime-assets.py Sources/Resources/ChatGPTRuntime.json "$PACKAGE_OUTPUT" "${CHATGPT_COMPONENT_DIR:-}"

DMGVENV="$PWD/.dmgvenv"
if [ ! -x "$DMGVENV/bin/dmgbuild" ]; then
  python3 -m venv "$DMGVENV"
  "$DMGVENV/bin/pip" install --quiet --upgrade pip dmgbuild pillow
fi

package_variant() {
local variant="$1" archs
archs="$(package_architectures "$variant")"
local BUILD_DIR="$PACKAGE_OUTPUT/$variant"
local ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
local EXPORT_DIR="$BUILD_DIR/export"
local APP_PATH="$EXPORT_DIR/$APP_NAME.app"
local DMG_PATH="$PACKAGE_OUTPUT/$(package_dmg_name "$variant")"
local OPTS_PLIST="$BUILD_DIR/ExportOptions.plist"
local HELPER HELPER_SIG CHATGPT_HELPER CHATGPT_SIG CHATGPT_NOTICE

note "Archiving $variant ($CONFIG, hardened runtime, Developer ID)"
mkdir -p "$BUILD_DIR"
xcodebuild archive \
  -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
  -archivePath "$ARCHIVE" -destination 'generic/platform=macOS' \
  ARCHS="$archs" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_CERT_HASH" DEVELOPMENT_TEAM="$TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES -quiet

note "Exporting signed .app"
plutil -create xml1 "$OPTS_PLIST"
plutil -insert method -string developer-id "$OPTS_PLIST"
plutil -insert teamID -string "$TEAM_ID" "$OPTS_PLIST"
plutil -insert signingStyle -string manual "$OPTS_PLIST"
plutil -insert signingCertificate -string "$SIGN_CERT_HASH" "$OPTS_PLIST"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" -exportOptionsPlist "$OPTS_PLIST" -quiet

package_verify_architectures "$APP_PATH/Contents/MacOS/$APP_NAME" "$variant"
note "Verifying embedded seminarly-cli (present + hardened, fail fast before notarizing)"
HELPER="$APP_PATH/Contents/Helpers/seminarly-cli"
if [ ! -x "$HELPER" ]; then
  echo "✗ Embedded CLI missing at Contents/Helpers/seminarly-cli." >&2
  echo "  Check the 'seminarly-cli' embed dependency on the Seminarly target in project.yml." >&2
  exit 1
fi
HELPER_SIG="$(codesign -dv --verbose=4 "$HELPER" 2>&1 || true)"
if ! grep -q 'flags=.*runtime' <<<"$HELPER_SIG"; then
  echo "✗ Embedded CLI lacks hardened runtime — notarization would reject it." >&2
  exit 1
fi
codesign --verify --strict "$HELPER"
package_verify_architectures "$HELPER" "$variant"
echo "  ✓ Contents/Helpers/seminarly-cli — Developer ID, hardened, valid"

note "Verifying small base app and pinned ChatGPT manifest"
CHATGPT_HELPER="$APP_PATH/Contents/Helpers/seminarly-chatgpt"
[ ! -e "$CHATGPT_HELPER" ] || {
  echo 'Legacy ChatGPT runtime unexpectedly remains inside base app.' >&2; exit 1;
}
if ! cmp -s Sources/Resources/ChatGPTRuntime.json "$APP_PATH/Contents/Resources/ChatGPTRuntime.json"; then
  echo 'ChatGPT manifest does not match the source pins.' >&2
  exit 1
fi
for CHATGPT_NOTICE in LICENSE NOTICE ORIGIN.txt; do
  test -s "$APP_PATH/Contents/Resources/ThirdParty/OpenAICodex/$CHATGPT_NOTICE"
done
codesign --verify --deep --strict "$APP_PATH/Contents/Frameworks/Sparkle.framework"
echo '  ✓ Optional ChatGPT runtime pins, attribution, and Sparkle framework present'

note "Building styled DMG (dmgbuild — headless, no Finder/AppleScript)"
"$DMGVENV/bin/dmgbuild" -s scripts/dmg-settings.py \
  -D app="$APP_PATH" -D bg="$PWD/scripts/dmg-assets/background.png" \
  "$APP_NAME" "$DMG_PATH"

note "Signing DMG with Developer ID"
# Notarization alone does not give the disk image a usable primary signature.
# The DMG was freshly created above, so fail rather than replace a signature.
# Use the preflight-resolved hash: standalone codesign does not consult TEAM_ID,
# and a partial common name fails when more than one certificate matches.
codesign --sign "$SIGN_CERT_HASH" --timestamp "$DMG_PATH"
codesign --verify --strict --verbose=2 "$DMG_PATH"

note "Notarizing (a few minutes — Apple inspects the app inside)"
notarize_path "$DMG_PATH"

note "Stapling the ticket"
xcrun stapler staple "$DMG_PATH"

note "Verifying"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --verify --strict --verbose=2 "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature -vv "$DMG_PATH"
hdiutil verify "$DMG_PATH"

if [ "$variant" != universal ]; then
  bash scripts/generate-update-feed.sh "$PACKAGE_OUTPUT" "$variant" "$APP_PATH"
fi

note "Done → $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
PACKAGE_ARTIFACTS+=("$DMG_PATH")
}

for PACKAGE_VARIANT in "${PACKAGE_VARIANTS[@]}"; do
  package_variant "$PACKAGE_VARIANT"
done

note "Verified installers → $PACKAGE_OUTPUT"
shasum -a 256 "${PACKAGE_ARTIFACTS[@]}"
echo 'Publish the native + legacy DMGs, appcast-*.xml, *.delta, and pinned ChatGPTConnection-*.tar.xz assets together.'
echo 'Keep update-history locally; set SPARKLE_PREVIOUS_DIR to it for the next release.'
