#!/usr/bin/env bash
# Offline integrity/packaging tests. No credentials or upstream downloads.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib/chatgpt-runtime.sh
TEST_RUNTIME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/seminarly-runtime-test.XXXXXX")"
trap 'rm -rf -- "$TEST_RUNTIME_DIR"' EXIT

test_fail() { echo "FAIL: $*" >&2; exit 1; }
[ "$(chatgpt_runtime_member arm64)" = codex-app-server-aarch64-apple-darwin ] || test_fail 'arm64 mapping'
[ "$(chatgpt_runtime_member x86_64)" = codex-app-server-x86_64-apple-darwin ] || test_fail 'Intel mapping'
if chatgpt_runtime_member unknown >/dev/null 2>&1; then test_fail 'unknown architecture accepted'; fi
for key in arm64 x86_64 LICENSE NOTICE; do
  digest="$(chatgpt_runtime_digest "$key")"
  [[ "$digest" =~ ^[a-f0-9]{64}$ ]] || test_fail "invalid digest for $key"
done

printf 'safe fixture' > "$TEST_RUNTIME_DIR/fixture"
digest="$(shasum -a 256 "$TEST_RUNTIME_DIR/fixture")"
digest="${digest%% *}"
chatgpt_verify_checksum "$TEST_RUNTIME_DIR/fixture" "$digest" || test_fail 'valid checksum rejected'
if chatgpt_verify_checksum "$TEST_RUNTIME_DIR/fixture" "$(chatgpt_runtime_digest arm64)"; then test_fail 'checksum mismatch accepted'; fi
ln -s "$TEST_RUNTIME_DIR/fixture" "$TEST_RUNTIME_DIR/link"
if chatgpt_verify_checksum "$TEST_RUNTIME_DIR/link" "$digest"; then test_fail 'symlink cache accepted'; fi

cp /usr/bin/true "$TEST_RUNTIME_DIR/runtime"
fixture_archs="$(lipo -archs "$TEST_RUNTIME_DIR/runtime")"
fixture_arch="${fixture_archs%% *}"
tar -czf "$TEST_RUNTIME_DIR/valid.tar.gz" -C "$TEST_RUNTIME_DIR" runtime
chatgpt_extract_runtime "$TEST_RUNTIME_DIR/valid.tar.gz" runtime "$fixture_arch" "$TEST_RUNTIME_DIR/extracted" || test_fail 'valid Mach-O rejected'
[ -x "$TEST_RUNTIME_DIR/extracted" ] || test_fail 'missing executable bit'
if chatgpt_extract_runtime "$TEST_RUNTIME_DIR/valid.tar.gz" other "$fixture_arch" "$TEST_RUNTIME_DIR/unexpected" >/dev/null 2>&1; then
  test_fail 'unexpected archive member accepted'
fi
[ ! -e "$TEST_RUNTIME_DIR/unexpected" ] || test_fail 'unexpected member was extracted'
tar -czf "$TEST_RUNTIME_DIR/extra.tar.gz" -C "$TEST_RUNTIME_DIR" runtime fixture
if chatgpt_extract_runtime "$TEST_RUNTIME_DIR/extra.tar.gz" runtime "$fixture_arch" "$TEST_RUNTIME_DIR/extra" >/dev/null 2>&1; then
  test_fail 'extra archive contents accepted'
fi
tar -czf "$TEST_RUNTIME_DIR/text.tar.gz" -C "$TEST_RUNTIME_DIR" fixture
if chatgpt_extract_runtime "$TEST_RUNTIME_DIR/text.tar.gz" fixture "$fixture_arch" "$TEST_RUNTIME_DIR/not-mach-o" >/dev/null 2>&1; then
  test_fail 'non-Mach-O accepted'
fi
if chatgpt_extract_runtime "$TEST_RUNTIME_DIR/valid.tar.gz" runtime ppc "$TEST_RUNTIME_DIR/wrong-arch" >/dev/null 2>&1; then
  test_fail 'wrong architecture accepted'
fi
echo 'ChatGPT runtime packaging tests passed.'
