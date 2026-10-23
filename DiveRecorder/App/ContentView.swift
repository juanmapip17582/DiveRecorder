import SwiftUI

struct ContentView: View {
    @StateObject private var captureManager: CaptureManager
    @StateObject private var stateMachine: RecordingStateMachine
    @ObservedObject private var calibrationStore = CalibrationStore.shared

    @State private var showingCalibration = false
    @State private var showingLibrary = false
    @State private var didStart = false
    private let clipStorage = ClipStorage()

    init() {
        let capture = CaptureManager()
        _captureManager = StateObject(wrappedValue: capture)
        _stateMachine = StateObject(wrappedValue: RecordingStateMachine(captureManager: capture))
    }

    var body: some View {
        ZStack {
            // The app's only camera preview: never unmounted or recreated (see CameraPreviewView).
            CameraPreviewView(captureManager: captureManager)
                .ignoresSafeArea()

            if showingCalibration {
                CalibrationView(calibrationStore: calibrationStore, captureManager: captureManager) {
                    showingCalibration = false
                }
                .transition(.opacity)
            } else {
                mainOverlay
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showingCalibration)
        .onAppear {
            // Only configure the session and start the state machine once, even if onAppear
            // fires again.
            guard !didStart else { return }
            didStart = true
            captureManager.requestAccessAndConfigure()
            // Give the session a moment to finish configuring before the state machine starts
            // driving frame rate changes and recording.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                stateMachine.start()
            }
        }
        .onChange(of: showingCalibration) { isShowing in
            // No arming/recording while calibrating; the session itself keeps running.
            stateMachine.setPaused(isShowing)
        }
        .sheet(isPresented: $showingLibrary) {
            ClipLibraryView(clipStorage: clipStorage)
        }
        .alert("Permiso de cámara necesario", isPresented: $captureManager.authorizationDenied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Activa el acceso a la cámara en Ajustes para usar DiveRecorder.")
        }
    }

    /// Badge + buttons; hidden while Calibración is open.
    private var mainOverlay: some View {
        VStack {
            statusBadge
                .padding(.top, 60)
            if stateMachine.state == .recording {
                RecordingDebugOverlay(
                    isPersonDetected: stateMachine.isPersonDetectedInROI,
                    boardExitAt: stateMachine.boardExitAt,
                    flightTimeSeconds: calibrationStore.settings.flightTimeSeconds
                )
                .padding(.top, 8)
            }
            Spacer()
            controls
                .padding(.bottom, 8)
        }
    }

    private var statusBadge: some View {
        Text(statusText)
            .font(.headline)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(statusColor.opacity(0.85))
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }

    private var statusText: String {
        switch stateMachine.state {
        case .standby: return "STANDBY"
        case .identifying: return "IDENTIFICANDO..."
        case .armed: return "ARMADO"
        case .recording: return "GRABANDO"
        }
    }

    private var statusColor: Color {
        switch stateMachine.state {
        case .standby: return .gray
        case .identifying: return .orange
        case .armed: return .yellow
        case .recording: return .red
        }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            controlButton(systemImage: "film.stack") { showingLibrary = true }
            controlButton(systemImage: "slider.horizontal.3") { showingCalibration = true }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .foregroundStyle(.white)
    }

    private func controlButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
        }
    }
}

/// Debug-only overlay, shown while `.recording`, reflecting `RecordingStateMachine`'s live
/// board-presence tracking. Pure SwiftUI drawn on top of the preview — AVCaptureMovieFileOutput
/// records straight from the camera sensor, so nothing rendered here ever reaches the saved
/// clip, regardless of what's on screen.
private struct RecordingDebugOverlay: View {
    let isPersonDetected: Bool
    let boardExitAt: Date?
    let flightTimeSeconds: Double

    var body: some View {
        Group {
            if let boardExitAt {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    let elapsed = context.date.timeIntervalSince(boardExitAt)
                    let remaining = max(0, flightTimeSeconds - elapsed)
                    badge(
                        icon: "figure.fall",
                        color: .orange,
                        title: "Salió del trampolín",
                        detail: String(format: "hace %.1fs · corta en %.1fs", elapsed, remaining)
                    )
                }
            } else {
                badge(
                    icon: isPersonDetected ? "figure.stand" : "questionmark.circle",
                    color: isPersonDetected ? .green : .yellow,
                    title: isPersonDetected ? "Detectado en el trampolín" : "No detectado (esperando)",
                    detail: nil
                )
            }
        }
    }

    private func badge(icon: String, color: Color, title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon)
                .foregroundStyle(color)
            if let detail {
                Text(detail)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .font(.caption.monospacedDigit())
        .padding(8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
    }
}
