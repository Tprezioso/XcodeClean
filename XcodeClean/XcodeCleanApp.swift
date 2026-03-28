import SwiftUI

@main
struct XcodeCleanApp: App {
  @StateObject private var cleanManager = CleanManager.shared

  var body: some Scene {
    MenuBarExtra {
      MenuBarView(cleanManager: cleanManager)
    } label: {
      Image(systemName: cleanManager.isRunning ? "arrow.triangle.2.circlepath" : "xmark.bin.fill")
    }
    .menuBarExtraStyle(.menu)
  }

  init() {
    HotKeyManager.shared.onAction = { action in
      Task { @MainActor in
        let manager = CleanManager.shared
        switch action {
        case .cleanAll: manager.cleanAll()
        case .deleteDerivedData: manager.deleteDerivedData()
        case .cleanBuild: manager.cleanBuild()
        case .resetPackages: manager.resetPackageCaches()
        case .resolvePackages: manager.resolvePackages()
        case .cleanSimulators: manager.cleanSimulatorData()
        }
      }
    }
    HotKeyManager.shared.register()
  }
}
