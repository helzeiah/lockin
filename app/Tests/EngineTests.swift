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
            "lockin_apps": ["Xcode", "Safari"], "sounds": false,
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

        // Typed edits without AI.
        e.clearDay(.today)
        e.addTodo(task: "LeetCode mediums", minutes: 45, start: "09:00")
        e.addTodo(task: "Write the essay intro", minutes: 30, start: "10:00")
        e.addTodo(task: "Reply to emails", minutes: 20, start: "")
        e.applyTyped("done leetcode", day: .today)
        check(e.todos.first { $0.task == "LeetCode mediums" }?.isDone == true, "done leetcode marks it done")
        e.applyTyped("essay at 23:30", day: .today)
        check(e.todos.first { $0.task == "Write the essay intro" }?.start == "23:30", "essay at a time moves it, no new task")
        check(e.todos.count == 3, "no duplicate added for a move: \(e.todos.map(\.task))")
        e.applyTyped("push emails to tomorrow", day: .today)
        check(e.tomorrow.contains { $0.task == "Reply to emails" } && !e.todos.contains { $0.task == "Reply to emails" }, "moves to tomorrow")
        e.applyTyped("make essay 60 min", day: .today)
        check(e.todos.first { $0.task == "Write the essay intro" }?.minutes == 60, "resizes")
        e.applyTyped("gym 60 at 23:00, remove essay", day: .today)
        while e.planning { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }   // new tasks land in the background
        check(e.todos.contains { $0.task == "gym" } && !e.todos.contains { $0.task == "Write the essay intro" }, "adds and removes in one line")
        check(e.planNote?.contains("Removed") == true, "says what it did")
        e.addTodo(task: "Problem set", minutes: 30, start: "")
        let moved = e.reflow(from: "22:00", day: .today)
        check(moved == 2 && e.todos.first { $0.task == "gym" }?.start == "22:00", "re-times what's left from a time")

        // Rewards: only signed, active work earns XP; edited lines earn nothing.
        func signed(_ fields: [String: Any]) -> [String: Any] { var f = fields; f["sig"] = Integrity.sign(f); return f }
        let ts = logTimestamp(Calendar.current.date(byAdding: .hour, value: 12, to: Stats.today)!)   // midday of today's plan day, whatever time the test runs
        let real = signed(["type": "block_end", "ts": ts, "task": "Essay", "planned_min": 50, "focused_min": 50, "active_min": 50,
                           "offline_min": 0, "completed": true])
        let idle = signed(["type": "block_end", "ts": ts, "task": "Fake", "planned_min": 60, "focused_min": 2, "active_min": 2,
                           "offline_min": 0, "completed": true])
        var forged = real; forged["active_min"] = 500; forged["focused_min"] = 500
        let lines = [real, idle, forged].map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
        try! (lines.joined(separator: "\n") + "\n").write(to: Paths.log, atomically: true, encoding: .utf8)
        let r = Rewards.load(goal: 25)
        check(r.xp == 50 + 10 + 25 + 2, "XP: 50 active + finish bonus + day bonus + 2 (no bonus for an idle session, forged line ignored): \(r.xp)")
        check(r.badges.first { $0.id == "first" }?.earned != nil, "first lock-in badge from the real session")
        check(Stats.load().todayMinutes == 52, "stats ignore the edited line: \(Stats.load().todayMinutes)")
        check(Integrity.valid(real) && !Integrity.valid(forged), "signature catches an edit")
        check(Rewards.levelStart(2) == 100 && Rewards.levelStart(3) == 300, "level curve")
        var big = Rewards(); big.xp = 1000
        check(big.level == 5 && big.title == "Locked In", "level 5 at 1000 XP")

        // Skins: only what your level unlocked can be equipped.
        Skin.noteLevel(1)
        UserDefaults.standard.set("vault", forKey: "skin")
        check(Skin.current.id == "green", "a locked skin falls back to the default")
        Skin.noteLevel(14)
        check(Skin.current.id == "vault", "an unlocked skin applies once equipped")
        UserDefaults.standard.removeObject(forKey: "skin"); UserDefaults.standard.removeObject(forKey: "rewardLevel")

        // After a session its card shows what it earned (87 XP so far, today already counts); crossing 100 makes it
        // the level-up card.
        e.startSession(task: "Essay draft", minutes: 30, apps: ["Pages"])
        e.block?.started -= 30 * 60; e.block?.activeSeconds = 30 * 60
        e.stopBlock(completed: true)
        let gain = e.card?.xp
        check(gain?.from == 87 && gain?.to == 127 && gain?.parts == ["30 min on task", "+10 finished"], "card XP: \(String(describing: gain))")
        check(gain?.levelUp == true && e.card?.icon == "emblem:2", "crossing a level shows the level-up card")
        e.card = nil
        UserDefaults.standard.removeObject(forKey: "rewardLevel")

        // The plan follows the day: late starts push what's next, finishing early pulls the queue up to the first gap,
        // and calendar events, repeats and times you set yourself stay put.
        do {
            let day = cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
            func at(_ s: String) -> Date { parseHHMM(s, on: day)! }
            func todo(_ id: String, _ start: String, _ min: Int, pinned: Bool? = nil, source: String? = nil) -> Todo {
                Todo(id: id, task: id, minutes: min, start: start, source: source, pinned: pinned)
            }
            func starts(_ l: [Todo]) -> [String] { l.map { $0.start ?? "" } }
            let end = at("23:30")
            let plan = [todo("a", "09:00", 45), todo("b", "09:50", 30), todo("c", "14:00", 60)]

            // Started 20 minutes late: b moves back, c's gap absorbs it.
            var r = TodoDoc.retimed(plan, from: at("10:05"), busy: [], dayEnd: end, now: at("09:20"), keep: "a")
            check(starts(r) == ["09:00", "10:05", "14:00"], "late start pushes the next one only: \(starts(r))")

            // Finished a at 9:30 instead of 9:45: b (right behind it) moves up, c (after a real gap) stays.
            var finished = plan; finished[0].done = true
            r = TodoDoc.retimed(finished, from: at("09:35"), busy: [], dayEnd: end, now: at("09:30"), freed: (at("09:00"), at("09:45")))
            check(starts(r) == ["09:00", "09:35", "14:00"], "finishing early pulls the queue up to the first gap: \(starts(r))")

            // A calendar event sits in the way: the session goes after it.
            r = TodoDoc.retimed(plan, from: at("10:05"), busy: [(at("10:00"), at("11:00"))], dayEnd: end, now: at("09:20"), keep: "a")
            check(starts(r)[1] == "11:00", "flows around calendar events: \(starts(r))")

            // Missed starts slide to now; a repeat and a pinned time ahead keep their time, and the rest flows around them.
            let busy = [todo("a", "08:00", 30), todo("r", "09:30", 30, source: "routine"), todo("p", "10:15", 30, pinned: true), todo("b", "08:40", 60)]
            r = TodoDoc.retimed(busy, from: at("09:00"), busy: [], dayEnd: end, now: at("09:00"))
            check(starts(r) == ["09:00", "09:30", "10:15", "10:50"], "missed sessions slide around fixed ones: \(starts(r))")

            // A pinned time that already went by moves like any other.
            r = TodoDoc.retimed([todo("p", "08:00", 30, pinned: true)], from: at("09:00"), busy: [], dayEnd: end, now: at("09:00"))
            check(r[0].start == "09:00" && r[0].pinned == nil, "a missed pinned time slides and unpins")

            // Ended a early: what's left of it goes after the others.
            r = TodoDoc.retimed(plan, from: at("09:25"), busy: [], dayEnd: end, now: at("09:20"), freed: (at("09:00"), at("09:45")), last: "a")
            check(starts(r) == ["15:05", "09:25", "14:00"], "an unfinished session goes to the back: \(starts(r))")

            // Nothing fits before the end of the day: it loses its time; done and untimed ones aren't touched.
            r = TodoDoc.retimed([todo("x", "09:00", 60), Todo(id: "d", task: "d", minutes: 30, start: "08:00", done: true), todo("u", "", 30)],
                                from: at("09:00"), busy: [], dayEnd: at("09:30"), now: at("09:00"))
            check(starts(r) == ["", "08:00", ""], "overflow loses its time; done and untimed stay: \(starts(r))")
        }

        // Breaks and a finish time: tomorrow's answer moves with the plan at rollover, and sessions fit inside it.
        try! json(["date": ymd(cal.date(byAdding: .day, value: -1, to: todayD)!), "items": [],
                   "tomorrow": [["id": "t", "task": "Planned last night", "minutes": 45, "start": "10:00"]],
                   "tomorrow_shape": ["breaks": [["start": "12:30", "minutes": 60]], "finish": "18:00"]]).write(to: Paths.todos)
        d = TodoDoc.load()
        check(d.shape?.finish == "18:00" && d.shape?.breaks.first?.start == "12:30" && d.tomorrow_shape == nil, "tomorrow's breaks become today's")
        try! json(["date": today(), "items": [],
                   "tomorrow": [["id": "a", "task": "Long one", "minutes": 60, "start": "12:00"],
                                ["id": "b", "task": "Short one", "minutes": 30, "start": "13:05"]]]).write(to: Paths.todos)
        e.reloadTodos()
        e.setShape(DayShape(breaks: [.init(start: "12:30", minutes: 60)], finish: "14:00"), day: .tomorrow)
        let fitted = TodoDoc.load().tomorrow ?? []
        check(fitted.first { $0.id == "a" }?.start == "" && fitted.first { $0.id == "b" }?.start == "13:30",
              "sessions move past the break and lose their time past the finish: \(fitted.map { $0.start ?? "" })")
        check(e.tomorrowShape?.finish == "14:00" && DayShape.last?.finish == "14:00", "the answer is saved and remembered")
        check(e.planNote?.contains("won't fit before") == true, "says what didn't fit: \(e.planNote ?? "")")
        check(DayShape(breaks: [.init(start: "12:30", minutes: 60)], finish: "18:00").summary.contains("for 1"), "summary line")
        UserDefaults.standard.removeObject(forKey: "lastDayShape")
        try! json(["date": today(), "items": []]).write(to: Paths.todos)
        e.reloadTodos()

        // The to-do list: typing a task in, ranking, suggestions, nudges, and finishing it from the plan.
        do {
            let base = Stats.day(of: Date())
            func day(_ n: Int) -> String { ymd(cal.date(byAdding: .day, value: n, to: base)!) }
            let typed = TaskList.parse("* sell fridge due tomorrow 30m\n  post it on marketplace\npolicy memo by 12/5 1.5h\nclean up drive", now: Date())
            check(typed.count == 3, "one task per line, indented lines are notes: \(typed.map(\.title))")
            check(typed[0].title == "sell fridge" && typed[0].isStarred && typed[0].minutes == 30 && typed[0].due == day(1)
                  && typed[0].notes == "post it on marketplace", "parses star, length, due date and notes: \(typed[0])")
            check(typed[1].title == "policy memo" && typed[1].minutes == 90 && typed[1].due?.hasSuffix("-12-05") == true, "by 12/5 and 1.5h")
            check(typed[2].due == nil && typed[2].minutes == nil && typed[2].openQuestions == [.due, .minutes, .firstStep], "a bare task gets asked the basics")
            check(TaskList.parseLine("stand by the door")?.title == "stand by the door", "\"by\" without a date stays in the title")
            if let fri = TaskList.dueDate("fri") { check(cal.component(.weekday, from: fri) == 6 && fri >= base, "fri is this coming Friday") }

            func task(_ id: String, due: Int? = nil, star: Bool = false) -> ListTask {
                ListTask(id: id, title: id, due: due.map(day), starred: star, created: day(-5))
            }
            let all = [task("later", due: 10), task("anytime"), task("star", star: true), task("soon", due: 2), task("today", due: 0), task("late", due: -2)]
            check(TaskList.ranked(all).map(\.id) == ["late", "today", "star", "soon", "later", "anytime"], "ranked: \(TaskList.ranked(all).map(\.id))")
            let sug = TaskList.suggestions(all, planned: ["today"], day: .today)
            check(sug.first?.task.id == "late" && sug.first?.picked == true && !sug.contains { $0.task.id == "today" }, "suggests what's due, minus what's planned")
            check(sug.first { $0.task.id == "soon" }?.picked == false && sug.first { $0.task.id == "star" }?.picked == true, "starred starts ticked, later ones don't")
            check(sug.first?.why == "Overdue 2 days", "says why: \(sug.first?.why ?? "")")
            let morning = cal.date(bySettingHour: 10, minute: 0, second: 0, of: base)!, evening = cal.date(bySettingHour: 19, minute: 0, second: 0, of: base)!
            check(TaskList.nudge(all, today: [], tomorrow: [], nudged: [], now: morning)?.task.id == "late", "nudges the overdue one first")
            check(TaskList.nudge(all, today: ["late", "today"], tomorrow: [], nudged: [], now: morning) == nil, "nothing to nudge once it's planned")
            let dueTomorrow = [task("t", due: 1)]
            check(TaskList.nudge(dueTomorrow, today: [], tomorrow: [], nudged: [], now: morning) == nil
                  && TaskList.nudge(dueTomorrow, today: [], tomorrow: [], nudged: [], now: evening)?.tomorrow == true, "due tomorrow: an evening nudge")

            // Finishing its session ticks it off the list; finishing it on the list ticks the session.
            try! json(["date": today(), "items": []]).write(to: Paths.todos)
            TaskListDoc(tasks: [task("a"), task("b")]).save()
            e.reloadTodos()
            try! json(["date": today(), "items": [["id": "pa", "task": "a", "minutes": 30, "task_id": "a"],
                                                  ["id": "pb", "task": "b", "minutes": 30, "task_id": "b"]]]).write(to: Paths.todos)
            e.reloadTodos()
            e.setDone("pa", true)
            check(e.listTasks.first { $0.id == "a" }?.isDone == true, "a session done ticks its list task")
            e.setListDone("b", true)
            check(e.todos.first { $0.id == "pb" }?.isDone == true, "a list task done ticks its session")
            e.setListDone("b", false)
            check(e.todos.first { $0.id == "pb" }?.isDone == false && e.listTasks.first { $0.id == "b" }?.isDone == false, "and back")

            // A list task left unfinished stays on the list instead of going to the backlog.
            try! json(["date": day(-1), "items": [["id": "pb", "task": "b", "minutes": 30, "task_id": "b"],
                                                  ["id": "x", "task": "Plain", "minutes": 30]]]).write(to: Paths.todos)
            let rolled = TodoDoc.load()
            check(rolled.backlog?.map(\.task) == ["Plain"], "list tasks don't land in the backlog: \(rolled.backlog?.map(\.task) ?? [])")
            try? FileManager.default.removeItem(at: Paths.tasks)
            try! json(["date": today(), "items": []]).write(to: Paths.todos)
            e.reloadTodos()
        }

        // Breaks scale with the session: its length ÷ the ratio; 0 = a fixed length; old configs keep a hand-set length.
        do {
            var c = Config.empty
            check(c.breakAfter(25) == 5 && c.breakAfter(90) == 18 && c.breakAfter(2) == 1, "÷ 5 by default: \(c.breakAfter(90))")
            c.break_ratio = 3
            check(c.breakAfter(90) == 30, "÷ 3")
            c.break_ratio = 0; c.break_minutes = 7
            check(c.breakAfter(90) == 7 && c.breakAfter(10) == 7, "fixed length")
            c.break_ratio = nil
            check(c.breakRatio == 0 && c.breakAfter(90) == 7, "a config with a hand-set break keeps it")

            // The plan leaves each session's own break after it.
            let day = cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
            let plan = [Todo(id: "a", task: "a", minutes: 90, start: "08:00"), Todo(id: "b", task: "b", minutes: 30, start: "08:00")]
            let r = TodoDoc.retimed(plan, from: day, busy: [], dayEnd: day.addingTimeInterval(14 * 3600), now: day, breakAfter: { $0 / 3 })
            check(r.map { $0.start ?? "" } == ["09:00", "11:00"], "90 min ÷ 3 leaves a 30-min break: \(r.map { $0.start ?? "" })")

            // After a session, the break offered is what it earned.
            e.reloadConfig()
            e.startSession(task: "Long one", minutes: 90, apps: ["Pages"])
            e.block?.started -= 90 * 60
            e.stopBlock(completed: false)
            check(e.nextBreakMinutes == 18, "90 locked-in minutes earn an 18-minute break: \(e.nextBreakMinutes)")
            e.card = nil
            e.startBreak()
            check(e.block?.kind == "break" && e.block?.minutes == 18, "the break runs that long")
            e.stopBlock(completed: false, silent: true); e.card = nil
        }

        // Commitment levels cut tasks to size; the day runs hardest and most urgent first.
        do {
            check(Commitment.small.pieces(45) == [10, 10, 10, 10, 5], "small: \(Commitment.small.pieces(45))")
            check(Commitment.medium.pieces(120) == [40, 40, 40] && Commitment.medium.pieces(40) == [40], "medium: \(Commitment.medium.pieces(120))")
            check(Commitment.large.pieces(120) == [60, 60] && Commitment.large.pieces(200) == [65, 65, 70], "large: \(Commitment.large.pieces(200))")
            for m in [7, 23, 45, 61, 95, 137, 240] { for c in Commitment.allCases {
                let p = c.pieces(m)
                check(p.reduce(0, +) == m && p.allSatisfy { $0 <= c.range.upperBound }, "\(c) \(m) adds up and fits: \(p)")
            } }

            let essay = Todo(id: "e", task: "Essay", minutes: 30, start: "")
            let small = TodoDoc.cut(essay, .small, firstStep: "open the doc")
            check(small.map(\.task) == ["Essay: open the doc", "Essay (2/3)", "Essay (3/3)"] && small.map(\.minutes) == [10, 10, 10]
                  && Set(small.compactMap(\.group)) == ["e"] && small[0].id == "e", "small pieces: \(small.map(\.task))")
            let named = TodoDoc.cut(essay, .small, steps: [("Open the doc", 5), ("Write the first heading", 10)])
            check(named.map(\.task) == ["Open the doc", "Write the first heading"] && named.map(\.minutes) == [5, 10], "AI steps name the pieces")

            // A new level joins up the pieces you haven't started and cuts again; a started piece stays.
            var day = small; day[0].done = true
            let large = TodoDoc.recut(day, .large)
            check(large.count == 2 && large[0].isDone && large[1].task == "Essay" && large[1].minutes == 20, "recut joins unstarted pieces: \(large.map(\.task))")
            check(TodoDoc.recut(TodoDoc.cut(Todo(id: "x", task: "X", minutes: 120, start: ""), .small), .large).map(\.minutes) == [60, 60], "small → large")

            // Order: due first, then hard, then long; pieces stay together and in order.
            let plan = [Todo(id: "easy", task: "easy", minutes: 20, start: "", effort: 1),
                        Todo(id: "long", task: "long", minutes: 90, start: ""),
                        Todo(id: "hard", task: "hard", minutes: 20, start: "", effort: 3),
                        Todo(id: "due", task: "due", minutes: 15, start: "", task_id: "L1", effort: 1)]
            let order = TodoDoc.prioritized(plan) { $0.task_id == "L1" ? 0 : nil }.map(\.id)
            check(order == ["due", "long", "hard", "easy"], "due, then hard (long counts as hard), then easy: \(order)")
            let cutUp = TodoDoc.cut(Todo(id: "big", task: "big", minutes: 30, start: ""), .small) + [Todo(id: "mid", task: "mid", minutes: 20, start: "")]
            check(TodoDoc.prioritized(cutUp) { _ in nil }.map(\.id).first == "big"
                  && TodoDoc.prioritized(cutUp) { _ in nil }.compactMap(\.part) == [1, 2, 3], "a cut-up task sorts as a whole, pieces in order")

            check(TaskList.parseLine("econ final study due fri 2h hard")?.effort == 3
                  && TaskList.parseLine("econ final study due fri 2h hard")?.title == "econ final study", "\"hard\" at the end sets difficulty")
            check(TaskList.parseLine("leetcode mediums")?.effort == nil, "only a last word sets difficulty")

            // Planning tomorrow on a small day: the list task arrives in pieces, hardest first.
            try! json(["date": today(), "items": [], "tomorrow": [["id": "t1", "task": "Light reading", "minutes": 20, "effort": 1]],
                       "tomorrow_shape": ["breaks": [], "level": "small"]]).write(to: Paths.todos)
            TaskListDoc(tasks: [ListTask(id: "L9", title: "Problem set", minutes: 30, first_step: "print it", effort: 3)]).save()
            e.reloadTodos()
            e.arrangeDay(.tomorrow)
            check(e.tomorrow.map(\.task) == ["Light reading (1/2)", "Light reading (2/2)"], "arrangeDay cuts to the level: \(e.tomorrow.map(\.task))")
            try! json(["date": today(), "items": []]).write(to: Paths.todos)
            try? FileManager.default.removeItem(at: Paths.tasks)
            e.reloadTodos()
        }

        // Setting a time yourself pins it; the plan doesn't pin times it picks.
        e.addTodo(task: "Pin me", minutes: 30, start: "")
        if let t = e.todos.first(where: { $0.task == "Pin me" }) {
            e.updateTodo(t.id, start: "23:00")
            check(TodoDoc.load().items.first { $0.id == t.id }?.pinned == true, "a time you set is pinned")
            e.deleteTodo(t.id)
        } else { check(false, "added a to-do") }

        if failures == 0 { print("Engine: all tests passed") } else { print("Engine: \(failures) failed"); exit(1) }
    }
}
