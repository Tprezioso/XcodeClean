import SwiftUI

struct MenuBarView: View {
  @ObservedObject var cleanManager: CleanManager

  var body: some View {
    if cleanManager.isRunning {
      Text(cleanManager.status)
        .disabled(true)
    } else if let lastResult = cleanManager.lastResult {
      Text(lastResult)
        .disabled(true)
    }

    Button("Clean All") { cleanManager.cleanAll() }
      .keyboardShortcut("k", modifiers: [.command, .shift, .option])
      .disabled(cleanManager.isRunning)

    Divider()

    Button("Delete Derived Data") { cleanManager.deleteDerivedData() }
      .disabled(cleanManager.isRunning)

    Button("Clean Build Folder") { cleanManager.cleanBuild() }
      .disabled(cleanManager.isRunning)

    Button("Reset Package Caches") { cleanManager.resetPackageCaches() }
      .disabled(cleanManager.isRunning)

    Button("Resolve Package Versions") { cleanManager.resolvePackages() }
      .disabled(cleanManager.isRunning)

    Divider()

    Text("\u{2318}\u{21E7}\u{2325}K to clean all globally")

    Divider()

    Button("Quit") { NSApplication.shared.terminate(nil) }
      .keyboardShortcut("q")
  }
}
