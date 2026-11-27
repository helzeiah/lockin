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
            Image(nsImage: MenuIcon.image(for: e))
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // lockin://start?task=Essay&minutes=25 (or block=<task rule>)  lockin://next  lockin://stop  lockin://plan
    // lockin://tomorrow  lockin://today  lockin://recap  lockin://stats  lockin://setup  lockin://gate
    func application(_ app: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            let e = Engine.shared
            for u in urls {
                let q = Dictionary((URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                                   uniquingKeysWith: { a, _ in a })
                let minutes = Int(q["minutes"] ?? "").map { min(max($0, 1), 480) }
                let task = q["task"].map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) }.flatMap { $0.isEmpty ? nil : $0 }
                switch u.host ?? "" {
                case "start":
                    if let p = e.presetFor(q["block"] ?? "") { e.startBlock(p, minutes: minutes, task: task) }
                    else if let task { e.startSession(task: task, minutes: minutes ?? 45) }
                    else { e.startQuick(minutes: minutes ?? 25) }
                case "next": if let t = e.nextTodo { e.startTodo(t) }
                case "stop": e.stopBlock(completed: false)
                case "plan": Planner.shared.open(tab: .plan, day: .today)
                case "tomorrow": Planner.shared.open(tab: .plan, day: .tomorrow)
                case "todo": Planner.shared.open(tab: .tasks)
                case "today": e.showPlan()
                case "recap": e.showRecap()
                case "stats": e.showStats()
                case "setup": SetupWindow.shared.open()
                case "gate": Gate.shared.show()
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

    // Quitting mid-session is on the record; the session picks back up on the next launch.
    func applicationWillTerminate(_ n: Notification) {
        MainActor.assumeIsolated { Engine.shared.noteQuit() }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("lockin runs in the menu bar")
        ProcessInfo.processInfo.disableSuddenTermination()
        // SwiftUI installs a full File/Edit/View/Window/Help menu; set ours after it's done.
        DispatchQueue.main.async { NSApp.mainMenu = minimalMainMenu() }
        DispatchQueue.global(qos: .utility).async { _ = InstalledApps.all }   // warm the app list for the pickers
        Task { @MainActor in
            Engine.shared.start()
            IslandController.shared.start()
            BlockerController.shared.start()
            // First launch (or after a big update): the one-time setup.
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
