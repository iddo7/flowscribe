import Carbon.HIToolbox
import Foundation

/// Global ⌃⌥Space press/release pair registered with Carbon.
final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var isPressed = false

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    /// Registers Control+Option+Space system-wide and listens for both edges.
    @discardableResult
    func register() -> Bool {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            let eventKind = GetEventKind(event)
            DispatchQueue.main.async { manager.handle(eventKind: eventKind) }
            return noErr
        }

        let status = eventTypes.withUnsafeMutableBufferPointer { buffer in
            InstallEventHandler(
                GetApplicationEventTarget(),
                callback,
                buffer.count,
                buffer.baseAddress,
                selfPtr,
                &handlerRef
            )
        }
        guard status == noErr else { return false }

        let hotKeyID = EventHotKeyID(signature: OSType(0x464C5753) /* 'FLWS' */, id: 1)
        let registered = RegisterEventHotKey(UInt32(kVK_Space),
                                             UInt32(controlKey | optionKey),
                                             hotKeyID,
                                             GetApplicationEventTarget(),
                                             0,
                                             &hotKeyRef)
        guard registered == noErr else {
            unregister()
            return false
        }
        return true
    }

    private func handle(eventKind: UInt32) {
        switch eventKind {
        case UInt32(kEventHotKeyPressed) where !isPressed:
            isPressed = true
            onPress?()
        case UInt32(kEventHotKeyReleased) where isPressed:
            isPressed = false
            onRelease?()
        default:
            break
        }
    }

    func unregister() {
        isPressed = false
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = handlerRef {
            RemoveEventHandler(handler)
            handlerRef = nil
        }
    }

    deinit { unregister() }
}
