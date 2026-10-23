import Foundation
import CoreGraphics
import Combine

/// Every value the spec calls out as "afinar con pruebas reales, no adivinar". Kept as plain
/// data (not hardcoded constants) so `CalibrationView` can expose them as live-adjustable
/// sliders and persist changes without needing a rebuild.
struct CalibrationSettings: Codable, Equatable {
    // Normalized ROI (0...1, origin top-left — UIKit view coordinates).
    static let defaultTrampolineROI = CGRect(x: 0.3, y: 0.1, width: 0.4, height: 0.5)
    var trampolineROI = CalibrationSettings.defaultTrampolineROI

    // Reference color, stored as an HSV hue histogram.
    var referenceHueHistogram = [Double](repeating: 0, count: ColorMatcher.hueBinCount)
    var hasReferenceColor = false

    // STANDBY
    var standbyFPS: Double = 3.0
    var identifyingTimeoutSeconds: Double = 4.0

    // Identificación por color
    var colorMatchThreshold: Double = 0.35 // chi-square distance; lower = stricter

    // Fin de grabación: mientras GRABANDO, PoseDetector sigue vigilando el ROI del trampolín. En
    // cuanto deja de detectar a la persona ahí, arranca esta cuenta regresiva fija hasta cortar.
    var flightTimeSeconds: Double = 3.5
    // Respaldo por si nunca se detecta que salió del trampolín (ver RecordingStateMachine).
    var recordingFailsafeSeconds: Double = 7.0
    var recordingFPS: Double = 60.0

    init() {}

    private enum CodingKeys: String, CodingKey {
        case trampolineROI, referenceHueHistogram, hasReferenceColor
        case standbyFPS, identifyingTimeoutSeconds, colorMatchThreshold
        case flightTimeSeconds, recordingFailsafeSeconds, recordingFPS
    }

    // Custom decode so settings persisted by an older build (before the splash/audio-based
    // end-of-recording logic was replaced by the board-exit countdown) migrate gracefully: any
    // field that still exists keeps its already-tuned value, fields that no longer exist are
    // ignored, and new fields (flightTimeSeconds) just fall back to their default — instead of
    // the whole decode failing and silently wiping every calibrated value back to defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CalibrationSettings()
        // Clamp on load: an older build could save a ROI drawn past the edges of the preview.
        let storedROI = try container.decodeIfPresent(CGRect.self, forKey: .trampolineROI)
        trampolineROI = storedROI?.clampedToUnit() ?? defaults.trampolineROI
        referenceHueHistogram = try container.decodeIfPresent([Double].self, forKey: .referenceHueHistogram) ?? defaults.referenceHueHistogram
        hasReferenceColor = try container.decodeIfPresent(Bool.self, forKey: .hasReferenceColor) ?? defaults.hasReferenceColor
        standbyFPS = try container.decodeIfPresent(Double.self, forKey: .standbyFPS) ?? defaults.standbyFPS
        identifyingTimeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .identifyingTimeoutSeconds) ?? defaults.identifyingTimeoutSeconds
        colorMatchThreshold = try container.decodeIfPresent(Double.self, forKey: .colorMatchThreshold) ?? defaults.colorMatchThreshold
        flightTimeSeconds = try container.decodeIfPresent(Double.self, forKey: .flightTimeSeconds) ?? defaults.flightTimeSeconds
        recordingFailsafeSeconds = try container.decodeIfPresent(Double.self, forKey: .recordingFailsafeSeconds) ?? defaults.recordingFailsafeSeconds
        recordingFPS = try container.decodeIfPresent(Double.self, forKey: .recordingFPS) ?? defaults.recordingFPS
    }
}

/// Persists `CalibrationSettings` to UserDefaults and publishes changes so both the live state
/// machine and the calibration UI stay in sync.
final class CalibrationStore: ObservableObject {
    static let shared = CalibrationStore()

    private let defaultsKey = "com.diverecorder.calibrationSettings"

    @Published var settings: CalibrationSettings {
        didSet { persist() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(CalibrationSettings.self, from: data) {
            settings = decoded
        } else {
            settings = CalibrationSettings()
        }
    }

    func reset() {
        settings = CalibrationSettings()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
