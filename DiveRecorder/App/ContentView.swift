import SwiftUI

struct ContentView: View {
    @StateObject private var captureManager: CaptureManager
    @StateObject private var stateMachine: RecordingStateMachine
    @ObservedObject private var calibrationStore = CalibrationStore.shared

    @State private var showingCalibration = false
    @State private var showingLibrary = false
    private let clipStorage = ClipStorage()

    init() {
        let capture = CaptureManager()
        _captureManager = StateObject(wrappedValue: capture)
        _stateMachine = StateObject(wrappedValue: RecordingStateMachine(captureManager: capture))
    }

    var body: some View {
        ZStack {
            CameraPreviewView(captureManager: captureManager)
                .ignoresSafeArea()

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
                    .padding(.bottom, 40)
            }
        }
        .onAppear {
            captureManager.requestAccessAndConfigure()
            // Give the session a moment to finish configuring before the state machine starts
            // driving frame rate changes and recording.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                stateMachine.start()
            }
        }
        .onDisappear {
            stateMachine.stop()
        }
        .sheet(isPresented: $showingCalibration) {
            CalibrationView(calibrationStore: calibrationStore, captureManager: captureManager)
        }
        .onChange(of: showingCalibration) { isShowing in
            // Calibration's own live preview borrows CaptureManager's single shared preview
            // layer while its sheet is open (see CameraPreviewView) — the layer reattaches
            // itself back to this screen the next time SwiftUI re-renders it, which already
            // happens here since this view's body reads `showingCalibration`. This explicit,
            // idempotent startSession() is just defensive backup in case the capture session
            // itself (not just the preview layer) ever ends up stopped by the time we return.
            if !isShowing {
                captureManager.startSession()
            }
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
        HStack(spacing: 24) {
            Button {
                showingLibrary = true
            } label: {
                Image(systemName: "film.stack")
                    .font(.title2)
                    .padding(14)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Button {
                showingCalibration = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title2)
                    .padding(14)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .foregroundStyle(.white)
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
