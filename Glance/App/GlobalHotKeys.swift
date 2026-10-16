import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts that work while other apps are frontmost (no Accessibility permission needed):
/// ⌥⇧⌘R start/stop, ⌥⇧⌘P pause/resume.
@MainActor
final class GlobalHotKeys {
    static let modifiers = UInt32(cmdKey | optionKey | shiftKey)
    static let toggleDescription = "⌥⇧⌘R"
    static let pauseDescription = "⌥⇧⌘P"

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private let actions: [UInt32: () -> Void]

    init(toggleRecording: @escaping () -> Void, togglePause: @escaping () -> Void) {
        actions = [1: toggleRecording, 2: togglePause]
        installHandler()
        register(id: 1, keyCode: UInt32(kVK_ANSI_R))
        register(id: 2, keyCode: UInt32(kVK_ANSI_P))
    }

    private func installHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let center = Unmanaged<GlobalHotKeys>.fromOpaque(userData).takeUnretainedValue()
            let id = hotKeyID.id
            MainActor.assumeIsolated { center.actions[id]?() }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType,
                            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    private func register(id: UInt32, keyCode: UInt32) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x474C4E43) /* 'GLNC' */, id: id)
        let status = RegisterEventHotKey(keyCode, Self.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            hotKeyRefs.append(ref)
        } else {
            Log.recording.error("Couldn't register global shortcut \(id) (status \(status))")
        }
    }
}
