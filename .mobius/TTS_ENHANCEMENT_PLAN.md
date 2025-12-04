# TTS Enhancement Plan: FluidAudio Kokoro

## Overview
Evolve FluidAudio TTS into a high-performance local engine comparable to Speechify/ElevenLabs,
optimized for the VoiceReader app.

## Current State
- **Model**: Kokoro (82M parameters, ~350MB)
- **Framework**: CoreML / Swift
- **Pipeline**: Text → Espeak-NG (G2P) → Phonemes → CoreML → Audio
- **Status**: Basic playback working with word-level sync

---

## Phase 1: Performance & Latency (Critical)

### 1.1 Model Quantization ⏳
**Goal**: Reduce app bundle size from ~350MB to <175MB

- [ ] Export Kokoro to ONNX from PyTorch checkpoint
- [ ] Convert to CoreML with Float16 precision using coremltools
- [ ] Validate audio quality (SNR > 40dB)
- [ ] Upload quantized models to HuggingFace

**Scripts**: `.mobius/scripts/quantize_kokoro.py`, `.mobius/scripts/analyze_ane.py`

**Success Metric**: Bundle size < 175MB with imperceptible quality loss

### 1.2 ANE Exclusive Execution ⏳
**Goal**: Force Neural Engine for battery efficiency

- [x] Change compute units from `.cpuAndGPU` → `.cpuAndNeuralEngine`
- [ ] Analyze model for ANE-incompatible layers
- [x] Add ANE memory optimization to TTS pipeline
- [ ] Profile with Instruments to verify ANE utilization

**Files Modified**: `TtsModels.swift`, `KokoroSynthesizer+ANE.swift`

### 1.3 G2P Caching ✅
**Goal**: Reduce CPU usage for repeated text

- [x] Implement LRU cache for eSpeak phonemization results
- [x] Add cache statistics for monitoring
- [x] Integrate with existing phonemization flow

**Files Created**: `G2PCache.swift`

**Success Metric**: >90% cache hit rate on typical documents

---

## Phase 2: Speechify-Style Playback Features

### 2.1 Time-Stretching
**Goal**: Enable 0.5x-3.0x playback without chipmunk effect

- [ ] Implement phase vocoder algorithm
- [ ] Replace simple sample decimation in `adjustSamples()`
- [ ] Add vDSP-accelerated FFT processing

**Files**: `TimeStretcher.swift`

### 2.2 Smart Pausing ✅
**Goal**: Natural rhythm via punctuation-based pauses

- [x] Create ProsodyProcessor for pause annotation
- [x] Define configurable pause durations (comma, period, paragraph)
- [ ] Integrate with synthesis pipeline

**Files Created**: `ProsodyProcessor.swift`

### 2.3 PDF Artifact Cleaning ✅
**Goal**: Clean PDF text before synthesis

- [x] Remove page numbers, citations, figure labels
- [x] Fix hyphenation at line breaks
- [x] Remove URLs, emails, copyright notices

**Files Created**: `TextSanitizer.swift`

---

## Phase 3: Advanced Voice Capabilities

### 3.1 Multi-Voice Dialogue ✅
**Goal**: Detect quotes and switch voices dynamically

- [x] Parse text into narrator/character segments
- [x] Extract speaker attribution from dialogue tags
- [x] Support configurable voice mapping

**Files Created**: `DialogueParser.swift`

### 3.2 Voice Cloning (Future)
**Goal**: Extract style vectors from user audio

- [ ] Port Kokoro speaker encoder to CoreML
- [ ] Create audio input pipeline for 10-second clips
- [ ] Generate compatible JSON style vectors

---

## Phase 4: Architecture & Maintenance

### 4.1 On-Demand Resources
**Goal**: Reduce App Store initial download size

- [ ] Configure ODR tags for TTS models
- [ ] Implement `TtsResourceManager` for download/state management
- [ ] Add progress UI integration hooks

### 4.2 Modular G2P (Future)
**Goal**: Replace GPL espeak-ng dependency

- [ ] Evaluate neural G2P models (Phonemizer, G2P-seq2seq)
- [ ] Create dictionary-based fallback for common words
- [ ] Port selected solution to CoreML

---

## Success Metrics Summary

| Metric | Current | Target | Status |
|--------|---------|--------|--------|
| Bundle Size | ~350MB | <175MB | ⏳ |
| Cold Start | ~3s | <1s | ⏳ |
| Battery (1hr) | ~15% | <8% | ⏳ |
| Speed Range | 1x only | 0.5x-3.0x | ⏳ |
| G2P Cache Hit | N/A | >90% | ✅ |

---

## File Changes Summary

### New Files Created
- `.mobius/scripts/quantize_kokoro.py`
- `.mobius/scripts/analyze_ane.py`
- `Sources/FluidAudioTTS/TextToSpeech/Kokoro/Assets/Lexicon/G2PCache.swift`
- `Sources/FluidAudioTTS/TextToSpeech/Kokoro/Pipeline/Synthesize/KokoroSynthesizer+ANE.swift`
- `Sources/FluidAudioTTS/TextToSpeech/Kokoro/Pipeline/Preprocess/TextSanitizer.swift`
- `Sources/FluidAudioTTS/TextToSpeech/Kokoro/Pipeline/Postprocess/ProsodyProcessor.swift`
- `Sources/FluidAudioTTS/TextToSpeech/Kokoro/Pipeline/Preprocess/DialogueParser.swift`

### Modified Files
- `Sources/FluidAudioTTS/TextToSpeech/TtsModels.swift` (compute units)

