import AppKit
import Foundation

// What are you doing right now? Front app, browser tab, Claude session folder, idle time.
struct FrontContext {
    var app = ""
    var url = ""
    var title = ""
    var project: String? = nil
}

enum Detect {
    static let browsers: [String: String] = ["Dia": "chromium", "Google Chrome": "chromium", "Arc": "chromium",
                                             "Brave Browser": "chromium", "Microsoft Edge": "chromium", "Vivaldi": "chromium",
                                             "Opera": "chromium", "Chromium": "chromium", "Safari": "safari"]
    static let terminals: Set<String> = ["iTerm2", "Terminal"]
    /// macOS's own UI (login, Dock, Spotlight, password prompts…). Never covered, whatever the lists say.
    static let systemApps: Set<String> = ["loginwindow", "Dock", "SystemUIServer", "Control Center", "Notification Center",
                                          "Spotlight", "WindowManager", "ScreenSaverEngine", "SecurityAgent", "CoreServicesUIAgent",
                                          "UserNotificationCenter", "universalAccessAuthWarn"]

    static func frontApp() -> String { NSWorkspace.shared.frontmostApplication?.localizedName ?? "" }

    @discardableResult
    static func osa(_ src: String) -> String? {
        var err: NSDictionary?
        guard let s = NSAppleScript(source: src) else { return nil }
        let r = s.executeAndReturnError(&err)
        return err == nil ? r.stringValue : nil
    }

    /// Apps whose AppleScript access was turned off in System Settings (error -1743), so the menu can say so.
    private static let lock = NSLock()
    private static var _denied = Set<String>()
    static var denied: Set<String> { lock.lock(); defer { lock.unlock() }; return _denied }
    private static func note(_ app: String, denied d: Bool) {
        lock.lock(); defer { lock.unlock() }
        if d { _denied.insert(app) } else { _denied.remove(app) }
    }
    /// Like osa(), but remembers whether macOS refused access to `app`.
    static func osa(_ src: String, app: String) -> String? {
        var err: NSDictionary?
        guard let s = NSAppleScript(source: src) else { return nil }
        let r = s.executeAndReturnError(&err)
        note(app, denied: (err?[NSAppleScript.errorNumber] as? Int) == -1743)
        return err == nil ? r.stringValue : nil
    }

    static func browserTab(_ app: String) -> (String, String) {
        let src = browsers[app] == "safari"
            ? "tell application \"Safari\" to return (URL of current tab of front window) & \"\\n\" & (name of current tab of front window)"
            : "tell application \"\(escape(app))\" to return (URL of active tab of front window) & \"\\n\" & (title of active tab of front window)"
        guard let out = osa(src, app: app) else { return ("", "") }
        let parts = out.split(separator: "\n", maxSplits: 1).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }

    static func sh(_ cmd: String) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", cmd]
        let o = Pipe(); p.standardOutput = o; p.standardError = Pipe()
        try? p.run(); let d = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // Folder of the Claude Code session in iTerm's front tab (tty -> claude process -> cwd).
    static func claudeProject(_ app: String) -> String? {
        guard app == "iTerm2", let tty = osa("tell application \"iTerm2\" to return tty of current session of current window") else { return nil }
        let t = tty.replacingOccurrences(of: "/dev/", with: "")
        let out = sh("ps -t \(t) -o pid=,comm= | awk '$2 ~ /claude/ {print $1; exit}' | xargs -I{} lsof -a -p {} -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'")
        return out.isEmpty ? nil : out
    }

    /// The front app, its open tab (browsers) and, with `terminals`, the folder of a Claude Code session in it.
    static func context(terminals withTerminals: Bool = true) -> FrontContext {
        var c = FrontContext(app: frontApp())
        if browsers[c.app] != nil { (c.url, c.title) = browserTab(c.app) }
        else if withTerminals, terminals.contains(c.app) { c.project = claudeProject(c.app) }
        return c
    }

    /// Makes text safe inside an AppleScript string literal.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    /// Seconds since the last key press, click or scroll. Mouse movement alone doesn't count, so a jiggler can't
    /// fake work. (Counts only, never which keys: no permission needed.)
    static func secondsSinceRealInput() -> Double {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
    }

    static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    // Front window bounds of an app in AppKit coordinates (no Accessibility permission needed).
    static func windowFrame(of app: String) -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list where (w[kCGWindowOwnerName as String] as? String) == app && (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat], let x = b["X"], let y = b["Y"],
                  let width = b["Width"], let height = b["Height"], width > 200, height > 200 else { continue }
            let primaryH = NSScreen.screens.first?.frame.height ?? 0
            return NSRect(x: x, y: primaryH - y - height, width: width, height: height)
        }
        return nil
    }
}

func anyIn(_ text: String, _ list: [String]?) -> String? {
    let t = text.lowercased()
    for k in list ?? [] where !k.isEmpty && t.contains(k.lowercased()) { return k }
    return nil
}
