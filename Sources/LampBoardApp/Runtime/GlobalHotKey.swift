import Carbon
import LampBoardCore

/// One shortcut that works from any application, through Carbon's hot keys:
/// they need no permission, where a global key monitor needs Accessibility and
/// would see every key typed anywhere (D77).
@MainActor
final class GlobalHotKey {

    private let action: () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init(action: @escaping () -> Void) {
        self.action = action
    }

    /// Registers the shortcut, replacing the previous one; `.off` leaves none.
    func apply(_ shortcut: BarShortcut) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        guard let code = shortcut.keyCode else { return }
        installHandler()
        // "LBKB": the signature names this app's hot keys among everybody's.
        let identity = EventHotKeyID(signature: OSType(0x4C42_4B42), id: 1)
        var registered: EventHotKeyRef?
        let status = RegisterEventHotKey(code, shortcut.carbonModifiers, identity, GetApplicationEventTarget(), 0, &registered)
        if status == noErr {
            hotKey = registered
        } else {
            // Another application holds the combination: said in the log, and
            // the panel's own ⌘K still works.
            Diagnostics.log("bar shortcut \(shortcut.label) not registered: \(status)")
        }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            guard let data else { return noErr }
            let owner = Unmanaged<GlobalHotKey>.fromOpaque(data).takeUnretainedValue()
            // Carbon delivers hot keys on the main thread's run loop.
            MainActor.assumeIsolated { owner.action() }
            return noErr
        }, 1, &pressed, me, &handler)
    }
}
