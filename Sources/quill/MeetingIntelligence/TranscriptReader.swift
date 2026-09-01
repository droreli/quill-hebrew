import Foundation

struct TranscriptReader: Sendable {
    enum ReaderError: Error, LocalizedError {
        case missingTranscript(URL)

        var errorDescription: String? {
            switch self {
            case let .missingTranscript(url): "No transcript.json at \(url.path)"
            }
        }
    }

    func read(from sessionDirectory: URL) throws -> SessionTranscript {
        try readTranscript(at: sessionDirectory.appendingPathComponent("transcript.json"))
    }

    func readTranscript(at url: URL) throws -> SessionTranscript {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ReaderError.missingTranscript(url)
        }
        return try JSONDecoder().decode(SessionTranscript.self, from: Data(contentsOf: url))
    }
}
