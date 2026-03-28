import SwiftUI

@main
struct XcodeCleanApp: App {
  @StateObject private var cleanManager = CleanManager.shared

  var body: some Scene {
    MenuBarExtra {
      MenuBarView(cleanManager: cleanManager)
    } label: {
      Image(systemName: cleanManager.isRunning ? "hammer.circle.fill" : "hammer.circle")
    }
    .menuBarExtraStyle(.menu)
  }

  init() {
    HotKeyManager.shared.onHotKey = {
      Task { @MainActor in
        CleanManager.shared.cleanAll()
      }
    }
    HotKeyManager.shared.register()
  }
}
