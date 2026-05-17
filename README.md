# Seminarly

A local-first macOS app that records meeting audio, transcribes it on-device with WhisperKit, identifies speakers with FluidAudio neural diarization with Chinese-aware k-means re-clustering on raw 256D embeddings, and uses your choice of LLM (Claude, ChatGPT, Gemini, and 8 others) to generate structured notes — typically ~$0.30/month on Claude Sonnet.

## Why Seminarly

Most AI note-taking apps send your audio to the cloud, charge $18+/month, and join your call as a bot. Seminarly runs entirely on your Mac — no bot, no upload, no subscription. You keep your data; you pay only the per-call cost of the LLM provider you choose (~$0.03 per meeting on Claude Sonnet, similar or lower on other providers).

The notepad is the key difference. Instead of passively summarising everything, Seminarly lets you jot shorthand during the meeting. Claude uses your notes as signals of what matters, expands them with transcript context, and fills in what you missed — the same "jot and enhance" workflow that makes Granola popular, at a fraction of the cost.

## Getting Started

### 1. Install

```bash
git clone https://github.com/daniellee-ux/Seminarly-AI.git
cd Seminarly
brew install xcodegen   # if not already installed
xcodegen generate
open Seminarly.xcodeproj
```

Build and run in Xcode (⌘R).

### 2. First launch

On first launch, Seminarly downloads the Whisper large-v3 model (~3GB from Hugging Face). This is a one-time download — transcription runs locally after that.

Grant permissions when prompted:
- **Microphone** — to capture your voice
- **Audio capture** — to tap other apps' audio (macOS 14.4+)

### 3. Pick your AI provider and add an API key

Open **Settings** (gear icon) → choose a provider in the **AI Provider** picker, then paste your API key for that provider. The key is stored in macOS Keychain (one entry per provider) and never leaves your device.

Default is **Anthropic Claude** ([console.anthropic.com](https://console.anthropic.com)). Other supported providers are listed below.

### 4. Record your first session

**Option A — Auto-detect (easiest)**
Start a Zoom/Meet/Teams call. Within a few seconds, Seminarly shows a banner: *"Zoom is producing audio — Record?"* Click **Record** and you're in.

**Option B — Manual**
Click the record button (⏺) in the toolbar or use the menu bar icon. Pick the audio source from the dropdown and hit **Start Recording**.

### 5. Take notes while recording (optional but recommended)

Once recording starts, the app transforms into a notepad. Type anything — shorthand, headings, fragments:

```
# Action items
- infra cost review → daniel
budget approved for Q2
sarah presenting next week
```

You don't need to write full sentences. The AI fills in the gaps.

### 6. Stop and enhance

Hit **Stop**. Seminarly will:
1. Finalize the transcript
2. Identify speakers (FluidAudio neural diarization)
3. If you wrote notes → **enhance** them with transcript context
4. If you wrote nothing → **structure** the transcript automatically

The result appears in the meeting detail view within ~15 seconds.

---

## Note Templates

Pick the template that fits your session before recording:

| Template | Best for |
|----------|----------|
| **Freeform** *(default)* | Any conversation — model picks natural topic groupings, with nested bullets |
| **Meeting** | Standups, 1:1s, team meetings — captures decisions and action items |
| **Lecture** | Classes, talks — Cornell-method notes with key concepts and review questions |
| **Study Guide** | Exam prep — Q&A pairs, memory aids, practice problems |
| **Podcast** | Interviews, panels — key insights, notable quotes, references |
| **Custom** | Anything else — write your own instructions |

---

## The Notepad Workflow

The notepad is Seminarly's core UX. A few tips:

- **Use `#` headings** to define sections — `# Action Items` tells the AI to create that section
- **Write fragments, not sentences** — `budget Q2 approved` is enough
- **Note names and owners** — `migration → alex by friday` produces a properly formatted action item
- **You don't have to write anything** — the auto-structure path works well on its own

After the session, your notes appear in the detail view. You can edit them and click **Enhance** to regenerate at any time.

---

## Features

- **System audio capture** — tap any app's audio (Zoom, Meet, Teams) via Core Audio Taps API
- **On-device transcription** — WhisperKit (Whisper large-v3) runs locally, no cloud fees
- **Speaker diarization** — FluidAudio neural embeddings with Chinese-aware k-means re-clustering
- **Live notepad** — jot notes during recording; AI expands them with transcript context
- **AI-structured notes** — summaries, action items, decisions with per-item source attribution
- **Multi-provider LLM support** — Claude, ChatGPT, Gemini, Grok, Kimi, GLM, MiniMax, DeepSeek, Doubao (China + International) — bring your own key, switch any time
- **Summary language picker** — generate notes in any of 24 preset languages (or any custom language) independent of the spoken transcript; covers Simplified vs Traditional Chinese, Cantonese, Bokmål vs Nynorsk, Brazilian vs European Portuguese
- **Auto-detect audio sources** — detects meeting apps and prompts to record
- **6 note templates** — freeform, meeting, lecture, study guide, podcast, custom
- **Local storage** — all data stays on your Mac (SwiftData)
- **Menu bar app** — start/stop recording from anywhere
- **Export** — Markdown file or clipboard copy

---

## Supported AI Providers

Pick whichever provider you have an API key for. Each is configured in **Settings → AI Provider** with its own key (stored separately in Keychain) and editable model field.

| Provider | Default model | Where to get a key |
|---|---|---|
| **Anthropic Claude** *(default)* | `claude-sonnet-4-6` | [console.anthropic.com](https://console.anthropic.com) |
| **OpenAI ChatGPT** | `gpt-5.5` | [platform.openai.com](https://platform.openai.com) |
| **Google Gemini** | `gemini-3.1-flash-lite-preview` | [aistudio.google.com](https://aistudio.google.com) |
| **xAI Grok** | `grok-4.20` | [console.x.ai](https://console.x.ai) |
| **Moonshot Kimi** (international + China) | `kimi-k2.6` | [platform.moonshot.ai](https://platform.moonshot.ai) / [platform.moonshot.cn](https://platform.moonshot.cn) |
| **Zhipu GLM** | `glm-5.1` | [bigmodel.cn](https://bigmodel.cn) |
| **MiniMax** | `MiniMax-M2.7` | [platform.minimaxi.com](https://platform.minimaxi.com) |
| **DeepSeek** | `deepseek-v4-flash` | [platform.deepseek.com](https://platform.deepseek.com) |
| **ByteDance Doubao** (China + International) | Endpoint ID (China) / `seed-1-8-251228` (Int'l) | [volcengine.com](https://www.volcengine.com) / [bytepluses.com](https://www.bytepluses.com) |

Model field is editable so you can switch to any other model the provider supports.

---

## Cost Comparison

| Service | Monthly (10 meetings) | Annual |
|---------|----------------------|--------|
| **Seminarly** *(Claude Sonnet)* | **~$0.30** | **~$3.60** |
| Granola | $18 | $216 |
| Notion AI | $20 | $240 |
| Otter.ai Pro | $8.33 | $100 |

Each note-generation call typically costs ~$0.02–0.04 on Claude Sonnet; comparable or lower on other providers (some Chinese providers are noticeably cheaper). No subscription, no base fee.

---

## Requirements

- macOS 14.4+ (required for Core Audio Taps)
- Apple Silicon recommended — Intel Macs can build and run it, but on-device transcription is slow
- 8 GB RAM minimum; 16 GB recommended if you want the default Whisper `large-v3` model. The smaller models work fine on lower-memory machines:
  - `large-v3` — best accuracy, ~3 GB RAM during inference
  - `medium` — good accuracy, ~1.5 GB RAM
  - `small` — usable for clear English, ~500 MB RAM
- Xcode 16.3+ (matches `project.yml`)
- An API key from one of the supported providers (see table above)

---

## Architecture

```
System Audio → Core Audio Taps → 16kHz PCM → WhisperKit → Transcript
                                                              ↓
Microphone  → AVAudioEngine  → 16kHz PCM ──────────────→ Diarization
                                                              ↓
                                               User Notes (optional)
                                                              ↓
                                              LLMProvider (selected)
                                  Anthropic / OpenAI-compatible / Gemini
                                                              ↓
                                                     Structured Notes
                                                              ↓
                                                     SwiftData (local)
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for a full breakdown of every module.

---

## Coding Agent Integration

A small read-only CLI (`seminarly-cli`) plus a checked-in Agent Skill lets coding agents — Claude Code, Codex, Cursor, Gemini CLI, anything that can shell out — read your sessions in Markdown form.

**In-repo (one-off):**

```bash
./scripts/build-cli.sh                       # build once
./Tools/seminarly-cli list                   # JSON of sessions, newest first
./Tools/seminarly-cli get latest             # Markdown for your most recent session
./Tools/seminarly-cli search "OKR"           # find sessions mentioning a topic
```

**Global install (use from any directory):**

```bash
./scripts/install-global.sh                  # builds CLI + symlinks the skill into
                                             # ~/.agents/skills/seminarly-cli/
                                             # (also Claude Code's ~/.claude/skills/)
                                             # and the binary into ~/.local/bin/
```

After install, open any project in your coding agent and the `seminarly-cli` skill is discoverable; the bare `seminarly-cli` command resolves via `$PATH`.

Output distinguishes the three data types (user notes, AI-enhanced notes, transcript) with separate sections and inline `[user]` / `[transcript]` source tags.

See [`docs/agent-access.md`](docs/agent-access.md) for the full design, JSON shapes, and instructions for extending it.

---

## Contributing

Bug reports, feature requests, and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, tests, and conventions.

## License

Apache 2.0. See [LICENSE](LICENSE). Third-party dependencies and their licenses are listed in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
