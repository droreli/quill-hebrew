import Foundation

/// Produces the human-readable companion to `meeting-brief.json`.  The JSON
/// remains canonical; this rendering intentionally contains no mutable state.
enum BriefMarkdownRenderer {
    static func render(_ brief: MeetingBrief) -> String {
        var lines = ["# Meeting brief", "", brief.overview, ""]

        append(items: brief.topics, heading: "Key topics", to: &lines)
        append(items: brief.decisions, heading: "Decisions", to: &lines)

        lines += ["## Action items", ""]
        if brief.actionItems.isEmpty {
            lines += ["- None recorded.", ""]
        } else {
            for item in brief.actionItems {
                var details = item.text
                if let owner = item.owner { details += " — owner: \(owner)" }
                if let dueDate = item.dueDate { details += " — due: \(dueDate)" }
                lines.append("- \(details)\(evidenceSuffix(item.evidence))")
            }
            lines.append("")
        }

        append(items: brief.openQuestions, heading: "Open questions", to: &lines)

        lines += ["## Warnings", ""]
        if brief.warnings.isEmpty {
            lines += ["- None.", ""]
        } else {
            lines += brief.warnings.map { "- \($0)" }
            lines.append("")
        }

        lines += [
            "---",
            "Generated: \(brief.createdAt)",
            "Transcript SHA-256: \(brief.inputs.transcriptSHA256)",
            "Transcript segments: \(brief.inputs.transcriptSegmentCount)",
            "Raw notes revision: \(brief.inputs.rawNotesRevision)",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    private static func append(items: [BriefItem], heading: String, to lines: inout [String]) {
        lines += ["## \(heading)", ""]
        if items.isEmpty {
            lines += ["- None recorded.", ""]
            return
        }
        for item in items {
            lines.append("- \(item.text)\(evidenceSuffix(item.evidence))")
        }
        lines.append("")
    }

    private static func evidenceSuffix(_ evidence: [EvidenceReference]) -> String {
        guard !evidence.isEmpty else { return "" }
        let locations = evidence.map { "\($0.speaker) \(timestamp($0.startMS))" }
        return " _(evidence: \(locations.joined(separator: ", ")))_"
    }

    private static func timestamp(_ milliseconds: Int) -> String {
        let totalSeconds = milliseconds / 1_000
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
