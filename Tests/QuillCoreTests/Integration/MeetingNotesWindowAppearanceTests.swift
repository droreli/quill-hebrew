import AppKit
import Testing

@testable import quill

@MainActor
@Test func meetingNotesRenderHebrewInkAndFullWidthRowsInShownDarkWindow() throws {
    let viewModel = MeetingNotesViewModel()
    let controller = MeetingNotesWindowController(viewModel: viewModel)
    let window = try #require(controller.window)
    window.appearance = NSAppearance(named: .darkAqua)
    window.setFrame(NSRect(x: 0, y: 0, width: 780, height: 640), display: false)

    let notes = (0..<3).map { index in
        RawMeetingNotes.Note(
            id: "hebrew-note-\(index)",
            text: "החלטנו להמשיך עם הגרסה המקומית ולשמור standup notes",
            capturedAtMS: 19_000 * (index + 1),
            createdAt: "2026-09-01T12:00:00Z",
            updatedAt: "2026-09-01T12:00:00Z"
        )
    }
    let snapshot = try RawMeetingNotes(
        sessionID: "session",
        revision: 1,
        template: "general",
        updatedAt: "2026-09-01T12:00:00Z",
        notes: notes
    )
    viewModel.bind(sessionID: "session", snapshot: snapshot)
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()

    let views = window.contentView.map(allDescendants) ?? []
    let editor = try #require(views.compactMap { $0 as? NSTextView }.first)
    // A visible scroll-view background is not proof that its document view
    // has usable geometry. The live regression accepted input into a
    // zero-width NSTextView, so notes saved while every glyph stayed hidden.
    #expect(editor.frame.width > 200)
    #expect(editor.bounds.width > 200)
    #expect((editor.textContainer?.containerSize.width ?? 0) > 200)
    editor.string = ""
    editor.setSelectedRange(NSRange(location: 0, length: 0))
    // Reproduce the live failure mode: a launchd/input-manager path supplies
    // concrete black model ink even though this shown editor is Dark Mode.
    // Adaptive mapping must render that stored ink with visible contrast.
    var inputAttributes = editor.typingAttributes
    inputAttributes[.foregroundColor] = NSColor.black
    editor.typingAttributes = inputAttributes
    for character in "עברית נראית במסך כהה וגם latin" {
        let insertionPoint = (editor.string as NSString).length
        editor.insertText(
            String(character),
            replacementRange: NSRange(location: insertionPoint, length: 0)
        )
    }
    let storedInk = try #require(
        editor.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    )
    let storedRGB = try #require(storedInk.usingColorSpace(.sRGB))
    #expect(storedRGB.brightnessComponent < 0.1)
    _ = window.makeFirstResponder(nil)
    editor.isEditable = false
    editor.displayIfNeeded()
    // Exercise the actual composited rendering path. Attribute-only checks
    // missed the original dark-mode defect because a visible caret could exist
    // while Hebrew glyph ink was absent from the editor bitmap.
    #expect(brightInkPixelCount(in: editor) > 80)

    let table = try #require(views.compactMap { $0 as? NSTableView }.first)
    table.layoutSubtreeIfNeeded()
    #expect(table.tableColumns[0].width > 200)
    for rowIndex in 0..<table.numberOfRows {
        let row = try #require(table.view(atColumn: 0, row: rowIndex, makeIfNecessary: true))
        #expect(row.frame.width > 200)
        #expect(brightInkPixelCount(in: row) > 40)
        let preview = try #require(allDescendants(row).compactMap { $0 as? NSTextField }.first {
            $0.stringValue.contains("החלטנו להמשיך")
        })
        #expect(preview.frame.width > 200)
    }
}

@MainActor
private func allDescendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + allDescendants($0) }
}

@MainActor
private func brightInkPixelCount(in view: NSView) -> Int {
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let width = Int(view.bounds.width)
    let height = Int(view.bounds.height)
    var count = 0
    for x in 8..<max(8, width - 8) {
        for y in 8..<max(8, height - 8) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if color.alphaComponent > 0.8, color.brightnessComponent > 0.65 {
                count += 1
            }
        }
    }
    return count
}
