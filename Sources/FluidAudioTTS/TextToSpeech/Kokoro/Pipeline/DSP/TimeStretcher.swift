import Accelerate
import Foundation

/// High-quality time stretching without pitch shift using WSOLA (Waveform Similarity Overlap-Add).
/// Enables Speechify-style 0.5x to 3.0x playback without the "chipmunk effect".
///
/// Uses Apple's Accelerate framework for optimized DSP operations.
public struct TimeStretcher {

    /// Configuration for time stretching
    public struct Configuration: Sendable {
        /// Analysis window size in samples (larger = better quality, more latency)
        public var windowSize: Int

        /// Overlap between windows as a fraction (0.5 = 50% overlap)
        public var overlapRatio: Float

        /// Maximum search range for best overlap position (in samples)
        public var seekWindowSize: Int

        /// Sample rate of the audio
        public var sampleRate: Int

        public init(
            windowSize: Int = 1024,
            overlapRatio: Float = 0.5,
            seekWindowSize: Int = 64,
            sampleRate: Int = 24_000
        ) {
            self.windowSize = windowSize
            self.overlapRatio = overlapRatio
            self.seekWindowSize = seekWindowSize
            self.sampleRate = sampleRate
        }

        /// Default configuration optimized for speech
        public static let speech = Configuration(
            windowSize: 1024,
            overlapRatio: 0.5,
            seekWindowSize: 64,
            sampleRate: 24_000
        )

        /// Configuration for higher quality (more CPU)
        public static let highQuality = Configuration(
            windowSize: 2048,
            overlapRatio: 0.75,
            seekWindowSize: 128,
            sampleRate: 24_000
        )

        /// Configuration for lower latency (less CPU)
        public static let lowLatency = Configuration(
            windowSize: 512,
            overlapRatio: 0.25,
            seekWindowSize: 32,
            sampleRate: 24_000
        )
    }

    private let config: Configuration
    private let hopSize: Int
    private let window: [Float]

    public init(config: Configuration = .speech) {
        self.config = config
        self.hopSize = Int(Float(config.windowSize) * (1.0 - config.overlapRatio))
        self.window = Self.createHannWindow(size: config.windowSize)
    }

    /// Time-stretch audio without changing pitch
    /// - Parameters:
    ///   - samples: Input audio samples (mono, Float32)
    ///   - factor: Speed factor (2.0 = 2x faster/half duration, 0.5 = half speed/double duration)
    /// - Returns: Time-stretched audio samples
    public func stretch(_ samples: [Float], factor: Float) -> [Float] {
        // Clamp factor to reasonable range
        let clampedFactor = max(0.25, min(4.0, factor))

        // No processing needed if factor is ~1.0
        if abs(clampedFactor - 1.0) < 0.01 {
            return samples
        }

        // Handle very short audio
        if samples.count < config.windowSize * 2 {
            return stretchShortAudio(samples, factor: clampedFactor)
        }

        // Use WSOLA algorithm
        return wsolaStretch(samples, factor: clampedFactor)
    }

    /// WSOLA (Waveform Similarity Overlap-Add) time stretching
    private func wsolaStretch(_ samples: [Float], factor: Float) -> [Float] {
        let inputLength = samples.count
        let outputLength = Int(Float(inputLength) / factor)

        // Calculate hop sizes
        let analysisHop = hopSize
        let synthesisHop = Int(Float(hopSize) / factor)

        // Allocate output buffer
        var output = [Float](repeating: 0, count: outputLength + config.windowSize)
        var outputWeights = [Float](repeating: 0, count: output.count)

        var inputPosition = 0
        var outputPosition = 0
        var previousBestOffset = 0

        while inputPosition + config.windowSize <= inputLength && outputPosition + config.windowSize <= output.count {
            // Find best overlap position using cross-correlation
            let bestOffset = findBestOverlapPosition(
                samples: samples,
                inputPosition: inputPosition,
                previousOffset: previousBestOffset
            )

            let adjustedInputPosition = max(0, min(inputLength - config.windowSize, inputPosition + bestOffset))

            // Extract and window the frame
            var frame = [Float](repeating: 0, count: config.windowSize)
            for i in 0..<config.windowSize {
                let srcIdx = adjustedInputPosition + i
                if srcIdx < inputLength {
                    frame[i] = samples[srcIdx] * window[i]
                }
            }

            // Overlap-add to output
            for i in 0..<config.windowSize {
                let outIdx = outputPosition + i
                if outIdx < output.count {
                    output[outIdx] += frame[i]
                    outputWeights[outIdx] += window[i]
                }
            }

            previousBestOffset = bestOffset
            inputPosition += analysisHop
            outputPosition += synthesisHop
        }

        // Normalize by overlap weights
        for i in 0..<output.count {
            if outputWeights[i] > 0.001 {
                output[i] /= outputWeights[i]
            }
        }

        // Trim to actual output length
        let actualLength = min(outputLength, output.count)
        return Array(output.prefix(actualLength))
    }

    /// Find the best position for overlap using cross-correlation
    private func findBestOverlapPosition(
        samples: [Float],
        inputPosition: Int,
        previousOffset: Int
    ) -> Int {
        let seekRange = config.seekWindowSize
        let windowSize = config.windowSize

        // Search around the expected position
        let searchStart = max(-seekRange, -inputPosition)
        let searchEnd = min(seekRange, samples.count - inputPosition - windowSize)

        if searchStart >= searchEnd {
            return 0
        }

        var bestOffset = 0
        var bestCorrelation: Float = -.greatestFiniteMagnitude

        // Use a smaller correlation window for efficiency
        let correlationWindowSize = min(windowSize / 4, 256)

        for offset in stride(from: searchStart, to: searchEnd, by: 2) {
            let pos = inputPosition + offset

            guard pos >= 0, pos + correlationWindowSize <= samples.count else { continue }

            // Calculate normalized cross-correlation
            var correlation: Float = 0
            var energy1: Float = 0
            var energy2: Float = 0

            for i in 0..<correlationWindowSize {
                let s1 = samples[pos + i]
                let s2 = i < windowSize ? window[i] : 0
                correlation += s1 * s2
                energy1 += s1 * s1
                energy2 += s2 * s2
            }

            let normFactor = sqrt(energy1 * energy2)
            if normFactor > 0.001 {
                correlation /= normFactor
            }

            // Prefer staying close to previous offset for smoother transitions
            let distancePenalty = Float(abs(offset - previousOffset)) * 0.001
            correlation -= distancePenalty

            if correlation > bestCorrelation {
                bestCorrelation = correlation
                bestOffset = offset
            }
        }

        return bestOffset
    }

    /// Handle very short audio that can't use full WSOLA
    private func stretchShortAudio(_ samples: [Float], factor: Float) -> [Float] {
        let outputLength = Int(Float(samples.count) / factor)

        if outputLength <= 0 {
            return []
        }

        var output = [Float](repeating: 0, count: outputLength)

        // Linear interpolation for short segments
        for i in 0..<outputLength {
            let srcPosition = Float(i) * factor
            let srcIndex = Int(srcPosition)
            let fraction = srcPosition - Float(srcIndex)

            if srcIndex + 1 < samples.count {
                output[i] = samples[srcIndex] * (1.0 - fraction) + samples[srcIndex + 1] * fraction
            } else if srcIndex < samples.count {
                output[i] = samples[srcIndex]
            }
        }

        return output
    }

    /// Create a Hann window for smooth overlap-add
    private static func createHannWindow(size: Int) -> [Float] {
        var window = [Float](repeating: 0, count: size)
        let factor = 2.0 * Float.pi / Float(size - 1)

        for i in 0..<size {
            window[i] = 0.5 * (1.0 - cos(factor * Float(i)))
        }

        return window
    }
}

// MARK: - Accelerate-Optimized Version

extension TimeStretcher {

    /// Accelerate-optimized time stretching using vDSP
    /// Use this for better performance on longer audio
    public func stretchOptimized(_ samples: [Float], factor: Float) -> [Float] {
        let clampedFactor = max(0.25, min(4.0, factor))

        if abs(clampedFactor - 1.0) < 0.01 {
            return samples
        }

        if samples.count < config.windowSize * 2 {
            return stretchShortAudio(samples, factor: clampedFactor)
        }

        return wsolaStretchOptimized(samples, factor: clampedFactor)
    }

    /// Optimized WSOLA using vDSP operations
    private func wsolaStretchOptimized(_ samples: [Float], factor: Float) -> [Float] {
        let inputLength = samples.count
        let outputLength = Int(Float(inputLength) / factor)

        let analysisHop = hopSize
        let synthesisHop = Int(Float(hopSize) / factor)

        var output = [Float](repeating: 0, count: outputLength + config.windowSize)
        var outputWeights = [Float](repeating: 0, count: output.count)

        var inputPosition = 0
        var outputPosition = 0

        // Pre-allocate frame buffer
        var frame = [Float](repeating: 0, count: config.windowSize)

        while inputPosition + config.windowSize <= inputLength && outputPosition + config.windowSize <= output.count {

            let safeInputPos = max(0, min(inputLength - config.windowSize, inputPosition))

            // Extract frame using vDSP
            samples.withUnsafeBufferPointer { samplesPtr in
                frame.withUnsafeMutableBufferPointer { framePtr in
                    guard let srcBase = samplesPtr.baseAddress,
                        let dstBase = framePtr.baseAddress
                    else { return }

                    // Copy samples to frame
                    vDSP_mmov(
                        srcBase.advanced(by: safeInputPos),
                        dstBase,
                        vDSP_Length(config.windowSize),
                        1,
                        vDSP_Length(config.windowSize),
                        1
                    )
                }
            }

            // Apply window using vDSP_vmul
            frame.withUnsafeMutableBufferPointer { framePtr in
                window.withUnsafeBufferPointer { windowPtr in
                    guard let frameBase = framePtr.baseAddress,
                        let windowBase = windowPtr.baseAddress
                    else { return }

                    vDSP_vmul(
                        frameBase, 1,
                        windowBase, 1,
                        frameBase, 1,
                        vDSP_Length(config.windowSize)
                    )
                }
            }

            // Overlap-add using vDSP_vadd
            output.withUnsafeMutableBufferPointer { outputPtr in
                frame.withUnsafeBufferPointer { framePtr in
                    guard let outBase = outputPtr.baseAddress,
                        let frameBase = framePtr.baseAddress
                    else { return }

                    let outStart = outBase.advanced(by: outputPosition)
                    vDSP_vadd(
                        outStart, 1,
                        frameBase, 1,
                        outStart, 1,
                        vDSP_Length(config.windowSize)
                    )
                }
            }

            // Accumulate weights
            outputWeights.withUnsafeMutableBufferPointer { weightsPtr in
                window.withUnsafeBufferPointer { windowPtr in
                    guard let weightsBase = weightsPtr.baseAddress,
                        let windowBase = windowPtr.baseAddress
                    else { return }

                    let weightsStart = weightsBase.advanced(by: outputPosition)
                    vDSP_vadd(
                        weightsStart, 1,
                        windowBase, 1,
                        weightsStart, 1,
                        vDSP_Length(config.windowSize)
                    )
                }
            }

            inputPosition += analysisHop
            outputPosition += synthesisHop
        }

        // Normalize by weights
        let outputCount = output.count
        for i in 0..<outputCount {
            if outputWeights[i] > 0.001 {
                output[i] /= outputWeights[i]
            }
        }

        return Array(output.prefix(outputLength))
    }
}

// MARK: - Convenience Extensions

extension TimeStretcher {

    /// Stretch audio with automatic quality selection based on factor
    public func stretchAuto(_ samples: [Float], factor: Float) -> [Float] {
        // Use optimized version for most cases
        return stretchOptimized(samples, factor: factor)
    }

    /// Process audio in chunks for memory efficiency on long audio
    public func stretchChunked(
        _ samples: [Float],
        factor: Float,
        chunkSize: Int = 48_000  // 2 seconds at 24kHz
    ) -> [Float] {
        let clampedFactor = max(0.25, min(4.0, factor))

        if abs(clampedFactor - 1.0) < 0.01 {
            return samples
        }

        if samples.count <= chunkSize {
            return stretchOptimized(samples, factor: clampedFactor)
        }

        var output: [Float] = []
        let overlap = config.windowSize

        var position = 0
        while position < samples.count {
            let chunkEnd = min(position + chunkSize + overlap, samples.count)
            let chunk = Array(samples[position..<chunkEnd])

            let stretchedChunk = stretchOptimized(chunk, factor: clampedFactor)

            if position == 0 {
                output.append(contentsOf: stretchedChunk)
            } else {
                // Crossfade with previous chunk
                let crossfadeLength = min(overlap, stretchedChunk.count, output.count)
                let startIndex = output.count - crossfadeLength

                for i in 0..<crossfadeLength {
                    let fadeOut = Float(crossfadeLength - i) / Float(crossfadeLength)
                    let fadeIn = Float(i) / Float(crossfadeLength)
                    output[startIndex + i] = output[startIndex + i] * fadeOut + stretchedChunk[i] * fadeIn
                }

                if crossfadeLength < stretchedChunk.count {
                    output.append(contentsOf: stretchedChunk[crossfadeLength...])
                }
            }

            position += chunkSize
        }

        return output
    }
}

// MARK: - Static Convenience

extension TimeStretcher {

    /// Quick time-stretch with default configuration
    public static func stretch(_ samples: [Float], factor: Float) -> [Float] {
        let stretcher = TimeStretcher(config: .speech)
        return stretcher.stretchOptimized(samples, factor: factor)
    }

    /// Quick time-stretch for playback speed adjustment
    public static func adjustPlaybackSpeed(_ samples: [Float], speed: Float) -> [Float] {
        // Speed > 1.0 means faster playback = shorter audio = stretch factor > 1.0
        return stretch(samples, factor: speed)
    }
}
