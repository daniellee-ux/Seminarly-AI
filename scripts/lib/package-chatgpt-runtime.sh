#!/usr/bin/env bash
# Called by package-app.sh after Developer ID / notary preflight. Does not publish.
source scripts/lib/chatgpt-runtime.sh

package_chatgpt_runtime() {
  local output="$1" tag="$2" team="$3" identity="$4" arch member archive component executable
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid release tag.' >&2; return 1; }
  local cache="$PWD/build/chatgpt-runtime/$CHATGPT_RUNTIME_VERSION"
  mkdir -p "$cache"
  for arch in arm64 x86_64; do
    local stage="$output/$arch"
    component="$stage/ChatGPTConnection.app"
    executable="$component/Contents/MacOS/seminarly-chatgpt"
    mkdir -p "$component/Contents/MacOS" "$component/Contents/Resources"
    member="$(chatgpt_runtime_member "$arch")"
    archive="$cache/$member.tar.gz"
    chatgpt_fetch_verified "$CHATGPT_RUNTIME_BASE_URL/$member.tar.gz" "$archive" "$(chatgpt_runtime_digest "$arch")" "$stage"
    chatgpt_extract_runtime "$archive" "$member" "$arch" "$executable"
    for notice in LICENSE NOTICE; do
      chatgpt_fetch_verified "$CHATGPT_RUNTIME_SOURCE_URL/$notice" "$cache/$notice" "$(chatgpt_runtime_digest "$notice")" "$stage"
      cp "$cache/$notice" "$component/Contents/Resources/$notice"
    done
    cp scripts/chatgpt-runtime-origin.txt "$component/Contents/Resources/ORIGIN.txt"
    local plist="$component/Contents/Info.plist"
    plutil -create xml1 "$plist"
    plutil -insert CFBundleIdentifier -string ai.seminarly.chatgpt "$plist"
    plutil -insert CFBundleExecutable -string seminarly-chatgpt "$plist"
    plutil -insert CFBundlePackageType -string APPL "$plist"
    plutil -insert CFBundleName -string 'ChatGPT Connection' "$plist"
    plutil -insert CFBundleVersion -string "$CHATGPT_RUNTIME_VERSION" "$plist"
    plutil -insert CFBundleShortVersionString -string "$CHATGPT_RUNTIME_VERSION" "$plist"
    plutil -insert LSUIElement -bool YES "$plist"
    # Keep the original app-owned helper identifier for existing Keychain grants.
    codesign --force --sign "$identity" --identifier ai.seminarly.chatgpt --options runtime --timestamp "$component"
    ditto -c -k --keepParent "$component" "$stage/notarization.zip"
    notarize_path "$stage/notarization.zip"
    xcrun stapler staple "$component"
    xcrun stapler validate "$component"
    codesign --verify --deep --strict "$component"
    spctl --assess --type execute -vv "$component"
    package_verify_architectures "$executable" "$arch"
    # No AppleDouble files; the stapled ticket is a regular bundle resource.
    COPYFILE_DISABLE=1 tar --no-xattrs -cJf "$output/ChatGPTConnection-$CHATGPT_RUNTIME_VERSION-$CHATGPT_RUNTIME_REVISION-$arch.tar.xz" -C "$stage" ChatGPTConnection.app
  done
  python3 scripts/runtime-manifest.py "$output" "$CHATGPT_RUNTIME_VERSION" "$CHATGPT_RUNTIME_REVISION" "$tag" "$team"
  echo "Prepared components and manifest in $output. Nothing has been published."
}
