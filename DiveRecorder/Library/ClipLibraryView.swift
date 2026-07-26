import SwiftUI
import AVKit

private struct PlayableClip: Identifiable {
    let id: URL
    var url: URL { id }
}

struct ClipLibraryView: View {
    let clipStorage: ClipStorage

    @State private var clips: [URL] = []
    @State private var selectedClip: PlayableClip?

    var body: some View {
        NavigationStack {
            Group {
                if clips.isEmpty {
                    ContentUnavailableFallback()
                } else {
                    List {
                        ForEach(clips, id: \.self) { clip in
                            Button {
                                selectedClip = PlayableClip(id: clip)
                            } label: {
                                Text(clip.lastPathComponent)
                                    .font(.subheadline)
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
