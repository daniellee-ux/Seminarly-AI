#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
case "$MODE" in
  run|--build-only|--debug|--logs|--telemetry|--verify) ;;
  *) echo "Usage: $0 [--build-only|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${SEMINARLY_DERIVED_DATA:-$PROJECT_ROOT/.build/DerivedData}"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/Seminarly.app"
cd "$PROJECT_ROOT"

if [[ "$MODE" != "--build-only" ]]; then
  # Use normal application termination so an active recording can finish saving.
  # Never SIGKILL a session merely to relaunch a development build.
  swift - <<'SWIFT'
import AppKit
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "ai.seminarly.Seminarly")
for app in apps { app.terminate() }
let deadline = Date().addingTimeInterval(120)
while apps.contains(where: { !$0.isTerminated }) && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
}
if apps.contains(where: { !$0.isTerminated }) {
    fputs("Seminarly is still saving or has declined to quit. Relaunch cancelled.\n", stderr)
    exit(1)
}
SWIFT
fi

xcodegen generate
xcodebuild -project Seminarly.xcodeproj -scheme Seminarly \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$PROJECT_ROOT/.build/DerivedData/SourcePackages" \
  -disableAutomaticPackageResolution -skipPackageUpdates build

[[ "$MODE" == "--build-only" ]] && exit 0

if [[ "$MODE" == "--debug" ]]; then
  exec lldb -- "$APP_BUNDLE/Contents/MacOS/Seminarly"
fi

/usr/bin/open -n "$APP_BUNDLE"
case "$MODE" in
  --logs)
    exec /usr/bin/log stream --info --style compact --predicate 'process == "Seminarly"'
    ;;
  --telemetry)
    exec /usr/bin/log stream --info --style compact --predicate 'subsystem == "ai.seminarly.Seminarly"'
    ;;
  --verify)
    sleep 2
    pgrep -f "$APP_BUNDLE/Contents/MacOS/Seminarly" >/dev/null
    ;;
esac
