import ServiceManagement
import SwiftUI

struct MenuBarView: View {
  @ObservedObject var cleanManager: CleanManager
  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

  var body: some View {
    if cleanManager.isRunning {
      Text(cleanManager.status)
        .disabled(true)
    } else if let lastResult = cleanManager.lastResult {
      Text(lastResult)
        .disabled(true)
    }

    if let project = cleanManager.activeProjectName {
      Text("Project: \(project)")
        .disabled(true)
    }

    Button("Clean All") { cleanManager.cleanAll() }
      .keyboardShortcut("k", modifiers: [.command, .shift, .option])
      .disabled(cleanManager.isRunning)

    Divider()

    Button(derivedDataLabel) { cleanManager.deleteDerivedData() }
      .keyboardShortcut("d", modifiers: [.command, .shift, .option])
      .disabled(cleanManager.isRunning)

    Button("Clean Build Folder") { cleanManager.cleanBuild() }
      .keyboardShortcut("b", modifiers: [.command, .shift, .option])
      .disabled(cleanManager.isRunning)

    Button("Reset Package Caches") { cleanManager.resetPackageCaches() }
      .keyboardShortcut("r", modifiers: [.command, .shift, .option])
      .disabled(cleanManager.isRunning)

    Button("Resolve Package Versions") { cleanManager.resolvePackages() }
      .keyboardShortcut("p", modifiers: [.command, .shift, .option])
      .disabled(cleanManager.isRunning)

    Divider()

    Button(simulatorLabel) { cleanManager.cleanSimulatorData() }
      .keyboardShortcut("s", modifiers: [.command, .shift, .option])
      .disabled(cleanManager.isRunning)

    Divider()

    Toggle("Launch at Login", isOn: $launchAtLogin)
      .onChange(of: launchAtLogin) { _, newValue in
        do {
          if newValue {
            try SMAppService.mainApp.register()
          } else {
            try SMAppService.mainApp.unregister()
          }
        } catch {
          NSLog("[XcodeClean] Launch at login error: %@", error.localizedDescription)
          launchAtLogin = SMAppService.mainApp.status == .enabled
        }
      }

    Divider()

    Button("Quit") { NSApplication.shared.terminate(nil) }
      .keyboardShortcut("q")
  }

  private var derivedDataLabel: String {
    if let size = cleanManager.derivedDataSize {
      return "Delete Derived Data (\(size))"
    }
    return "Delete Derived Data"
  }

  private var simulatorLabel: String {
    if let size = cleanManager.simulatorDataSize {
      return "Clean Simulator Data (\(size))"
    }
    return "Clean Simulator Data"
  }
}
