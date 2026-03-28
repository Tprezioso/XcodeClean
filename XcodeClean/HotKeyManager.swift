import Carbon
import Cocoa

final class HotKeyManager {
  static let shared = HotKeyManager()

  enum Action: UInt32, CaseIterable {
    case cleanAll = 1          // Cmd+Shift+Option+K
    case deleteDerivedData = 2 // Cmd+Shift+Option+D
    case cleanBuild = 3        // Cmd+Shift+Option+B
    case resetPackages = 4     // Cmd+Shift+Option+R
    case resolvePackages = 5   // Cmd+Shift+Option+P
    case cleanSimulators = 6   // Cmd+Shift+Option+S

    var keyCode: UInt32 {
      switch self {
      case .cleanAll: UInt32(kVK_ANSI_K)
      case .deleteDerivedData: UInt32(kVK_ANSI_D)
      case .cleanBuild: UInt32(kVK_ANSI_B)
      case .resetPackages: UInt32(kVK_ANSI_R)
      case .resolvePackages: UInt32(kVK_ANSI_P)
      case .cleanSimulators: UInt32(kVK_ANSI_S)
      }
    }
  }

  var onAction: ((Action) -> Void)?

  private var hotKeyRefs: [EventHotKeyRef?] = []

  func register() {
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

    let modifiers = UInt32(cmdKey | shiftKey | optionKey)

    for action in Action.allCases {
      let hotKeyID = EventHotKeyID(signature: 0x58434C4E, id: action.rawValue)
      var ref: EventHotKeyRef?
      RegisterEventHotKey(
        action.keyCode,
        modifiers,
        hotKeyID,
        GetApplicationEventTarget(),
        0,
        &ref
      )
      hotKeyRefs.append(ref)
    }
  }
}

private func hotKeyCallback(
  nextHandler: EventHandlerCallRef?,
  event: EventRef?,
  userData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let userData, let event else { return OSStatus(eventNotHandledErr) }
  let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()

  var hotKeyID = EventHotKeyID()
  GetEventParameter(
    event,
    EventParamName(kEventParamDirectObject),
    EventParamType(typeEventHotKeyID),
    nil,
    MemoryLayout<EventHotKeyID>.size,
    nil,
    &hotKeyID
  )

  guard let action = HotKeyManager.Action(rawValue: hotKeyID.id) else {
    return OSStatus(eventNotHandledErr)
  }

  DispatchQueue.main.async {
    manager.onAction?(action)
  }
  return noErr
}
