import Foundation

/// The explicit set of recordings that can be used as Meeting Brief inputs.
/// A recording may have `meta.json` before its post-recording transcription is
/// ready, so it is intentionally excluded until its canonical transcript
/// exists.
struct CompletedTranscriptSessions {
    static func directories(in root: URL, fileManager: FileManager = .default) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { directory in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return false
            }
            return fileManager.fileExists(atPath: directory.appendingPathComponent("meta.json").path)
                && fileManager.fileExists(atPath: directory.appendingPathComponent("transcript.json").path)
        }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
