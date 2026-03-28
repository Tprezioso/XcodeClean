import Cocoa
import Foundation
import UserNotifications

@MainActor
final class CleanManager: ObservableObject {
  static let shared = CleanManager()

  @Published var isRunning = false
  @Published var status = ""
  @Published var lastResult: String?

  init() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  // MARK: - Public Actions

  func cleanAll() {
    run(successMessage: "Xcode project cleaned.") {
      let document = try await self.activeXcodeDocument()
      let derivedData = try self.derivedDataPath(for: document)

      self.status = "Cleaning build..."
      try await self.appleScriptCleanBuild(for: document)

      self.status = "Deleting Derived Data..."
      try await self.deleteDerivedDataContents(at: derivedData)

      self.status = "Resetting package caches..."
      try await self.xcodeResetPackageCaches()
    }
  }

  func deleteDerivedData() {
    run(successMessage: "Derived Data deleted.") {
      let document = try? await self.activeXcodeDocument()
      let derivedData = try self.derivedDataPath(for: document)

      self.status = "Deleting Derived Data..."
      try await self.deleteDerivedDataContents(at: derivedData)
    }
  }

  func cleanBuild() {
    run(successMessage: "Build cleaned.") {
      let document = try await self.activeXcodeDocument()

      self.status = "Cleaning build..."
      try await self.appleScriptCleanBuild(for: document)
    }
  }

  func resetPackageCaches() {
    run(successMessage: "Package caches reset.") {
      _ = try await self.activeXcodeDocument()

      self.status = "Resetting package caches..."
      try await self.xcodeResetPackageCaches()
    }
  }

  func resolvePackages() {
    run(successMessage: "Packages resolved.") {
      _ = try await self.activeXcodeDocument()

      self.status = "Resolving packages..."
      try await self.xcodeResolvePackageVersions()
    }
  }

  // MARK: - Operation Runner

  private func run(
    successMessage: String,
    operation: @escaping @MainActor () async throws -> Void
  ) {
    guard !isRunning else { return }
    Task {
      isRunning = true
      lastResult = nil
      defer {
        isRunning = false
        status = ""
      }
      do {
        try await operation()
        lastResult = successMessage
        NSLog("[XcodeClean] %@", successMessage)
        notify(successMessage)
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
    try await onBackgroundThread {
      let fm = FileManager.default
      guard fm.fileExists(atPath: path) else { return }

      let items = try fm.contentsOfDirectory(atPath: path)
      var failures: [String] = []
      for item in items {
        let itemPath = (path as NSString).appendingPathComponent(item)
        do {
          try fm.removeItem(atPath: itemPath)
        } catch {
          NSLog("[XcodeClean] Could not remove %@: %@", item, error.localizedDescription)
          failures.append(item)
        }
      }
      if !failures.isEmpty, failures.count == items.count {
        throw CleanError.operationFailed(
          "Could not delete any items in Derived Data. Files may be locked by Xcode."
        )
      }
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

  // MARK: - Active Xcode Document (AppleScript)

  private func activeXcodeDocument() async throws -> XcodeDocument {
    let maxAttempts = 5
    for attempt in 1...maxAttempts {
      do {
        return try await queryXcodeDocument()
      } catch where attempt < maxAttempts {
        NSLog("[XcodeClean] Waiting for Xcode document (attempt %d/%d)...", attempt, maxAttempts)
        try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
      }
    }
    return try await queryXcodeDocument()
  }

  private func queryXcodeDocument() async throws -> XcodeDocument {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.main.async {
        let script = NSAppleScript(source: """
          tell application "Xcode"
            if not (exists active workspace document) then return ""
            if not (loaded of active workspace document) then
              error "The active Xcode workspace is still loading."
            end if
            return path of active workspace document
          end tell
          """)

        var errorInfo: NSDictionary?
        let result = script?.executeAndReturnError(&errorInfo)

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

        let path = result?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if path.isEmpty {
          continuation.resume(throwing: CleanError.noOpenProject)
        } else {
          continuation.resume(returning: XcodeDocument(path: path))
        }
      }
    }
  }

  // MARK: - Helpers

  private func runAppleScript(_ source: String) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      DispatchQueue.main.async {
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

  private func onBackgroundThread(_ work: @escaping @Sendable () throws -> Void) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          try work()
          continuation.resume()
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
}

enum CleanError: LocalizedError {
  case noOpenProject
  case notAuthorized
  case operationFailed(String)

  var userMessage: String {
    switch self {
    case .noOpenProject:
      "No open Xcode project or workspace found."
    case .notAuthorized:
      "Not authorized to control Xcode. Grant permission in System Settings → Privacy & Security → Automation."
    case .operationFailed(let message):
      message
    }
  }

  var errorDescription: String? { userMessage }
}
