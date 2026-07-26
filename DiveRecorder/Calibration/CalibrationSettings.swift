import Foundation
import CoreGraphics
import Combine

/// Every value the spec calls out as "afinar con pruebas reales, no adivinar". Kept as plain
/// data (not hardcoded constants) so `CalibrationView` can expose them as live-adjustable
/// sliders and persist changes without needing a rebuild.
struct CalibrationSettings: Codable, Equatable {
    // Normalized ROIs (0...1, origin top-left — UIKit view coordinates).
    var trampolineROI = CGRect(x: 0.3, y: 0.1, width: 0.4, height: 0.5)
    var waterROI = CGRect(x: 0.1, y: 0.6, width: 0.8, height: 0.35)

    // Reference color, stored as an HSV hue histogram.
    var referenceHueHistogram = [Double](repeating: 0, count: ColorMatcher.hueBinCount)
    var hasReferenceColor = false

    // STANDBY
    var standbyFPS: Double = 3.0
    var identifyingTimeoutSeconds: Double = 4.0

    // Identificación por color
    var colorMatchThreshold: Double = 0.35 // chi-square distance; lower = stricter

    // Detección de splash
    var useSplashVisualSignal = true
    var splashMotionThreshold: Double = 0.12
    var useSplashAudioSignal = true
    var splashAudioThreshold: Double = 0.20
    var postSplashPaddingSeconds: Double = 0.75
    var recordingFailsafeSeconds: Double = 7.0
    var recordingFPS: Double = 60.0
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
