import Carbon
import Cocoa

final class HotKeyManager {
  static let shared = HotKeyManager()

  var onHotKey: (() -> Void)?

  private var hotKeyRef: EventHotKeyRef?

  func register() {
    let hotKeyID = EventHotKeyID(signature: 0x58434C4E, id: 1)

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )

    InstallEventHandler(
      GetApplicationEventTarget(),
      hotKeyCallback,
      1,
      &eventType,
      Unmanaged.passUnretained(self).toOpaque(),
      nil
    )

    // Cmd + Shift + Option + K
    RegisterEventHotKey(
      UInt32(kVK_ANSI_K),
      UInt32(cmdKey | shiftKey | optionKey),
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &hotKeyRef
    )
  }
}

private func hotKeyCallback(
  nextHandler: EventHandlerCallRef?,
  event: EventRef?,
  userData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let userData else { return OSStatus(eventNotHandledErr) }
  let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
  DispatchQueue.main.async {
    manager.onHotKey?()
  }
  return noErr
}
