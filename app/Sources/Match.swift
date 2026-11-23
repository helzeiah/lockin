import AppKit
import EventKit
import Foundation

// MARK: - Which apps a session allows

/// Picks a task's apps from its words, so planning never means filling in app lists:
///   1. a task rule whose name shares words with the task ("Co-op (Acme)" matches "co-op: finish the web UI"),
///   2. else the apps you used last time for a task with similar words (learned from the log),
///   3. else your lock-in apps.
enum TaskMatch {
    private static let stopWords: Set<String> = [
        "the", "and", "or", "to", "for", "of", "on", "in", "at", "my", "do", "work", "finish", "start", "with", "from",
        "up", "get", "some", "more", "is", "it", "this", "that", "an", "a", "then", "again", "today", "tomorrow", "session",
        "block", "focus", "time", "min", "mins", "minutes", "hour", "hours", "part", "few", "quick", "new", "next",
    ]

    /// Lowercased words of 2+ letters, minus filler. Hyphenated words count joined ("co-op" gives "coop"), plus
    /// their longer parts ("deep-learning" also gives "deep" and "learning"; "co" and "op" are too short to mean much).
    static func words(_ s: String) -> Set<String> {
        var out = Set<String>()
        for token in s.lowercased().split(whereSeparator: { $0.isWhitespace || "/()[],.:;!?\"'&+".contains($0) }) {
            let joined = String(token.filter { $0.isLetter || $0.isNumber })
            if joined.count >= 2, !stopWords.contains(joined), joined.contains(where: \.isLetter) { out.insert(joined) }
            let parts = token.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            guard parts.count > 1 else { continue }
            for p in parts where p.count >= 3 && !stopWords.contains(p) && p.contains(where: \.isLetter) { out.insert(p) }
        }
        return out
    }

    /// The task rule sharing the most with the task (by matched letters), if any.
    static func rule(for task: String, in rules: [Preset]) -> Preset? {
        let tw = words(task)
        var best: (rule: Preset, score: Int)?
        for r in rules {
            let score = words(r.name).intersection(tw).reduce(0) { $0 + $1.count }
            if score >= 2, score > (best?.score ?? 0) { best = (r, score) }
        }
        return best?.rule
    }

    struct Past { var task: String; var apps: [String] }

    /// Finished and started sessions that recorded their apps, newest first.
    static func history(limit: Int = 300) -> [Past] {
        guard let text = try? String(contentsOf: Paths.log, encoding: .utf8) else { return [] }
        var out: [Past] = []
        for line in text.split(separator: "\n").suffix(4000).reversed() where line.contains("\"apps\"") {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  ["block_end", "block_start"].contains(obj["type"] as? String ?? ""),
                  let task = obj["task"] as? String, !task.isEmpty,
                  let apps = obj["apps"] as? [String], !apps.isEmpty else { continue }
            out.append(Past(task: task, apps: apps))
            if out.count >= limit { break }
        }
        return out
    }

    /// The apps from the most similar past task (at least 3 shared letters of real words), newest on ties.
    static func learned(for task: String, history: [Past]) -> [String]? {
        let tw = words(task)
        var best: (apps: [String], score: Int)?
        for p in history {
            let score = words(p.task).intersection(tw).reduce(0) { $0 + $1.count }
            if score >= 3, score > (best?.score ?? 0) { best = (p.apps, score) }
        }
        return best?.apps
    }

    /// The apps a session for this task allows, and the task rule behind them (if one matched).
    static func apps(for task: String, cfg: Config, history: [Past]? = nil) -> (apps: [String], rule: String?) {
        let fallback = cfg.lockin_apps ?? []
        if let r = rule(for: task, in: cfg.blocks) {
            let ra = r.apps ?? []
            return (ra.isEmpty ? fallback : ra, r.name)
        }
        if let l = learned(for: task, history: history ?? self.history()) { return (l, nil) }
        return (fallback, nil)
    }
}

// MARK: - Installed apps (for the pickers)

struct AppEntry: Hashable, Identifiable {
    var name: String           // what macOS reports while it runs (NSRunningApplication.localizedName), used for matching
    var display: String        // its name in Finder, when that's different ("Visual Studio Code" for "Code")
    var url: URL
    var id: String { name }
}

enum InstalledApps {
    /// Every app in the usual folders (one level of subfolders too), by the name macOS shows for it.
    static let all: [AppEntry] = scan()

    /// Apps people usually work in, in the order the pickers suggest them.
    static let workHints = ["Dia", "Google Chrome", "Safari", "Arc", "Firefox", "Brave Browser", "Microsoft Edge",
                            "Visual Studio Code", "Cursor", "Zed", "Xcode", "IntelliJ IDEA", "PyCharm", "CLion", "WebStorm",
                            "Android Studio", "Sublime Text", "iTerm2", "Terminal", "Warp", "Ghostty", "Claude", "ChatGPT",
                            "Notion", "Obsidian", "Notes", "GoodNotes", "Pages", "Keynote", "Numbers", "Microsoft Word",
                            "Microsoft Excel", "Microsoft PowerPoint", "Preview", "Figma", "Linear", "Slack", "Zotero", "Anki",
                            "Calendar", "Mail"]

    /// Installed work apps first, then whatever else is running right now.
    static var suggested: [String] {
        let names = Set(all.map(\.name))
        let hints = workHints.filter { names.contains($0) }
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName).filter { $0 != selfAppName && !hints.contains($0) }
        return hints + Array(Set(running)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func url(for name: String) -> URL? {
        if let e = all.first(where: { $0.name == name || $0.display == name }) { return e.url }
        if let r = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) { return r.bundleURL }
        let n = name.lowercased()   // "iTerm" vs "iTerm2"
        return all.first { $0.name.lowercased().hasPrefix(n) || n.hasPrefix($0.name.lowercased()) }?.url
    }
    /// The Finder name for a picker label, if it differs from the running name.
    static func display(for name: String) -> String { all.first { $0.name == name }?.display ?? name }

    private static var iconCache: [String: NSImage] = [:]
    static func icon(for name: String) -> NSImage {
        if let i = iconCache[name] { return i }
        let img = url(for: name).map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: name) ?? NSImage()
        iconCache[name] = img
        return img
    }

    private static func scan() -> [AppEntry] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                    "\(home)/Applications"]
        var seen = Set<String>(), out: [AppEntry] = []
        func add(_ path: String) {
            let url = URL(fileURLWithPath: path)
            var display = fm.displayName(atPath: path)
            if display.hasSuffix(".app") { display = String(display.dropLast(4)) }
            // The name macOS reports for the running app comes from the bundle, not the file name.
            let b = Bundle(url: url)
            let keys = ["CFBundleDisplayName", "CFBundleName"]
            let raw = keys.lazy.compactMap { k in (b?.localizedInfoDictionary?[k] ?? b?.infoDictionary?[k]) as? String }
                .first { !$0.isEmpty } ?? display
            // Some apps put invisible direction marks in their name (WhatsApp); matching is by substring, so drop them.
            let name = String(raw.unicodeScalars.filter { $0.properties.generalCategory != .format }.map(Character.init))
            guard !name.isEmpty, name != selfAppName, !seen.contains(name) else { return }
            seen.insert(name); out.append(AppEntry(name: name, display: display, url: url))
        }
        for d in dirs {
            for item in (try? fm.contentsOfDirectory(atPath: d)) ?? [] where !item.hasPrefix(".") {
                let path = (d as NSString).appendingPathComponent(item)
                if item.hasSuffix(".app") { add(path); continue }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue, item != "Utilities" else { continue }
                for sub in (try? fm.contentsOfDirectory(atPath: path)) ?? [] where sub.hasSuffix(".app") {
                    add((path as NSString).appendingPathComponent(sub))
                }
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Calendar

struct CalEvent: Identifiable, Hashable {
    var id: String               // one id per occurrence, so a repeating event can be answered each time
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var recurring: Bool
    var minutes: Int { max(5, Int(end.timeIntervalSince(start) / 60)) }
    var startHHMM: String { hhmm(start) }
}

/// Today's events, read in-process with EventKit (read-only). Empty without calendar access.
enum CalendarFeed {
    private static let store = EKEventStore()
    private static let skip: Set<String> = ["Birthdays", "Siri Suggestions", "Scheduled Reminders"]

    static var allowed: Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: return true
        default: return false
        }
    }

    static func events(on day: Date = Stats.day(of: Date())) -> [CalEvent] {
        guard allowed else { return [] }
        let start = Calendar.current.startOfDay(for: day)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { !skip.contains($0.calendar.title) && $0.calendar.type != .birthday }
            .map { e in
                CalEvent(id: "\(e.eventIdentifier ?? e.title ?? "event")|\(Int(e.startDate.timeIntervalSince1970))",
                         title: (e.title ?? "Event").trimmingCharacters(in: .whitespaces),
                         start: e.startDate, end: e.endDate, allDay: e.isAllDay, recurring: e.hasRecurrenceRules)
            }
            .sorted { $0.start < $1.start }
    }
}
