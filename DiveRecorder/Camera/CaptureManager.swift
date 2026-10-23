import AVFoundation
import CoreVideo
import ImageIO

protocol CaptureFrameDelegate: AnyObject {
    func captureManager(_ manager: CaptureManager, didOutput pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation)
}

/// Owns the AVCaptureSession: a video data output for live frame inspection (pose detection in
/// standby/identifying/recording) and a movie file output for the actual full-quality
/// recording. Both share the same session/input, so live analysis and recording run
/// concurrently without duplicating capture.
final class CaptureManager: NSObject, ObservableObject {
    let session = AVCaptureSession()

    weak var frameDelegate: CaptureFrameDelegate?

    @Published private(set) var isRecording = false
    @Published var authorizationDenied = false

    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let movieFileOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "com.diverecorder.session")
    private let videoDataQueue = DispatchQueue(label: "com.diverecorder.videodata")

    private var videoDevice: AVCaptureDevice?
    private var recordingCompletion: ((URL?) -> Void)?
    private var singleFrameCompletion: ((CVPixelBuffer?) -> Void)?

    func requestAccessAndConfigure() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            if granted {
                self.sessionQueue.async { self.configureSession() }
            } else {
                DispatchQueue.main.async { self.authorizationDenied = true }
            }
        }
    }

    private func configureSession() {
        session.beginConfiguration()

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            session.commitConfiguration()
            return
        }
        videoDevice = device
        if session.canAddInput(input) { session.addInput(input) }

        videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(self, queue: videoDataQueue)
        if session.canAddOutput(videoDataOutput) { session.addOutput(videoDataOutput) }

        if session.canAddOutput(movieFileOutput) { session.addOutput(movieFileOutput) }

        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        }

        // Rotate both outputs' connections to portrait so buffers arrive already right-side-up —
        // downstream Vision requests can then always use `.up` instead of tracking device orientation.
        for output in [videoDataOutput as AVCaptureOutput, movieFileOutput as AVCaptureOutput] {
            if let connection = output.connection(with: .video), connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }

        session.commitConfiguration()

        try? device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        device.unlockForConfiguration()
    }

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    /// Adjusts the capture device's active frame rate — throttled way down in standby to save
    /// battery, and back up to full fps once a dive is armed and recording starts.
    func setFrameRate(_ fps: Double) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            let clampedFPS = max(1.0, fps)
            let duration = CMTimeMake(value: 1, timescale: Int32(clampedFPS))

            let supported = device.activeFormat.videoSupportedFrameRateRanges.contains {
                clampedFPS >= $0.minFrameRate && clampedFPS <= $0.maxFrameRate
            }
            guard supported else { return }

            do {
                try device.lockForConfiguration()
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                device.unlockForConfiguration()
            } catch {
                print("CaptureManager: could not lock device for frame rate change: \(error)")
            }
        }
    }

    func startRecording(to url: URL) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.movieFileOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording(completion: @escaping (URL?) -> Void) {
        recordingCompletion = completion
        sessionQueue.async { [weak self] in
            self?.movieFileOutput.stopRecording()
        }
    }

    /// Grabs the next frame delivered to the video data output, for one-off uses like capturing
    /// the reference color during calibration — outside the normal per-frame analysis path.
    func captureSingleFrame(completion: @escaping (CVPixelBuffer?) -> Void) {
        videoDataQueue.async { [weak self] in
            self?.singleFrameCompletion = completion
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.videoDataQueue.async {
                guard let pending = self?.singleFrameCompletion else { return }
                self?.singleFrameCompletion = nil
                DispatchQueue.main.async { pending(nil) }
            }
        }
    }
}

extension CaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if let pending = singleFrameCompletion {
            singleFrameCompletion = nil
            DispatchQueue.main.async { pending(pixelBuffer) }
        }
        frameDelegate?.captureManager(self, didOutput: pixelBuffer, orientation: .up)
    }
}

extension CaptureManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async { self.isRecording = true }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { self.isRecording = false }
        let completion = recordingCompletion
        recordingCompletion = nil
        completion?(error == nil ? outputFileURL : nil)
    }
}
