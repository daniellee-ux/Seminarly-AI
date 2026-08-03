#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/signing-identity.sh
source "$REPO_ROOT/scripts/lib/signing-identity.sh"

HASH_A="1111111111111111111111111111111111111111"
HASH_B="2222222222222222222222222222222222222222"
TEAM_A="TEAMAAAAAA"
TEAM_B="TEAMBBBBBB"

fail() {
  echo "✗ $*" >&2
  exit 1
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  [ "$actual" = "$expected" ] || fail "$message (expected '$expected', got '$actual')"
}

assert_failure() {
  local message="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "$message"
  fi
}

IDENTITIES_TWO_TEAMS="$(printf '%s\n' \
  "  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \"Apple Development: Example ($TEAM_A)\"" \
  "  2) $HASH_A \"Developer ID Application: Example A ($TEAM_A)\"" \
  "  3) $HASH_B \"Developer ID Application: Example B ($TEAM_B)\"" \
  "     3 valid identities found")"

assert_failure \
  "auto-detection must not silently choose between multiple teams" \
  resolve_developer_id_application_team "$IDENTITIES_TWO_TEAMS"

IDENTITIES_ONE_TEAM="$(printf '%s\n' \
  "  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \"Apple Development: Example ($TEAM_B)\"" \
  "  2) $HASH_B \"Developer ID Application: Example B ($TEAM_B)\"")"
assert_equal \
  "$TEAM_B" \
  "$(resolve_developer_id_application_team "$IDENTITIES_ONE_TEAM")" \
  "auto-detection should ignore non-Developer-ID identities"

# Keep enough data after the match to catch an early-exiting reader connected
# through a pipe: with `set -o pipefail`, that pattern can SIGPIPE the writer.
LARGE_TRAILING_SNAPSHOT="$IDENTITIES_ONE_TEAM
$(awk 'BEGIN { for (i = 0; i < 20000; i++) print "     unrelated identity output padding" }')"
assert_equal \
  "$TEAM_B" \
  "$(resolve_developer_id_application_team "$LARGE_TRAILING_SNAPSHOT")" \
  "team resolution should consume large snapshots without a SIGPIPE failure"

assert_equal \
  "$HASH_B" \
  "$(resolve_developer_id_application_hash "$TEAM_B" "$IDENTITIES_TWO_TEAMS")" \
  "resolution should bind the hash to the selected team"

IDENTITIES_DUPLICATE_HASH="$(printf '%s\n' \
  "  1) $HASH_A \"Developer ID Application: Example A ($TEAM_A)\"" \
  "  2) $HASH_A \"Developer ID Application: Example A ($TEAM_A)\"")"
assert_equal \
  "$HASH_A" \
  "$(resolve_developer_id_application_hash "$TEAM_A" "$IDENTITIES_DUPLICATE_HASH")" \
  "duplicate references to the same certificate should be harmless"
assert_equal \
  "$TEAM_A" \
  "$(resolve_developer_id_application_team "$IDENTITIES_DUPLICATE_HASH")" \
  "duplicate references to one team should remain unambiguous"

IDENTITIES_AMBIGUOUS="$(printf '%s\n' \
  "  1) $HASH_A \"Developer ID Application: Example A ($TEAM_A)\"" \
  "  2) $HASH_B \"Developer ID Application: Renewed A ($TEAM_A)\"")"
assert_failure \
  "two distinct certificates for one team must fail closed" \
  resolve_developer_id_application_hash "$TEAM_A" "$IDENTITIES_AMBIGUOUS"

assert_failure \
  "a team with no matching certificate must fail" \
  resolve_developer_id_application_hash "TEAMCCCCCC" "$IDENTITIES_TWO_TEAMS"

assert_failure \
  "an invalid team ID must fail" \
  resolve_developer_id_application_hash "not-a-team" "$IDENTITIES_TWO_TEAMS"

assert_failure \
  "a non-ASCII team ID must fail regardless of the caller locale" \
  env LC_ALL=en_US.UTF-8 /bin/bash -c \
    'source "$1"; resolve_developer_id_application_hash "TEAMAAAAAÉ" "$2"' \
    _ "$REPO_ROOT/scripts/lib/signing-identity.sh" "$IDENTITIES_TWO_TEAMS"

assert_failure \
  "auto-detection with no Developer ID identity must fail" \
  resolve_developer_id_application_team ""

echo "✓ signing identity resolver tests"
