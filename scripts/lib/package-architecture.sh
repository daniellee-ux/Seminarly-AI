#!/usr/bin/env bash
# Keep distribution names in sync with UpdateChecker.downloadURL(for:architecture:).

package_architectures() {
  case "$1" in
    arm64) printf '%s\n' arm64 ;;
    x86_64) printf '%s\n' x86_64 ;;
    universal) printf '%s\n' 'arm64 x86_64' ;;
    *) echo "Unsupported package architecture: $1" >&2; return 1 ;;
  esac
}

package_dmg_name() {
  case "$1" in
    arm64) printf '%s\n' Seminarly-AppleSilicon.dmg ;;
    x86_64) printf '%s\n' Seminarly-Intel.dmg ;;
    # Releases must retain this asset for update links in v0.1.11 and earlier.
    universal) printf '%s\n' Seminarly.dmg ;;
    *) echo "Unsupported package architecture: $1" >&2; return 1 ;;
  esac
}

package_verify_architectures() {
  local executable="$1" variant="$2" actual expected
  actual="$(/usr/bin/lipo -archs "$executable")" || return 1
  expected="$(package_architectures "$variant")" || return 1
  actual="$(printf '%s\n' "$actual" | tr ' ' '\n' | LC_ALL=C sort)"
  expected="$(printf '%s\n' "$expected" | tr ' ' '\n' | LC_ALL=C sort)"
  if [ "$actual" != "$expected" ]; then
    echo "Unexpected architectures in $executable (wanted $variant)." >&2
    return 1
  fi
}
