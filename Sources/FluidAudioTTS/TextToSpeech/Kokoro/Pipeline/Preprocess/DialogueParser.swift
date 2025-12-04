import Foundation

/// Parses text to identify dialogue and narration for multi-voice rendering.
/// Enables Speechify-style voice switching for character dialogue.
public struct DialogueParser {

    /// A segment of parsed text with role assignment
    public struct Segment: Equatable, Sendable {
        /// The role of this segment (narrator or character)
        public enum Role: Equatable, Sendable {
            case narrator
            case character(name: String?)

            public var isNarrator: Bool {
                if case .narrator = self { return true }
                return false
            }

            public var characterName: String? {
                if case .character(let name) = self { return name }
                return nil
            }
        }

        /// The text content of this segment
        public let text: String

        /// The role/voice for this segment
        public let role: Role

        /// Character range in the original text
        public let range: Range<String.Index>

        public init(text: String, role: Role, range: Range<String.Index>) {
            self.text = text
            self.role = role
            self.range = range
        }
    }

    /// Quote detection patterns (open, close)
    private static let quotePatterns: [(open: String, close: String)] = [
        ("\"", "\""),  // Straight double quotes
        ("\u{201C}", "\u{201D}"),  // Curly double quotes " "
        ("\u{2018}", "\u{2019}"),  // Curly single quotes ' '
        ("\u{00AB}", "\u{00BB}"),  // French-style guillemets « »
        ("\u{300C}", "\u{300D}"),  // Japanese brackets 「 」
    ]

    /// Attribution verbs for speaker identification
    private static let attributionVerbs: Set<String> = [
        "said", "asked", "replied", "answered", "shouted", "whispered",
        "exclaimed", "muttered", "called", "cried", "yelled", "screamed",
        "murmured", "stammered", "stuttered", "growled", "snapped",
        "pleaded", "begged", "demanded", "declared", "announced",
        "inquired", "questioned", "responded", "retorted", "added",
        "continued", "began", "finished", "interrupted", "suggested",
        "warned", "promised", "admitted", "confessed", "explained",
        "observed", "noted", "remarked", "commented", "mentioned",
    ]

    /// Compiled attribution pattern
    private static let attributionPattern: NSRegularExpression = {
        let verbs = attributionVerbs.joined(separator: "|")
        let pattern = #"\s*(?:"# + verbs + #")\s+(\w+)"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    public init() {}

    /// Parse text into dialogue and narration segments
    public func parse(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var currentIndex = text.startIndex
        var lastSpeaker: String?

        while currentIndex < text.endIndex {
            // Look for opening quote
            guard let (_, closeQuote, quoteStart) = findNextQuote(in: text, from: currentIndex) else {
                // No more quotes - rest is narration
                let remaining = String(text[currentIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !remaining.isEmpty {
                    segments.append(
                        Segment(
                            text: remaining,
                            role: .narrator,
                            range: currentIndex..<text.endIndex
                        ))
                }
                break
            }

            // Add narration before quote
            if quoteStart > currentIndex {
                let narrationText = String(text[currentIndex..<quoteStart])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !narrationText.isEmpty {
                    segments.append(
                        Segment(
                            text: narrationText,
                            role: .narrator,
                            range: currentIndex..<quoteStart
                        ))

                    // Check for speaker attribution before the quote
                    if let speaker = findAttributionBefore(in: text, before: quoteStart) {
                        lastSpeaker = speaker
                    }
                }
            }

            // Find closing quote
            let searchStart = text.index(after: quoteStart)
            if let closeRange = text.range(of: closeQuote, range: searchStart..<text.endIndex) {
                let dialogueStart = text.index(after: quoteStart)
                let dialogueEnd = closeRange.lowerBound
                let dialogue = String(text[dialogueStart..<dialogueEnd])

                // Look for attribution after quote
                let afterQuote = closeRange.upperBound
                if let speaker = findAttributionAfter(in: text, after: afterQuote) {
                    lastSpeaker = speaker
                }

                let segmentEnd = closeRange.upperBound
                segments.append(
                    Segment(
                        text: dialogue,
                        role: .character(name: lastSpeaker),
                        range: quoteStart..<segmentEnd
                    ))

                currentIndex = afterQuote
            } else {
                // No closing quote - treat rest as dialogue
                let dialogueStart = text.index(after: quoteStart)
                let dialogue = String(text[dialogueStart...])
                segments.append(
                    Segment(
                        text: dialogue,
                        role: .character(name: lastSpeaker),
                        range: quoteStart..<text.endIndex
                    ))
                currentIndex = text.endIndex
            }
        }

        return segments
    }

    /// Parse and merge short adjacent segments of the same role
    public func parseAndMerge(_ text: String, minimumSegmentLength: Int = 20) -> [Segment] {
        let segments = parse(text)
        guard segments.count > 1 else { return segments }

        var merged: [Segment] = []
        var current = segments[0]

        for next in segments.dropFirst() {
            // Merge if same role type and current is short
            let sameRoleType = current.role.isNarrator == next.role.isNarrator
            let currentIsShort = current.text.count < minimumSegmentLength

            if sameRoleType && currentIsShort {
                // Merge segments
                let mergedText = current.text + " " + next.text
                let mergedRange = current.range.lowerBound..<next.range.upperBound
                current = Segment(text: mergedText, role: current.role, range: mergedRange)
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)

        return merged
    }

    private func findNextQuote(
        in text: String,
        from start: String.Index
    ) -> (open: String, close: String, index: String.Index)? {
        var earliest: (String, String, String.Index)?

        for (open, close) in Self.quotePatterns {
            if let range = text.range(of: open, range: start..<text.endIndex) {
                if earliest == nil || range.lowerBound < earliest!.2 {
                    earliest = (open, close, range.lowerBound)
                }
            }
        }

        return earliest
    }

    private func findAttributionAfter(in text: String, after index: String.Index) -> String? {
        guard index < text.endIndex else { return nil }

        // Look in the next 60 characters
        let endOffset = min(60, text.distance(from: index, to: text.endIndex))
        let endIndex = text.index(index, offsetBy: endOffset)
        let searchText = String(text[index..<endIndex])

        let range = NSRange(searchText.startIndex..., in: searchText)
        if let match = Self.attributionPattern.firstMatch(in: searchText, options: [], range: range) {
            if let speakerRange = Range(match.range(at: 1), in: searchText) {
                return String(searchText[speakerRange]).capitalized
            }
        }

        return nil
    }

    private func findAttributionBefore(in text: String, before index: String.Index) -> String? {
        guard index > text.startIndex else { return nil }

        // Look in the previous 60 characters
        let startOffset = min(60, text.distance(from: text.startIndex, to: index))
        let startIndex = text.index(index, offsetBy: -startOffset)
        let searchText = String(text[startIndex..<index])

        let range = NSRange(searchText.startIndex..., in: searchText)
        if let match = Self.attributionPattern.firstMatch(in: searchText, options: [], range: range) {
            if let speakerRange = Range(match.range(at: 1), in: searchText) {
                return String(searchText[speakerRange]).capitalized
            }
        }

        return nil
    }
}

// MARK: - Multi-Voice Configuration

/// Configuration for multi-voice dialogue synthesis
public struct MultiVoiceConfig: Sendable {
    /// Voice ID for narration
    public var narratorVoice: String

    /// Default voice ID for character dialogue when no specific mapping exists
    public var defaultCharacterVoice: String

    /// Mapping of character names to voice IDs
    public var characterVoices: [String: String]

    /// Whether to alternate voices for unattributed dialogue
    public var alternateUnattributedDialogue: Bool

    /// Alternate voices to cycle through for unattributed dialogue
    public var alternateVoices: [String]

    public init(
        narratorVoice: String = "af_heart",
        defaultCharacterVoice: String = "am_adam",
        characterVoices: [String: String] = [:],
        alternateUnattributedDialogue: Bool = false,
        alternateVoices: [String] = ["am_adam", "af_bella"]
    ) {
        self.narratorVoice = narratorVoice
        self.defaultCharacterVoice = defaultCharacterVoice
        self.characterVoices = characterVoices
        self.alternateUnattributedDialogue = alternateUnattributedDialogue
        self.alternateVoices = alternateVoices
    }

    /// Default configuration with neutral narrator and distinct character voice
    public static let `default` = MultiVoiceConfig()

    /// Configuration optimized for fiction with multiple characters
    public static let fiction = MultiVoiceConfig(
        narratorVoice: "af_heart",
        defaultCharacterVoice: "am_michael",
        alternateUnattributedDialogue: true,
        alternateVoices: ["am_michael", "af_jessica", "am_adam", "af_bella"]
    )

    /// Get the voice ID for a segment
    public func voice(for segment: DialogueParser.Segment, alternateIndex: Int = 0) -> String {
        switch segment.role {
        case .narrator:
            return narratorVoice
        case .character(let name):
            if let name = name, let voice = characterVoices[name] {
                return voice
            }
            if alternateUnattributedDialogue && !alternateVoices.isEmpty {
                return alternateVoices[alternateIndex % alternateVoices.count]
            }
            return defaultCharacterVoice
        }
    }
}

// MARK: - Convenience Extensions

extension DialogueParser.Segment: CustomStringConvertible {
    public var description: String {
        let roleStr: String
        switch role {
        case .narrator:
            roleStr = "Narrator"
        case .character(let name):
            roleStr = name.map { "Character(\($0))" } ?? "Character(unknown)"
        }
        let preview = text.prefix(40)
        let ellipsis = text.count > 40 ? "..." : ""
        return "[\(roleStr)] \"\(preview)\(ellipsis)\""
    }
}

extension Array where Element == DialogueParser.Segment {
    /// Get all unique character names from segments
    public var characterNames: [String] {
        compactMap { segment -> String? in
            if case .character(let name) = segment.role {
                return name
            }
            return nil
        }.uniqued()
    }

    /// Count of narrator segments
    public var narratorSegmentCount: Int {
        filter { $0.role.isNarrator }.count
    }

    /// Count of character segments
    public var characterSegmentCount: Int {
        filter { !$0.role.isNarrator }.count
    }
}

// Helper extension for unique elements
extension Array where Element: Hashable {
    fileprivate func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
