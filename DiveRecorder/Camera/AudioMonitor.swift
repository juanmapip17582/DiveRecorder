import AVFoundation
import Combine

/// Taps the microphone input via AVAudioEngine and publishes a simple energy/onset score,
/// used as the audio half of splash detection (a sudden broadband transient on top of ambient
/// pool noise). Runs independently of AVCaptureSession's own audio path.
final class AudioMonitor: ObservableObject {
    @Published private(set) var currentEnergy: Double = 0

    /// Fired on the main thread with a normalized ~0...1+ energy score each time a new audio
    /// buffer arrives.
    var onEnergyUpdate: ((Double) -> Void)?

    private let engine = AVAudioEngine()
    private var isRunning = false
    private var smoothedBaseline: Double = 0

    func start() {
        guard !isRunning else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .videoRecording, options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            print("AudioMonitor: failed to configure AVAudioSession: \(error)")
            return
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let rms = Self.rms(of: buffer)
            // Onset = sudden positive jump above the recent (slowly-adapting) baseline.
            let onset = max(0, rms - self.smoothedBaseline)
            self.smoothedBaseline = rms * 0.3 + self.smoothedBaseline * 0.7

            // Weight sudden transients higher than steady loudness, since a splash is a spike,
            // not sustained volume (pool ambience, voices, etc.).
            let score = max(rms, onset * 3)

            DispatchQueue.main.async {
                self.currentEnergy = score
                self.onEnergyUpdate?(score)
            }
        }

        do {
            try engine.start()
            isRunning = true
        } catch {
            print("AudioMonitor: failed to start AVAudioEngine: \(error)")
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        smoothedBaseline = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        let channel = channelData[0]

        var sumSquares: Float = 0
        for i in 0..<frameLength {
            let sample = channel[i]
            sumSquares += sample * sample
        }
        let meanSquare = sumSquares / Float(frameLength)
        return Double(sqrtf(meanSquare))
    }
}
