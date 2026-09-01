import ArgumentParser
import Testing

@testable import quill

@Test func appRuntimeUsesSynchronousCommandRoot() {
    #expect(!(Quill.self is any AsyncParsableCommand.Type))
    #expect(!(Run.self is any AsyncParsableCommand.Type))
    #expect(!(Brief.self is any AsyncParsableCommand.Type))
}

@MainActor
@Test func notesBindingFailureRemainsVisibleWhileUnbound() {
    let viewModel = MeetingNotesViewModel()
    viewModel.setSaveState(.failed(message: "fixture failure"))

    #expect(viewModel.isBound == false)
    #expect(viewModel.saveState == .failed(message: "fixture failure"))
}
