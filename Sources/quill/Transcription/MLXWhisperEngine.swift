import Foundation

/// Local Apple-GPU transcription backed by the pinned Hebrew Whisper Large V3
/// Turbo MLX conversion already used by Tamlil. It starts a local Python
/// helper rather than linking Python into the menu-bar process, which keeps
/// model memory isolated and lets the daemon release it between sessions.
actor MLXWhisperEngine: TranscriptionEngine {
    enum EngineError: Error, CustomStringConvertible {
        case runtimeUnavailable(String)
        case processFailed(Int32, String)
        case invalidOutput

        var description: String {
            switch self {
            case .runtimeUnavailable(let message): "Hebrew MLX runtime unavailable: \(message)"
            case .processFailed(let status, let output): "Hebrew MLX process exited \(status): \(output)"
            case .invalidOutput: "Hebrew MLX helper produced invalid timed transcript data"
            }
        }
    }

    nonisolated let name = "mlx-hebrew"
    nonisolated let model = "mlx-community/ivrit-ai-whisper-large-v3-turbo-mlx@53ad8c6"

    private var runner: URL?
    private let language: String

    init(language: TranscriptionLanguage = .automatic) {
        self.language = language == .hebrew ? "he" : "auto"
    }

    func prepare() async throws {
        guard runner == nil else { return }
        let python = Config.mlxPython()
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw EngineError.runtimeUnavailable("Python not found at \(python.path)")
        }
        let model = Config.mlxModelDirectory()
        guard FileManager.default.fileExists(atPath: model.appendingPathComponent("config.json").path),
              FileManager.default.fileExists(atPath: model.appendingPathComponent("weights.safetensors").path)
        else {
            throw EngineError.runtimeUnavailable("pinned model is missing at \(model.path)")
        }
        let runner = try writeRunner()
        let result = try await run(python: python, arguments: [runner.path, "--check"])
        guard result.status == 0 else {
            throw EngineError.runtimeUnavailable(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        self.runner = runner
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        guard let runner else { throw EngineError.runtimeUnavailable("engine used before prepare") }
        let output = audio.deletingLastPathComponent()
            .appendingPathComponent(".quill-mlx-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try await run(
            python: Config.mlxPython(),
            arguments: [runner.path, audio.path, output.path, "--language", language]
        )
        guard result.status == 0 else { throw EngineError.processFailed(result.status, result.output) }
        guard let data = try? Data(contentsOf: output),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { throw EngineError.invalidOutput }
        return json.compactMap { item in
            guard let start = item["start"] as? Double,
                  let end = item["end"] as? Double,
                  let text = item["text"] as? String
            else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : TranscriptSegment(start: start, end: max(start, end), text: trimmed)
        }
    }

    func release() async { runner = nil }

    private func writeRunner() throws -> URL {
        let directory = Config.path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("quill-mlx-whisper.py")
        try Data(Self.pythonRunner.utf8).write(to: url, options: .atomic)
        return url
    }

    private func run(python: URL, arguments: [String]) async throws -> (status: Int32, output: String) {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = python
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            // launchd starts agents with /usr/bin:/bin:… only. mlx-whisper
            // invokes `ffmpeg` by name to decode CAF, so preserve the normal
            // system paths and explicitly include Homebrew's local tools.
            // This is a local executable lookup, not a network dependency.
            let localToolPaths = [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
                "/usr/sbin",
                "/sbin",
            ]
            let inheritedPaths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            environment["PATH"] = (localToolPaths + inheritedPaths.filter { !localToolPaths.contains($0) })
                .joined(separator: ":")
            environment["HF_HUB_OFFLINE"] = "1"
            environment["TRANSFORMERS_OFFLINE"] = "1"
            environment["QUILL_MLX_MODEL_DIR"] = Config.mlxModelDirectory().path
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (process.terminationStatus, output)
        }.value
    }

    /// Written under Quill's config directory so a built executable can stay
    /// self-contained. The helper is deliberately offline and uses Tamlil's
    /// exact pinned local model directory.
    private static let pythonRunner = #"""
import json
import os
import sys
from pathlib import Path

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"

import mlx.core as mx
import mlx_whisper

MODEL_DIR = Path(os.environ["QUILL_MLX_MODEL_DIR"])

def fail(message):
    print(message, file=sys.stderr, flush=True)
    raise SystemExit(1)

def check():
    if not (MODEL_DIR / "config.json").is_file() or not (MODEL_DIR / "weights.safetensors").is_file():
        fail("Pinned local Hebrew MLX model is missing or incomplete.")
    if not mx.metal.is_available():
        fail("Metal GPU support is unavailable on this Mac.")
    mx.set_default_device(mx.gpu)

if sys.argv[1:] == ["--check"]:
    check()
    print("Hebrew MLX GPU runtime ready", file=sys.stderr, flush=True)
    raise SystemExit(0)

if len(sys.argv) != 5 or sys.argv[3] != "--language":
    fail("Usage: quill-mlx-whisper.py INPUT OUTPUT --language auto|he")

source, target, language = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[4]
if not source.is_file():
    fail(f"Input not found: {source}")
check()
result = mlx_whisper.transcribe(
    str(source),
    path_or_hf_repo=str(MODEL_DIR),
    language="he" if language == "he" else None,
    initial_prompt="This is a Hebrew and English meeting conversation. Preserve Hebrew, English names, numbers, dates, company names, product names, and technical terms.",
    temperature=0.0,
    condition_on_previous_text=False,
    word_timestamps=False,
    verbose=False,
)
segments = []
for segment in result.get("segments", []):
    text = str(segment.get("text", "")).strip()
    if text:
        segments.append({"start": float(segment.get("start", 0.0)), "end": float(segment.get("end", 0.0)), "text": text})
target.parent.mkdir(parents=True, exist_ok=True)
temporary = target.with_name(f".{target.name}.tmp")
temporary.write_text(json.dumps(segments, ensure_ascii=False), encoding="utf-8")
os.replace(temporary, target)
"""#
}
