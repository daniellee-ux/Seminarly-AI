# Native Qwen ASR subset

Qwen3-ASR model, configuration and mel preprocessing adapted from
[Blaizzy/mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift/tree/01dec7c9bdce3088a6b6b7ab9f2e403458195efb), MIT licensed.
Upstream files: `Sources/MLXAudioSTT/Models/Qwen3ASR/{Qwen3ASR,Qwen3ASRConfig}.swift`
and `Sources/MLXAudioCore/DSP.swift`.

This deliberately small subset supports the pinned 0.6B mixed-quantization
artifact through Swift 6.1 / macOS 14.4 without importing all STT, TTS, codec,
or voice-agent implementations. MLXLMCommon supplies the KV cache and attention
utilities. There is no Python runtime or local HTTP service.

Local changes: remove generic STT/streaming/download APIs; add cancellation in
the decode loop; load separate quantization_config.json (decoder 4-bit, encoder
8-bit, group size 64); preserve tied token embeddings; keep mel inputs and position additions in FP16; serialize MLX access in
QwenASRRuntime. Match the reference frontend by trimming the final centered
STFT frame before normalization, building Hann/mel coefficients in Float64
before casting to Float32, and using integer floor division for valid encoder
token lengths. Generate tokenizer files in an isolated per-load workspace,
removed after loading, so external/read-only model folders stay untouched.
Update this provenance when refreshing vendored source.
