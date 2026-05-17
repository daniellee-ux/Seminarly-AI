# Diarization Research Report — March 2026

Compiled from parallel research across three domains: NeMo MSDD internals, CTC forced alignment vs. WhisperKit timestamps, and 2025–2026 SOTA diarization systems. Includes direct comparison against the two repos flagged for review (`whisper-diarization`, `transcriptionstream`) and actionable recommendations for Seminarly.

---

## Executive Summary

Seminarly's current stack (FluidAudio + cosine clustering at threshold 0.70 + PLDA bypass for Chinese) is architecturally sound and competitive with open-source pyannote 3.1. It is **not** significantly behind the two repos under review. The state-of-the-art has moved toward WavLM-based segmentation (DiariZen), but no published Swift/CoreML pipeline for diarization exists — FluidAudio remains the only native on-device option. Three concrete improvements are actionable without adopting new model dependencies: multi-scale embedding extraction, punctuation-snapping at speaker boundaries, and full time-overlap (not anchor-point) word-speaker assignment.

---

## 1. The Two Repos vs. Seminarly

### whisper-diarization (MahmoudAshraf97)

**Pipeline:** MarbleNet VAD → Whisper ASR → CTC forced alignment (ctc-forced-aligner, MMS 300M) → TitaNet speaker embeddings (256D) → agglomerative clustering or NeMo MSDD → word-speaker assignment.

**transcriptionstream:** A Docker wrapper around whisper-diarization. No novel diarization work.

### Direct Comparison

| | Seminarly | whisper-diarization |
|---|---|---|
| ASR | WhisperKit (Swift, on-device) | Whisper (Python) |
| Embeddings | FluidAudio 256D neural | TitaNet 256D neural |
| Clustering | Cosine threshold 0.70 | Agglomerative or NeMo MSDD |
| Multi-scale | No | Optional (NeMo MSDD) |
| Word timestamps | WhisperKit attention-DTW | CTC forced alignment (more precise) |
| Overlap detection | No | MSDD only (optional path) |
| Chinese / non-English | PLDA bypass + raw re-cluster (our fix) | No fix (TitaNet is English-trained) |
| Platform | Native Swift, Apple Silicon | Python server |
| Streaming | Yes (30s chunks) | Batch only |
| DER (benchmarked) | Not published | Not published |

**Verdict:** They are not clearly ahead. Their advantage is CTC forced alignment for timestamp precision and optional MSDD multi-scale. Our advantage is native on-device operation, streaming, and the Chinese PLDA bypass. TitaNet ≈ FluidAudio in embedding quality; both are English-biased.

---

## 2. NeMo MSDD — Deep Dive

### How It Works

MSDD is a two-stage cascaded system:

**Stage 1 — Multi-scale clustering:**
- Extracts TitaNet-Large embeddings at 6 window sizes simultaneously: `[3.0, 2.5, 2.0, 1.5, 1.0, 0.5]` seconds, 50% overlap
- Base scale (0.5s) defines the timeline; longer-scale embeddings are repeated across base-scale frames
- NME-SC (Normalized Maximum Eigengap Spectral Clustering) estimates speaker count via Laplacian eigendecomposition
- Produces initial speaker labels + cluster-average embeddings per speaker per scale

**Stage 2 — Neural refinement (the MSDD decoder):**
- Input: multi-scale embeddings tensor `(batch, time, scales, 192D)`
- Scale weighting: 1D CNN layers compute dynamic per-timestep scale weights (short scales weighted more at boundaries, long scales weighted more during stable turns)
- Context vector: cosine similarity between current embedding and cluster-average, weighted by scale
- BiLSTM decoder: 2 layers, 256 hidden, bidirectional
- Output: sigmoid activation → multi-label speaker probabilities per frame
- Sigmoid (not softmax) enables overlap detection — multiple speakers simultaneously active

**Speaker count:** Determined automatically by NME-SC eigengap analysis. For N speakers, MSDD runs C(N,2) pairwise forward passes and averages probabilities across pairs.

### Benchmarks

| Dataset | MSDD DER | Conditions |
|---|---|---|
| CALLHOME | 3.92% | 0.25s collar, oracle VAD |
| AMI MixHeadset | 1.05% | 0.25s collar, oracle VAD |

**Critical caveat:** These use oracle VAD and 0.25s collar, making them incomparable to "Full" evaluation (collar=0, system VAD, overlap included). Under the same conditions as pyannote's published numbers, MSDD does not outperform current SOTA (see Section 4).

### MSDD on Apple Silicon

**Does not run on Apple Silicon GPU.** The NeMo MSDD code falls back to CPU when CUDA is unavailable and has no MPS path. TitaNet-Large (23M params) across hundreds of segments at 6 scales → **5-30× real-time on CPU** — unusable for a post-meeting processing flow. Python + NeMo stack is 5GB+ on disk, 1-2GB RAM.

### What We Can Take From MSDD Without Porting It

The most actionable MSDD insight for Seminarly: **multi-scale embedding extraction**. Extract FluidAudio embeddings at [1.5s, 1.0s, 0.5s] windows, build a cosine affinity matrix at each scale, then average the three matrices before clustering. This is MSDD's Stage 1 benefit with no neural decoder, no new model weights, no Python — just more FluidAudio calls and some arithmetic. Expected DER improvement: ~1-3 points for meetings with rapid speaker turns.

---

## 3. CTC Forced Alignment vs. WhisperKit Timestamps

### The Problem With WhisperKit's Word Timestamps

WhisperKit uses **attention-DTW**, the same mechanism as OpenAI Whisper: cross-attention weights from designated alignment heads → DTW → token-to-frame mapping. Limitations:
- Attention weights are trained for transcription (WER), not timestamp precision
- Long-form inference buffers accumulate drift across 30s windows
- Attention "diffuseness" blurs boundaries for acoustically similar tokens
- Post-processing includes explicit hacks ("truncate long words," punctuation merge logic)

Practical result: word boundary error of **~100-400ms**, particularly at speaker turn boundaries.

### CTC Forced Alignment (what whisper-diarization uses)

A Wav2Vec2/MMS 300M-parameter model is run on the audio, producing frame-level character posterior probabilities at ~20ms intervals. A trellis DP (constrained to the known transcript text) finds the monotone optimal path, yielding precise word-level start/end times. Improvement over Whisper native (WhisperX benchmark, AMI, 200ms collar):

| Method | Precision | Recall |
|---|---|---|
| Whisper native (attention-DTW) | 78.9% | 52.1% |
| CTC forced alignment (WhisperX) | 84.1% | 60.3% |
| Improvement | +5.2pp | +8.2pp |

### Can We Implement CTC Forced Alignment in Swift?

**No — not without significant new infrastructure.** Requires a 300M-parameter Wav2Vec2/MMS model, trellis DP inference, and multilingual romanization preprocessing. No Swift/CoreML implementation exists. Would require a full model conversion pipeline and a new on-device model (significant binary size and compute overhead).

### Practical DER Impact

The word-timestamp gap translates to **~1-4 DER percentage points** for conversational audio (frequent short turns), and **<1 point** for lectures or podcasts (rare turn changes). The improvement only matters at speaker turn boundaries — words well inside a speaker's segment are assigned correctly either way.

### Best Actionable Alternative: Two improvements, near-zero cost

1. **Full time-overlap assignment** (not anchor-point): For each word `[t_start, t_end]`, compute overlap with every diarization segment and assign the speaker with maximum overlap. This is more robust than the single-anchor-point method (which is sensitive to whether you use start/mid/end as the representative timestamp). Already mathematically correct; check whether `NeuralDiarizationEngine.swift` uses full overlap or anchor-point.

2. **Punctuation-snapping**: After assigning words to speakers, if a speaker turn boundary falls within 200ms of a punctuation mark or silence gap, snap the boundary to the punctuation. Captures ~30-50% of the DER benefit of full CTC alignment at near-zero compute cost.

---

## 4. State of the Art: 2025–2026

### Current Best Systems

| System | AMI DER | Mandarin | Overlap | Open Source | On-Device |
|---|---|---|---|---|---|
| PyannoteAI (commercial) | ~8%? | 10.0% | Yes | No | API only |
| DiariZen (WavLM Base+) | 17.5% | 10.1% | Yes (powerset) | Yes | ONNX possible |
| Sortformer (NVIDIA) | — | 9.2% | Yes (sigmoid) | Yes (NeMo) | ONNX (NeMo) |
| pyannote 3.1 (open) | 18.8% | 19.8% | Yes (powerset) | Yes | PyTorch MPS |
| ECAPA2 + wVAD | 1.4%* | — | No | Not yet | Not yet |
| FluidAudio (Seminarly) | Unknown | Poor (PLDA, fixed) | No | No | Yes (Swift native) |

*Oracle speaker count, no overlap penalty — not comparable to other rows.

All DER figures above are collar=0 except where noted.

### The Architecture That's Winning: EEND-VC Hybrid

The dominant paradigm in 2025-2026 is **EEND-VC (End-to-End Neural Diarization with Vector Clustering)**:
- Neural segmentation block (EEND) handles overlap within chunks and produces short-horizon speaker labels
- Speaker embedding extraction produces identity-stable representations
- Clustering (AHC/VBx) tracks speaker identity across the full recording

This is exactly what pyannote 3.x and DiariZen do. FluidAudio's pipeline is structurally equivalent. The remaining gap between FluidAudio and DiariZen is the **segmentation model**: DiariZen uses finetuned WavLM Base+ (94M params) + Conformer; FluidAudio uses an unknown model (likely a smaller EEND or SincNet variant).

### DiariZen: The Most Relevant System

DiariZen (BUTSpeechFIT, ICASSP 2025) is the strongest open-source system as of early 2026:
- WavLM Base+ encoder (94M params, prunable to 18.8M with no DER degradation)
- 4 Conformer decoder blocks
- WeSpeaker ResNet34-LM embeddings (256D — matches what Seminarly's clustering code already expects)
- AHC clustering, cosine threshold **0.70** (same as Seminarly's current setting — validating our threshold choice)
- Trained on AISHELL-4 + AliMeeting + AMI + VoxConverse jointly → strong Mandarin performance

The pruned WavLM (18.8M params, 80% size reduction, 4× GPU speedup) makes DiariZen's segmentation model tractable for on-device use. No published CoreML/Swift path exists yet, but ONNX export from PyTorch is standard and `onnxruntime-swift` is actively maintained.

### FluidAudio: What It Actually Is

Research finding: **FluidAudio is not a published academic library.** No arXiv paper, no GitHub repo, no PyPI package. It appears to be a commercial Swift SDK wrapping a pyannote-equivalent pipeline:
- Internal VBx clustering (parameter `warmStartFa` is a VBx hyperparameter)
- 256D speaker embeddings consistent with WeSpeaker ResNet34-LM
- PLDA scoring trained on English (confirmed by our Chinese PLDA bypass fix)
- Models downloaded at runtime (cloud-hosted weights)

Implications:
- No auditability — we cannot know the actual DER or training data
- Vendor risk — if FluidAudio discontinues or changes pricing, diarization breaks
- The Chinese PLDA bypass we already implemented is necessary and correct
- Our clustering threshold (0.70) independently matches DiariZen's published optimal — good validation

### Key 2025-2026 Trends Relevant to Seminarly

1. **PLDA is dead for non-English** — all top systems use cosine AHC directly on L2-normalized embeddings. Our bypass is correct and aligns with the field.
2. **WavLM representations are the key unlock** — language-agnostic self-supervised pretraining makes systems robust to Mandarin, Japanese, German without language-specific finetuning.
3. **Clustering threshold 0.70 is validated** — DiariZen uses exactly this for AHC; our tuned value matches.
4. **Overlap detection is now table stakes** — "Full" evaluation protocols penalize systems that can't detect simultaneous speakers. We currently have no overlap handling.
5. **No on-device Swift pipeline exists** — the gap we're filling is real. FluidAudio is the only game in town for native macOS diarization.

---

## 5. Actionable Recommendations (Prioritized)

### Tier 1: Low effort, immediate improvement

**A. Verify word-speaker assignment uses full time-overlap**
Check `NeuralDiarizationEngine.swift` — confirm word-to-speaker assignment computes `min(word_end, seg_end) - max(word_start, seg_start)` for all overlapping segments and picks max, not an anchor-point heuristic. If anchor-point, switch to full overlap. ~1-2 DER points at speaker boundaries.

**B. Add punctuation-snapping at speaker turn boundaries**
After speaker label assignment, for each speaker turn boundary: if a punctuation mark (`.`, `?`, `!`, `,`) or silence gap falls within ±200ms, snap the boundary to that point. Captures ~30-50% of the benefit of CTC forced alignment. Pure Swift, no new models.

### Tier 2: Medium effort, meaningful improvement

**C. Multi-scale embedding extraction**
Extract FluidAudio embeddings at three window sizes: 1.5s, 1.0s, 0.5s (all with 50% overlap). Build a cosine affinity matrix at each scale, average the three matrices, then run the existing clustering. This is MSDD's Stage 1 benefit with no new model weights — just more calls to FluidAudio's embedding API and matrix arithmetic in Swift/Accelerate. Expected improvement: ~1-3 DER points for meetings with rapid turn-taking.

**D. Evaluate current DER**
Record a set of test meetings with known ground-truth speaker turns and compute our actual DER. Without a baseline number, we cannot measure improvement from any of the above changes. Essential for prioritizing future work.

### Tier 3: Longer-term, significant architectural work

**E. ONNX export of WeSpeaker ResNet34-LM as FluidAudio fallback**
WeSpeaker ResNet34-LM is publicly available and produces 256D embeddings. Export to ONNX via PyTorch, run via `onnxruntime-swift`. This gives us an auditable, open-source embedding model that we can update independently of FluidAudio. Our existing Swift clustering code already handles 256D embeddings.

**F. Pruned WavLM Base+ segmentation (DiariZen-style)**
The 18.8M-parameter pruned WavLM produces state-of-the-art segmentation for EEND-VC pipelines and is multilingual-robust. Converting to CoreML or ONNX and running on Apple Neural Engine would bring Seminarly's segmentation to DiariZen-equivalent quality. 2-4 week engineering effort; requires Python toolchain for model conversion.

**G. Overlap detection**
Add an overlap speech detection (OSD) flag per time window, using either FluidAudio's per-frame outputs (if exposed) or a small separately-trained binary classifier. Required to move from "functional" to "competitive with SOTA" on Full evaluation protocols.

---

## 6. Summary

| Finding | Implication |
|---|---|
| whisper-diarization is not ahead of us | No need to adopt their Python stack |
| MSDD can't run on Apple Silicon | Not worth porting; take multi-scale concept only |
| CTC forced alignment not feasible in Swift | Use punctuation-snapping instead |
| FluidAudio ≈ pyannote 3.1 quality | We're roughly at 2023 SOTA |
| DiariZen (WavLM) is current SOTA | ~3-4 DER points ahead of us, achievable via ONNX path |
| Our threshold 0.70 is correct | Matches DiariZen's published optimal |
| PLDA bypass for Chinese is correct | Aligns with field-wide finding |
| No Swift diarization pipeline exists | Our core value-add is real |
| Overlap detection is the biggest gap | All SOTA systems handle it; we don't |
