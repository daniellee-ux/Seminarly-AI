#!/usr/bin/env bash
# Optional local integration test. Uses disposable signed fixture apps, not any
# installed Seminarly or meeting database. Needs resolved Sparkle tools + Keychain key.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib/package-architecture.sh
source scripts/lib/sparkle-tools.sh
resolve_sparkle_tools
export SPARKLE_BIN
: "${SPARKLE_TEST_SIGN_IDENTITY:?Set a Developer ID identity for compatible fixture signatures}"
SMOKE_ROOT="$(mktemp -d /private/tmp/seminarly-delta-smoke.XXXXXX)"
echo "Disposable delta fixtures: $SMOKE_ROOT"
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Sources/Info.plist)"
FRAMEWORK="$(dirname "$SPARKLE_BIN")/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[ -d "$FRAMEWORK" ] || { echo 'Sparkle framework not found.' >&2; exit 1; }
for arch in arm64 x86_64; do
  for build in 1 2; do
    output="$SMOKE_ROOT/$build"
    app="$output/$arch/Seminarly.app"
    contents="$app/Contents"
    mkdir -p "$contents/MacOS" "$contents/Frameworks"
    # Generated fixture binary, not application source. Never launched.
    printf 'int main(void) { return %s; }\n' "$build" | xcrun clang -x c - -arch "$arch" -o "$contents/MacOS/Seminarly"
    ditto "$FRAMEWORK" "$contents/Frameworks/Sparkle.framework"
    plist="$contents/Info.plist"
    plutil -create xml1 "$plist"
    plutil -insert CFBundleIdentifier -string ai.seminarly.delta-fixture "$plist"
    plutil -insert CFBundleExecutable -string Seminarly "$plist"
    plutil -insert CFBundleName -string Seminarly "$plist"
    plutil -insert CFBundlePackageType -string APPL "$plist"
    plutil -insert CFBundleVersion -string "$build" "$plist"
    plutil -insert CFBundleShortVersionString -string "99.0.$build" "$plist"
    plutil -insert LSMinimumSystemVersion -string 14.4 "$plist"
    plutil -insert SUFeedURL -string "https://github.com/daniellee-ux/Seminarly-AI/releases/latest/download/appcast-$arch.xml" "$plist"
    plutil -insert SUPublicEDKey -string "$PUBLIC_KEY" "$plist"
    plutil -insert SURequireSignedFeed -bool YES "$plist"
    codesign --force --sign "$SPARKLE_TEST_SIGN_IDENTITY" --options runtime --timestamp "$app"
    hdiutil create -quiet -srcfolder "$app" -volname 'Seminarly Delta Fixture' -format ULMO "$output/$(package_dmg_name "$arch")"
    if [ "$build" = 1 ]; then
      bash scripts/generate-update-feed.sh "$output" "$arch" "$app"
    else
      SPARKLE_PREVIOUS_DIR="$SMOKE_ROOT/1/update-history" bash scripts/generate-update-feed.sh "$output" "$arch" "$app"
    fi
  done
  delta="$SMOKE_ROOT/2/$arch-Seminarly2-1.delta"
  [ -s "$delta" ] || { echo 'Expected a delta between compatible fixture versions.' >&2; exit 1; }
  "$SPARKLE_BIN/BinaryDelta" apply "$SMOKE_ROOT/1/$arch/Seminarly.app" "$SMOKE_ROOT/patched-$arch.app" "$delta"
  codesign --verify --deep --strict "$SMOKE_ROOT/patched-$arch.app"
  diff -qr "$SMOKE_ROOT/2/$arch/Seminarly.app" "$SMOKE_ROOT/patched-$arch.app"
done
echo 'PASS: both architecture feeds, Ed25519 verification, full fallback enclosures, delta generation/application, and patched code signatures.'
echo "Fixture artifacts retained for inspection in $SMOKE_ROOT (not production releases)."
