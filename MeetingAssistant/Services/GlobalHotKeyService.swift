import Carbon.HIToolbox
import Foundation

struct GlobalHotKeyDefinition: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var identifier: UInt32

    static let replyHintNow = GlobalHotKeyDefinition(
        // kVK_Return
        keyCode: UInt32(kVK_Return),
        modifiers: UInt32(cmdKey | shiftKey),
        identifier: 0x4D41484E  // 'MAHN' — Meeting Assistant Hint Now
    )
}

/// Carbon-based global hot key. Fires `handler` on the main run loop whenever
/// the registered key combination is pressed, regardless of which app is
/// focused. Requires no Accessibility permission.
@MainActor
final class GlobalHotKeyService {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var handler: (() -> Void)?
    private var registeredIdentifier: UInt32?

    func register(_ definition: GlobalHotKeyDefinition, handler: @escaping () -> Void) {
        unregister()
        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, userData) -> OSStatus in
                guard let eventRef, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                let service = Unmanaged<GlobalHotKeyService>.fromOpaque(userData).takeUnretainedValue()
                guard let registeredIdentifier = service.registeredIdentifier,
                      hotKeyID.signature == registeredIdentifier,
                      hotKeyID.id == registeredIdentifier
                else {
                    return OSStatus(eventNotHandledErr)
                }
                DispatchQueue.main.async {
                    service.handler?()
                }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandlerRef
        )

        guard installStatus == noErr else {
            self.handler = nil
            print("[GlobalHotKeyService] InstallEventHandler failed: \(installStatus)")
            return
        }

        let hotKeyID = EventHotKeyID(
            signature: definition.identifier,
            id: definition.identifier
        )
        var newHotKeyRef: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            definition.keyCode,
            definition.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &newHotKeyRef
        )

        guard registerStatus == noErr else {
            print("[GlobalHotKeyService] RegisterEventHotKey failed: \(registerStatus)")
            removeEventHandler()
            self.handler = nil
            return
        }

        hotKeyRef = newHotKeyRef
        registeredIdentifier = definition.identifier
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        removeEventHandler()
        handler = nil
        registeredIdentifier = nil
    }

    private func removeEventHandler() {
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }
}
