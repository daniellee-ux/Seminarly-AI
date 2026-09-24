#!/usr/bin/env bash
# Keep attribution in the small base app. Executable code is prepared on first use.
set -euo pipefail
RUNTIME_REPO="$(cd "$(dirname "$0")/.." && pwd)"
source "$RUNTIME_REPO/scripts/lib/chatgpt-runtime.sh"
: "${TARGET_BUILD_DIR:?Run this script from the Seminarly Xcode build phase.}"
: "${CONTENTS_FOLDER_PATH:?Missing app bundle contents path.}"
[[ "$CONTENTS_FOLDER_PATH" = *.app/Contents ]] || exit 1
RUNTIME_CONTENTS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
RUNTIME_NOTICES="$RUNTIME_CONTENTS/Resources/ThirdParty/OpenAICodex"
RUNTIME_CACHE="$RUNTIME_REPO/build/chatgpt-runtime/$CHATGPT_RUNTIME_VERSION"
mkdir -p "$RUNTIME_CACHE" "$RUNTIME_NOTICES"
RUNTIME_STAGE="$(mktemp -d "$RUNTIME_CACHE/notices.XXXXXX")"
trap 'rm -rf -- "$RUNTIME_STAGE"' EXIT
for RUNTIME_NOTICE in LICENSE NOTICE; do
  chatgpt_fetch_verified "$CHATGPT_RUNTIME_SOURCE_URL/$RUNTIME_NOTICE" \
    "$RUNTIME_CACHE/$RUNTIME_NOTICE" "$(chatgpt_runtime_digest "$RUNTIME_NOTICE")" "$RUNTIME_STAGE"
  cp "$RUNTIME_CACHE/$RUNTIME_NOTICE" "$RUNTIME_NOTICES/$RUNTIME_NOTICE"
done
cp "$RUNTIME_REPO/scripts/chatgpt-runtime-origin.txt" "$RUNTIME_NOTICES/ORIGIN.txt"
# Remove only the previous build phase's obsolete output in this build product.
# Incremental builds must not accidentally retain the 180–380 MB legacy helper.
if [ -f "$RUNTIME_CONTENTS/Helpers/seminarly-chatgpt" ] || [ -L "$RUNTIME_CONTENTS/Helpers/seminarly-chatgpt" ]; then
  rm -- "$RUNTIME_CONTENTS/Helpers/seminarly-chatgpt"
fi
echo 'Embedded ChatGPT license notices; the runtime is downloaded on first use.'
