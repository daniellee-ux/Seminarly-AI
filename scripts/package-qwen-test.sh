#!/usr/bin/env bash
# Local Apple Silicon test app; no release publication or notarization.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ "$(uname -m)" == arm64 ]] || { echo 'Qwen ASR requires Apple Silicon.' >&2; exit 1; }
APP_NAME='Seminarly Qwen Test'
DERIVED="$ROOT/.build/DerivedData"
mkdir -p "$ROOT/build"
OUTPUT="$(mktemp -d "$ROOT/build/qwen-test.XXXXXX")"
xcodegen generate
xcodebuild -project Seminarly.xcodeproj -scheme Seminarly -configuration QwenTest \
  -destination 'generic/platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  -derivedDataPath "$DERIVED" -clonedSourcePackagesDirPath "$DERIVED/SourcePackages" \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual build
mkdir -p "$OUTPUT/payload"
ditto "$DERIVED/Build/Products/QwenTest/$APP_NAME.app" "$OUTPUT/payload/$APP_NAME.app"
codesign --verify --deep --strict "$OUTPUT/payload/$APP_NAME.app"
ln -s /Applications "$OUTPUT/payload/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$OUTPUT/payload" \
  -format UDZO "$OUTPUT/Seminarly-Qwen-Test-arm64.dmg"
hdiutil verify "$OUTPUT/Seminarly-Qwen-Test-arm64.dmg"
echo "Test app: $OUTPUT/payload/$APP_NAME.app"
echo "Disk image: $OUTPUT/Seminarly-Qwen-Test-arm64.dmg"
