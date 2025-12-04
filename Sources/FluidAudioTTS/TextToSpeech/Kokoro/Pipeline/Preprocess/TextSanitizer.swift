import Foundation

/// Sanitizes text by removing common PDF artifacts, headers, footers, and noise.
/// Use before synthesis to improve output quality when processing extracted PDF text.
public struct TextSanitizer {

    /// Sanitization options
    public struct Options: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let pageNumbers = Options(rawValue: 1 << 0)
        public static let headers = Options(rawValue: 1 << 1)
        public static let footers = Options(rawValue: 1 << 2)
        public static let citations = Options(rawValue: 1 << 3)
        public static let figureLabels = Options(rawValue: 1 << 4)
        public static let tableLabels = Options(rawValue: 1 << 5)
        public static let urlsAndEmails = Options(rawValue: 1 << 6)
        public static let copyrightNotices = Options(rawValue: 1 << 7)
        public static let hyphenation = Options(rawValue: 1 << 8)
        public static let extraWhitespace = Options(rawValue: 1 << 9)

        public static let all: Options = [
            .pageNumbers, .headers, .footers, .citations,
            .figureLabels, .tableLabels, .urlsAndEmails,
            .copyrightNotices, .hyphenation, .extraWhitespace,
        ]

        public static let minimal: Options = [.pageNumbers, .citations, .extraWhitespace]

        public static let pdfDocument: Options = [
            .pageNumbers, .citations, .figureLabels, .tableLabels,
            .hyphenation, .extraWhitespace,
        ]
    }

    private let options: Options

    // MARK: - Compiled Regex Patterns

    private static let patterns: [Options: NSRegularExpression] = {
        var patterns: [Options: NSRegularExpression] = [:]

        // Page numbers: "Page 1", "1", "- 1 -", "1 of 10", "p. 12", etc.
        patterns[.pageNumbers] = try! NSRegularExpression(
            pattern: #"(?i)(?:^|\n)\s*(?:(?:page|p\.?)\s*)?\d+(?:\s*(?:of|\/)\s*\d+)?\s*(?:$|\n)"#,
            options: [.anchorsMatchLines]
        )

        // Citations: [1], [12], [1,2,3], [1-5], (Smith 2020), (Smith et al., 2020), etc.
        patterns[.citations] = try! NSRegularExpression(
            pattern: #"\[\d+(?:[,\-–]\s*\d+)*\]|\(\w+(?:\s+et\s+al\.?)?\s*,?\s*\d{4}(?:[a-z])?\)"#,
            options: []
        )

        // Figure labels: "Figure 1", "Fig. 3.2", "FIGURE 1:", "Figure 1a", etc.
        patterns[.figureLabels] = try! NSRegularExpression(
            pattern: #"(?i)\b(?:fig(?:ure)?\.?\s*\d+(?:\.\d+)?[a-z]?:?\s*)"#,
            options: []
        )

        // Table labels: "Table 1", "TABLE 3.2:", "Table 1a", etc.
        patterns[.tableLabels] = try! NSRegularExpression(
            pattern: #"(?i)\b(?:table\s*\d+(?:\.\d+)?[a-z]?:?\s*)"#,
            options: []
        )

        // URLs and emails
        patterns[.urlsAndEmails] = try! NSRegularExpression(
            pattern: #"(?:https?://\S+|www\.\S+|\S+@\S+\.\S+)"#,
            options: []
        )

        // Copyright notices: "© 2024", "(c) 2024 Company", "Copyright 2024", etc.
        patterns[.copyrightNotices] = try! NSRegularExpression(
            pattern: #"(?i)(?:©|\(c\)|copyright)\s*\d{4}[^\n]*"#,
            options: []
        )

        // Word hyphenation at line breaks: "some-\nword" -> "someword"
        patterns[.hyphenation] = try! NSRegularExpression(
            pattern: #"(\w+)-\s*\n\s*(\w+)"#,
            options: []
        )

        return patterns
    }()

    // Patterns for whitespace cleanup
    private static let multipleSpaces = try! NSRegularExpression(pattern: #" {2,}"#, options: [])
    private static let multipleNewlines = try! NSRegularExpression(pattern: #"\n{3,}"#, options: [])

    public init(options: Options = .all) {
        self.options = options
    }

    /// Sanitize text by removing artifacts based on configured options
    public func sanitize(_ text: String) -> String {
        var result = text

        // Apply hyphenation fix first (joins words before other processing)
        if options.contains(.hyphenation), let pattern = Self.patterns[.hyphenation] {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: "$1$2"
            )
        }

        // Apply each enabled removal pattern
        for (option, pattern) in Self.patterns where option != .hyphenation {
            if options.contains(option) {
                let range = NSRange(result.startIndex..., in: result)
                result = pattern.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: range,
                    withTemplate: ""
                )
            }
        }

        // Clean up whitespace
        if options.contains(.extraWhitespace) {
            result = collapseWhitespace(result)
        }

        return result
    }

    /// Sanitize with specific options (ignoring instance options)
    public func sanitize(_ text: String, with specificOptions: Options) -> String {
        let customSanitizer = TextSanitizer(options: specificOptions)
        return customSanitizer.sanitize(text)
    }

    private func collapseWhitespace(_ text: String) -> String {
        var result = text

        // Replace multiple spaces with single space
        var range = NSRange(result.startIndex..., in: result)
        result = Self.multipleSpaces.stringByReplacingMatches(
            in: result,
            options: [],
            range: range,
            withTemplate: " "
        )

        // Replace 3+ newlines with double newline (preserve paragraph breaks)
        range = NSRange(result.startIndex..., in: result)
        result = Self.multipleNewlines.stringByReplacingMatches(
            in: result,
            options: [],
            range: range,
            withTemplate: "\n\n"
        )

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Convenience Extensions

extension TextSanitizer {

    /// Create a sanitizer optimized for academic papers
    public static var academicPaper: TextSanitizer {
        TextSanitizer(options: [
            .pageNumbers, .citations, .figureLabels, .tableLabels,
            .hyphenation, .extraWhitespace,
        ])
    }

    /// Create a sanitizer optimized for ebooks
    public static var ebook: TextSanitizer {
        TextSanitizer(options: [
            .pageNumbers, .hyphenation, .extraWhitespace,
        ])
    }

    /// Create a sanitizer optimized for web content
    public static var webContent: TextSanitizer {
        TextSanitizer(options: [
            .urlsAndEmails, .extraWhitespace,
        ])
    }
}

// MARK: - String Extension

extension String {

    /// Sanitize this string for TTS synthesis
    public func sanitizedForTTS(options: TextSanitizer.Options = .pdfDocument) -> String {
        TextSanitizer(options: options).sanitize(self)
    }
}
