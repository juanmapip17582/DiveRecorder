import SwiftUI
import Vision
import CoreVideo

/// One-time-per-mount calibration screen: draw the trampoline/platform ROI over the live
/// preview, capture the reference shorts color, and tune every threshold the spec flags as
/// "measure in the real pool, don't guess" — all persisted immediately via `CalibrationStore`,
/// no rebuild needed to iterate.
///
/// Presented full screen: the camera takes most of the screen (so the ROI is easy to draw) and
/// the settings live in a compact, collapsible bottom panel.
struct CalibrationView: View {
    @ObservedObject var calibrationStore: CalibrationStore
    @ObservedObject var captureManager: CaptureManager

    @Environment(\.dismiss) private var dismiss

    @State private var captureFeedback: String?
    @State private var panelExpanded = false

    private let poseDetector = PoseDetector()

    /// Portrait 1920x1080 buffers (see CaptureManager). Showing the preview at exactly this
    /// aspect ratio with aspect-fill means nothing is cropped, so the ROI's view-normalized
    /// coordinates are the same as image-normalized coordinates used by Vision.
    private static let cameraAspectRatio: CGFloat = 1080.0 / 1920.0

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                cameraArea
                Spacer(minLength: 0)
            }

            settingsPanel
        }
        .overlay(alignment: .top) { topBar }
        .preferredColorScheme(.dark)
    }

    // MARK: - Camera + ROI

    private var cameraArea: some View {
        ZStack {
            CameraPreviewView(captureManager: captureManager)
            ROISelectionView(title: "Trampolín", roi: $calibrationStore.settings.trampolineROI, overlayColor: .yellow)
        }
        .aspectRatio(Self.cameraAspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Text("Calibración")
                .font(.subheadline.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())

            Spacer()

            Button {
                calibrationStore.settings.trampolineROI = CalibrationSettings.defaultTrampolineROI
            } label: {
                Label("Restablecer ROI", systemImage: "arrow.counterclockwise")
                    .font(.footnote)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Listo") { dismiss() }
                .font(.subheadline.bold())
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    // MARK: - Settings panel

    private var settingsPanel: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { panelExpanded.toggle() }
            } label: {
                VStack(spacing: 4) {
                    Capsule()
                        .fill(.secondary)
                        .frame(width: 36, height: 4)
                    HStack {
                        Text("Ajustes")
                            .font(.subheadline.bold())
                        Spacer()
                        Image(systemName: panelExpanded ? "chevron.down" : "chevron.up")
                            .font(.footnote.bold())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            colorCaptureRow
                .padding(.horizontal, 16)
                .padding(.bottom, panelExpanded ? 8 : 12)

            if panelExpanded {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        tuningSections
                    }
                    .padding(16)
                }
                .frame(maxHeight: 340)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private var colorCaptureRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    captureReferenceColor()
                } label: {
                    Label("Capturar color", systemImage: "eyedropper")
                        .font(.footnote.bold())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if calibrationStore.settings.hasReferenceColor {
                    Label("Guardado", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
                Spacer()
            }
            Text(captureFeedback ?? "Arrastra sobre la imagen para dibujar el trampolín. Para el color: párate dentro del rectángulo, de frente, y toca capturar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var tuningSections: some View {
        PanelSection("Standby") {
            LabeledSlider(label: "FPS en standby", value: $calibrationStore.settings.standbyFPS, range: 1...10, format: "%.0f fps")
            LabeledSlider(label: "Timeout identificando", value: $calibrationStore.settings.identifyingTimeoutSeconds, range: 1...10, format: "%.1f s")
        }

        PanelSection("Identificación por color") {
            LabeledSlider(label: "Umbral de coincidencia", value: $calibrationStore.settings.colorMatchThreshold, range: 0.05...1.0, format: "%.2f",
                          hint: "Más bajo = más estricto (menos falsos positivos, más falsos negativos).")
        }

        PanelSection("Fin de grabación") {
            LabeledSlider(label: "Tiempo de vuelo", value: $calibrationStore.settings.flightTimeSeconds, range: 1...8, format: "%.1f s",
                          hint: "Cuenta regresiva desde que deja de detectarse a la persona en el trampolín hasta cortar.")
            LabeledSlider(label: "Timer failsafe", value: $calibrationStore.settings.recordingFailsafeSeconds, range: 3...15, format: "%.1f s",
                          hint: "Respaldo por si nunca se detecta que salió del trampolín.")
            LabeledSlider(label: "FPS de grabación", value: $calibrationStore.settings.recordingFPS, range: 24...60, format: "%.0f fps")
        }

        Button("Restablecer valores por defecto", role: .destructive) {
            calibrationStore.reset()
        }
        .font(.footnote)
        .buttonStyle(.bordered)
        .controlSize(.small)
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

private struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var hint: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: format, value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.footnote)
            Slider(value: $value, in: range)
                .controlSize(.mini)
            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
