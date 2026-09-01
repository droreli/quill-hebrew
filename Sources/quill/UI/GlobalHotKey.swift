import Carbon.HIToolbox
import Foundation

/// Registers a system-wide keyboard shortcut without requiring Accessibility
/// permission. Carbon's hot-key API still provides the native, conflict-aware
/// registration needed by a menu-bar utility.
final class GlobalHotKey: @unchecked Sendable {
    private static let signature: OSType = 0x5175_696C // "Quil"
    private static let recordingToggleID: UInt32 = 1

    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let action: @MainActor () -> Void

    static func recordingToggle(
        action: @escaping @MainActor () -> Void
    ) -> GlobalHotKey? {
        GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_R),
            modifiers: UInt32(cmdKey | controlKey),
            identifier: recordingToggleID,
            action: action
        )
    }

    private init?(
        keyCode: UInt32,
        modifiers: UInt32,
        identifier: UInt32,
        action: @escaping @MainActor () -> Void
    ) {
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.handleEvent,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard installStatus == noErr else {
            Self.logFailure("install event handler", status: installStatus)
            return nil
        }

        let hotKeyID = EventHotKeyID(
            signature: Self.signature,
            id: identifier
        )
        let registrationStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard registrationStatus == noErr else {
            if let eventHandler { RemoveEventHandler(eventHandler) }
            eventHandler = nil
            Self.logFailure("register ⌃⌘R (it may already be in use)", status: registrationStatus)
            return nil
        }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    private static let handleEvent: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr,
              hotKeyID.signature == signature,
              hotKeyID.id == recordingToggleID
        else { return OSStatus(eventNotHandledErr) }

        let owner = Unmanaged<GlobalHotKey>
            .fromOpaque(userData)
            .takeUnretainedValue()
        MainActor.assumeIsolated {
            owner.action()
        }
        return noErr
    }

    private static func logFailure(_ operation: String, status: OSStatus) {
        FileHandle.standardError.write(Data(
            "warning: couldn't \(operation): OSStatus \(status)\n".utf8
        ))
    }
}
