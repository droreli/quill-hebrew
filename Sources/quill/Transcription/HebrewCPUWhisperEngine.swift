import Foundation

/// Uses Tamlil's existing local faster-whisper Hebrew command as a recovery
/// path for Macs where the MLX GPU runtime cannot be used. It never uses a
/// network API. The command emits timestamped text, so end times are inferred
/// from the next segment (or a conservative 15-second window for the last).
actor HebrewCPUWhisperEngine: TranscriptionEngine {
    enum EngineError: Error, CustomStringConvertible {
        case unavailable(URL)
        case failed(Int32, String)

        var description: String {
            switch self {
            case .unavailable(let url): "Hebrew CPU fallback not found at \(url.path)"
            case .failed(let status, let output): "Hebrew CPU fallback exited \(status): \(output)"
            }
        }
    }

    nonisolated let name = "hebrew-cpu"
    nonisolated let model = "ivrit-ai/whisper-large-v3-turbo-ct2"

    func prepare() async throws {
        let script = Config.cpuScript()
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            throw EngineError.unavailable(script)
        }
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        let output = audio.deletingLastPathComponent()
            .appendingPathComponent(".quill-cpu-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = Config.cpuScript()
            process.arguments = [audio.path, output.path, "--timestamps"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            return (
                process.terminationStatus,
                String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            )
        }.value
        guard result.0 == 0 else { throw EngineError.failed(result.0, result.1) }
        let text = try String(contentsOf: output, encoding: .utf8)
        let startsAndText = text.split(whereSeparator: { $0.isNewline }).compactMap { line -> (TimeInterval, String)? in
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
            let timestamp = line[line.index(after: line.startIndex)..<close]
            let parts = timestamp.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 3 else { return nil }
            let start = parts[0] * 3600 + parts[1] * 60 + parts[2]
            let body = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? nil : (start, body)
        }
        return startsAndText.enumerated().map { index, item in
            let next = index + 1 < startsAndText.count ? startsAndText[index + 1].0 : item.0 + 15
            return TranscriptSegment(start: item.0, end: max(item.0, next), text: item.1)
        }
    }

    func release() async {}
}
