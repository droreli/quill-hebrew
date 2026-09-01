import AppKit
import Testing

@testable import quill

@MainActor
@Test func meetingNotesStayReadableAndFullWidthInDarkMode() throws {
    let viewModel = MeetingNotesViewModel()
    let controller = MeetingNotesWindowController(viewModel: viewModel)
    let window = try #require(controller.window)
    window.appearance = NSAppearance(named: .darkAqua)
    window.setFrame(NSRect(x: 0, y: 0, width: 780, height: 640), display: false)

    let note = RawMeetingNotes.Note(
        id: "hebrew-note",
        text: "החלטנו להמשיך עם הגרסה המקומית",
        capturedAtMS: 19_000,
        createdAt: "2026-09-01T12:00:00Z",
        updatedAt: "2026-09-01T12:00:00Z"
    )
    let snapshot = try RawMeetingNotes(
        sessionID: "session",
        revision: 1,
        template: "general",
        updatedAt: "2026-09-01T12:00:00Z",
        notes: [note]
    )
    viewModel.bind(sessionID: "session", snapshot: snapshot)
    window.contentView?.layoutSubtreeIfNeeded()

    let views = window.contentView.map(allDescendants) ?? []
    let editor = try #require(views.compactMap { $0 as? NSTextView }.first)
    let foreground = try #require(editor.typingAttributes[.foregroundColor] as? NSColor)
    let rgb = try #require(foreground.usingColorSpace(.sRGB))
    #expect(rgb.brightnessComponent > 0.8)

    editor.textStorage?.setAttributedString(NSAttributedString(
        string: "עברית נראית",
        attributes: [.foregroundColor: NSColor.black]
    ))
    controller.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
    let storedForeground = try #require(
        editor.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    )
    let storedRGB = try #require(storedForeground.usingColorSpace(.sRGB))
    #expect(storedRGB.brightnessComponent > 0.8)

    let row = try #require(views.compactMap { $0 as? NSButton }.first {
        $0.identifier?.rawValue == note.id
    })
    #expect(row.frame.width > 200)
    let preview = try #require(allDescendants(row).compactMap { $0 as? NSTextField }.first {
        $0.stringValue.contains("החלטנו להמשיך")
    })
    #expect(preview.frame.width > 200)
}

@MainActor
private func allDescendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + allDescendants($0) }
}
