import ESpeakNG
import FluidAudio
import Foundation

/// Thread-safe wrapper around eSpeak NG C API to get IPA phonemes for a word.
/// Uses espeak_TextToPhonemes with IPA mode.
final class EspeakG2P {
    enum EspeakG2PError: Error, LocalizedError {
        case frameworkBundleMissing
        case dataBundleMissing
        case voicesDirectoryMissing
        case initializationFailed(code: Int32)
        case voiceSelectionFailed(voice: String, error: espeak_ERROR)

        var errorDescription: String? {
            switch self {
            case .frameworkBundleMissing:
                return "ESpeakNG.framework is not bundled with this build."
            case .dataBundleMissing:
                return "espeak-ng-data.bundle is missing from the ESpeakNG framework resources."
            case .voicesDirectoryMissing:
                return "eSpeak NG voices directory is missing inside espeak-ng-data.bundle."
            case .initializationFailed(let code):
                return "eSpeak NG initialization failed with status code \(code)."
            case .voiceSelectionFailed(let voice, let error):
                return "Failed to select eSpeak NG voice \(voice) (status code \(error.rawValue))."
            }
        }
    }

    static let shared = EspeakG2P()
    private let logger = AppLogger(subsystem: "com.fluidaudio.tts", category: "EspeakG2P")

    private let queue = DispatchQueue(label: "com.fluidaudio.tts.espeak.g2p")
    private var initialized = false
    private var currentVoice: String = ""

    private init() {}

    deinit {
        queue.sync {
            if initialized {
                espeak_Terminate()
            }
        }
    }

    func phonemize(word: String, espeakVoice: String = "en-us") throws -> [String]? {
        return try queue.sync {
            do {
                try initializeIfNeeded(espeakVoice: espeakVoice)
            } catch {
                if ProcessInfo.processInfo.environment["CI"] != nil {
                    logger.warning("G2P unavailable in CI, returning nil for word: \(word)")
                    return nil
                }
                throw error
            }

            return word.withCString { cstr -> [String]? in
                var raw: UnsafeRawPointer? = UnsafeRawPointer(cstr)
                let modeIPA = Int32(espeakPHONEMES_IPA)
                let textmode = Int32(espeakCHARS_AUTO)
                guard let outPtr = espeak_TextToPhonemes(&raw, textmode, modeIPA) else {
                    logger.warning("espeak_TextToPhonemes returned nil for word: \(word)")
                    return nil
                }
                let phonemeString = String(cString: outPtr)
                if phonemeString.isEmpty { return nil }
                if phonemeString.contains(where: { $0.isWhitespace }) {
                    return phonemeString.split { $0.isWhitespace }.map { String($0) }
                } else {
                    return phonemeString.unicodeScalars.map { String($0) }
                }
            }
        }
    }

    private func initializeIfNeeded(espeakVoice: String = "en-us") throws {
        if initialized {
            if espeakVoice != currentVoice {
                let result = espeakVoice.withCString { espeak_SetVoiceByName($0) }
                guard result == EE_OK else {
                    logger.error("Failed to set voice to \(espeakVoice), error code: \(result)")
                    throw EspeakG2PError.voiceSelectionFailed(voice: espeakVoice, error: result)
                }
                currentVoice = espeakVoice
            }
            return
        }

        let dataDir = try Self.ensureResourcesAvailable()
        logger.info("Using eSpeak NG data from framework: \(dataDir.path)")
        let rc: Int32 = dataDir.path.withCString { espeak_Initialize(AUDIO_OUTPUT_SYNCHRONOUS, 0, $0, 0) }

        guard rc >= 0 else {
            logger.error("eSpeak NG initialization failed (rc=\(rc))")
            throw EspeakG2PError.initializationFailed(code: rc)
        }
        let voiceResult = espeakVoice.withCString { espeak_SetVoiceByName($0) }
        guard voiceResult == EE_OK else {
            logger.error("Failed to set initial voice to \(espeakVoice), error code: \(voiceResult)")
            espeak_Terminate()
            throw EspeakG2PError.voiceSelectionFailed(voice: espeakVoice, error: voiceResult)
        }
        currentVoice = espeakVoice
        initialized = true
    }

    private static let staticLogger = AppLogger(subsystem: "com.fluidaudio.tts", category: "EspeakG2P")

    @discardableResult
    static func ensureResourcesAvailable() throws -> URL {
        let url = try frameworkBundledDataPath()
        staticLogger.info("eSpeak NG data directory: \(url.path)")
        return url
    }

    private static func frameworkBundledDataPath() throws -> URL {
        var espeakBundle = Bundle(identifier: "com.fluidinference.espeakng")
        if espeakBundle == nil {
            espeakBundle = Bundle.allBundles.first { $0.bundlePath.hasSuffix("ESpeakNG.framework") }
        }

        // Fallback: Check for framework on disk relative to the executable (for CLI/SPM builds)
        if espeakBundle == nil {
            let bundlePath = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(
                "ESpeakNG.framework")
            if FileManager.default.fileExists(atPath: bundlePath.path) {
                espeakBundle = Bundle(url: bundlePath)
            }
        }

        // Fallback: Check for PackageFrameworks directory (common in SPM builds)
        if espeakBundle == nil {
            let bundlePath = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(
                "PackageFrameworks/ESpeakNG.framework")
            if FileManager.default.fileExists(atPath: bundlePath.path) {
                espeakBundle = Bundle(url: bundlePath)
            }
        }

        // Final Fallback: Check if resources are flattened into the main bundle (common in some release builds)
        if espeakBundle == nil {
            if let resourceURL = Bundle.main.resourceURL {
                let flattenedDataDir = resourceURL.appendingPathComponent("espeak-ng-data")
                if FileManager.default.fileExists(atPath: flattenedDataDir.path) {
                    staticLogger.info("Found espeak-ng-data flattened in main bundle resources")
                    return flattenedDataDir
                }
            }
        }

        guard let espeakBundle = espeakBundle else {
            staticLogger.error("ESpeakNG.framework not found; ensure it is embedded with the application.")
            staticLogger.debug("Available bundles: \(Bundle.allBundles.map { $0.bundleIdentifier ?? $0.bundlePath })")
            throw EspeakG2PError.frameworkBundleMissing
        }

        guard let resourceURL = espeakBundle.resourceURL else {
            staticLogger.error("ESpeakNG.framework has no resource URL at \(espeakBundle.bundlePath)")
            throw EspeakG2PError.dataBundleMissing
        }

        var dataDir: URL? = nil

        // iOS: Check for espeak-ng-data.bundle inside the framework (common on iOS builds)
        let dataBundlePath = resourceURL.appendingPathComponent("espeak-ng-data.bundle")
        if FileManager.default.fileExists(atPath: dataBundlePath.path) {
            staticLogger.debug("Found espeak-ng-data.bundle at \(dataBundlePath.path)")
            // The data is inside the bundle at espeak-ng-data.bundle/espeak-ng-data/
            let innerDataDir = dataBundlePath.appendingPathComponent("espeak-ng-data")
            if FileManager.default.fileExists(atPath: innerDataDir.path) {
                staticLogger.info("Found espeak-ng-data inside bundle")
                dataDir = innerDataDir
            } else {
                // Try loading the bundle and getting its resource URL
                if let dataBundle = Bundle(url: dataBundlePath),
                   let bundleResourceURL = dataBundle.resourceURL {
                    let bundleDataDir = bundleResourceURL.appendingPathComponent("espeak-ng-data")
                    if FileManager.default.fileExists(atPath: bundleDataDir.path) {
                        dataDir = bundleDataDir
                    }
                }
            }
        }

        // macOS/CLI: Check for espeak-ng-data directly in framework resources
        if dataDir == nil {
            let directDataDir = resourceURL.appendingPathComponent("espeak-ng-data")
            if FileManager.default.fileExists(atPath: directDataDir.path) {
                dataDir = directDataDir
            }
        }

        // Fallback: Check main bundle resources (framework resources may be copied there)
        if dataDir == nil, let mainResourceURL = Bundle.main.resourceURL {
            // Check for espeak-ng-data.bundle in main bundle
            let mainBundlePath = mainResourceURL.appendingPathComponent("espeak-ng-data.bundle")
            if FileManager.default.fileExists(atPath: mainBundlePath.path) {
                let innerDataDir = mainBundlePath.appendingPathComponent("espeak-ng-data")
                if FileManager.default.fileExists(atPath: innerDataDir.path) {
                    staticLogger.info("Found espeak-ng-data.bundle in main bundle resources")
                    dataDir = innerDataDir
                }
            }
            // Check for direct espeak-ng-data in main bundle
            if dataDir == nil {
                let mainDataDir = mainResourceURL.appendingPathComponent("espeak-ng-data")
                if FileManager.default.fileExists(atPath: mainDataDir.path) {
                    staticLogger.info("Found espeak-ng-data in main bundle resources (fallback)")
                    dataDir = mainDataDir
                }
            }
        }

        guard var finalDataDir = dataDir else {
            staticLogger.error(
                "espeak-ng-data directory missing from ESpeakNG.framework resources at \(resourceURL.path)")
            staticLogger.debug("Checked paths: \(dataBundlePath.path), \(resourceURL.appendingPathComponent("espeak-ng-data").path)")
            throw EspeakG2PError.dataBundleMissing
        }

        // Check for nested espeak-ng-data (common in some framework structures)
        let nestedDataDir = finalDataDir.appendingPathComponent("espeak-ng-data")
        if FileManager.default.fileExists(atPath: nestedDataDir.path) {
            staticLogger.debug("Found nested espeak-ng-data directory, descending...")
            finalDataDir = nestedDataDir
        }

        let voicesPath = finalDataDir.appendingPathComponent("voices")

        guard FileManager.default.fileExists(atPath: voicesPath.path) else {
            staticLogger.error("espeak-ng-data found but voices directory missing at \(voicesPath.path)")
            throw EspeakG2PError.voicesDirectoryMissing
        }

        return finalDataDir
    }
}
