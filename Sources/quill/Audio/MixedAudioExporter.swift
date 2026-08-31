import AVFoundation
import Foundation

/// A single source track placed on Quill's shared recording clock.
struct MixedAudioInput: Sendable {
    let url: URL
    let offset: TimeInterval
}

/// Exports a listening copy of both tracks. Transcription keeps using clean
/// tracks because mixing overlapping voices makes both listening and ASR worse.
enum MixedAudioExporter {
    enum ExportError: Error, CustomStringConvertible {
        case noAudio(URL)
        case compositionTrack
        case exporterUnavailable
        case failed(String)

        var description: String {
            switch self {
            case .noAudio(let url): "no audio track in \(url.lastPathComponent)"
            case .compositionTrack: "couldn't create mixed-audio composition track"
            case .exporterUnavailable: "macOS could not create an M4A exporter"
            case .failed(let message): "mixed-audio export failed: \(message)"
            }
        }
    }

    /// Render each source on its own composition track at its measured offset.
    /// AVFoundation mixes enabled tracks together; -3 dB per source leaves
    /// headroom when both people speak.
    static func export(inputs: [MixedAudioInput], to output: URL) async throws {
        let usable = inputs.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard !usable.isEmpty else { throw ExportError.noAudio(output) }

        let composition = AVMutableComposition()
        var parameters: [AVAudioMixInputParameters] = []
        for input in usable {
            let asset = AVURLAsset(url: input.url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else {
                throw ExportError.noAudio(input.url)
            }
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, duration > .zero else { continue }
            guard let target = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { throw ExportError.compositionTrack }
            try target.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: source,
                at: CMTime(seconds: input.offset, preferredTimescale: 600)
            )
            let parameter = AVMutableAudioMixInputParameters(track: target)
            parameter.setVolume(0.707, at: .zero)
            parameters.append(parameter)
        }

        guard !parameters.isEmpty else { throw ExportError.noAudio(output) }
        try? FileManager.default.removeItem(at: output)
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else { throw ExportError.exporterUnavailable }
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = parameters
        exporter.audioMix = audioMix
        do {
            try await exporter.export(to: output, as: .m4a)
        } catch {
            throw ExportError.failed(error.localizedDescription)
        }
    }
}
