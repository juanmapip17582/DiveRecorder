import SwiftUI
import AVKit
import Photos

private struct PlayableClip: Identifiable {
    let id: URL
    var url: URL { id }
}

/// Save state of a clip's "Descargar" button — clips live only in the app's private Documents
/// folder (see ClipStorage) until explicitly saved to Photos here, so this is the only way to
/// get a clip out to AirDrop, Messages, iCloud Photos, etc.
private enum DownloadState: Equatable {
    case idle
    case saving
    case saved
}

struct ClipLibraryView: View {
    let clipStorage: ClipStorage

    @State private var clips: [URL] = []
    @State private var selectedClip: PlayableClip?
    @State private var downloadStates: [URL: DownloadState] = [:]
    @State private var downloadErrorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if clips.isEmpty {
                    ContentUnavailableFallback()
                } else {
                    List {
                        ForEach(clips, id: \.self) { clip in
                            HStack {
                                Button {
                                    selectedClip = PlayableClip(id: clip)
                                } label: {
                                    Text(clip.lastPathComponent)
                                        .font(.subheadline)
                                }
                                .buttonStyle(.plain)

                                Spacer()

                                downloadButton(for: clip)
                            }
                        }
                        .onDelete(perform: deleteClips)
                    }
                }
            }
            .navigationTitle("Clavados guardados")
            .toolbar { EditButton() }
            .onAppear { refresh() }
            .sheet(item: $selectedClip) { clip in
                VideoPlayer(player: AVPlayer(url: clip.url))
            }
            .alert("No se pudo guardar", isPresented: Binding(
                get: { downloadErrorMessage != nil },
                set: { if !$0 { downloadErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(downloadErrorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private func downloadButton(for clip: URL) -> some View {
        switch downloadStates[clip, default: .idle] {
        case .idle:
            Button {
                download(clip)
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
        case .saving:
            ProgressView()
        case .saved:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    private func refresh() {
        clips = clipStorage.allClips()
    }

    private func deleteClips(at offsets: IndexSet) {
        for index in offsets {
            clipStorage.delete(clips[index])
        }
        refresh()
    }

    /// Saves a clip into Photos via `PHPhotoLibrary`. Requests add-only authorization (we only
    /// ever write, never read the user's existing library) the first time it's needed.
    private func download(_ clip: URL) {
        downloadStates[clip] = .saving

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized, .limited:
                    performSave(clip)
                default:
                    downloadStates[clip] = .idle
                    downloadErrorMessage = "Activa el acceso a Fotos para DiveRecorder en Ajustes para poder descargar clips."
                }
            }
        }
    }

    private func performSave(_ clip: URL) {
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: clip)
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                if success {
                    downloadStates[clip] = .saved
                } else {
                    downloadStates[clip] = .idle
                    downloadErrorMessage = error?.localizedDescription ?? "No se pudo guardar el clip en Fotos."
                }
            }
        }
    }
}

private struct ContentUnavailableFallback: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Todavía no hay clavados guardados")
                .foregroundStyle(.secondary)
        }
    }
}
