import Foundation
import CoreVideo
import ImageIO

enum DiveRecorderState: String {
    case standby
    case identifying
    case armed
    case recording
}

/// Orchestrates the 5-state flow from the spec: STANDBY -> IDENTIFICANDO -> ARMADO -> GRABANDO
/// -> (splash or failsafe) -> STANDBY. Ties together CaptureManager (frames + recording),
/// AudioMonitor (splash audio signal), PoseDetector, ColorMatcher and SplashDetector.
final class RecordingStateMachine: ObservableObject {
    @Published private(set) var state: DiveRecorderState = .standby
    @Published private(set) var lastClipURL: URL?

    private let captureManager: CaptureManager
    private let audioMonitor: AudioMonitor
    private let poseDetector = PoseDetector()
    private let splashDetector = SplashDetector()
    private let calibrationStore: CalibrationStore
    private let clipStorage: ClipStorage

    /// Serializes every state read/mutation and all frame-processing decisions, so callbacks
    /// arriving from different AVFoundation queues (video data output, movie file output,
    /// audio tap) never race with each other. `state` above is only ever written from here via
    /// a hop to the main thread, and is never read back for decision-making — decisions always
    /// go through `processingState`, which only this queue touches.
    private let stateQueue = DispatchQueue(label: "com.diverecorder.statemachine")

    private var processingState: DiveRecorderState = .standby
    private var identifyingStartedAt: Date?
    private var splashDetectedAt: Date?
    private var currentAudioEnergy: Double = 0
    private var failsafeWorkItem: DispatchWorkItem?
    private var paddingWorkItem: DispatchWorkItem?

    private var settings: CalibrationSettings { calibrationStore.settings }

    init(
        captureManager: CaptureManager,
        audioMonitor: AudioMonitor,
        calibrationStore: CalibrationStore = .shared,
        clipStorage: ClipStorage = ClipStorage()
    ) {
        self.captureManager = captureManager
        self.audioMonitor = audioMonitor
        self.calibrationStore = calibrationStore
        self.clipStorage = clipStorage

        captureManager.frameDelegate = self
        audioMonitor.onEnergyUpdate = { [weak self] energy in
            self?.stateQueue.async { self?.currentAudioEnergy = energy }
        }
    }

    func start() {
        stateQueue.async { [weak self] in self?.applyStandbyState() }
        audioMonitor.start()
        captureManager.startSession()
    }

    func stop() {
        audioMonitor.stop()
        captureManager.stopSession()
        stateQueue.async { [weak self] in
            self?.failsafeWorkItem?.cancel()
            self?.paddingWorkItem?.cancel()
        }
    }

    // MARK: - Transitions (stateQueue only)

    private func enter(_ newState: DiveRecorderState) {
        guard newState != processingState else { return }
        processingState = newState
        DispatchQueue.main.async { [weak self] in self?.state = newState }

        switch newState {
        case .standby: applyStandbyState()
        case .identifying: identifyingStartedAt = Date()
        case .armed: break // momentary; immediately followed by `.recording`
        case .recording: beginRecording()
        }
    }

    private func applyStandbyState() {
        captureManager.setFrameRate(settings.standbyFPS)
        identifyingStartedAt = nil
        splashDetectedAt = nil
        splashDetector.reset()
    }

    private func beginRecording() {
        captureManager.setFrameRate(settings.recordingFPS)
        let url = clipStorage.newClipURL()
        captureManager.startRecording(to: url)
        scheduleFailsafe()
    }

    private func scheduleFailsafe() {
        failsafeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finishRecording() }
        failsafeWorkItem = work
        stateQueue.asyncAfter(deadline: .now() + settings.recordingFailsafeSeconds, execute: work)
    }

    private func finishRecording() {
        failsafeWorkItem?.cancel()
        paddingWorkItem?.cancel()
        captureManager.stopRecording { [weak self] url in
            guard let self else { return }
            DispatchQueue.main.async { self.lastClipURL = url }
            self.stateQueue.async { self.enter(.standby) }
        }
    }

    private func handleSplashDetected() {
        guard processingState == .recording, splashDetectedAt == nil else { return }
        splashDetectedAt = Date()
        failsafeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finishRecording() }
        paddingWorkItem = work
        stateQueue.asyncAfter(deadline: .now() + settings.postSplashPaddingSeconds, execute: work)
    }
}

extension RecordingStateMachine: CaptureFrameDelegate {
    func captureManager(_ manager: CaptureManager, didOutput pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        stateQueue.async { [weak self] in
            self?.process(pixelBuffer: pixelBuffer, orientation: orientation)
        }
    }

    private func process(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        switch processingState {
        case .standby:
            evaluateStandby(pixelBuffer: pixelBuffer, orientation: orientation)
        case .identifying:
            evaluateIdentifying(pixelBuffer: pixelBuffer, orientation: orientation)
        case .armed:
            break
        case .recording:
            evaluateSplash(pixelBuffer: pixelBuffer)
        }
    }

    private func evaluateStandby(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        let roi = settings.trampolineROI.visionNormalized
        let poses = poseDetector.detectPoses(in: pixelBuffer, roi: roi, orientation: orientation)
        if poses.contains(where: { poseDetector.isStandingPose($0) }) {
            enter(.identifying)
        }
    }

    private func evaluateIdentifying(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        guard settings.hasReferenceColor else {
            enter(.standby)
            return
        }
        if let startedAt = identifyingStartedAt, Date().timeIntervalSince(startedAt) > settings.identifyingTimeoutSeconds {
            enter(.standby) // timed out — probably a different diver in the ROI
            return
        }

        let roi = settings.trampolineROI.visionNormalized
        let poses = poseDetector.detectPoses(in: pixelBuffer, roi: roi, orientation: orientation)
        guard let pose = poses.first(where: { poseDetector.isStandingPose($0) }),
              let hip = pose.hip, let knee = pose.knee else { return }

        let cropRect = ColorMatcher.torsoLegsCropRect(
            hip: hip, knee: knee,
            imageWidth: CVPixelBufferGetWidth(pixelBuffer),
            imageHeight: CVPixelBufferGetHeight(pixelBuffer)
        )
        guard let histogram = ColorMatcher.hueHistogram(from: pixelBuffer, cropRect: cropRect) else { return }

        let distance = ColorMatcher.distance(histogram, settings.referenceHueHistogram)
        if distance <= settings.colorMatchThreshold {
            enter(.armed)
            enter(.recording)
        }
        // No match: keep waiting within the timeout window above, in case pose tracking was
        // just briefly noisy — the timeout is what actually sends us back to `.standby`.
    }

    private func evaluateSplash(pixelBuffer: CVPixelBuffer) {
        guard splashDetectedAt == nil else { return }

        var visualTriggered = false
        var audioTriggered = false

        if settings.useSplashVisualSignal {
            let energy = splashDetector.motionEnergy(pixelBuffer: pixelBuffer, roi: settings.waterROI)
            visualTriggered = energy >= settings.splashMotionThreshold
        }
        if settings.useSplashAudioSignal {
            audioTriggered = currentAudioEnergy >= settings.splashAudioThreshold
        }

        if visualTriggered || audioTriggered {
            handleSplashDetected()
        }
    }
}
