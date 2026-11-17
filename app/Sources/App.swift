import AppKit
import SwiftUI

@main
struct FocusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var e = Engine.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(e)
        } label: {
            Image(systemName: e.block == nil ? "scope" : (e.drifting ? "exclamationmark.circle" : "timer"))
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // lockin://start?block=Study&minutes=25&task=...  lockin://stop  lockin://plan  lockin://today  lockin://recap  lockin://stats  lockin://setup
    func application(_ app: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            let e = Engine.shared
            for u in urls {
                let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                switch u.host ?? "" {
                case "start":
                    if let p = e.presetFor(q["block"] ?? "") ?? e.cfg.blocks.first {
                        e.startBlock(p, minutes: Int(q["minutes"] ?? ""), task: q["task"].flatMap { $0.isEmpty ? nil : $0 })
                    }
                case "next": if let t = e.nextTodo { e.startTodo(t) }
                case "stop": e.stopBlock(completed: false)
                case "plan": Planner.shared.open()
                case "today": e.showPlan()
                case "recap": e.showRecap()
                case "stats": e.showStats()
                case "setup": SetupWindow.shared.open()
                default: break
                }
            }
        }
    }

    // A menu-bar app keeps running when its windows close. Some macOS versions (Sequoia) otherwise quit it, or let
    // automatic termination reclaim it once no window is open, and the menu-bar icon vanishes with it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Opening lockin.app again while it's running shows the day plan instead of doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        Task { @MainActor in Planner.shared.open() }
        return false
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("lockin runs in the menu bar")
        ProcessInfo.processInfo.disableSuddenTermination()
        // SwiftUI installs a full File/Edit/View/Window/Help menu; set ours after it's done.
        DispatchQueue.main.async { NSApp.mainMenu = minimalMainMenu() }
        Task { @MainActor in
            Engine.shared.start()
            IslandController.shared.start()
            BlockerController.shared.start()
            // First launch: the one-time setup (distractions, strictness, permissions, goal).
            if SetupWindow.needed { try? await Task.sleep(nanoseconds: 800_000_000); SetupWindow.shared.open() }
        }
    }
}

/// No menus at all. lockin becomes the frontmost app while you type in its windows (so dictation apps find it), and
/// any menus would then take menu-bar space; on a notched Mac that makes macOS hide status items, lockin's icon
/// included. With an empty main menu only the Apple menu shows. `KeyPanel` handles ⌘X/C/V/A/Z, ⌘W and ⌘Q itself.
@MainActor func minimalMainMenu() -> NSMenu { NSMenu() }

// Close the menu-bar popover (it's the key window while open).
// Only the dropdown: the icon itself lives in a menu-bar-height status window (NSStatusBarWindow on macOS 15), and
// ordering that out makes the icon vanish until relaunch.
@MainActor func closePopover() {
    for w in NSApp.windows where !isStatusItemWindow(w) && (w.className.contains("MenuBarExtra") || w.className.contains("StatusBarWindow")) {
        w.orderOut(nil)
    }
}
@MainActor func isStatusItemWindow(_ w: NSWindow) -> Bool {
    w.className.contains("StatusBarWindow") && w.frame.height <= 44
}
/// Where the menu-bar icon is on screen, if macOS is showing it.
@MainActor func statusItemFrame() -> NSRect? {
    NSApp.windows.first { isStatusItemWindow($0) && $0.isVisible }?.frame
}
