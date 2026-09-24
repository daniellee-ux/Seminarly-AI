#!/usr/bin/env bash
# Override SPARKLE_BIN when using a custom DerivedData / cloned packages location.
resolve_sparkle_tools() {
  if [ -z "${SPARKLE_BIN:-}" ]; then
    local products
    products="$(xcodebuild -project Seminarly.xcodeproj -scheme Seminarly -showBuildSettings -json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["buildSettings"]["BUILD_DIR"])')" || return 1
    SPARKLE_BIN="$(dirname "$(dirname "$products")")/SourcePackages/artifacts/sparkle/Sparkle/bin"
  fi
  local tool
  for tool in generate_keys generate_appcast sign_update BinaryDelta; do
    [ -x "$SPARKLE_BIN/$tool" ] || { echo 'Set SPARKLE_BIN to the resolved Sparkle 2.10.0 bin directory.' >&2; return 1; }
  done
}
