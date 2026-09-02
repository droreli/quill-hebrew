# Incremental local transcription: current decision

Quill does **not** ship recording-time transcript text in this revision. This
is an intentional safety boundary, not a delayed UI update.

The current recorder appends AAC data to `mic.caf` and `system.caf` throughout
the meeting. The current final transcription pipeline reads those finished,
independent tracks after `meta.json` exists, applies their measured start
offsets, and writes the one canonical `transcript.json` atomically. The
default Hebrew/mixed-language route launches the local MLX Whisper helper for
each transcription invocation; it does not keep a streaming decoder resident.
Re-opening a growing CAF every 15 seconds would either re-read earlier audio,
or repeatedly reload the approximately 1.6 GB Hebrew model. Neither approach
meets the product promise of incremental processing, and simultaneous use of
the GPU could delay or destabilize canonical final transcription.

## What a safe future thin slice must do

1. Write separate, closed 15-second sidecar chunks from the recorder callback
   while continuing to preserve the full `mic.caf` and `system.caf` tracks.
   A worker may only read a chunk after its file handle is closed.
2. Use a dedicated, opt-in live engine with a single resident model. It must
   not be the final-transcription engine instance.
3. Append clearly marked **preliminary** timed segments to a separate live
   artifact and Meeting Notes panel. It must never overwrite
   `transcript.json`, `transcript.md`, raw notes, or a brief.
4. On Stop, stop accepting chunks, wait for the live worker to become idle and
   release its model, then enqueue the existing final coordinator. If that
   handoff times out or fails, discard only the preliminary display and run
   canonical final transcription normally.

## M5 / 64 GB operating envelope

Parakeet v2 is the candidate for an English-only experimental route because it
can keep a local Core ML model resident. It still needs a real benchmark before
shipping: target a 15-second finalized chunk, one worker, a bounded queue of
at most two chunks, and a visible backlog indicator. If a chunk takes longer
than its capture interval, Quill must skip ahead with an explicit gap rather
than accumulate memory or replay old audio.

Hebrew MLX and the CPU fallback are not candidates in their present
process-per-request form. A proper Hebrew live route needs a long-lived
streaming helper, chunk-boundary prompting/deduplication, measured per-track
offsets, thermal/load testing, and a reliable cancellation handshake. Until
then, the honest latency for the default Hebrew workflow is post-stop final
transcription, with no synthetic or partial text shown as live.
