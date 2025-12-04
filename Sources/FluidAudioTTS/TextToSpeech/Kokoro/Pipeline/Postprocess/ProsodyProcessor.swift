import Foundation

/// Handles dynamic pause insertion based on punctuation for natural rhythm.
/// Enables Speechify-style prosody control in synthesized speech.
public struct ProsodyProcessor {

    /// Pause durations in milliseconds for different punctuation
    public struct PauseDurations: Sendable {
        public var comma: Int
        public var semicolon: Int
        public var colon: Int
        public var period: Int
        public var question: Int
        public var exclamation: Int
        public var paragraph: Int
        public var ellipsis: Int
        public var dash: Int

        public init(
            comma: Int = 200,
            semicolon: Int = 350,
            colon: Int = 350,
            period: Int = 500,
            question: Int = 550,
            exclamation: Int = 500,
            paragraph: Int = 800,
            ellipsis: Int = 700,
            dash: Int = 250
        ) {
            self.comma = comma
            self.semicolon = semicolon
            self.colon = colon
            self.period = period
            self.question = question
            self.exclamation = exclamation
            self.paragraph = paragraph
            self.ellipsis = ellipsis
            self.dash = dash
        }

        /// Default durations for natural speech rhythm
        public static let `default` = PauseDurations()

        /// Longer pauses for dramatic effect
        public static let dramatic = PauseDurations(
            comma: 300,
            semicolon: 450,
            colon: 450,
            period: 700,
            question: 750,
            exclamation: 700,
            paragraph: 1200,
            ellipsis: 1000,
            dash: 400
        )

        /// Shorter pauses for faster-paced content
        public static let fast = PauseDurations(
            comma: 100,
            semicolon: 175,
            colon: 175,
            period: 300,
            question: 350,
            exclamation: 300,
            paragraph: 500,
            ellipsis: 400,
            dash: 150
        )

        /// Minimal pauses for rapid speech
        public static let minimal = PauseDurations(
            comma: 50,
            semicolon: 100,
            colon: 100,
            period: 150,
            question: 175,
            exclamation: 150,
            paragraph: 300,
            ellipsis: 200,
            dash: 75
        )

        /// Scale all durations by a factor
        public func scaled(by factor: Double) -> PauseDurations {
            PauseDurations(
                comma: Int(Double(comma) * factor),
                semicolon: Int(Double(semicolon) * factor),
                colon: Int(Double(colon) * factor),
                period: Int(Double(period) * factor),
                question: Int(Double(question) * factor),
                exclamation: Int(Double(exclamation) * factor),
                paragraph: Int(Double(paragraph) * factor),
                ellipsis: Int(Double(ellipsis) * factor),
                dash: Int(Double(dash) * factor)
            )
        }
    }

    private let durations: PauseDurations
    private let sampleRate: Int

    public init(durations: PauseDurations = .default, sampleRate: Int = 24_000) {
        self.durations = durations
        self.sampleRate = sampleRate
    }

    /// Analyze text and return pause annotations
    public func analyzePauses(in text: String) -> [PauseAnnotation] {
        var annotations: [PauseAnnotation] = []
        var currentIndex = text.startIndex
        var skipUntil: String.Index?

        while currentIndex < text.endIndex {
            // Skip if we're in a skip region (e.g., after detecting ellipsis)
            if let skip = skipUntil, currentIndex < skip {
                currentIndex = text.index(after: currentIndex)
                continue
            }
            skipUntil = nil

            let char = text[currentIndex]
            let position = text.distance(from: text.startIndex, to: currentIndex)

            if let (pauseMs, punctuation, endIndex) = pauseInfo(for: char, in: text, at: currentIndex) {
                annotations.append(
                    PauseAnnotation(
                        position: position,
                        durationMs: pauseMs,
                        punctuation: punctuation
                    ))
                skipUntil = endIndex
            }

            currentIndex = text.index(after: currentIndex)
        }

        return annotations
    }

    private func pauseInfo(
        for char: Character,
        in text: String,
        at index: String.Index
    ) -> (durationMs: Int, punctuation: String, endIndex: String.Index?)? {
        switch char {
        case ",":
            return (durations.comma, ",", nil)

        case ";":
            return (durations.semicolon, ";", nil)

        case ":":
            // Check if this is part of a time (e.g., "10:30")
            if isPartOfTime(in: text, at: index) {
                return nil
            }
            return (durations.colon, ":", nil)

        case ".":
            // Check for ellipsis (... or …)
            if let ellipsisEnd = checkEllipsis(in: text, at: index) {
                return (durations.ellipsis, "...", ellipsisEnd)
            }
            // Check if this is an abbreviation or decimal
            if isAbbreviationOrDecimal(in: text, at: index) {
                return nil
            }
            return (durations.period, ".", nil)

        case "…":  // Unicode ellipsis
            return (durations.ellipsis, "…", nil)

        case "?":
            return (durations.question, "?", nil)

        case "!":
            return (durations.exclamation, "!", nil)

        case "—", "–":  // Em dash, en dash
            return (durations.dash, String(char), nil)

        case "\n":
            // Check for paragraph break (double newline)
            if isParagraphBreak(in: text, at: index) {
                return (durations.paragraph, "¶", nil)
            }
            return nil

        default:
            return nil
        }
    }

    private func checkEllipsis(in text: String, at index: String.Index) -> String.Index? {
        var count = 0
        var i = index
        while i < text.endIndex && text[i] == "." {
            count += 1
            i = text.index(after: i)
        }
        if count >= 3 {
            return i
        }
        return nil
    }

    private func isPartOfTime(in text: String, at index: String.Index) -> Bool {
        // Check if surrounded by digits (e.g., "10:30")
        guard index > text.startIndex else { return false }
        let prevIndex = text.index(before: index)
        let nextIndex = text.index(after: index)

        let prevIsDigit = text[prevIndex].isNumber
        let nextIsDigit = nextIndex < text.endIndex && text[nextIndex].isNumber

        return prevIsDigit && nextIsDigit
    }

    private func isAbbreviationOrDecimal(in text: String, at index: String.Index) -> Bool {
        // Check for decimal (e.g., "3.14")
        if index > text.startIndex {
            let prevIndex = text.index(before: index)
            let nextIndex = text.index(after: index)

            if text[prevIndex].isNumber && nextIndex < text.endIndex && text[nextIndex].isNumber {
                return true
            }
        }

        // Check for common abbreviations (e.g., "Dr.", "Mr.", "etc.")
        // Look back up to 4 characters for abbreviation
        var start = index
        var lookback = 0
        while start > text.startIndex && lookback < 4 {
            start = text.index(before: start)
            lookback += 1
        }

        let prefix = String(text[start...index]).lowercased()
        let abbreviations = ["dr.", "mr.", "mrs.", "ms.", "jr.", "sr.", "etc.", "vs.", "i.e.", "e.g."]
        return abbreviations.contains { prefix.hasSuffix($0) }
    }

    private func isParagraphBreak(in text: String, at index: String.Index) -> Bool {
        // Check for consecutive newlines
        let nextIndex = text.index(after: index)
        guard nextIndex < text.endIndex else { return false }
        return text[nextIndex] == "\n"
    }

    /// Generate silence samples for a pause duration
    public func generateSilence(durationMs: Int) -> [Float] {
        let sampleCount = (durationMs * sampleRate) / 1000
        return [Float](repeating: 0, count: sampleCount)
    }

    /// Insert pauses into audio samples based on annotations
    public func insertPauses(
        samples: [Float],
        annotations: [PauseAnnotation],
        samplesPerCharacter: Int
    ) -> [Float] {
        guard !annotations.isEmpty else { return samples }

        var result: [Float] = []
        result.reserveCapacity(samples.count + annotations.count * (durations.period * sampleRate / 1000))

        var lastSampleIndex = 0

        for annotation in annotations.sorted(by: { $0.position < $1.position }) {
            let sampleIndex = min(annotation.position * samplesPerCharacter, samples.count)

            // Add samples up to this point
            if sampleIndex > lastSampleIndex {
                result.append(contentsOf: samples[lastSampleIndex..<sampleIndex])
            }

            // Add pause
            let silence = generateSilence(durationMs: annotation.durationMs)
            result.append(contentsOf: silence)

            lastSampleIndex = sampleIndex
        }

        // Add remaining samples
        if lastSampleIndex < samples.count {
            result.append(contentsOf: samples[lastSampleIndex...])
        }

        return result
    }
}

/// Annotation for a pause position in text
public struct PauseAnnotation: Sendable, Equatable {
    /// Character position in the original text
    public let position: Int

    /// Pause duration in milliseconds
    public let durationMs: Int

    /// The punctuation that triggered this pause
    public let punctuation: String

    public init(position: Int, durationMs: Int, punctuation: String) {
        self.position = position
        self.durationMs = durationMs
        self.punctuation = punctuation
    }
}

// MARK: - Convenience Extensions

extension ProsodyProcessor {

    /// Create a processor with speed-adjusted pauses
    /// - Parameter speed: Speed multiplier (1.0 = normal, 2.0 = half pauses, 0.5 = double pauses)
    public static func adjusted(for speed: Float) -> ProsodyProcessor {
        let factor = 1.0 / Double(max(0.1, speed))
        return ProsodyProcessor(durations: .default.scaled(by: factor))
    }
}
