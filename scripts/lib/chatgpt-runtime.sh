#!/usr/bin/env bash
# Pinned official upstream artifacts. Upgrade deliberately, then run the actual
# App Server smoke and auth tests before shipping a new version.
CHATGPT_RUNTIME_VERSION=0.156.1
CHATGPT_RUNTIME_REVISION=1
# OpenAI's release publisher mirrors the same checksum-verified GitHub artifacts
# here (.github/scripts/publish_r2_release.py in the pinned upstream source).
CHATGPT_RUNTIME_BASE_URL="https://releases.openai.com/codex/releases/${CHATGPT_RUNTIME_VERSION}"
CHATGPT_RUNTIME_SOURCE_URL="https://raw.githubusercontent.com/openai/codex/rust-v${CHATGPT_RUNTIME_VERSION}"

chatgpt_runtime_member() {
  case "$1" in
    arm64) printf '%s\n' codex-app-server-aarch64-apple-darwin ;;
    x86_64) printf '%s\n' codex-app-server-x86_64-apple-darwin ;;
    *) echo "Unsupported ChatGPT runtime architecture: $1" >&2; return 1 ;;
  esac
}

chatgpt_runtime_digest() {
  case "$1" in
    arm64) printf '%s\n' 2dc9271c793f0be7e0ffd95227b220f107fee239ebcdae39122941329d90a136 ;;
    x86_64) printf '%s\n' d686257b5ee0d8dfb8313724a71610c2c7345f5e74e495c2d2f1b15463f557ed ;;
    LICENSE) printf '%s\n' d17f227e4df5da1600391338865ce0f3055211760a36688f816941d58232d8dc ;;
    NOTICE) printf '%s\n' 9d71575ecfd9a843fc1677b0efb08053c6ba9fd686a0de1a6f5382fd3c220915 ;;
    *) return 1 ;;
  esac
}

chatgpt_verify_checksum() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  local actual
  actual="$(/usr/bin/shasum -a 256 "$1")" || return 1
  [ "${actual%% *}" = "$2" ]
}

chatgpt_extract_runtime() {
  local archive="$1" member="$2" arch="$3" output="$4" listing
  # Never unpack paths from an archive. Accept precisely the one expected member
  # and stream its bytes to a destination chosen by our build, then inspect Mach-O.
  listing="$(/usr/bin/tar -tzf "$archive")" || return 1
  if [ "$listing" != "$member" ]; then
    echo "Unexpected contents in ChatGPT runtime archive." >&2
    return 1
  fi
  /usr/bin/tar -xOzf "$archive" "$member" > "$output" || return 1
  /usr/bin/lipo "$output" -verify_arch "$arch" || return 1
  /bin/chmod 755 "$output"
}

chatgpt_fetch_verified() {
  local url="$1" destination="$2" digest="$3" staging="$4"
  if chatgpt_verify_checksum "$destination" "$digest"; then return 0; fi
  # An invalid cache is not executed. Only replace it after a fresh download has
  # passed the source-controlled checksum; partial downloads stay in staging.
  local download
  download="$(/usr/bin/mktemp "$staging/download.XXXXXX")" || return 1
  /usr/bin/curl --fail --location --silent --show-error --retry 2 \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 20 --max-time 600 --output "$download" "$url" || return 1
  if ! chatgpt_verify_checksum "$download" "$digest"; then
    echo "ChatGPT runtime download failed its SHA-256 check." >&2
    return 1
  fi
  /bin/mv -f "$download" "$destination"
}
