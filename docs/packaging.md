# Small installers, first-use components, and delta updates

## Distribution

| Asset | Purpose |
| --- | --- |
| `Seminarly-AppleSilicon.dmg` | Native Apple Silicon app + CLI + Sparkle |
| `Seminarly-Intel.dmg` | Native Intel app + CLI + Sparkle |
| `Seminarly.dmg` | Universal compatibility installer for older update links |
| `appcast-arm64.xml`, `appcast-x86_64.xml` | Signed Sparkle feeds |
| `arm64-*.delta`, `x86_64-*.delta` | Signed patches when a compatible predecessor is available |
| `ChatGPTConnection-<version>-<revision>-<arch>.tar.xz` | Pinned, signed/notarized first-use ChatGPT component |

The base app does **not** contain the ChatGPT executable. Users simply click **Sign in with ChatGPT**; the app downloads the matching component, verifies it, and caches it across app updates. No developer tool or manual installation is required. Non-ChatGPT users never download it. ChatGPT users still need these bytes once: this improves the initial installer and subsequent updates, not the total disk space required by that feature.

Publish the complete set together, including `Seminarly.dmg`: versions through v0.1.11 use the fixed `/releases/latest/download/Seminarly.dmg` link. The Sparkle client uses separate native feeds, choosing Apple Silicon even when an Intel build is running under Rosetta. The first upgrade from a pre-Sparkle version is a full download; delta savings start with subsequent compatible releases. Sparkle falls back to the full DMG when a patch is unavailable or cannot be applied.

## Security and user control

- Automatic checks remain default-off and opt-in, once a day. They only show a quiet banner. Manual checks and installing a chosen update use Sparkle's standard UI; there is no automatic download, install, or system profiling.
- Updates and feeds require Ed25519 signatures. Archives are verified before extraction. The private signing key lives in macOS Keychain under account `ai.seminarly.updates`; only the public key in `Sources/Info.plist` is committed. Back up the key through a secure process, never the repository or logs.
- Runtime pins are sealed into the signed app's `ChatGPTRuntime.json`, not downloaded from a mutable server manifest. The installer checks archive/executable hashes, byte counts, Developer ID team/identifier, regular files, and symlink-free cache paths. Component bundles carry stapled notarization tickets. Changing the version requires a new app release.
- Cancelling or failing preparation discards the operation's staging files. Cache repair does not touch the separate ChatGPT sign-in profile/Keychain namespace. Existing cached code is revalidated before launch.
- Sparkle cannot restart during an active recording or recording-save pipeline. The existing termination/save/checkpoint delegate remains in the termination path.

## Initial component release or deliberate runtime upgrade

```sh
# Signs and notarizes both native components; does not publish.
CHATGPT_RUNTIME_RELEASE_TAG=v0.1.12 bash scripts/package-app.sh --runtime-only
```

This prints a fresh `build/packages/release.XXXXXX` directory with both archives and a generated public `ChatGPTRuntime.json`. Review and copy that manifest into `Sources/Resources/ChatGPTRuntime.json` **before** building the app. Preserve the exact matching archives. The URLs must point at the release in which these assets will first be published. Do not rebuild/re-sign an already-published runtime under the same pins; change its version/revision deliberately in `scripts/lib/chatgpt-runtime.sh`.

For v0.1.12's first publication, supply the local component directory because these URLs do not exist on GitHub yet:

```sh
CHATGPT_COMPONENT_DIR=/absolute/path/to/prepared-components \
  bash scripts/package-app.sh
```

On later releases the script can fetch the exact previously published component archives using their pinned immutable URLs. The app cache key remains unchanged and users do not download them again. Never remove old releases containing runtime assets still pinned by supported app versions.

## Build installers and feeds

Resolve the pinned Sparkle dependency with Xcode/XcodeGen. Its tools are at `SourcePackages/artifacts/sparkle/Sparkle/bin`. The script discovers the default DerivedData location; set `SPARKLE_BIN` explicitly when using a custom clone/cache directory.

```sh
# Once per signing machine; stores private material only in Keychain.
"$SPARKLE_BIN/generate_keys" --account ai.seminarly.updates
# A new signing machine must import the existing key securely, not silently
# generate a different key. Packaging rejects mismatched public keys.

# First Sparkle release: full signed feeds, no predecessor delta yet.
bash scripts/package-app.sh

# Subsequent releases: always increment CFBundleVersion in project.yml first.
SPARKLE_PREVIOUS_DIR=/absolute/path/to/previous-release/update-history \
  bash scripts/package-app.sh

# Local architecture-specific verification is also supported.
bash scripts/package-app.sh --arch arm64
```

Each invocation uses a fresh output directory and preserves previous artifacts. Native main app/CLI architecture sets are verified. The archive includes Sparkle and license notices, uses hardened runtime and Developer ID signing, then creates/signs/notarizes/staples an LZMA (`ULMO`) DMG. The script verifies Gatekeeper, signatures, and image integrity before generating signed feeds.

`generate_appcast` receives a **copy** of the trusted previous release history, creates patches, and signs enclosures. Public delta filenames are namespaced by architecture to avoid collisions in GitHub's flat asset namespace; feed URLs are rewritten to immutable release paths, then the feeds are signed again and verified. Keep `update-history` outside the public assets and retain it for the next release. Do not point it at untrusted archives. Omitting history produces a valid full-download-only feed, not a fabricated delta.

Upload all root-level DMGs, appcasts, referenced deltas, and runtime archives to one draft release. Publish it as a prerelease first (without making it latest), run the anonymous public download checks below, and only then promote it to latest. Finally rerun the checks with `--latest` to cover the old universal download link and both new feed links. A release missing a signed appcast cannot be consumed by the in-app installer. These scripts **prepare only** and never create a GitHub release.

## Verification

```sh
bash scripts/tests/signing-identity-test.sh
bash scripts/tests/chatgpt-runtime-test.sh
bash scripts/tests/package-architecture-test.sh
python3 scripts/tests/update-feed-test.py
python3 scripts/verify-release-downloads.py v0.1.12 /absolute/path/to/release-artifacts
# After promoting the complete release:
python3 scripts/verify-release-downloads.py v0.1.12 /absolute/path/to/release-artifacts --latest
xcodegen generate
xcodebuild test -project Seminarly.xcodeproj -scheme SeminarlyTests -destination 'platform=macOS'
```

The unit tests cover first-use ordering, cancellation/retry, corrupt caches/downloads, wrong signatures, symlinks, architecture selection, safe updater defaults, and save-pipeline guards. `scripts/smoke-runtime-install.swift` exercises real signed packages through the production installer plus unauthenticated protocol startup, using disposable profiles. Pass a component directory for offline local checks, or `--download` after publishing to use the actual URLSession downloader and manifest URLs for both CPUs. It also checks a second preparation reuses the cache without downloading again. Intel execution under Rosetta is useful but does not replace a physical Intel Mac test.

For delta checks use the pinned Sparkle `BinaryDelta create --version=4 old.app new.app patch.delta`, then `BinaryDelta apply old.app patched.app patch.delta` and verify the patched code signature. A disposable fixture can validate this mechanism; genuine prior/current released apps and a disposable install are needed to claim an end-to-end production upgrade. Never test by overwriting the user's running app.

## Earlier size investigation

The completed on-demand **v0.1.12 (build 13)** installers measure **3.6 MB (Apple Silicon)**, **4.1 MB (Intel)**, and **6.1 MB (universal)**. All three passed Developer ID signing, Apple notarization, ticket stapling, Gatekeeper, and image verification. The native DMGs were additionally mounted read-only and their code, architecture, manifest, and attribution checked.

Validation completed with **465 passing unit tests**, offline packaging tests, production hash/signature/cache/protocol smoke tests for both native components, and signed-feed/delta generation/application checks for both CPUs using disposable fixture apps. Those fixture deltas validate the pipeline; they are not a claim about production delta size. The public first-download URLs and an actual in-app upgrade remain publication-time checks. No real account login or model call was made for this change.

The released v0.1.11 universal DMG was **174.2 MB** (decimal). Recompressing its contents with LZMA measured **116.1 MB**. Native bundled-runtime prototypes measured **53.8 MB** (Apple Silicon), **63.2 MB** (Intel), and **116.0 MB** (universal). These are historical prototypes, not the new on-demand installer sizes.

The separate first-use runtime archives are about **43.9 MB** (Apple Silicon) and **52.3 MB** (Intel), with roughly 183.1/197.6 MB of executable code after extraction. Stripping debug/local symbols saved zero bytes in the official runtime; it is not modified for speculative savings. The base installer now excludes those executables entirely.

References: [Sparkle setup and signing](https://sparkle-project.org/documentation/), [delta generation and fallback](https://sparkle-project.org/documentation/delta-updates/), [publishing](https://sparkle-project.org/documentation/publishing/).
