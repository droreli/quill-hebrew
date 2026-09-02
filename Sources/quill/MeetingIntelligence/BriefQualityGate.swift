import Foundation

/// Applies deterministic publication rules after model decoding and before a
/// brief can become a user-visible artifact. This is intentionally stricter
/// than JSON-schema validation: a syntactically valid model response is not
/// necessarily a useful or grounded meeting brief.
struct BriefQualityGate: Sendable {
    static let maximumEvidenceReferencesPerItem = 2

    struct Result: Sendable {
        let payload: BriefResponseDecoder.ModelBriefPayload
        let overviewSupport: BriefClaimSupport
        let warnings: [String]
    }

    func evaluate(
        _ payload: BriefResponseDecoder.ModelBriefPayload,
        transcript: SessionTranscript,
        rawNotes: RawMeetingNotes
    ) -> Result {
        let source = SourceIndex(transcript: transcript, rawNotes: rawNotes)
        let topics = payload.topics.compactMap { sanitize($0, source: source) }
        let decisions = payload.decisions.compactMap { sanitize($0, source: source) }
        let questions = payload.openQuestions.compactMap { sanitize($0, source: source) }
        let actions = payload.actionItems.compactMap { sanitize($0, source: source) }
        let sanitized = BriefResponseDecoder.ModelBriefPayload(
            language: payload.language,
            overview: payload.overview,
            topics: topics,
            decisions: decisions,
            actionItems: actions,
            openQuestions: questions,
            warnings: []
        )
        let hasClaims = !topics.isEmpty || !decisions.isEmpty || !actions.isEmpty || !questions.isEmpty
        let overviewIsPublishable = isPublishableOverview(payload.overview, source: source)

        guard hasClaims else {
            return coverageFallback(source: source)
        }

        if !overviewIsPublishable {
            let fallback = coverageFallback(source: source)
            return Result(
                payload: .init(
                    language: sanitized.language,
                    overview: fallback.payload.overview,
                    topics: sanitized.topics,
                    decisions: sanitized.decisions,
                    actionItems: sanitized.actionItems,
                    openQuestions: sanitized.openQuestions,
                    warnings: []
                ),
                overviewSupport: .quillSystemNotice,
                warnings: fallback.warnings
            )
        }

        let removedCount = payload.topics.count + payload.decisions.count + payload.actionItems.count
            + payload.openQuestions.count - topics.count - decisions.count - actions.count - questions.count
        let warnings = removedCount > 0
            ? ["Some generated items were withheld because they lacked compact, direct transcript support or repeated raw notes. Raw notes remain separate and unchanged."]
            : []
        return Result(payload: sanitized, overviewSupport: .aiGeneratedRequiresReview, warnings: warnings)
    }

    private func sanitize(
        _ item: BriefResponseDecoder.ModelBriefPayload.Item,
        source: SourceIndex
    ) -> BriefResponseDecoder.ModelBriefPayload.Item? {
        guard let evidence = compactEvidence(item.evidenceSegmentIDs),
              isGroundedClaim(item.text, evidence: evidence, source: source)
        else { return nil }
        return .init(id: item.id, text: item.text, evidenceSegmentIDs: evidence)
    }

    private func sanitize(
        _ action: BriefResponseDecoder.ModelBriefPayload.Action,
        source: SourceIndex
    ) -> BriefResponseDecoder.ModelBriefPayload.Action? {
        guard let evidence = compactEvidence(action.evidenceSegmentIDs),
              isGroundedClaim(action.text, evidence: evidence, source: source),
              hasExplicitAction(action.text),
              hasSupportedOwner(action.owner, evidence: evidence, source: source)
                || evidenceContainCommitment(evidence, source: source)
        else { return nil }
        return .init(
            id: action.id,
            text: action.text,
            owner: action.owner?.trimmingCharacters(in: .whitespacesAndNewlines),
            dueDate: supportedDueDate(action.dueDate, evidence: evidence, source: source),
            evidenceSegmentIDs: evidence
        )
    }

    private func compactEvidence(_ evidence: [String]) -> [String]? {
        let unique = evidence.reduce(into: [String]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        guard !unique.isEmpty else { return nil }
        return Array(unique.prefix(Self.maximumEvidenceReferencesPerItem))
    }

    private func isGroundedClaim(_ text: String, evidence: [String], source: SourceIndex) -> Bool {
        let tokens = SourceIndex.tokens(in: text)
        guard !tokens.isEmpty else { return false }
        let evidenceTokens = source.tokens(for: evidence)
        let overlapCount = tokens.intersection(evidenceTokens).count
        let hasTranscriptOverlap = overlapCount > 0
        // A note can repeat a fact that also appears in the transcript. It is
        // publishable only when the cited transcript independently shares a
        // substantive token with the generated claim.
        guard hasTranscriptOverlap else { return false }
        if source.isRawNoteEcho(tokens) {
            return Double(overlapCount) / Double(tokens.count) >= 0.5
        }
        return true
    }

    private func isPublishableOverview(_ text: String, source: SourceIndex) -> Bool {
        guard !text.contains("\u{FFFD}") else { return false }
        let tokens = SourceIndex.tokens(in: text)
        guard tokens.count >= 5,
              !source.isRawNoteEcho(tokens),
              !tokens.intersection(source.allTranscriptTokens).isEmpty
        else { return false }
        guard !source.prefersHebrew || SourceIndex.hebrewLetterRatio(in: text) >= 0.45 else { return false }
        return true
    }

    private func hasSupportedOwner(_ owner: String?, evidence: [String], source: SourceIndex) -> Bool {
        guard let owner = owner?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty else {
            return false
        }
        let ownerTokens = SourceIndex.tokens(in: owner)
        let evidenceTokens = source.tokens(for: evidence)
        return !ownerTokens.isEmpty && ownerTokens.allSatisfy { ownerToken in
            evidenceTokens.contains { evidenceToken in
                evidenceToken == ownerToken || evidenceToken.hasSuffix(ownerToken)
            }
        }
    }

    private func supportedDueDate(_ dueDate: String?, evidence: [String], source: SourceIndex) -> String? {
        guard let dueDate = dueDate?.trimmingCharacters(in: .whitespacesAndNewlines), !dueDate.isEmpty else {
            return nil
        }
        let dueTokens = SourceIndex.tokens(in: dueDate)
        let evidenceTokens = source.tokens(for: evidence)
        guard !dueTokens.isEmpty, dueTokens.allSatisfy({ dueToken in
            evidenceTokens.contains { evidenceToken in
                evidenceToken == dueToken || evidenceToken.hasSuffix(dueToken)
            }
        }) else { return nil }
        return dueDate
    }

    private func evidenceContainCommitment(_ evidence: [String], source: SourceIndex) -> Bool {
        let text = source.text(for: evidence).lowercased()
        let markers = [
            "i will", "we will", "i'll", "we'll", "will send", "will prepare", "will follow",
            "אני א", "אשלח", "אבדוק", "אכין", "אדאג", "נטפל", "נשלח", "נבצע"
        ]
        return markers.contains { text.contains($0) }
    }

    private func hasExplicitAction(_ text: String) -> Bool {
        let value = text.lowercased()
        let markers = [
            "send", "prepare", "review", "schedule", "follow", "update", "share", "confirm",
            "לשלוח", "להכין", "לבדוק", "לתאם", "לעדכן", "לטפל", "לסכם", "אשלח", "אבדוק", "אכין",
            "תשלח", "תבדוק", "תכין", "תעדכן", "תטפל", "נשלח", "נבדוק", "נכין", "נטפל"
        ]
        return markers.contains { value.contains($0) }
    }

    private func coverageFallback(source: SourceIndex) -> Result {
        let hebrew = source.prefersHebrew
        let overview = hebrew
            ? "לא נוצר תקציר אוטומטי אמין: התמלול קצר או לא ברור מספיק כדי לבסס טענות, החלטות או משימות. ההערות הגולמיות נשמרו בנפרד ולא שונו."
            : "No reliable automatic brief was generated: the transcript is too limited or unclear to support claims, decisions, or action items. Raw notes remain separate and unchanged."
        let warning = hebrew
            ? "לא פורסמו טענות אוטומטיות ללא תמיכה ישירה וקצרה בתמלול."
            : "No generated claims were published without compact, direct transcript support."
        return Result(
            payload: .init(
                language: hebrew ? "Hebrew" : "undetermined",
                overview: overview,
                topics: [],
                decisions: [],
                actionItems: [],
                openQuestions: [],
                warnings: []
            ),
            overviewSupport: .quillSystemNotice,
            warnings: [warning]
        )
    }
}

private struct SourceIndex: Sendable {
    let textBySegmentID: [String: String]
    let rawNoteTokens: [Set<String>]
    let prefersHebrew: Bool

    init(transcript: SessionTranscript, rawNotes: RawMeetingNotes) {
        textBySegmentID = Dictionary(uniqueKeysWithValues: transcript.segments.map { ($0.id, $0.text) })
        let text = transcript.segments.map(\.text).joined(separator: "\n")
        rawNoteTokens = rawNotes.notes.map { Self.tokens(in: $0.text) }
        prefersHebrew = Self.hebrewLetterRatio(in: text) >= 0.55
    }

    func text(for evidence: [String]) -> String {
        evidence.compactMap { textBySegmentID[$0] }.joined(separator: "\n")
    }

    func tokens(for evidence: [String]) -> Set<String> {
        Self.tokens(in: text(for: evidence))
    }

    func isRawNoteEcho(_ candidate: Set<String>) -> Bool {
        guard candidate.count >= 3 else { return false }
        return rawNoteTokens.contains { note in
            Double(candidate.intersection(note).count) / Double(candidate.count) >= 0.8
        }
    }

    static func tokens(in text: String) -> Set<String> {
        let pattern = "[\\p{L}\\p{N}_]{1,}"
        let range = NSRange(text.startIndex..., in: text)
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return Set(expression.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]).lowercased() }
        })
    }

    static func hebrewLetterRatio(in text: String) -> Double {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return 0 }
        let hebrew = letters.filter { (0x0590...0x05FF).contains($0.value) }
        return Double(hebrew.count) / Double(letters.count)
    }

    var allTranscriptTokens: Set<String> {
        Set(textBySegmentID.values.flatMap { Self.tokens(in: $0) })
    }
}
