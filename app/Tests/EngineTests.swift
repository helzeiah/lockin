// Logic tests for the app itself, run headless against a temporary data folder (nothing is shown on screen).
// ./app/test.sh compiles them with the app's sources.
import AppKit
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { failures += 1; print("FAIL line \(line): \(what)") }
}
func ymd(_ d: Date) -> String { DateFormatter.ymd.string(from: d) }
func json(_ obj: Any) -> Data { try! JSONSerialization.data(withJSONObject: obj) }
func readLog() -> [[String: Any]] {
    ((try? String(contentsOf: Paths.log, encoding: .utf8)) ?? "").split(separator: "\n")
        .compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
}

@main
struct EngineTests {
    @MainActor static func main() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lockin-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("LOCKIN_DATA", dir.path, 1)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cal = Calendar.current
        let todayD = Stats.day(of: Date())
        let weekday = cal.component(.weekday, from: todayD)
        try! json([
            "distractions": ["apps": ["Steam"], "sites": ["youtube.com"]], "block_sites": ["youtube.com"],
            "lockin_apps": ["Xcode", "Safari"],
            "blocks": [["name": "LeetCode / OA", "minutes": 45, "apps": ["Safari", "CLion"], "sites": ["leetcode.com"]],
                       ["name": "Co-op (Acme)", "minutes": 90, "apps": ["iTerm2", "Dia"], "projects": ["acme"]]],
            "routines": [["id": "r1", "task": "Morning review", "minutes": 20, "start": "08:00", "days": [weekday]]],
        ]).write(to: Paths.config)

        // Plan files written by other tools (or older versions) can leave fields out; they still load.
        let partial = #"{"date": "\#(today())", "items": [{"id": "a", "task": "No block field", "minutes": 30}]}"#
        let doc = try? JSONDecoder().decode(TodoDoc.self, from: Data(partial.utf8))
        check(doc?.items.first?.block == "" && doc?.items.first?.start == "", "decodes a to-do with missing fields")

        // Rollover: yesterday's leftovers go to the backlog, tomorrow's plan becomes today's, repeats get added.
        let yesterday = ymd(cal.date(byAdding: .day, value: -1, to: todayD)!)
        try! json(["date": yesterday,
                   "items": [["id": "u", "task": "Unfinished", "minutes": 30], ["id": "d", "task": "Done", "minutes": 30, "done": true],
                             ["id": "x", "task": "Morning review", "minutes": 20, "source": "routine", "ref": "r1"]],
                   "tomorrow": [["id": "t", "task": "Planned last night", "minutes": 45, "start": "10:00"]]]).write(to: Paths.todos)
        var d = TodoDoc.load()
        check(d.date == today(), "rollover sets today's date")
        check(d.items.map(\.task).sorted() == ["Morning review", "Planned last night"], "tomorrow + repeat become today: \(d.items.map(\.task))")
        check(d.backlog?.map(\.task) == ["Unfinished"], "unfinished goes to the backlog, repeats and done items don't")
        check(d.tomorrow?.isEmpty ?? true, "tomorrow is emptied")

        // Away for a few days: that old "tomorrow" lands in the backlog instead of today.
        let longAgo = ymd(cal.date(byAdding: .day, value: -4, to: todayD)!)
        try! json(["date": longAgo, "items": [], "tomorrow": [["id": "t", "task": "Stale plan", "minutes": 45, "start": "10:00"]]]).write(to: Paths.todos)
        d = TodoDoc.load()
        check(!d.items.contains { $0.task == "Stale plan" } && d.backlog?.contains { $0.task == "Stale plan" } == true, "a stale tomorrow goes to the backlog")

        // An unreadable plan file is kept, not overwritten silently.
        try! Data("{not json".utf8).write(to: Paths.todos)
        _ = TodoDoc.load()
        check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("todos.unreadable.json").path), "keeps a copy of an unreadable plan")

        // Word matching.
        let cfg = Config.load()!
        check(TaskMatch.words("Co-op (Acme)").contains("coop"), "hyphenated words count joined")
        check(!TaskMatch.words("Co-op").contains("op"), "short parts of hyphenated words don't count")
        check(TaskMatch.rule(for: "co-op: finish the web UI", in: cfg.blocks)?.name == "Co-op (Acme)", "matches a rule by its words")
        check(TaskMatch.rule(for: "OA practice", in: cfg.blocks)?.name == "LeetCode / OA", "short standalone words still match")
        check(TaskMatch.rule(for: "op amp lab", in: cfg.blocks) == nil, "no false match on a fragment")
        check(TaskMatch.apps(for: "leetcode mediums", cfg: cfg, history: []).apps == ["Safari", "CLion"], "a rule's apps")
        let past = [TaskMatch.Past(task: "Write the essay intro", apps: ["Pages"])]
        check(TaskMatch.apps(for: "essay conclusion", cfg: cfg, history: past).apps == ["Pages"], "learned from a similar past task")
        check(TaskMatch.apps(for: "groceries", cfg: cfg, history: past).apps == ["Xcode", "Safari"], "falls back to lock-in apps")

        // Sessions: only the session's apps; a rule brings its Claude folders.
        let e = Engine.shared
        e.reloadConfig(); e.reloadTodos()
        e.startSession(task: "Co-op standup notes", minutes: 30)
        check(e.block?.rule == "Co-op (Acme)" && e.block?.apps == ["iTerm2", "Dia"], "session takes the rule's apps")
        check(e.preset?.strict == true && e.preset?.terminal_ok == true && e.preset?.any_claude == false, "allowlist with folder rule")
        check(readLog().last { $0["type"] as? String == "block_start" }?["apps"] as? [String] == ["iTerm2", "Dia"], "block_start logs the apps")
        check(readLog().last?["type"] as? String == "gate_passed", "starting a session counts as starting the day")
        e.stopBlock(completed: false, silent: true)
        check(e.block == nil && readLog().last?["how"] as? String == "stopped", "ending early is logged")
        e.startSession(task: nil, minutes: 25, apps: ["Xcode"])
        check(e.preset?.any_claude == false && e.preset?.terminal_ok == false, "no terminal unless it's one of the apps")
        e.stopBlock(completed: true, silent: true)
        check(readLog().last?["completed"] as? Bool == true, "a finished session is logged as kept")

        // Planning today and tomorrow, moving between them.
        e.addTodo(task: "Tomorrow thing", minutes: 30, start: "09:00", day: .tomorrow)
        check(e.tomorrow.map(\.task) == ["Tomorrow thing"], "adds to tomorrow")
        e.move(e.tomorrow[0].id, to: .today)
        check(e.todos.contains { $0.task == "Tomorrow thing" } && e.tomorrow.isEmpty, "moves to today")

        // Repeats survive a settings save (settings re-read the file before writing).
        let settings = SettingsModel()
        let t = e.todos.first { $0.task == "Tomorrow thing" }!
        e.setRepeat(t, days: [2, 3, 4, 5, 6])
        settings.statsGoal = 40
        settings.save(includeKey: false)
        let after = Config.load()!
        check(after.routines?.contains { $0.task == "Tomorrow thing" && $0.days == [2, 3, 4, 5, 6] } == true, "repeat saved and kept")
        check(after.stats_goal == 40, "settings saved")

        // The morning screen: skipping is on the record.
        e.passGate(how: "skip", reason: "travel day")
        check(AppState.load().plan_shown == today(), "gate marked passed for today")
        check(readLog().last?["type"] as? String == "gate_skipped" && readLog().last?["reason"] as? String == "travel day", "skip and reason logged")

        // Stats count kept vs. ended early.
        let st = Stats.load()
        check(st.keptCount(Stats.today) == 1 && st.ended(Stats.today) == 2 && st.skips[Stats.today] == 1, "stats: 1 kept, 2 ended, 1 skip")

        // Rewards: XP from the log, levels, badges.
        let r = Rewards.load(goal: 25)
        check(r.xp > 0 && r.level >= 1, "XP from finished sessions")
        check(r.badges.first { $0.id == "first" }?.earned != nil, "first lock-in badge")
        check(Rewards.levelStart(2) == 100 && Rewards.levelStart(3) == 300, "level curve")
        var big = Rewards(); big.xp = 1000
        check(big.level == 5 && big.title == "Locked In", "level 5 at 1000 XP")

        if failures == 0 { print("Engine: all tests passed") } else { print("Engine: \(failures) failed"); exit(1) }
    }
}
