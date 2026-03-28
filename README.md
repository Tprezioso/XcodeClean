# XcodeClean

A lightweight macOS menu bar app that cleans Xcode build artifacts, resets package caches, and manages simulator data — all from your menu bar or with global keyboard shortcuts.

If you've ever wasted time navigating to `~/Library/Developer/Xcode/DerivedData` to manually delete folders, or clicking through Xcode's menus to reset package caches, XcodeClean puts all of that one click (or one hotkey) away.

## Features

- **Delete Derived Data** — Removes the contents of your DerivedData folder, with the size displayed in the menu so you know when it's worth cleaning
- **Clean Build Folder** — Triggers Xcode's own clean build command on the active project via AppleScript
- **Reset Package Caches** — Invokes Xcode's File > Packages > Reset Package Caches menu action, using Xcode's native resolver
- **Resolve Package Versions** — Invokes Xcode's File > Packages > Resolve Package Versions menu action
- **Clean Simulator Data** — Shuts down all simulators, erases their data, and removes unavailable devices
- **Clean All** — Runs Clean Build, Delete Derived Data, and Reset Package Caches in the correct order to avoid PIF transfer errors
- **Global Keyboard Shortcuts** — Every action is accessible from any app without opening the menu
- **Live Size Display** — Shows DerivedData and Simulator data sizes directly in the menu, updated every 30 seconds
- **Active Project Detection** — Displays which Xcode project will be targeted before you click
- **Launch at Login** — Optional toggle to start XcodeClean automatically

## Keyboard Shortcuts

All shortcuts use **Cmd + Shift + Option** as the modifier:

| Action | Shortcut |
|---|---|
| Clean All | `Cmd+Shift+Option+K` |
| Delete Derived Data | `Cmd+Shift+Option+D` |
| Clean Build Folder | `Cmd+Shift+Option+B` |
| Reset Package Caches | `Cmd+Shift+Option+R` |
| Resolve Package Versions | `Cmd+Shift+Option+P` |
| Clean Simulator Data | `Cmd+Shift+Option+S` |

These work globally — you don't need to have XcodeClean focused.

## Clean All Order of Operations

The "Clean All" action runs steps in a specific order to avoid Xcode's "unable to initiate PIF transfer session" error:

1. **Clean Build Folder** — Runs first while Xcode's internal state is fully intact
2. **Delete Derived Data** — Removes build artifacts after Xcode is done processing
3. **Reset Package Caches** — Clears and re-resolves packages into a fresh DerivedData, leaving you ready to build

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode installed (for build cleaning and package operations)

## Installation

### Build from Source

1. Clone the repository:
   ```
   git clone https://github.com/YOUR_USERNAME/XcodeClean.git
   ```
2. Open `XcodeClean.xcodeproj` in Xcode
3. Build and run (Cmd+R)

The app will appear as a bin icon in your menu bar.

## Permissions

XcodeClean requires two macOS permissions to function. You'll be prompted to grant these the first time you use the app.

### Automation (required)

XcodeClean uses AppleScript to communicate with Xcode for clean build operations.

**System Settings > Privacy & Security > Automation** — Allow XcodeClean to control Xcode.

### Accessibility (required for package operations)

Package cache and resolve operations work by triggering Xcode's own menu items via System Events, which requires Accessibility access.

**System Settings > Privacy & Security > Accessibility** — Allow XcodeClean.

### Resetting Permissions

If permissions get stuck or denied, you can reset them from Terminal:

```bash
# Reset Automation permission
tccutil reset AppleEvents

# Reset Accessibility permission
tccutil reset Accessibility
```

Then relaunch XcodeClean to be prompted again.

## How It Works

XcodeClean uses different mechanisms for each operation, chosen for reliability:

| Operation | Mechanism | Why |
|---|---|---|
| Delete Derived Data | FileManager (concurrent) | Direct file deletion is fastest; items are deleted in parallel |
| Clean Build Folder | AppleScript to Xcode | Uses Xcode's scripting dictionary to target a specific workspace document |
| Reset Package Caches | System Events menu click | Triggers Xcode's own menu item, which handles internal state correctly |
| Resolve Package Versions | System Events menu click | Same as above — Xcode's native resolver handles submodules and edge cases better than `xcodebuild` |
| Clean Simulator Data | `xcrun simctl` | Uses Apple's official simulator management tool |

### Project Targeting

When you trigger an action, XcodeClean captures the active Xcode workspace document at the start of the operation. All subsequent steps target that same project, even if you switch to a different project or app while the operation is running.

### Custom Derived Data Locations

XcodeClean reads Xcode's preferences (`com.apple.dt.Xcode`) to detect custom DerivedData locations, including both absolute and project-relative paths.

## Architecture

```
XcodeClean/
  XcodeCleanApp.swift    — App entry point, menu bar setup, hotkey wiring
  MenuBarView.swift      — SwiftUI menu with actions, size display, and settings
  CleanManager.swift     — All cleaning logic, AppleScript, and state management
  HotKeyManager.swift    — Global keyboard shortcut registration via Carbon Events
  Info.plist             — Apple Events usage description, background app config
  XcodeClean.entitlements — Sandbox disabled, automation entitlement
```

## Contributing

Contributions are welcome! Some ideas for future improvements:

- Delete All Derived Data option (all projects, not just the active one)
- Show space freed after each operation
- Per-project size breakdown in the menu
- Configurable keyboard shortcuts
- Auto-clean when DerivedData exceeds a size threshold

## License

[MIT](LICENSE)
