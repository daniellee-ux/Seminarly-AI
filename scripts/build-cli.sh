#!/usr/bin/env bash
# Build the seminarly-cli binary and drop it at ./Tools/seminarly-cli.
# Idempotent; safe to re-run after pulling.

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen not installed. Install with 'brew install xcodegen'." >&2
    exit 1
fi

xcodegen generate

xcodebuild \
    -project Seminarly.xcodeproj \
    -scheme seminarly-cli \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath .build/cli \
    build \
    | xcbeautify --quiet 2>/dev/null || \
xcodebuild \
    -project Seminarly.xcodeproj \
    -scheme seminarly-cli \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath .build/cli \
    build

BINARY_PATH=".build/cli/Build/Products/Release/seminarly-cli"

if [[ -z "${BINARY_PATH:-}" ]]; then
    echo "error: could not locate seminarly-cli after build" >&2
    exit 1
fi

mkdir -p Tools
cp "$BINARY_PATH" Tools/seminarly-cli
chmod +x Tools/seminarly-cli

echo
echo "Built: $(pwd)/Tools/seminarly-cli"
Tools/seminarly-cli --version
