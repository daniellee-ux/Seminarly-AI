#!/usr/bin/env bash
# Offline tests for release names and native/universal architecture validation.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib/package-architecture.sh

fail() { echo "FAIL: $*" >&2; exit 1; }
[ "$(package_architectures arm64)" = arm64 ] || fail 'Apple Silicon architecture'
[ "$(package_architectures x86_64)" = x86_64 ] || fail 'Intel architecture'
[ "$(package_architectures universal)" = 'arm64 x86_64' ] || fail 'universal architectures'
[ "$(package_dmg_name arm64)" = Seminarly-AppleSilicon.dmg ] || fail 'Apple Silicon name'
[ "$(package_dmg_name x86_64)" = Seminarly-Intel.dmg ] || fail 'Intel name'
[ "$(package_dmg_name universal)" = Seminarly.dmg ] || fail 'legacy update link'
if package_architectures invalid >/dev/null 2>&1; then fail 'unknown architecture'; fi
if package_dmg_name invalid >/dev/null 2>&1; then fail 'unknown package'; fi
if package_verify_architectures /nonexistent/runtime arm64 >/dev/null 2>&1; then fail 'missing executable'; fi
bash scripts/package-app.sh --help >/dev/null || fail 'packaging help'
if bash scripts/package-app.sh --arch invalid >/dev/null 2>&1; then fail 'invalid CLI architecture'; fi
if bash scripts/package-app.sh --unexpected >/dev/null 2>&1; then fail 'invalid CLI option'; fi

# A tiny fixture, built locally, checks that a native package cannot silently
# contain a universal (twice-as-large) executable. No signing or network needed.
PACKAGE_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/seminarly-package-test.XXXXXX")"
trap 'rm -rf -- "$PACKAGE_TEST_DIR"' EXIT
for arch in arm64 x86_64; do
  printf 'int main(void) { return 0; }\n' | xcrun clang -x c - -arch "$arch" -o "$PACKAGE_TEST_DIR/$arch"
  package_verify_architectures "$PACKAGE_TEST_DIR/$arch" "$arch" || fail "$arch rejected"
  if package_verify_architectures "$PACKAGE_TEST_DIR/$arch" universal >/dev/null 2>&1; then
    fail 'thin executable accepted as universal'
  fi
done
lipo -create "$PACKAGE_TEST_DIR/arm64" "$PACKAGE_TEST_DIR/x86_64" -output "$PACKAGE_TEST_DIR/universal"
package_verify_architectures "$PACKAGE_TEST_DIR/universal" universal || fail 'universal rejected'
if package_verify_architectures "$PACKAGE_TEST_DIR/universal" arm64 >/dev/null 2>&1; then
  fail 'universal executable accepted in native package'
fi
if package_verify_architectures "$PACKAGE_TEST_DIR/arm64" x86_64 >/dev/null 2>&1; then
  fail 'wrong native architecture accepted'
fi
echo 'Package architecture tests passed.'
