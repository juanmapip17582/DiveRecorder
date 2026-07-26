import Foundation

/// Saves and lists finished clips in the app's Documents/Clips folder.
final class ClipStorage {
    private let fileManager = FileManager.default

    private var clipsDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Clips", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func newClipURL() -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTime]
        let name = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return clipsDirectory.appendingPathComponent("clavado-\(name).mov")
    }

    func allClips() -> [URL] {
        let files = (try? fileManager.contentsOfDirectory(at: clipsDirectory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "mov" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return l > r
            }
    }

    func delete(_ url: URL) {
        try? fileManager.removeItem(at: url)
    }
}
