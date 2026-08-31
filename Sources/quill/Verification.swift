import ArgumentParser
import AVFoundation
import Foundation

/// A no-permission targeted verification for the optional listening export.
/// It creates two short synthetic CAF tracks, offsets one by half a second,
/// exports mixed.m4a, and verifies both timeline duration and readability.
struct VerifyMix: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify-mix",
        abstract: "Verify the optional mixed-audio exporter with synthetic tracks."
    )

    func run() throws {
        let result = LockedResult<Void>()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("quill-mix-verify-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }
                let mic = dir.appendingPathComponent("mic.caf")
                let system = dir.appendingPathComponent("system.caf")
                try Self.writeTone(to: mic, hertz: 440)
                try Self.writeTone(to: system, hertz: 660)
                let mixed = dir.appendingPathComponent("mixed.m4a")
                try await MixedAudioExporter.export(
                    inputs: [
                        MixedAudioInput(url: mic, offset: 0),
                        MixedAudioInput(url: system, offset: 0.5),
                    ],
                    to: mixed
                )
                let duration = try await AVURLAsset(url: mixed).load(.duration)
                guard duration.seconds > 1.45, try AVAudioFile(forReading: mixed).length > 0 else {
                    throw ValidationError("mixed output was empty or lost its offset")
                }
                result.value = .success(())
            } catch {
                result.value = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let outcome = result.value else {
            throw ValidationError("verification did not return a result")
        }
        try outcome.get()
        print("✓ mixed-audio export verified (two 1-second tracks, 0.5-second offset)")
    }

    private static func writeTone(to url: URL, hertz: Double) throws {
        let rate = 44_100.0
        let frames: AVAudioFrameCount = 44_100
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frames) {
            samples[index] = Float(sin(2 * Double.pi * hertz * Double(index) / rate) * 0.25)
        }
        try file.write(from: buffer)
    }
}

/// Exercises Quill's exact MLX process bridge against a supplied local audio
/// file. It is intentionally opt-in so `doctor` never loads the 1.6 GB model.
struct VerifyMLX: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify-mlx",
        abstract: "Verify local Hebrew MLX transcription and segment timing for one audio file."
    )

    @Argument(help: "A local audio file; it is read only.")
    var audio: String

    @Option(name: .long, help: "automatic (default), hebrew, or english.")
    var language = "automatic"

    func run() throws {
        let input = URL(fileURLWithPath: (audio as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw ValidationError("audio file not found: \(input.path)")
        }
        let chosen = TranscriptionLanguage(rawValue: language.lowercased()) ?? .automatic
        let result = LockedResult<[TranscriptSegment]>()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let engine = MLXWhisperEngine(language: chosen)
                try await engine.prepare()
                let segments = try await engine.transcribe(input)
                await engine.release()
                result.value = .success(segments)
            } catch {
                result.value = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let outcome = result.value else {
            throw ValidationError("verification did not return a result")
        }
        let segments = try outcome.get()
        guard !segments.isEmpty,
              zip(segments, segments.dropFirst()).allSatisfy({ pair in pair.0.start <= pair.1.start })
        else { throw ValidationError("MLX returned no usable monotonic timed segments") }
        for segment in segments {
            print(String(format: "[%.2f–%.2f] %@", segment.start, segment.end, segment.text))
        }
        print("✓ local Hebrew MLX verified (\(segments.count) timed segment(s))")
    }
}

/// Re-run local transcription for a finished session without recording again.
struct Retranscribe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "retranscribe",
        abstract: "Re-transcribe one completed session without changing its audio files."
    )

    @Argument(help: "Path to a Quill session folder containing meta.json.")
    var session: String

    func run() throws {
        let dir = URL(fileURLWithPath: (session as NSString).expandingTildeInPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("meta.json").path) else {
            throw ValidationError("not a completed Quill session: \(dir.path)")
        }
        let result = LockedResult<Void>()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let coordinator = TranscriptionCoordinator()
                try await coordinator.retranscribe(dir)
                result.value = .success(())
            } catch {
                result.value = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let outcome = result.value else {
            throw ValidationError("retranscription did not return a result")
        }
        try outcome.get()
        print("✓ transcript written to \(dir.path)")
    }
}

/// The verification task writes from a detached task and reads after its
/// semaphore completes. This tiny box avoids introducing a testing runtime.
private final class LockedResult<Value>: @unchecked Sendable {
    var value: Result<Value, Error>?
}
