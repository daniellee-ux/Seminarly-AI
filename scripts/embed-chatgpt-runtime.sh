#!/usr/bin/env bash
# Xcode build phase: include the pinned App Server, not a system-wide CLI.
# Downloading is a developer/build-time operation only. End users never install
# software or download executable code while signing in.
set -euo pipefail

RUNTIME_REPO="$(cd "$(dirname "$0")/.." && pwd)"
source "$RUNTIME_REPO/scripts/lib/chatgpt-runtime.sh"

: "${TARGET_BUILD_DIR:?Run this script from the Seminarly Xcode build phase.}"
: "${CONTENTS_FOLDER_PATH:?Missing app bundle contents path.}"
: "${ARCHS:?Missing Xcode architectures.}"
RUNTIME_CONTENTS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
RUNTIME_HELPERS="$RUNTIME_CONTENTS/Helpers"
RUNTIME_NOTICES="$RUNTIME_CONTENTS/Resources/ThirdParty/OpenAICodex"
RUNTIME_CACHE="$RUNTIME_REPO/build/chatgpt-runtime/$CHATGPT_RUNTIME_VERSION"
mkdir -p "$RUNTIME_HELPERS" "$RUNTIME_CACHE" "$RUNTIME_NOTICES"
RUNTIME_STAGE="$(mktemp -d "$RUNTIME_HELPERS/.chatgpt-runtime.XXXXXX")"
# The only recursive cleanup target is this invocation's fresh staging directory.
trap 'rm -rf -- "$RUNTIME_STAGE"' EXIT

RUNTIME_SLICES=()
for RUNTIME_ARCH in $ARCHS; do
  RUNTIME_MEMBER="$(chatgpt_runtime_member "$RUNTIME_ARCH")"
  RUNTIME_ARCHIVE="$RUNTIME_CACHE/$RUNTIME_MEMBER.tar.gz"
  chatgpt_fetch_verified "$CHATGPT_RUNTIME_BASE_URL/$RUNTIME_MEMBER.tar.gz" \
    "$RUNTIME_ARCHIVE" "$(chatgpt_runtime_digest "$RUNTIME_ARCH")" "$RUNTIME_STAGE"
  chatgpt_extract_runtime "$RUNTIME_ARCHIVE" "$RUNTIME_MEMBER" "$RUNTIME_ARCH" "$RUNTIME_STAGE/$RUNTIME_ARCH"
  RUNTIME_SLICES+=("$RUNTIME_STAGE/$RUNTIME_ARCH")
done
if [ "${#RUNTIME_SLICES[@]}" -eq 0 ]; then
  echo "No ChatGPT runtime architectures selected." >&2
  exit 1
fi
/usr/bin/lipo -create "${RUNTIME_SLICES[@]}" -output "$RUNTIME_STAGE/seminarly-chatgpt"
chmod 755 "$RUNTIME_STAGE/seminarly-chatgpt"

# Nested code is signed before the enclosing app. Debug builds use ad-hoc
# signing; archives use the exact same Developer ID identity as Seminarly.
RUNTIME_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [ -z "$RUNTIME_IDENTITY" ]; then RUNTIME_IDENTITY=-; fi
# A stable application-owned identifier lets Keychain trust carry across signed
# Seminarly updates, independent of upstream executable names or architecture.
RUNTIME_SIGN_ARGS=(--force --sign "$RUNTIME_IDENTITY" --identifier ai.seminarly.chatgpt --options runtime)
if [ "$RUNTIME_IDENTITY" != - ]; then RUNTIME_SIGN_ARGS+=(--timestamp); fi
/usr/bin/codesign "${RUNTIME_SIGN_ARGS[@]}" "$RUNTIME_STAGE/seminarly-chatgpt"
/usr/bin/codesign --verify --strict "$RUNTIME_STAGE/seminarly-chatgpt"

for RUNTIME_NOTICE in LICENSE NOTICE; do
  chatgpt_fetch_verified "$CHATGPT_RUNTIME_SOURCE_URL/$RUNTIME_NOTICE" \
    "$RUNTIME_CACHE/$RUNTIME_NOTICE" "$(chatgpt_runtime_digest "$RUNTIME_NOTICE")" "$RUNTIME_STAGE"
  cp "$RUNTIME_CACHE/$RUNTIME_NOTICE" "$RUNTIME_NOTICES/$RUNTIME_NOTICE"
done
cp "$RUNTIME_REPO/scripts/chatgpt-runtime-origin.txt" "$RUNTIME_NOTICES/ORIGIN.txt"
mv -f "$RUNTIME_STAGE/seminarly-chatgpt" "$RUNTIME_HELPERS/seminarly-chatgpt"
echo "Embedded ChatGPT connection component $CHATGPT_RUNTIME_VERSION ($ARCHS)."
