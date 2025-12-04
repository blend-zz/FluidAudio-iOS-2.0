import CoreML
import FluidAudio
import Foundation

// MARK: - ANE Optimization for TTS Pipeline

extension KokoroSynthesizer {

    /// Create ANE-optimized MLMultiArray for TTS inference
    /// Uses 64-byte alignment for optimal Neural Engine DMA transfers
    static func createANEOptimizedArray(
        shape: [NSNumber],
        dataType: MLMultiArrayDataType
    ) throws -> MLMultiArray {
        return try ANEMemoryUtils.createAlignedArray(
            shape: shape,
            dataType: dataType,
            zeroClear: false  // TTS fills arrays before inference
        )
    }

    /// Prefetch model inputs to ANE for reduced first-inference latency
    static func prefetchInputsForANE(
        inputIds: MLMultiArray,
        attentionMask: MLMultiArray,
        refStyle: MLMultiArray,
        randomPhases: MLMultiArray
    ) {
        // Touch first/last elements to trigger DMA prefetch
        inputIds.prefetchForANE()
        attentionMask.prefetchForANE()
        refStyle.prefetchForANE()
        randomPhases.prefetchForANE()
    }

    /// Check if current device supports optimal ANE execution
    /// A15+ chips (iPhone 13+, M1+) have significantly improved ANE
    public static func supportsOptimalANE() -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        if #available(iOS 15.0, macOS 12.0, *) {
            return true
        }
        return false
        #endif
    }

    /// Get recommended compute units for the current device
    public static func recommendedComputeUnits() -> MLComputeUnits {
        #if targetEnvironment(simulator)
        return .cpuOnly
        #else
        // Prefer ANE for battery efficiency
        // CoreML will fall back to GPU/CPU if ANE can't handle specific operations
        return .cpuAndNeuralEngine
        #endif
    }

    /// Optimal batch size for ANE processing
    /// Larger batches amortize ANE dispatch overhead
    public static var optimalBatchSize: Int {
        #if targetEnvironment(simulator)
        return 1
        #else
        // ANE benefits from batching but TTS is typically single-inference
        return 1
        #endif
    }
}

// MARK: - ANE Memory Pool for TTS

/// Pooled memory management for TTS inference to reduce allocation overhead
actor TTSMemoryPool {
    private var inputIdsPools: [Int: [MLMultiArray]] = [:]
    private var attentionMaskPools: [Int: [MLMultiArray]] = [:]
    private var refStylePools: [Int: [MLMultiArray]] = [:]
    private var phasesPools: [MLMultiArray] = []

    private let logger = AppLogger(subsystem: "com.fluidaudio.tts", category: "TTSMemoryPool")

    /// Rent an input_ids array from the pool
    func rentInputIds(tokenLength: Int) throws -> MLMultiArray {
        if var pool = inputIdsPools[tokenLength], !pool.isEmpty {
            let array = pool.removeLast()
            inputIdsPools[tokenLength] = pool
            return array
        }

        // Create new ANE-aligned array
        let shape: [NSNumber] = [1, NSNumber(value: tokenLength)]
        return try ANEMemoryUtils.createAlignedArray(
            shape: shape,
            dataType: .int32,
            zeroClear: false
        )
    }

    /// Rent an attention_mask array from the pool
    func rentAttentionMask(tokenLength: Int) throws -> MLMultiArray {
        if var pool = attentionMaskPools[tokenLength], !pool.isEmpty {
            let array = pool.removeLast()
            attentionMaskPools[tokenLength] = pool
            return array
        }

        let shape: [NSNumber] = [1, NSNumber(value: tokenLength)]
        return try ANEMemoryUtils.createAlignedArray(
            shape: shape,
            dataType: .int32,
            zeroClear: false
        )
    }

    /// Rent a ref_s (style vector) array from the pool
    func rentRefStyle(dimension: Int) throws -> MLMultiArray {
        if var pool = refStylePools[dimension], !pool.isEmpty {
            let array = pool.removeLast()
            refStylePools[dimension] = pool
            return array
        }

        let shape: [NSNumber] = [1, NSNumber(value: dimension)]
        return try ANEMemoryUtils.createAlignedArray(
            shape: shape,
            dataType: .float32,
            zeroClear: false
        )
    }

    /// Rent a random_phases array from the pool
    func rentPhases() throws -> MLMultiArray {
        if !phasesPools.isEmpty {
            return phasesPools.removeLast()
        }

        let shape: [NSNumber] = [1, 9]
        return try ANEMemoryUtils.createAlignedArray(
            shape: shape,
            dataType: .float32,
            zeroClear: true  // Phases start at zero
        )
    }

    /// Return arrays to the pool for reuse
    func recycle(
        inputIds: MLMultiArray?,
        attentionMask: MLMultiArray?,
        refStyle: MLMultiArray?,
        phases: MLMultiArray?
    ) {
        if let inputIds = inputIds {
            let tokenLength = inputIds.shape[1].intValue
            if inputIdsPools[tokenLength] == nil {
                inputIdsPools[tokenLength] = []
            }
            inputIdsPools[tokenLength]?.append(inputIds)
        }

        if let attentionMask = attentionMask {
            let tokenLength = attentionMask.shape[1].intValue
            if attentionMaskPools[tokenLength] == nil {
                attentionMaskPools[tokenLength] = []
            }
            attentionMaskPools[tokenLength]?.append(attentionMask)
        }

        if let refStyle = refStyle {
            let dimension = refStyle.shape[1].intValue
            if refStylePools[dimension] == nil {
                refStylePools[dimension] = []
            }
            refStylePools[dimension]?.append(refStyle)
        }

        if let phases = phases {
            phasesPools.append(phases)
        }
    }

    /// Clear all pools to free memory
    func clearPools() {
        inputIdsPools.removeAll()
        attentionMaskPools.removeAll()
        refStylePools.removeAll()
        phasesPools.removeAll()
        logger.info("TTS memory pools cleared")
    }

    /// Get pool statistics
    func statistics() -> (inputIds: Int, attentionMask: Int, refStyle: Int, phases: Int) {
        let inputIdsCount = inputIdsPools.values.reduce(0) { $0 + $1.count }
        let attentionMaskCount = attentionMaskPools.values.reduce(0) { $0 + $1.count }
        let refStyleCount = refStylePools.values.reduce(0) { $0 + $1.count }
        return (inputIdsCount, attentionMaskCount, refStyleCount, phasesPools.count)
    }
}
