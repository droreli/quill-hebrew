import Foundation
import Testing

@testable import quill

private func facts(
    name: String? = "2026.09.02-1000",
    recording: Bool = false,
    meta: Bool = true,
    segments: Int? = nil,
    activity: MeetingPadStatus.TranscriptionActivity = .idle,
    transcriptionEnabled: Bool = true,
    provider: Bool = false,
    brief: Bool = false
) -> MeetingPadStatus.Facts {
    MeetingPadStatus.Facts(
        sessionName: name,
        isRecording: recording,
        startedAt: Date(timeIntervalSince1970: 1_000),
        hasCompletedMeta: meta,
        transcriptSegmentCount: segments,
        transcriptionActivity: activity,
        transcriptionEnabled: transcriptionEnabled,
        providerEnabled: provider,
        briefExists: brief
    )
}

@Test func padWithoutSessionIsUnboundAndCannotEnhance() {
    let status = MeetingPadStatus.resolve(facts(name: nil))
    #expect(status == .unbound)
    #expect(status.enhancement.isEnabled == false)
    #expect(status.lifecycle.headline() == "No meeting bound")
}

@Test func recordingNeverClaimsATranscriptEvenIfOneIsOnDisk() {
    let status = MeetingPadStatus.resolve(facts(recording: true, meta: false, segments: 12, provider: true, brief: true))
    #expect(status.lifecycle == .recording(startedAt: Date(timeIntervalSince1970: 1_000)))
    #expect(status.lifecycle.transcript == .afterRecording)
    #expect(status.enhancement == .recording)
    #expect(status.lifecycle.headline(elapsed: "12:34") == "Recording · 12:34")
}

@Test func stoppedSessionWaitsUntilTheCoordinatorNamesIt() {
    let pending = MeetingPadStatus.resolve(facts(activity: .idle))
    #expect(pending.lifecycle == .stopped(transcript: .pending))
    let otherBusy = MeetingPadStatus.resolve(facts(activity: .transcribing(session: "other", queued: 1)))
    #expect(otherBusy.lifecycle == .stopped(transcript: .pending))
    let thisBusy = MeetingPadStatus.resolve(facts(activity: .transcribing(session: "2026.09.02-1000", queued: 0)))
    #expect(thisBusy.lifecycle == .stopped(transcript: .transcribing))
    #expect(thisBusy.enhancement.isEnabled == false)
}

@Test func transcriptionFailureAndDisabledConfigAreReportedPlainly() {
    let failed = MeetingPadStatus.resolve(facts(activity: .failed(session: "2026.09.02-1000")))
    #expect(failed.lifecycle == .stopped(transcript: .failed))
    #expect(failed.lifecycle.detail.contains("transcribe.log"))
    let disabled = MeetingPadStatus.resolve(facts(transcriptionEnabled: false))
    #expect(disabled.lifecycle == .stopped(transcript: .disabled))
    #expect(disabled.enhancement.action == .none)
}

@Test func readyTranscriptUnlocksEnhancementOnlyWithTheLocalProvider() {
    let noProvider = MeetingPadStatus.resolve(facts(segments: 42))
    #expect(noProvider.lifecycle == .stopped(transcript: .ready(segmentCount: 42)))
    #expect(noProvider.enhancement == .providerDisabled)
    #expect(noProvider.enhancement.buttonTitle == "Set up local AI…")
    let provider = MeetingPadStatus.resolve(facts(segments: 1, provider: true))
    #expect(provider.enhancement == .ready)
    #expect(provider.enhancement.action == .generateBrief)
    let existingBrief = MeetingPadStatus.resolve(facts(segments: 5, brief: true))
    #expect(existingBrief.enhancement.action == .openBrief)
}

@Test func transcriptOnDiskWinsOverStaleFailureStatus() {
    let status = MeetingPadStatus.resolve(facts(segments: 3, activity: .failed(session: "2026.09.02-1000")))
    #expect(status.lifecycle == .stopped(transcript: .ready(segmentCount: 3)))
}
