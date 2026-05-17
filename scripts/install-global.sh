#!/usr/bin/env bash
# install-global.sh — set up seminarly-cli + agent skill so they work from any directory.
#
# Canonical user-level skill path: ~/.agents/skills/seminarly-cli/   (open standard;
#   read directly by Codex CLI, Gemini CLI, Kiro, Antigravity).
# Compatibility symlink: ~/.claude/skills/seminarly-cli            (Claude Code's
#   default path; harmless once Claude Code reads ~/.agents/skills/).
# Binary symlink: ~/.local/bin/seminarly-cli                       (so the bare
#   `seminarly-cli` name referenced by SKILL.md resolves via $PATH).
#
# Usage:
#   ./scripts/install-global.sh                # install
#   ./scripts/install-global.sh --uninstall    # remove symlinks (leaves PATH edits)
#   ./scripts/install-global.sh --no-path-edit # don't append to ~/.zshrc
#   ./scripts/install-global.sh --dry-run      # print actions, don't execute
#
# Idempotent. No sudo. Symlinks (not copies) so `git pull` updates everything.

set -euo pipefail

DRY_RUN=0
NO_PATH_EDIT=0
UNINSTALL=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --no-path-edit) NO_PATH_EDIT=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown flag: $arg" >&2
      echo "Usage: $0 [--uninstall] [--no-path-edit] [--dry-run]" >&2
      exit 2
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_SRC="$REPO_ROOT/.agents/skills/seminarly-cli"
BIN_SRC="$REPO_ROOT/Tools/seminarly-cli"

CANONICAL_SKILL_DIR="$HOME/.agents/skills/seminarly-cli"
COMPAT_SKILL_DIR="$HOME/.claude/skills/seminarly-cli"
BIN_LINK="$HOME/.local/bin/seminarly-cli"

say() { echo "→ $*"; }
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [dry-run] $*"
  else
    eval "$@"
  fi
}

if [[ $UNINSTALL -eq 1 ]]; then
  say "Uninstalling Seminarly skill and CLI symlinks"
  for target in "$CANONICAL_SKILL_DIR" "$COMPAT_SKILL_DIR" "$BIN_LINK"; do
    if [[ -L "$target" ]]; then
      say "Removing symlink $target"
      run "rm \"$target\""
    elif [[ -e "$target" ]]; then
      say "Skipping $target — exists but is not a symlink (manual cleanup required)"
    fi
  done
  echo
  echo "PATH edits in ~/.zshrc are not removed automatically."
  echo "If you previously added '\$HOME/.local/bin' to PATH and want it gone, edit ~/.zshrc by hand."
  exit 0
fi

# --- Build CLI if missing ---

if [[ ! -x "$BIN_SRC" ]]; then
  say "Building seminarly-cli (binary not found at $BIN_SRC)"
  run "\"$REPO_ROOT/scripts/build-cli.sh\""
fi

if [[ ! -x "$BIN_SRC" && $DRY_RUN -eq 0 ]]; then
  echo "Build did not produce $BIN_SRC — aborting." >&2
  exit 1
fi

# --- Canonical skill symlink (~/.agents/skills/seminarly-cli) ---

say "Linking canonical skill: $CANONICAL_SKILL_DIR → $SKILL_SRC"
run "mkdir -p \"$HOME/.agents/skills\""
if [[ -L "$CANONICAL_SKILL_DIR" ]]; then
  current="$(readlink "$CANONICAL_SKILL_DIR")"
  if [[ "$current" == "$SKILL_SRC" ]]; then
    say "  Already pointing at this repo — leaving alone"
  else
    say "  Replacing existing symlink (was → $current)"
    run "rm \"$CANONICAL_SKILL_DIR\""
    run "ln -s \"$SKILL_SRC\" \"$CANONICAL_SKILL_DIR\""
  fi
elif [[ -e "$CANONICAL_SKILL_DIR" ]]; then
  say "  Path exists but is not a symlink — skipping (manual cleanup required: $CANONICAL_SKILL_DIR)"
else
  run "ln -s \"$SKILL_SRC\" \"$CANONICAL_SKILL_DIR\""
fi

# --- Compat symlink for Claude Code (~/.claude/skills/seminarly-cli) ---

if [[ -d "$HOME/.claude" ]]; then
  say "Linking Claude Code compat: $COMPAT_SKILL_DIR → $CANONICAL_SKILL_DIR"
  run "mkdir -p \"$HOME/.claude/skills\""
  if [[ -L "$COMPAT_SKILL_DIR" ]]; then
    current="$(readlink "$COMPAT_SKILL_DIR")"
    if [[ "$current" == "$CANONICAL_SKILL_DIR" ]]; then
      say "  Already pointing at canonical — leaving alone"
    else
      say "  Replacing existing symlink (was → $current)"
      run "rm \"$COMPAT_SKILL_DIR\""
      run "ln -s \"$CANONICAL_SKILL_DIR\" \"$COMPAT_SKILL_DIR\""
    fi
  elif [[ -e "$COMPAT_SKILL_DIR" ]]; then
    say "  Path exists but is not a symlink — skipping (manual cleanup required: $COMPAT_SKILL_DIR)"
  else
    run "ln -s \"$CANONICAL_SKILL_DIR\" \"$COMPAT_SKILL_DIR\""
  fi
else
  say "Skipping ~/.claude/ (not present — Claude Code is not installed)"
fi

# --- Binary symlink (~/.local/bin/seminarly-cli) ---

say "Linking binary: $BIN_LINK → $BIN_SRC"
run "mkdir -p \"$HOME/.local/bin\""
if [[ -L "$BIN_LINK" ]]; then
  current="$(readlink "$BIN_LINK")"
  if [[ "$current" == "$BIN_SRC" ]]; then
    say "  Already pointing at this repo's binary — leaving alone"
  else
    say "  Replacing existing symlink (was → $current)"
    run "rm \"$BIN_LINK\""
    run "ln -s \"$BIN_SRC\" \"$BIN_LINK\""
  fi
elif [[ -e "$BIN_LINK" ]]; then
  say "  Path exists but is not a symlink — skipping (manual cleanup required: $BIN_LINK)"
else
  run "ln -s \"$BIN_SRC\" \"$BIN_LINK\""
fi

# --- PATH edit ---

if [[ $NO_PATH_EDIT -eq 0 ]]; then
  if echo "$PATH" | tr ':' '\n' | grep -q "^$HOME/.local/bin\$"; then
    say "~/.local/bin already on \$PATH — skipping ~/.zshrc edit"
  elif [[ -f "$HOME/.zshrc" ]] && grep -q 'HOME/.local/bin' "$HOME/.zshrc"; then
    say "~/.zshrc already references \$HOME/.local/bin — skipping edit"
  else
    say "Adding \$HOME/.local/bin to PATH in ~/.zshrc"
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "  [dry-run] would append: export PATH=\"\$HOME/.local/bin:\$PATH\""
    else
      printf '\n# Added by Seminarly install-global.sh — exposes seminarly-cli\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$HOME/.zshrc"
    fi
    echo "  Restart your shell or run: source ~/.zshrc"
  fi
fi

echo
echo "Done."
echo
echo "Verify:"
echo "  which seminarly-cli            # should resolve to ~/.local/bin/seminarly-cli"
echo "  seminarly-cli list             # should print sessions"
echo "  ls -la ~/.agents/skills/       # should show seminarly-cli symlink"
