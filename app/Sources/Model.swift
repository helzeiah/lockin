import Foundation
import Security

// Data lives in ~/Library/Application Support/Focus (the same files the Python helper reads and writes).
// The helper scripts and the calendar reader ship inside the app bundle (Contents/Resources).
enum Paths {
    static let dir: URL = {
        let fm = FileManager.default
        let d = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Focus")
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: d.appendingPathComponent("config.json").path) {
            // First launch: bring over data from the old ~/projects/focus-coach layout, else start from the example config.
            let legacy = fm.homeDirectoryForCurrentUser.appendingPathComponent("projects/focus-coach")
            if fm.fileExists(atPath: legacy.appendingPathComponent("config.json").path) {
                for f in ["config.json", "todos.json", "state.json", "log.jsonl"] {
                    try? fm.copyItem(at: legacy.appendingPathComponent(f), to: d.appendingPathComponent(f))
                }
            } else {
                try? fm.copyItem(at: resources.appendingPathComponent("config.example.json"), to: d.appendingPathComponent("config.json"))
            }
        }
        return d
    }()
    static let config = dir.appendingPathComponent("config.json")
    static let log = dir.appendingPathComponent("log.jsonl")
    static let todos = dir.appendingPathComponent("todos.json")
    static let state = dir.appendingPathComponent("state.json")
    // build.sh copies these into Contents/Resources
    static let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
    static let coach = resources.appendingPathComponent("coach.py")
    static let calevents = resources.appendingPathComponent("calevents")
}

// The AI API key, kept in the login Keychain rather than in config.json.
enum Keychain {
    private static let service = "Focus AI API key"
    private static let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                             kSecAttrService as String: service, kSecAttrAccount as String: "default"]
    static func get() -> String? {
        var q = base; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func set(_ key: String?) {
        SecItemDelete(base as CFDictionary)
        guard let key, !key.isEmpty else { return }
        var q = base; q[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}

struct Preset: Codable, Identifiable, Hashable {
    var name: String
    var minutes: Int
    var sites: [String]? = []
    var apps: [String]? = []
    var projects: [String]? = []
    var offline_ok: Bool? = false
    var any_claude: Bool? = false
    var terminal_ok: Bool? = true
    var strict: Bool? = false          // cover anything that isn't one of this block's apps or sites
    var id: String { name }
    var short: String { String(name.split(whereSeparator: { " /(".contains($0) }).first ?? Substring(name)) }
}

struct Distractions: Codable { var apps: [String]; var sites: [String] }
struct AISettings: Codable { var provider: String? }

struct Config: Codable {
    var drift_seconds: Double? = 30
    var renudge_seconds: Double? = 120
    var break_minutes: Int? = 5
    var recap_at: String? = "21:00"
    var morning_hour: Int? = 5
    var idle_nudge_minutes: Double? = 40
    var active_hours: [Int]? = [8, 23]
    var away_seconds: Double? = 45
    var mac_away_seconds: Double? = 180
    var distractions: Distractions
    var block_sites: [String]
    var always_ok_apps: [String]? = []
    var blocks: [Preset]
    var ai: AISettings? = nil
    var menu_style: String? = "both"   // what "Start" shows in the menu: both | quick | blocks
    var aiOn: Bool { !["", "none"].contains(ai?.provider ?? "none") }

    static func load() -> Config? {
        guard let d = try? Data(contentsOf: Paths.config) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: d)
    }
}

struct Todo: Codable, Identifiable, Hashable {
    var id: String
    var task: String
    var block: String
    var minutes: Int
    var start: String? = ""
    var done: Bool? = false
    var why: String? = ""
    var from: String? = nil          // backlog items: the day they were planned for
    var isDone: Bool { done ?? false }
}

struct ChatMsg: Codable, Hashable { var role: String; var text: String }

struct TodoDoc: Codable {
    var date: String? = ""
    var items: [Todo] = []
    var chat: [ChatMsg]? = []
    var backlog: [Todo]? = []

    static func load() -> TodoDoc {
        guard let d = try? Data(contentsOf: Paths.todos), var doc = try? JSONDecoder().decode(TodoDoc.self, from: d) else { return TodoDoc() }
        if doc.rollover() { doc.save() }
        return doc
    }

    /// New day: unfinished to-dos move to the backlog (shown in the planner, never nudged about); today starts empty.
    mutating func rollover() -> Bool {
        let t = today()
        guard let d = date, !d.isEmpty, d != t else { return false }
        var back = Dictionary((backlog ?? []).map { ($0.task.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        for var item in items where !item.isDone {
            item.start = ""; item.why = ""; item.from = d
            back[item.task.lowercased()] = item
        }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let cutoff = f.string(from: Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date())
        backlog = back.values.filter { ($0.from ?? t) >= cutoff }.sorted { ($0.from ?? "") > ($1.from ?? "") }
        items = []; chat = []; date = t
        return true
    }
    /// By start time; finished items without a time first, unscheduled to-dos last.
    mutating func sortItems() {
        func key(_ t: Todo) -> (Int, String) { !(t.start ?? "").isEmpty ? (1, t.start ?? "") : (t.isDone ? 0 : 2, "") }
        items = items.enumerated().sorted { a, b in key(a.element) != key(b.element) ? key(a.element) < key(b.element) : a.offset < b.offset }.map(\.element)
    }
    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        if let d = try? enc.encode(self) { try? d.write(to: Paths.todos) }
    }
}

struct ActiveBlock: Codable {
    var kind: String          // "focus" | "break"
    var name: String
    var task: String?
    var todoId: String?
    var started: Double
    var ends: Double
    var minutes: Int
    var offSeconds: Double
    var apps: [String]? = nil   // quick focus: the apps picked when it started (no saved block behind it)
}

func today() -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
}

func appendLog(_ ev: [String: Any]) {
    var e = ev
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    e["ts"] = f.string(from: Date())
    guard let d = try? JSONSerialization.data(withJSONObject: e), var line = String(data: d, encoding: .utf8) else { return }
    line += "\n"
    if let h = try? FileHandle(forWritingTo: Paths.log) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else { try? line.write(to: Paths.log, atomically: true, encoding: .utf8) }
}

// Small persistent state: running block, the day the morning plan was shown.
struct AppState: Codable {
    var active: ActiveBlock?
    var plan_shown: String?
    static func load() -> AppState {
        guard let d = try? Data(contentsOf: Paths.state), let s = try? JSONDecoder().decode(AppState.self, from: d) else { return AppState() }
        return s
    }
    func save() { if let d = try? JSONEncoder().encode(self) { try? d.write(to: Paths.state) } }
}

func fmtTime(_ sec: Double) -> String {
    let s = max(0, Int(sec.rounded(.up)))
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}

// Runs the Python helper (plan text, recap text, Claude planner) with an environment Claude can log in from.
func runCoach(_ args: [String], input: String? = nil) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = [Paths.coach.path] + args
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let user = NSUserName()
    // PATH covers the usual install spots of the `claude` CLI (npm global, Homebrew, the native installer).
    var env = ["PATH": "\(home)/.local/bin:\(home)/.claude/local:\(home)/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
               "HOME": home, "USER": user, "LOGNAME": user, "LANG": "en_US.UTF-8", "TERM": "xterm",
               "FOCUS_DATA": Paths.dir.path, "FOCUS_CALEVENTS": Paths.calevents.path,
               "PYTHONDONTWRITEBYTECODE": "1"]   // never write __pycache__ into the signed app bundle
    if ["todos", "test"].contains(args.first ?? ""), let key = Keychain.get() { env["FOCUS_AI_KEY"] = key }  // only calls that reach the AI
    p.environment = env
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    let inp = Pipe(); p.standardInput = inp
    do { try p.run() } catch { return "" }
    if let input { inp.fileHandleForWriting.write(input.data(using: .utf8)!) }
    try? inp.fileHandleForWriting.close()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

/// Soonest start today ("HH:MM") for a block this long: after now, around fixed calendar events and anything
/// already scheduled. "" if nothing fits before the end of the day. Runs the helper script, so call it off the main thread.
func soonestSlot(minutes: Int, skip: String? = nil) -> String {
    let out = runCoach(["slot", String(minutes)] + (skip.map { [$0] } ?? []))
    let obj = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any]
    return obj?["start"] as? String ?? ""
}
