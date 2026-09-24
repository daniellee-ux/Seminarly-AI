# ChatGPT plan sign-in (Beta)

Seminarly can generate and enhance notes using the **Codex allowance associated with a ChatGPT account**, via OpenAI's local App Server. It is not a conversion of ChatGPT subscription usage into general API credits. Model access, plan limits, and organization restrictions still apply. The existing **OpenAI API** option remains separate, and there is no automatic paid-API fallback.

## Setup

1. Install or update the official [Codex CLI](https://learn.chatgpt.com/docs/codex-cli) to **0.155.1 or later**. Seminarly does not download or install a runtime automatically.
2. In Seminarly, open **Settings → AI Provider → ChatGPT plan (Beta)**.
3. If Codex is not detected, use **Choose executable…** to select the installed `codex` executable. Common Homebrew, `~/.local/bin`, and `~/.npm-global/bin` installations are detected automatically. Node-based installations must also have Node available beside Codex or in a standard Homebrew/system path.
4. Click **Sign in with ChatGPT** and complete the official browser flow. If the localhost callback is unavailable, use **Use device code**. Device-code authentication may require enabling it in ChatGPT security settings or asking your workspace administrator.
5. Leave **Model** on **Automatic**, or choose from the runtime's model catalog. Generate or enhance notes as usual.

**Refresh account** rechecks account, model catalog, and available usage information. Missing usage information means unknown, not zero remaining. Hitting a plan limit reports an error without changing existing notes or charging an API key. Choose an API provider explicitly if you want to switch billing methods.

## Isolation and privacy

- The app launches `codex app-server --listen stdio://` directly, without a shell, daemon, or public server port. Browser sign-in uses the runtime's local OAuth callback; Seminarly does not implement token exchange itself.
- The runtime uses a dedicated profile at `~/Library/Application Support/ai.seminarly/ChatGPT`, with `cli_auth_credentials_store="keyring"`. Tokens are managed by Codex in macOS Keychain, not placed in UserDefaults or app logs. Seminarly does not copy `~/.codex/auth.json` or reuse the user's regular Codex profile. Signing out here does not sign out those other tools.
- Only the transcript, optional typed notes, and generation instructions for the selected meeting are sent to OpenAI. Audio remains local. OpenAI's account data controls and policies still apply; ephemeral local sessions do not imply zero retention by OpenAI.
- Each generation has its own process, empty temporary working directory, and `ephemeral: true` thread. Seminarly verifies the ephemeral response and selected restricted permissions profile before sending meeting content. Model instructions forbid tools; shell, browser, apps, plugins, hooks, image tools, host skill discovery, and delegation features are disabled. A named permissions profile limits local command reads to platform-minimal files and the empty workspace, permits no writes, and disables command network access. Unexpected tool or approval requests abort generation.
- No prompt/output text is written into app error messages. Only a successful completed turn's final answer is decoded and saved; commentary, deltas, interrupted turns, and failed turns are not saved. Cancel and sign-out terminate owned work without stopping another application's Codex process.

## Compatibility and remaining release checks

The unauthenticated protocol/isolation smoke test has passed with **Codex 0.155.1 and 0.156.1** on Apple Silicon macOS. With **0.156.1**, browser sign-in was completed in Seminarly, a new process successfully reused the app's persisted sign-in, and the production provider generated valid Traditional Chinese notes from a short fictional transcript. That live check used the ChatGPT account, not an API key, and did not open or modify the meeting database.

The minimum-version check is not a guarantee that every future App Server release is compatible. OpenAI currently documents App Server as experimental and unsupported for production workloads, so this provider remains Beta. Keep the normal API providers available.

Before promoting out of Beta, additionally verify real device-code login, full app-relaunch restoration, logout isolation, quota exhaustion, and managed-workspace restrictions with test accounts. These failure/auth flows have offline test coverage, but not all have been exercised against live accounts. Intel runtime compatibility also needs release verification. The standard release pipeline separately verifies Developer ID signatures, hardened runtime, notarization, and Gatekeeper assessment.

## Developer verification

Offline tests use `Tests/Fixtures/fake-codex.py` (Python 3 provided with Xcode command-line tools) as a JSONL process fixture. They cover chunk framing, login races, URL validation, cancellation, pagination, timeout/process exit, unsupported runtimes, structured schemas, partial-response rejection, tool refusal, quota errors, and logout failures. No credentials or remote AI requests are used.

```sh
xcodegen generate
xcodebuild test -project Seminarly.xcodeproj -scheme SeminarlyTests -destination 'platform=macOS'
```

To verify the actual runtime protocol without signing in or submitting a prompt, compile the smoke helper with the production transport/configuration files:

```sh
swiftc -swift-version 6 -parse-as-library \
  Sources/NoteStructuring/ChatGPT/CodexProtocol.swift \
  Sources/NoteStructuring/ChatGPT/CodexAppServerClient.swift \
  Sources/NoteStructuring/ChatGPT/CodexRuntime.swift \
  Sources/Utilities/SemanticVersion.swift scripts/smoke-codex.swift \
  -o /tmp/seminarly-codex-smoke
/tmp/seminarly-codex-smoke /absolute/path/to/codex
```

The helper uses a fresh temporary profile, verifies it is signed out, creates an ephemeral empty thread with the named permissions profile, then cleans up its temporary files. It does not initiate OAuth or send a model turn.

## Official references

- [App Server: authentication, lifecycle, models, structured output](https://learn.chatgpt.com/docs/app-server)
- [Named permission profiles and their enforcement boundaries](https://learn.chatgpt.com/docs/permissions)
- [Configuration reference: credential storage, features, history](https://learn.chatgpt.com/docs/config-reference)
- [Tracking issue #33](https://github.com/daniellee-ux/Seminarly-AI/issues/33)
