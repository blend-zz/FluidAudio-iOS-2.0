# VoiceReader Integration Handoff

## Context

This document describes the TTS enhancements made to the **FluidAudio** library for integration into the **VoiceReader** app. These changes transform FluidAudio's Kokoro TTS into a Speechify-comparable local engine with better performance, battery efficiency, and advanced features.

**FluidAudio Repository**: Local iOS wrapper around Kokoro TTS (82M parameter model)
**Target App**: VoiceReader (screen reader / document reader app)

---

## Summary of Changes

### New Swift Files Created

| File Path | Purpose |
|-----------|---------|
| `Sources/FluidAudioTTS/.../Lexicon/G2PCache.swift` | LRU cache for phonemization results |
| `Sources/FluidAudioTTS/.../Synthesize/KokoroSynthesizer+ANE.swift` | ANE (Neural Engine) optimizations |
| `Sources/FluidAudioTTS/.../Preprocess/TextSanitizer.swift` | PDF/document artifact removal |
| `Sources/FluidAudioTTS/.../Postprocess/ProsodyProcessor.swift` | Smart pause insertion |
| `Sources/FluidAudioTTS/.../Preprocess/DialogueParser.swift` | Multi-voice dialogue detection |

### Modified Files

| File | Change |
|------|--------|
| `TtsModels.swift` | Compute units changed from `.cpuAndGPU` → `.cpuAndNeuralEngine` for battery savings |

---

## Feature 1: G2P Caching (Performance)

### What It Does
Caches eSpeak-NG phonemization results in an LRU cache (50,000 entries). When users replay or rewind content, the expensive G2P conversion is skipped.

### API Usage

```swift
import FluidAudioTTS

// Single word with caching (replaces phonemize())
let phonemes = try await EspeakG2P.shared.phonemizeCached(word: "hello")

// Batch phonemization with caching
let results = try await EspeakG2P.shared.phonemizeBatchCached(
    words: ["hello", "world", "test"],
    espeakVoice: "en-us"
)

// Monitor cache performance
let stats = await EspeakG2P.cacheStatistics()
print(stats.description) // "G2PCache: 1234 entries, 5000 hits, 500 misses (90.9% hit rate)"

// Clear cache if needed (e.g., language change)
await EspeakG2P.clearCache()

// Preload cache from known dictionary
await EspeakG2P.preloadCache(from: myDictionary, voice: "en-us")
```

### Integration Notes
- The cache is **actor-isolated** (thread-safe)
- Cache persists for the app session; cleared on app termination
- Consider preloading common words from VoiceReader's dictionary

---

## Feature 2: ANE (Apple Neural Engine) Optimization

### What It Does
Forces CoreML to prefer the Neural Engine over GPU for TTS inference. ANE is significantly more power-efficient, reducing battery drain during long reading sessions.

### Automatic Behavior
This is **automatic** - no code changes needed in VoiceReader. The change is in `TtsModels.swift`:

```swift
// Before:
let computeUnits: MLComputeUnits = .cpuAndGPU

// After:
let computeUnits: MLComputeUnits = .cpuAndNeuralEngine
```

### Additional APIs (Optional)

```swift
import FluidAudioTTS

// Check if device has optimal ANE support (A15+/M1+)
if KokoroSynthesizer.supportsOptimalANE() {
    print("Device has modern ANE")
}

// Get recommended compute units for current device
let units = KokoroSynthesizer.recommendedComputeUnits()
```

### Memory Pool (Advanced)
For high-frequency synthesis, use `TTSMemoryPool` to reduce allocation overhead:

```swift
let pool = TTSMemoryPool()

// Rent pre-allocated arrays
let inputIds = try await pool.rentInputIds(tokenLength: 124)
let attentionMask = try await pool.rentAttentionMask(tokenLength: 124)
let refStyle = try await pool.rentRefStyle(dimension: 256)
let phases = try await pool.rentPhases()

// After inference, return to pool
await pool.recycle(
    inputIds: inputIds,
    attentionMask: attentionMask,
    refStyle: refStyle,
    phases: phases
)
```

---

## Feature 3: Text Sanitization (PDF Cleaning)

### What It Does
Removes common document artifacts before synthesis:
- Page numbers ("Page 12", "- 3 -", "12 of 100")
- Citations ("[1]", "[12,15]", "(Smith 2020)")
- Figure/Table labels ("Figure 3.2:", "Table 1")
- URLs and emails
- Copyright notices
- Hyphenation at line breaks ("some-\nword" → "someword")

### API Usage

```swift
import FluidAudioTTS

// Quick sanitization with String extension
let cleanText = pdfText.sanitizedForTTS()

// Using preset configurations
let sanitizer = TextSanitizer.academicPaper  // For research papers
let sanitizer = TextSanitizer.ebook          // For ebooks
let sanitizer = TextSanitizer.webContent     // For web articles

let clean = sanitizer.sanitize(rawText)

// Custom options
let custom = TextSanitizer(options: [
    .pageNumbers,
    .citations,
    .hyphenation,
    .extraWhitespace,
])
let clean = custom.sanitize(rawText)
```

### Available Options

```swift
public struct Options: OptionSet {
    static let pageNumbers        // "Page 12", "1 of 10"
    static let headers            // Repeated header text
    static let footers            // Repeated footer text
    static let citations          // [1], (Smith 2020)
    static let figureLabels       // "Figure 3:", "Fig. 2.1"
    static let tableLabels        // "Table 1:", "TABLE 3.2"
    static let urlsAndEmails      // https://..., user@email.com
    static let copyrightNotices   // © 2024, Copyright...
    static let hyphenation        // Fixes "word-\n" breaks
    static let extraWhitespace    // Collapses multiple spaces/newlines
    
    static let all                // All options
    static let minimal            // pageNumbers + citations + whitespace
    static let pdfDocument        // Common PDF artifacts
}
```

### Integration Example for VoiceReader

```swift
// In your PDF/document processor
func prepareTextForSpeech(_ rawText: String, documentType: DocumentType) -> String {
    let sanitizer: TextSanitizer
    
    switch documentType {
    case .pdf:
        sanitizer = TextSanitizer(options: .pdfDocument)
    case .ebook:
        sanitizer = .ebook
    case .webpage:
        sanitizer = .webContent
    case .plainText:
        sanitizer = TextSanitizer(options: .extraWhitespace)
    }
    
    return sanitizer.sanitize(rawText)
}
```

---

## Feature 4: Smart Pausing (Prosody)

### What It Does
Analyzes text for punctuation and inserts natural pauses:
- Commas: 200ms
- Periods: 500ms
- Questions: 550ms
- Paragraphs: 800ms
- Ellipsis: 700ms

### API Usage

```swift
import FluidAudioTTS

// Create processor with default durations
let prosody = ProsodyProcessor()

// Or use presets
let prosody = ProsodyProcessor(durations: .dramatic)  // Longer pauses
let prosody = ProsodyProcessor(durations: .fast)      // Shorter pauses
let prosody = ProsodyProcessor(durations: .minimal)   // Rapid speech

// Analyze text for pause points
let pauses = prosody.analyzePauses(in: text)
// Returns: [PauseAnnotation(position: 12, durationMs: 500, punctuation: "."), ...]

// Generate silence samples for a pause
let silenceSamples = prosody.generateSilence(durationMs: 500)

// Adjust pauses based on playback speed
let fastProsody = ProsodyProcessor.adjusted(for: 2.0)  // Half the pause durations
```

### PauseAnnotation Structure

```swift
public struct PauseAnnotation {
    let position: Int      // Character position in text
    let durationMs: Int    // Pause duration in milliseconds
    let punctuation: String // What triggered it: ".", ",", "?", "¶", etc.
}
```

### Integration with Synthesis

```swift
// Option 1: Pre-analyze and modify chunk boundaries
let pauses = prosody.analyzePauses(in: text)
// Use pause positions to inform KokoroChunker's sentence splitting

// Option 2: Post-process audio (insert silence)
let samplesPerChar = estimatedSamplesPerCharacter()
let modifiedAudio = prosody.insertPauses(
    samples: originalSamples,
    annotations: pauses,
    samplesPerCharacter: samplesPerChar
)
```

---

## Feature 5: Multi-Voice Dialogue

### What It Does
Parses text to identify dialogue vs. narration, enabling different voices for:
- **Narrator**: Descriptive text outside quotes
- **Characters**: Text inside quotation marks

Detects speaker attribution: `"Hello," said John` → assigns "John" as speaker.

### API Usage

```swift
import FluidAudioTTS

// Parse text into segments
let parser = DialogueParser()
let segments = parser.parse("""
    The room fell silent. "I can't believe it," said Mary.
    John nodded. "Neither can I."
    """)

// Result:
// segments[0]: Narrator, "The room fell silent."
// segments[1]: Character(Mary), "I can't believe it,"
// segments[2]: Narrator, "John nodded."
// segments[3]: Character(John), "Neither can I."

// Check segment properties
for segment in segments {
    switch segment.role {
    case .narrator:
        print("Narrator: \(segment.text)")
    case .character(let name):
        print("Character \(name ?? "unknown"): \(segment.text)")
    }
}

// Get all character names detected
let characters = segments.characterNames  // ["Mary", "John"]
```

### Multi-Voice Configuration

```swift
// Configure voice assignments
var config = MultiVoiceConfig()
config.narratorVoice = "af_heart"           // Female narrator
config.defaultCharacterVoice = "am_adam"    // Male default for characters
config.characterVoices = [
    "Mary": "af_bella",
    "John": "am_michael",
]

// Get voice for a segment
let voice = config.voice(for: segment)

// Or use presets
let config = MultiVoiceConfig.fiction  // Optimized for novels
```

### Full Integration Example

```swift
func synthesizeWithMultiVoice(text: String) async throws -> Data {
    let parser = DialogueParser()
    let segments = parser.parseAndMerge(text, minimumSegmentLength: 20)
    
    var config = MultiVoiceConfig()
    config.narratorVoice = "af_heart"
    config.defaultCharacterVoice = "am_michael"
    
    var allSamples: [Float] = []
    
    for (index, segment) in segments.enumerated() {
        let voice = config.voice(for: segment, alternateIndex: index)
        
        let result = try await KokoroSynthesizer.synthesizeDetailed(
            text: segment.text,
            voice: voice
        )
        
        allSamples.append(contentsOf: result.chunks.flatMap { $0.samples })
    }
    
    return try AudioWAV.data(
        from: allSamples,
        sampleRate: Double(TtsConstants.audioSampleRate)
    )
}
```

---

## Complete VoiceReader Integration Example

Here's a full example of how VoiceReader might use all these features:

```swift
import FluidAudioTTS

class LocalTTSEngine {
    private let prosodyProcessor: ProsodyProcessor
    private let textSanitizer: TextSanitizer
    private let dialogueParser: DialogueParser
    private var multiVoiceConfig: MultiVoiceConfig
    
    init() {
        self.prosodyProcessor = ProsodyProcessor(durations: .default)
        self.textSanitizer = TextSanitizer(options: .pdfDocument)
        self.dialogueParser = DialogueParser()
        self.multiVoiceConfig = .default
    }
    
    /// Main synthesis entry point for VoiceReader
    func synthesize(
        text: String,
        documentType: DocumentType,
        enableMultiVoice: Bool,
        speed: Float
    ) async throws -> SynthesisResult {
        
        // Step 1: Clean the text
        let cleanText = textSanitizer.sanitize(text)
        
        // Step 2: Decide synthesis strategy
        if enableMultiVoice {
            return try await synthesizeMultiVoice(cleanText, speed: speed)
        } else {
            return try await synthesizeSingleVoice(cleanText, speed: speed)
        }
    }
    
    private func synthesizeSingleVoice(_ text: String, speed: Float) async throws -> SynthesisResult {
        // Use default TtsManager
        let manager = TtSManager()
        try await manager.initialize()
        
        return try await manager.synthesizeDetailed(
            text: text,
            voiceSpeed: speed
        )
    }
    
    private func synthesizeMultiVoice(_ text: String, speed: Float) async throws -> SynthesisResult {
        let segments = dialogueParser.parseAndMerge(text)
        
        // ... synthesize each segment with appropriate voice
        // (see full example above)
    }
    
    /// Get cache statistics for debugging/analytics
    func getCacheStats() async -> G2PCacheStatistics {
        await EspeakG2P.cacheStatistics()
    }
}
```

---

## Model Quantization (Optional - Phase 1.1)

Python scripts are provided in `.mobius/scripts/` for model quantization:

```bash
# Quantize to Float16 (recommended - 50% size reduction)
python .mobius/scripts/quantize_kokoro.py \
    --input path/to/kokoro.mlpackage \
    --output kokoro_fp16.mlpackage \
    --precision float16 \
    --validate

# Analyze ANE compatibility
python .mobius/scripts/analyze_ane.py --model kokoro.mlpackage
```

This reduces bundle size from ~350MB to ~175MB with imperceptible quality loss.

---

## Important Notes

1. **Thread Safety**: All new components use Swift actors or are struct-based (value types)

2. **Sample Rate**: Kokoro outputs 24kHz audio (`TtsConstants.audioSampleRate`)

3. **Voice IDs**: Available voices are in `TtsConstants.availableVoices`
   - Recommended: `af_heart` (female), `am_adam` (male)

4. **Existing API**: The main `TtSManager` API is unchanged - these are additive features

5. **Build Requirements**: 
   - iOS 15.0+ / macOS 12.0+
   - Swift 5.10+
   - Xcode 15+

---

## Questions?

The implementation follows patterns already established in FluidAudio:
- Actors for thread-safe mutable state
- Async/await for all I/O operations
- Protocol conformance to `Sendable` where needed
- Flattened control flow with guard statements

All new code builds and passes the existing test suite.

