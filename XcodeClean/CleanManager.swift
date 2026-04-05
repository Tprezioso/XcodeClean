import Cocoa
import Foundation
import UserNotifications

@MainActor
final class CleanManager: ObservableObject {
  static let shared = CleanManager()

  @Published var isRunning = false
  @Published var status = ""
  @Published var lastResult: String?
  @Published var derivedDataSize: String?
  @Published var simulatorDataSize: String?
  @Published var activeProjectName: String?

  private var refreshTimer: Timer?
  private var isRefreshing = false

  private let compiledQueryScript: NSAppleScript? = {
    let script = NSAppleScript(source: """
      tell application "Xcode"
        if not (exists active workspace document) then return ""
        if not (loaded of active workspace document) then return "LOADING"
        return path of active workspace document
      end tell
      """)
    script?.compileAndReturnError(nil)
    return script
  }()

  init() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    startPeriodicRefresh()
  }

  // MARK: - Periodic Info Refresh

  func refreshInfo() {
    guard !isRefreshing else { return }
    isRefreshing = true
    Task {
      defer { isRefreshing = false }
      async let ddSize = self.computeDirectorySize(
        NSHomeDirectory() + "/Library/Developer/Xcode/DerivedData"
      )
      async let simSize = self.computeDirectorySize(
        NSHomeDirectory() + "/Library/Developer/CoreSimulator"
      )
      async let project = self.currentProjectName()

      self.derivedDataSize = await ddSize
      self.simulatorDataSize = await simSize
      self.activeProjectName = await project
    }
  }

  private func startPeriodicRefresh() {
    refreshInfo()
    refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refreshInfo() }
    }
  }

  private func computeDirectorySize(_ path: String) async -> String? {
    await Task.detached(priority: .utility) {
      let url = URL(fileURLWithPath: path, isDirectory: true)
      let fm = FileManager.default
      let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
      guard fm.fileExists(atPath: path),
            let enumerator = fm.enumerator(
              at: url,
              includingPropertiesForKeys: keys,
              options: [.skipsHiddenFiles]
            ) else { return nil }

      var totalBytes: UInt64 = 0
      while let fileURL = enumerator.nextObject() as? URL {
        guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
              values.isRegularFile == true,
              let size = values.totalFileAllocatedSize else { continue }
        totalBytes += UInt64(size)
      }
      guard totalBytes > 0 else { return nil }
      return ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
    }.value
  }

  private func currentProjectName() async -> String? {
    guard isXcodeRunning else { return nil }
    return try? await queryXcodeDocument().projectName
  }

  // MARK: - Public Actions

  func cleanAll() {
    run {
      let document = try await self.activeXcodeDocument()
      let projectName = document.projectName
      let derivedData = try self.derivedDataPath(for: document)

      self.status = "Cleaning build for \(projectName)..."
      try await self.appleScriptCleanBuild(for: document)

      self.status = "Deleting Derived Data..."
      try await self.deleteDerivedDataContents(at: derivedData)

      self.status = "Waiting for Xcode to be ready..."
      try await self.waitForXcodeReady(document: document)

      self.status = "Resetting package caches..."
      try await self.xcodeResetPackageCaches()

      return "\(projectName) cleaned."
    }
  }

  func deleteDerivedData() {
    run {
      let document = try? await self.activeXcodeDocument()
      let derivedData = try self.derivedDataPath(for: document)

      self.status = "Deleting Derived Data..."
      try await self.deleteDerivedDataContents(at: derivedData)

      return "Derived Data deleted."
    }
  }

  func cleanBuild() {
    run {
      let document = try await self.activeXcodeDocument()

      self.status = "Cleaning build for \(document.projectName)..."
      try await self.appleScriptCleanBuild(for: document)

      return "\(document.projectName) build cleaned."
    }
  }

  func resetPackageCaches() {
    run {
      let document = try await self.activeXcodeDocument()

      self.status = "Resetting package caches for \(document.projectName)..."
      try await self.xcodeResetPackageCaches()

      return "\(document.projectName) package caches reset."
    }
  }

  func resolvePackages() {
    run {
      let document = try await self.activeXcodeDocument()

      self.status = "Resolving packages for \(document.projectName)..."
      try await self.xcodeResolvePackageVersions()

      return "\(document.projectName) packages resolved."
    }
  }

  func cleanSimulatorData() {
    run {
      self.status = "Shutting down simulators..."
      try await self.shutdownSimulators()

      self.status = "Erasing simulator data..."
      try await self.eraseSimulatorData()

      self.status = "Deleting unavailable simulators..."
      try await self.deleteUnavailableSimulators()

      return "Simulator data cleaned."
    }
  }

  // MARK: - Operation Runner

  private func run(operation: @escaping @MainActor () async throws -> String) {
    guard !isRunning else { return }
    Task {
      isRunning = true
      lastResult = nil
      defer {
        isRunning = false
        status = ""
        refreshInfo()
      }
      do {
        let message = try await operation()
        lastResult = message
        NSLog("[XcodeClean] %@", message)
        notify(message)
      } catch {
        let message = (error as? CleanError)?.userMessage
          ?? "Failed: \(error.localizedDescription)"
        lastResult = message
        NSLog("[XcodeClean] %@", message)
        notify(message)
      }
    }
  }

  // MARK: - Derived Data

  private func deleteDerivedDataContents(at path: String) async throws {
    let items: [String] = try await onBackgroundThread {
      let fm = FileManager.default
      guard fm.fileExists(atPath: path) else { return [] }
      return try fm.contentsOfDirectory(atPath: path)
    }
    guard !items.isEmpty else { return }

    let failures = await withTaskGroup(of: String?.self, returning: [String].self) { group in
      for item in items {
        group.addTask {
          let itemPath = (path as NSString).appendingPathComponent(item)
          do {
            try FileManager.default.removeItem(atPath: itemPath)
            return nil
          } catch {
            NSLog("[XcodeClean] Could not remove %@: %@", item, error.localizedDescription)
            return item
          }
        }
      }
      var failed: [String] = []
      for await result in group {
        if let name = result { failed.append(name) }
      }
      return failed
    }

    if !failures.isEmpty, failures.count == items.count {
      throw CleanError.operationFailed(
        "Could not delete any items in Derived Data. Files may be locked by Xcode."
      )
    }
  }

  private func derivedDataPath(for document: XcodeDocument?) throws -> String {
    let defaults = UserDefaults.standard.persistentDomain(forName: "com.apple.dt.Xcode")

    guard
      let custom = defaults?["IDECustomDerivedDataLocation"] as? String,
      !custom.isEmpty
    else {
      return NSHomeDirectory() + "/Library/Developer/Xcode/DerivedData"
    }

    let expanded = (custom as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
      return expanded
    }

    guard let document else {
      throw CleanError.operationFailed(
        "Open an Xcode project so the relative Derived Data path can be resolved."
      )
    }

    return URL(fileURLWithPath: document.path)
      .deletingLastPathComponent()
      .appendingPathComponent(expanded, isDirectory: true)
      .path
  }

  // MARK: - Clean Build (AppleScript)

  private func appleScriptCleanBuild(for document: XcodeDocument) async throws {
    let escapedPath = document.path.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    try await runAppleScript("""
      tell application "Xcode"
        set targetDoc to missing value
        repeat with doc in workspace documents
          if path of doc is "\(escapedPath)" then
            set targetDoc to doc
            exit repeat
          end if
        end repeat
        if targetDoc is missing value then
          error "Could not find the workspace document for this project in Xcode."
        end if
        if not (loaded of targetDoc) then
          error "The workspace is still loading. Try again in a moment."
        end if
        set actionResult to clean targetDoc
        repeat 240 times
          if completed of actionResult then exit repeat
          delay 0.5
        end repeat
        if not (completed of actionResult) then
          error "Clean timed out after 2 minutes."
        end if
        set err to error message of actionResult
        if err is not missing value then error err
      end tell
      """)
  }

  // MARK: - Wait for Xcode Ready

  private func waitForXcodeReady(document: XcodeDocument, timeout: TimeInterval = 30) async throws {
    let escapedPath = document.path.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    try await runAppleScript("""
      tell application "Xcode"
        set deadline to (current date) + \(Int(timeout))
        repeat
          if (current date) > deadline then
            error "Xcode did not become ready within \(Int(timeout)) seconds."
          end if
          try
            set targetDoc to missing value
            repeat with doc in workspace documents
              if path of doc is "\(escapedPath)" then
                set targetDoc to doc
                exit repeat
              end if
            end repeat
            if targetDoc is not missing value and loaded of targetDoc then exit repeat
          end try
          delay 0.5
        end repeat
      end tell
      """)
  }

  // MARK: - Package Operations (via Xcode menu)

  private func xcodeResetPackageCaches() async throws {
    try await clickXcodeMenuItem("Reset Package Caches")
  }

  private func xcodeResolvePackageVersions() async throws {
    try await clickXcodeMenuItem("Resolve Package Versions")
  }

  private func clickXcodeMenuItem(_ menuItem: String) async throws {
    try await runAppleScript("""
      tell application "Xcode" to activate
      delay 0.5
      tell application "System Events"
        tell process "Xcode"
          set packagesMenu to menu 1 of menu item "Packages" of menu "File" of menu bar 1
          set targetItem to menu item "\(menuItem)" of packagesMenu
          -- Wait up to 30 seconds for the menu item to become enabled
          repeat 60 times
            if enabled of targetItem then exit repeat
            delay 0.5
          end repeat
          if not (enabled of targetItem) then
            error "\\\"\(menuItem)\\\" is not available. Xcode may still be loading."
          end if
          click targetItem
        end tell
      end tell
      """)
  }

  // MARK: - Simulator Operations

  private func shutdownSimulators() async throws {
    try await shell("/usr/bin/xcrun", arguments: ["simctl", "shutdown", "all"], timeout: 30)
  }

  private func eraseSimulatorData() async throws {
    try await shell("/usr/bin/xcrun", arguments: ["simctl", "erase", "all"], timeout: 60)
  }

  private func deleteUnavailableSimulators() async throws {
    try await shell("/usr/bin/xcrun", arguments: ["simctl", "delete", "unavailable"], timeout: 30)
  }

  private func shell(
    _ executable: String,
    arguments: [String],
    timeout: TimeInterval
  ) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      DispatchQueue.global(qos: .userInitiated).async {
        let process = Process()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        do {
          try process.run()
        } catch {
          let name = URL(fileURLWithPath: executable).lastPathComponent
          continuation.resume(throwing: CleanError.operationFailed("Failed to launch \(name)."))
          return
        }

        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
          if process.isRunning { process.terminate() }
        }
        timer.resume()

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()

        let name = URL(fileURLWithPath: executable).lastPathComponent

        if process.terminationReason == .uncaughtSignal {
          continuation.resume(throwing: CleanError.operationFailed("\(name) timed out."))
          return
        }

        guard process.terminationStatus == 0 else {
          let stderr = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          NSLog("[XcodeClean] %@ failed (%d): %@", name, process.terminationStatus, stderr)
          continuation.resume(
            throwing: CleanError.operationFailed(stderr.isEmpty ? "\(name) failed." : stderr)
          )
          return
        }

        continuation.resume()
      }
    }
  }

  // MARK: - Active Xcode Document (AppleScript)

  private func activeXcodeDocument() async throws -> XcodeDocument {
    guard isXcodeRunning else {
      throw CleanError.xcodeNotRunning
    }

    let maxAttempts = 3
    for attempt in 1...maxAttempts {
      do {
        return try await queryXcodeDocument()
      } catch CleanError.xcodeLoading where attempt < maxAttempts {
        NSLog("[XcodeClean] Workspace loading (attempt %d/%d), retrying...", attempt, maxAttempts)
        try await Task.sleep(nanoseconds: 2_000_000_000)
      }
    }
    return try await queryXcodeDocument()
  }

  private var isXcodeRunning: Bool {
    NSWorkspace.shared.runningApplications.contains {
      $0.bundleIdentifier == "com.apple.dt.Xcode"
    }
  }

  private func queryXcodeDocument() async throws -> XcodeDocument {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async { [compiledQueryScript] in
        guard let script = compiledQueryScript else {
          continuation.resume(throwing: CleanError.operationFailed("Failed to compile AppleScript."))
          return
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)

        if let errorInfo {
          let message = errorInfo[NSAppleScript.errorMessage] as? String
            ?? "Unknown AppleScript error."
          let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
          NSLog("[XcodeClean] AppleScript error (%d): %@", code, message)

          if code == -1743 {
            continuation.resume(throwing: CleanError.notAuthorized)
          } else {
            continuation.resume(throwing: CleanError.operationFailed(message))
          }
          return
        }

        let path = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch path {
        case "":
          continuation.resume(throwing: CleanError.noOpenProject)
        case "LOADING":
          continuation.resume(throwing: CleanError.xcodeLoading)
        default:
          continuation.resume(returning: XcodeDocument(path: path))
        }
      }
    }
  }

  // MARK: - Helpers

  private func runAppleScript(_ source: String) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      DispatchQueue.global(qos: .userInitiated).async {
        let script = NSAppleScript(source: source)
        var errorInfo: NSDictionary?
        script?.executeAndReturnError(&errorInfo)

        if let errorInfo {
          let message = errorInfo[NSAppleScript.errorMessage] as? String
            ?? "Unknown AppleScript error."
          let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
          NSLog("[XcodeClean] AppleScript error (%d): %@", code, message)

          if code == -1743 {
            continuation.resume(throwing: CleanError.notAuthorized)
          } else {
            continuation.resume(throwing: CleanError.operationFailed(message))
          }
          return
        }

        continuation.resume()
      }
    }
  }

  private func onBackgroundThread<T: Sendable>(
    _ work: @escaping @Sendable () throws -> T
  ) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          continuation.resume(returning: try work())
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func notify(_ body: String) {
    let content = UNMutableNotificationContent()
    content.title = "Xcode Clean"
    content.body = body
    content.sound = .default
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    )
  }
}

// MARK: - Supporting Types

struct XcodeDocument {
  enum Kind { case workspace, project, unknown }

  let path: String

  var kind: Kind {
    switch (path as NSString).pathExtension {
    case "xcworkspace": .workspace
    case "xcodeproj": .project
    default: .unknown
    }
  }

  var projectName: String {
    ((path as NSString).lastPathComponent as NSString).deletingPathExtension
  }
}

enum CleanError: LocalizedError {
  case noOpenProject
  case notAuthorized
  case xcodeNotRunning
  case xcodeLoading
  case operationFailed(String)

  var userMessage: String {
    switch self {
    case .noOpenProject:
      "No open Xcode project or workspace found."
    case .notAuthorized:
      "Not authorized to control Xcode. Grant permission in System Settings → Privacy & Security → Automation."
    case .xcodeNotRunning:
      "Xcode is not running."
    case .xcodeLoading:
      "Xcode is still loading the workspace. Try again in a moment."
    case .operationFailed(let message):
      message
    }
  }

  var errorDescription: String? { userMessage }
}
