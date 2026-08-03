#!/usr/bin/env bash

# Parse `security find-identity -v -p codesigning` without exposing certificate
# hashes in logs. These helpers intentionally support the Bash 3.2 shipped with
# macOS because package-app.sh is a developer/release-machine entry point.

resolve_developer_id_application_team() {
  local LC_ALL=C
  local identities="${1-}"
  local teams=""
  local team_count=0
  local selected_team=""
  local team=""

  teams="$(
    awk '
      index($0, "\"Developer ID Application:") {
        line = $0
        sub(/[[:space:]]+$/, "", line)
        if (match(line, /\([^()]+\)"$/)) {
          team = substr(line, RSTART + 1, RLENGTH - 3)
          if (length(team) == 10 && team !~ /[^A-Z0-9]/ && !seen[team]++) {
            print team
          }
        }
      }
    ' <<<"$identities"
  )"

  while IFS= read -r team; do
    [ -z "$team" ] && continue
    team_count=$((team_count + 1))
    selected_team="$team"
  done <<<"$teams"

  case "$team_count" in
    1)
      printf '%s\n' "$selected_team"
      ;;
    0)
      echo "✗ No valid 'Developer ID Application' identity in the keychain." >&2
      return 1
      ;;
    *)
      echo "✗ Developer ID identities from multiple Teams are installed." >&2
      echo "  Set DEVELOPMENT_TEAM explicitly before packaging." >&2
      return 2
      ;;
  esac
}

resolve_developer_id_application_hash() {
  local LC_ALL=C
  local team_id="${1-}"
  local identities="${2-}"
  local matches=""
  local match_count=0
  local selected_hash=""
  local hash=""

  if [ "${#team_id}" -ne 10 ] || [[ "$team_id" == *[!A-Z0-9]* ]]; then
    echo "✗ Invalid or missing Developer ID Team ID: '$team_id'." >&2
    return 64
  fi

  matches="$(
    awk -v team="$team_id" '
      index($0, "\"Developer ID Application:") {
        line = $0
        sub(/[[:space:]]+$/, "", line)
        suffix = "(" team ")\""
        hash = toupper($2)
        if (length(line) >= length(suffix) &&
            substr(line, length(line) - length(suffix) + 1) == suffix &&
            length(hash) == 40 && hash !~ /[^0-9A-F]/ &&
            !seen[hash]++) {
          print hash
        }
      }
    ' <<<"$identities"
  )"

  while IFS= read -r hash; do
    [ -z "$hash" ] && continue
    match_count=$((match_count + 1))
    selected_hash="$hash"
  done <<<"$matches"

  case "$match_count" in
    1)
      printf '%s\n' "$selected_hash"
      ;;
    0)
      echo "✗ No valid 'Developer ID Application' identity for Team $team_id." >&2
      return 1
      ;;
    *)
      echo "✗ Multiple valid 'Developer ID Application' identities for Team $team_id." >&2
      echo "  Remove the duplicate identity before packaging so signing is deterministic." >&2
      return 2
      ;;
  esac
}
