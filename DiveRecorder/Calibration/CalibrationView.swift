import SwiftUI
import Vision
import CoreVideo

/// One-time-per-mount calibration screen: draw the trampoline/platform ROI and water ROI over
/// the live preview, capture the reference shorts color, and tune every threshold the spec
/// flags as "measure in the real pool, don't guess" — all persisted immediately via
/// `CalibrationStore`, no rebuild needed to iterate.
struct CalibrationView: View {
    @ObservedObject var calibrationStore: CalibrationStore
    @ObservedObject var captureManager: CaptureManager

    private enum EditingROI { case trampoline, water }
    @State private var editingROI: EditingROI = .trampoline
    @State private var captureFeedback: String?

    private let poseDetector = PoseDetector()

    var body: some View {
        NavigationStack {
            Form {
                Section("Regiones de interés") {
                    Picker("Editando", selection: $editingROI) {
                        Text("Trampolín/plataforma").tag(EditingROI.trampoline)
                        Text("Agua").tag(EditingROI.water)
                    }
                    .pickerStyle(.segmented)

                    ZStack {
                        CameraPreviewView(session: captureManager.session)
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                        if editingROI == .trampoline {
                            ROISelectionView(title: "Trampolín", roi: $calibrationStore.settings.trampolineROI, overlayColor: .yellow)
                        } else {
                            ROISelectionView(title: "Agua", roi: $calibrationStore.settings.waterROI, overlayColor: .blue)
                        }
                    }
                    .frame(height: 320)

                    Text("Arrastra sobre la vista para dibujar el rectángulo de \(editingROI == .trampoline ? "el trampolín" : "el agua").")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Color de referencia (pantaloneta)") {
                    Button("Capturar color ahora") { captureReferenceColor() }

                    if calibrationStore.settings.hasReferenceColor {
                        Label("Color de referencia guardado", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    if let captureFeedback {
                        Text(captureFeedback)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Párate dentro del rectángulo del trampolín, de frente, y presiona capturar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Standby") {
                    LabeledSlider(label: "FPS en standby", value: $calibrationStore.settings.standbyFPS, range: 1...10, format: "%.0f fps")
                    LabeledSlider(label: "Timeout identificando", value: $calibrationStore.settings.identifyingTimeoutSeconds, range: 1...10, format: "%.1f s")
                }

                Section("Identificación por color") {
                    LabeledSlider(label: "Umbral de coincidencia", value: $calibrationStore.settings.colorMatchThreshold, range: 0.05...1.0, format: "%.2f")
                    Text("Más bajo = más estricto (menos falsos positivos, más falsos negativos).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Detección de splash") {
                    Toggle("Usar señal visual", isOn: $calibrationStore.settings.useSplashVisualSignal)
                    LabeledSlider(label: "Umbral de movimiento", value: $calibrationStore.settings.splashMotionThreshold, range: 0.01...0.5, format: "%.2f")

                    Toggle("Usar señal de audio", isOn: $calibrationStore.settings.useSplashAudioSignal)
                    LabeledSlider(label: "Umbral de audio", value: $calibrationStore.settings.splashAudioThreshold, range: 0.01...1.0, format: "%.2f")

                    LabeledSlider(label: "Padding posterior", value: $calibrationStore.settings.postSplashPaddingSeconds, range: 0...3, format: "%.2f s")
                    LabeledSlider(label: "Timer failsafe", value: $calibrationStore.settings.recordingFailsafeSeconds, range: 3...15, format: "%.1f s")
                    LabeledSlider(label: "FPS de grabación", value: $calibrationStore.settings.recordingFPS, range: 24...60, format: "%.0f fps")
                }

                Section {
                    Button("Restablecer valores por defecto", role: .destructive) {
                        calibrationStore.reset()
                    }
                }
            }
            .navigationTitle("Calibración")
        }
    }

    private func captureReferenceColor() {
        captureManager.captureSingleFrame { pixelBuffer in
            guard let pixelBuffer else {
                captureFeedback = "No se pudo capturar un frame. Intenta de nuevo."
                return
            }
            let roi = calibrationStore.settings.trampolineROI.visionNormalized
            let poses = poseDetector.detectPoses(in: pixelBuffer, roi: roi, orientation: .up)
            guard let pose = poses.first, let hip = pose.hip, let knee = pose.knee else {
                captureFeedback = "No se detectó una persona de pie dentro del ROI del trampolín."
                return
            }
            let cropRect = ColorMatcher.torsoLegsCropRect(
                hip: hip, knee: knee,
                imageWidth: CVPixelBufferGetWidth(pixelBuffer),
                imageHeight: CVPixelBufferGetHeight(pixelBuffer)
            )
            guard let histogram = ColorMatcher.hueHistogram(from: pixelBuffer, cropRect: cropRect) else {
                captureFeedback = "No se pudo calcular el color en esa región."
                return
            }
            calibrationStore.settings.referenceHueHistogram = histogram
            calibrationStore.settings.hasReferenceColor = true
            captureFeedback = "¡Color de referencia capturado!"
        }
    }
}

private struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: format, value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range)
        }
    }
}
