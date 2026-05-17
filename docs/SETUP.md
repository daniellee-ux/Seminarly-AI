# Development Setup

## Prerequisites

- macOS 14.4+ (required for Core Audio Taps API)
- Apple Silicon Mac with 16GB+ RAM (for WhisperKit large-v3 model)
- Xcode 16.0+
- Homebrew (for XcodeGen)

## First-Time Setup

### 1. Clone and generate project

```bash
git clone https://github.com/daniellee-ux/Seminarly-AI.git
cd Seminarly-AI
brew install xcodegen
xcodegen generate
```

### 2. Open in Xcode

```bash
open Seminarly.xcodeproj
```

### 3. Whisper model

On first launch, WhisperKit will download the `large-v3` model (~3GB). This happens automatically. To use a smaller/faster model, change the model name in `RecordingView.swift`:

```swift
await transcriptionEngine.loadModel(name: "base")  // faster, less accurate
```

Available models: `tiny`, `base`, `small`, `medium`, `large-v3`

### 4. Anthropic API key

1. Get a key from https://console.anthropic.com/
2. Open Seminarly → Settings → paste your key
3. Key is stored in macOS Keychain (never in files)

### 5. Permissions

On first recording, macOS will prompt for:
- **Microphone access** — for capturing your voice
- **Audio capture** — for tapping other apps' audio (macOS 14.4+)

### 6. Audio source auto-detection

Seminarly automatically watches for meeting apps (Zoom, Teams, Meet, etc.) starting to produce audio and shows a banner prompting you to record. This is enabled by default. To disable it: **Settings → Auto-detect audio sources**.

## Modifying the Project

```bash
# Edit project.yml (NOT .xcodeproj)
# Then regenerate:
xcodegen generate

# Build from CLI:
xcodebuild -project Seminarly.xcodeproj -scheme Seminarly -destination 'platform=macOS' build
```

## Troubleshooting

### Audio capture permission denied
- System Settings → Privacy & Security → Microphone → enable Seminarly
- System Settings → Privacy & Security → Audio Capture → enable Seminarly (macOS 14.4+)
- If Seminarly doesn't appear in the list, delete the app and rebuild — macOS registers the permission on first launch
- Check `Console.app` for `tccd` denials: filter by `kTCCServiceAudioCapture`

### WhisperKit model download failures
- Requires internet on first launch to download from Hugging Face
- Models cached at `~/Library/Caches/ai.seminarly.Seminarly/` (approximate path)
- If download stalls, delete cache and restart
- Switch to smaller model (`base` or `small`) if download is too large
- Check that your network allows Hugging Face CDN traffic

### API key issues
- "No API key configured" → go to Settings and paste your key
- 401 error → key is invalid or expired, regenerate at console.anthropic.com
- 429 error → rate limited, wait and retry
- Key not persisting → check Keychain Access.app for `ai.seminarly.Seminarly` entries
- If Keychain is locked, unlock it in Keychain Access.app

### Build errors after Xcode update
- Run `xcodegen generate` to regenerate project with new SDK paths
- Clean build folder: Xcode → Product → Clean Build Folder (Cmd+Shift+K)
- Delete DerivedData: `rm -rf ~/Library/Developer/Xcode/DerivedData/Seminarly-*`
- Check `project.yml` deployment target matches your SDK

### No audio from tapped process
- Verify the target app is actually playing audio (check system volume)
- `kAudioAggregateDeviceTapAutoStartKey: true` causes `AudioDeviceStart` to block until audio plays
- Some apps (e.g., FaceTime) may not expose audio to process taps
- Check `isRunningOutput` for the process in the app selector

### High memory usage
- WhisperKit large-v3 uses ~3-4GB RAM during inference
- Switch to `medium` (~1.5GB) or `small` (~500MB) model in Settings
- Close other memory-intensive apps during recording
- Monitor in Activity Monitor → Memory tab

### App not appearing in menu bar
- Menu bar icon is `waveform.circle.fill`
- If too many menu bar items, the icon may be hidden — resize menu bar or remove other icons
- Check that `LSUIElement` is `false` in Info.plist (it is by default)
