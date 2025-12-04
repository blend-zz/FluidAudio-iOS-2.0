import FluidAudio
import Foundation

// MARK: - Synchronous Cache (Actor-based for thread safety)

/// Thread-safe LRU cache for G2P results using actor isolation.
/// Used internally by EspeakG2P for phonemization with caching.
actor SyncG2PCache {
    private let maxEntries: Int
    private var cache: [String: CacheEntry] = [:]
    private var accessOrder: [String] = []
    private var hits: Int = 0
    private var misses: Int = 0

    private struct CacheEntry {
        let phonemes: [String]?
    }

    init(maxEntries: Int = 50_000) {
        self.maxEntries = maxEntries
    }

    /// Get cached phonemes.
    /// Returns outer nil if not in cache, inner nil if word was cached as unphonemizable.
    func get(_ key: String) -> [String]?? {
        guard let entry = cache[key] else {
            misses += 1
            return nil
        }

        hits += 1

        // Update LRU order
        if let index = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: index)
            accessOrder.append(key)
        }

        return entry.phonemes
    }

    /// Set cached phonemes
    func set(_ key: String, phonemes: [String]?) {
        // Evict if at capacity
        if cache.count >= maxEntries, let oldest = accessOrder.first {
            cache.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }

        cache[key] = CacheEntry(phonemes: phonemes)

        if let index = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: index)
        }
        accessOrder.append(key)
    }

    /// Get statistics
    func statistics() -> G2PCacheStatistics {
        let total = hits + misses
        let hitRate = total > 0 ? Double(hits) / Double(total) : 0
        return G2PCacheStatistics(
            hits: hits,
            misses: misses,
            hitRate: hitRate,
            entryCount: cache.count
        )
    }

    /// Clear the cache
    func clear() {
        cache.removeAll()
        accessOrder.removeAll()
        hits = 0
        misses = 0
    }
}

// MARK: - Async Cache (for use in async contexts)

/// Thread-safe LRU cache for eSpeak G2P phonemization results.
/// Dramatically reduces CPU usage when the same text is re-synthesized.
public actor G2PCache {

    /// Maximum entries before eviction
    private let maxEntries: Int

    /// Cache storage: word -> phonemes
    private var cache: [String: CacheEntry] = [:]

    /// Access order for LRU eviction (most recent at end)
    private var accessOrder: [String] = []

    /// Cache metrics
    private var hits: Int = 0
    private var misses: Int = 0

    private struct CacheEntry {
        let phonemes: [String]?
        let timestamp: Date
    }

    public init(maxEntries: Int = 10_000) {
        self.maxEntries = maxEntries
    }

    /// Get cached phonemes for a word.
    /// Returns outer nil if not in cache, inner nil if word was cached as unphonemizable.
    public func get(_ word: String) -> [String]?? {
        guard let entry = cache[word] else {
            misses += 1
            return nil
        }

        hits += 1

        // Move to end of access order (most recently used)
        if let index = accessOrder.firstIndex(of: word) {
            accessOrder.remove(at: index)
            accessOrder.append(word)
        }

        return entry.phonemes
    }

    /// Store phonemization result (including nil for failed lookups)
    public func set(_ word: String, phonemes: [String]?) {
        // Evict if at capacity
        if cache.count >= maxEntries, let oldest = accessOrder.first {
            cache.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }

        cache[word] = CacheEntry(phonemes: phonemes, timestamp: Date())

        // Update access order
        if let index = accessOrder.firstIndex(of: word) {
            accessOrder.remove(at: index)
        }
        accessOrder.append(word)
    }

    /// Batch lookup for efficiency.
    /// Returns a dictionary with all words that were found in cache.
    /// Words not in cache are omitted from results.
    /// Words cached with nil phonemes (unphonemizable) are included with nil value.
    public func getBatch(_ words: [String]) -> [String: [String]?] {
        var results: [String: [String]?] = [:]
        for word in words {
            // get() returns [String]?? - outer nil means not cached, .some(nil) means cached as unphonemizable
            let cacheResult = get(word)
            if cacheResult != nil {
                // Word is in cache (either with phonemes or cached as nil/unphonemizable)
                results[word] = cacheResult!
            }
            // If cacheResult is nil (outer nil), word is not in cache - don't add to results
        }
        return results
    }

    /// Clear the cache
    public func clear() {
        cache.removeAll()
        accessOrder.removeAll()
        hits = 0
        misses = 0
    }

    /// Cache statistics
    public func statistics() -> G2PCacheStatistics {
        let total = hits + misses
        let hitRate = total > 0 ? Double(hits) / Double(total) : 0
        return G2PCacheStatistics(
            hits: hits,
            misses: misses,
            hitRate: hitRate,
            entryCount: cache.count
        )
    }

    /// Preload cache from a dictionary file
    public func preload(from dictionary: [String: [String]]) {
        for (word, phonemes) in dictionary.prefix(maxEntries) {
            cache[word] = CacheEntry(phonemes: phonemes, timestamp: Date())
            accessOrder.append(word)
        }
    }

    /// Remove specific entries (useful for invalidation)
    public func remove(_ word: String) {
        cache.removeValue(forKey: word)
        if let index = accessOrder.firstIndex(of: word) {
            accessOrder.remove(at: index)
        }
    }
}

/// Statistics for G2P cache performance monitoring
public struct G2PCacheStatistics: Sendable {
    public let hits: Int
    public let misses: Int
    public let hitRate: Double
    public let entryCount: Int

    public var description: String {
        let hitPct = String(format: "%.1f%%", hitRate * 100)
        return "G2PCache: \(entryCount) entries, \(hits) hits, \(misses) misses (\(hitPct) hit rate)"
    }
}

// MARK: - Integration with EspeakG2P

extension EspeakG2P {

    /// Shared G2P cache for runtime lookups (actor-based for thread safety)
    private static let g2pCache = SyncG2PCache(maxEntries: 50_000)

    /// Shared async G2P cache for async contexts
    private static let asyncCache = G2PCache(maxEntries: 50_000)

    // MARK: - Cached Phonemization (async - required for actor-based cache)

    /// Phonemize with caching - for use in async contexts.
    /// This is the preferred method for all phonemization with caching.
    public func phonemizeWithCache(word: String, espeakVoice: String = "en-us") async throws -> [String]? {
        let cacheKey = "\(espeakVoice):\(word.lowercased())"

        // Check cache first
        let cacheResult = await Self.g2pCache.get(cacheKey)
        if cacheResult != nil {
            // Cache hit - return the cached value (may be nil for unphonemizable words)
            return cacheResult!
        }

        // Not cached - perform G2P
        let result = try phonemize(word: word, espeakVoice: espeakVoice)

        // Cache the result (including nil for failures)
        await Self.g2pCache.set(cacheKey, phonemes: result)

        return result
    }

    /// Phonemize with async caching - alias for consistency
    public func phonemizeCached(word: String, espeakVoice: String = "en-us") async throws -> [String]? {
        try await phonemizeWithCache(word: word, espeakVoice: espeakVoice)
    }

    /// Batch phonemize with caching
    public func phonemizeBatchCached(
        words: [String],
        espeakVoice: String = "en-us"
    ) async throws -> [String: [String]?] {
        var results: [String: [String]?] = [:]
        var uncachedWords: [String] = []

        // First pass: check cache
        for word in words {
            let cacheKey = "\(espeakVoice):\(word.lowercased())"
            let cacheResult = await Self.asyncCache.get(cacheKey)
            if cacheResult != nil {
                // Cache hit (including cached nil for unphonemizable words)
                results[word] = cacheResult!
            } else {
                uncachedWords.append(word)
            }
        }

        // Second pass: phonemize uncached words
        for word in uncachedWords {
            let cacheKey = "\(espeakVoice):\(word.lowercased())"
            let phonemes = try phonemize(word: word, espeakVoice: espeakVoice)
            results[word] = phonemes
            await Self.asyncCache.set(cacheKey, phonemes: phonemes)
        }

        return results
    }

    // MARK: - Cache Management

    /// Get cache statistics for monitoring
    public static func cacheStatistics() async -> G2PCacheStatistics {
        await g2pCache.statistics()
    }

    /// Get async cache statistics
    public static func asyncCacheStatistics() async -> G2PCacheStatistics {
        await asyncCache.statistics()
    }

    /// Clear all caches
    public static func clearCache() async {
        await g2pCache.clear()
        await asyncCache.clear()
    }

    /// Preload cache with known word->phoneme mappings
    public static func preloadCache(from dictionary: [String: [String]], voice: String = "en-us") async {
        var prefixed: [String: [String]] = [:]
        for (word, phonemes) in dictionary {
            let key = "\(voice):\(word.lowercased())"
            prefixed[key] = phonemes
        }
        await asyncCache.preload(from: prefixed)
    }
}
