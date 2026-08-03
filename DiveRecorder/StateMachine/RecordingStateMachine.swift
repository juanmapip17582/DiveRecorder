import Foundation
import CoreVideo
import ImageIO

enum DiveRecorderState: String {
    case standby
    case identifying
    case armed
    case recording
}

/// Orchestrates the 4-state flow: STANDBY -> IDENTIFICANDO -> ARMADO -> GRABANDO -> (board-exit
/// countdown, or failsafe) -> STANDBY. Ties together CaptureManager (frames + recording),
/// PoseDetector and ColorMatcher.
final class RecordingStateMachine: ObservableObject {
    @Published private(set) var state: DiveRecorderState = .standby
    @Published private(set) var lastClipURL: URL?

    /// Debug-overlay-facing: whether the trampoline ROI currently has a detected person while
    /// recording. `true` outside `.recording` and right after entering it, until a miss streak
    /// proves otherwise.
    @Published private(set) var isPersonDetectedInROI: Bool = true
    /// Debug-overlay-facing: when the person was confirmed to have left the trampoline ROI
    /// (`missedFrameThreshold` consecutive misses) during the current recording. `nil` while
    /// still detected, or outside `.recording`.
    @Published private(set) var boardExitAt: Date?

    private let captureManager: CaptureManager
    private let poseDetector = PoseDetector()
    private let calibrationStore: CalibrationStore
    private let clipStorage: ClipStorage

    /// Serializes every state read/mutation and all frame-processing decisions, so callbacks
    /// arriving from different AVFoundation queues (video data output, movie file output) never
    /// race with each other. `state` above is only ever written from here via a hop to the main
    /// thread, and is never read back for decision-making — decisions always go through
    /// `processingState`, which only this queue touches.
    private let stateQueue = DispatchQueue(label: "com.diverecorder.statemachine")

    private var processingState: DiveRecorderState = .standby
    private var identifyingStartedAt: Date?
    private var failsafeWorkItem: DispatchWorkItem?
    private var flightCountdownWorkItem: DispatchWorkItem?

    /// stateQueue-only mirror of `boardExitAt`: `nil` means still watching for the exit,
    /// non-nil means the countdown is already committed and evaluation should stop. Reading
    /// `@Published` state from a background queue isn't safe, hence the separate mirror — same
    /// pattern as `state`/`processingState`.
    private var processingBoardExitAt: Date?
    /// stateQueue-only mirror of `isPersonDetectedInROI`, used purely to detect edges so we only
    /// hop to the main thread when the value actually changes.
    private var processingIsPersonDetected = true
    private var consecutiveMissedFrames = 0
    /// Consecutive *analyzed* frames (see `recordingFrameStride`) without a detected person in
    /// the ROI before we consider the diver to have left — 2-3 per the spec, to absorb a single
    /// momentary miss (motion blur mid-jump, a brief occlusion) without cutting the countdown
    /// short on a false alarm.
    private static let missedFrameThreshold = 3

    /// Running VNDetectHumanBodyPoseRequest on every single frame at full recording fps (up to
    /// 60/s) would compete heavily with the actual video encoding for CPU. This only analyzes
    /// every Nth frame delivered to the video data output while recording — the recorded movie
    /// itself is untouched by this (AVCaptureMovieFileOutput gets every frame regardless); only
    /// the parallel analysis stream is throttled.
    private static let recordingFrameStride = 4
    private var recordingFrameCounter = 0

    private var settings: CalibrationSettings { calibrationStore.settings }

    init(
        captureManager: CaptureManager,
        calibrationStore: CalibrationStore = .shared,
        clipStorage: ClipStorage = ClipStorage()
    ) {
        self.captureManager = captureManager
        self.calibrationStore = calibrationStore
        self.clipStorage = clipStorage

        captureManager.frameDelegate = self
    }

    func start() {
        stateQueue.async { [weak self] in self?.applyStandbyState() }
        captureManager.startSession()
    }

    func stop() {
        captureManager.stopSession()
        stateQueue.async { [weak self] in
            self?.failsafeWorkItem?.cancel()
            self?.flightCountdownWorkItem?.cancel()
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
        processingBoardExitAt = nil
        processingIsPersonDetected = true
        consecutiveMissedFrames = 0
        recordingFrameCounter = 0
        DispatchQueue.main.async { [weak self] in
            self?.isPersonDetectedInROI = true
            self?.boardExitAt = nil
        }
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
        flightCountdownWorkItem?.cancel()
        captureManager.stopRecording { [weak self] url in
            guard let self else { return }
            DispatchQueue.main.async { self.lastClipURL = url }
            self.stateQueue.async { self.enter(.standby) }
        }
    }

    /// Called once, the moment `missedFrameThreshold` consecutive analyzed frames find nobody in
    /// the trampoline ROI: starts the fixed flight-time countdown to the cut, and hands off from
    /// the failsafe (now redundant — we have a precise cutoff) to that countdown.
    private func handleBoardExit() {
        guard processingState == .recording, processingBoardExitAt == nil else { return }
        let now = Date()
        processingBoardExitAt = now
        DispatchQueue.main.async { [weak self] in
            self?.isPersonDetectedInROI = false
            self?.boardExitAt = now
        }

        failsafeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finishRecording() }
        flightCountdownWorkItem = work
        stateQueue.asyncAfter(deadline: .now() + settings.flightTimeSeconds, execute: work)
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
            evaluatePresenceWhileRecording(pixelBuffer: pixelBuffer, orientation: orientation)
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

    /// Keeps running PoseDetector on the trampoline ROI while recording, so we know the moment
    /// the diver leaves the board. Once `missedFrameThreshold` consecutive analyzed frames come
    /// up empty, `handleBoardExit()` fires and this stops evaluating (`processingBoardExitAt`
    /// guard below) — the fixed flight-time countdown takes over from there.
    private func evaluatePresenceWhileRecording(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        guard processingBoardExitAt == nil else { return }

        recordingFrameCounter += 1
        guard recordingFrameCounter % Self.recordingFrameStride == 0 else { return }

        let roi = settings.trampolineROI.visionNormalized
        let poses = poseDetector.detectPoses(in: pixelBuffer, roi: roi, orientation: orientation)
        let detected = !poses.isEmpty

        if detected != processingIsPersonDetected {
            processingIsPersonDetected = detected
            DispatchQueue.main.async { [weak self] in self?.isPersonDetectedInROI = detected }
        }

        if detected {
            consecutiveMissedFrames = 0
        } else {
            consecutiveMissedFrames += 1
            if consecutiveMissedFrames >= Self.missedFrameThreshold {
                handleBoardExit()
            }
        }
    }
}
