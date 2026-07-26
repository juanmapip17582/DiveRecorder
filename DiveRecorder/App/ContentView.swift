import SwiftUI

struct ContentView: View {
    @StateObject private var captureManager: CaptureManager
    @StateObject private var audioMonitor: AudioMonitor
    @StateObject private var stateMachine: RecordingStateMachine
    @ObservedObject private var calibrationStore = CalibrationStore.shared

    @State private var showingCalibration = false
    @State private var showingLibrary = false
    private let clipStorage = ClipStorage()

    init() {
        let capture = CaptureManager()
        let audio = AudioMonitor()
        _captureManager = StateObject(wrappedValue: capture)
        _audioMonitor = StateObject(wrappedValue: audio)
        _stateMachine = StateObject(wrappedValue: RecordingStateMachine(captureManager: capture, audioMonitor: audio))
    }

    var body: some View {
        ZStack {
            CameraPreviewView(session: captureManager.session)
                .ignoresSafeArea()

            VStack {
                statusBadge
                    .padding(.top, 60)
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
