import AppKit
import Foundation
import Testing

@testable import quill

@MainActor
@Test func controlsWindowIsCompactResizableAndScrollable() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-controls-layout-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let controller = ControlsWindowController(
        root: root,
        options: RecordingOptions(
            output: .separate,
            language: .automatic,
            engine: .hebrewMLX,
            showTimestamps: true,
            showSpeakerLabels: false
        )
    )
    let window = try #require(controller.window)

    #expect(window.styleMask.contains(.resizable))
    #expect(window.frame.width == 600)
    #expect(window.frame.height == 680)
    #expect(window.minSize == NSSize(width: 560, height: 480))
    let contentView = try #require(window.contentView)
    let scrollView = try #require(firstScrollView(in: contentView))
    #expect(scrollView.documentView?.isFlipped == true)
}

@MainActor
@Test func appMenuRoutesCommandQToStandardTerminationAction() {
    let menu = quillMainMenu()
    let quitItem = menu.item(at: 0)?.submenu?.item(at: 0)

    #expect(quitItem?.keyEquivalent == "q")
    #expect(quitItem?.keyEquivalentModifierMask == .command)
    #expect(quitItem?.action == #selector(NSApplication.terminate(_:)))
    #expect(quitItem?.target === NSApplication.shared)
}

@MainActor
private func firstScrollView(in view: NSView) -> NSScrollView? {
    if let scrollView = view as? NSScrollView { return scrollView }
    for child in view.subviews {
        if let scrollView = firstScrollView(in: child) { return scrollView }
    }
    return nil
}
