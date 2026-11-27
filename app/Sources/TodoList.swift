import Foundation

/// One thing on your running to-do list. It stays until you finish it, however many days that takes; planning a day
/// puts it on that day's plan as a session (Todo.task_id points back here).
struct ListTask: Codable, Identifiable, Hashable {
    struct QA: Codable, Hashable { var q: String; var a: String }
    struct Step: Codable, Hashable { var task: String; var minutes: Int }

    var id: String
    var title: String
    var notes: String? = ""
    var due: String? = nil           // "yyyy-MM-dd"; "" = you said it has no due date; nil = not asked yet
    var minutes: Int? = nil          // how long it takes, generously; nil = not estimated yet (see length)
    var estimated: Bool? = nil       // minutes is lockin's or the AI's estimate, not a length you set
    var first_step: String? = nil
    var steps: [Step]? = nil         // the AI's breakdown into 5-15 minute steps; nil = not broken down yet
    var starred: Bool? = false
    var done: String? = nil          // the day you finished it
    var created: String? = nil       // the day you added it
    var qa: [QA]? = []               // your answers to the AI's questions about it
    var ai_questions: [String]? = nil   // the AI's questions still waiting for an answer
    var skipped: Bool? = nil         // "Stop asking" about this one
    var effort: Int? = nil           // how hard it is to get into: 1 easy, 2 medium, 3 hard; nil = judged by length

    var isDone: Bool { done != nil }
    /// How long to plan for it: its length, else a generous guess from its words (see Estimate).
    var length: Int { minutes ?? Estimate.minutes(title, notes: notes ?? "") }
    static let effortNames = [1: "Easy", 2: "Medium", 3: "Hard"]
    var isStarred: Bool { starred ?? false }
    var dueDate: Date? { due.flatMap { $0.isEmpty ? nil : DateFormatter.ymd.date(from: $0) } }

    /// Days until it's due (negative = overdue), counted in plan days.
    func daysLeft(from now: Date = Date()) -> Int? {
        guard let d = dueDate else { return nil }
        return Calendar.current.dateComponents([.day], from: Stats.day(of: now), to: d).day
    }
    /// "Overdue 2 days", "Due today", "Due tomorrow", "Due Fri", "Due Dec 12".
    func dueLabel(from now: Date = Date()) -> String {
        guard let n = daysLeft(from: now), let d = dueDate else { return "" }
        switch n {
        case ..<(-1): return "Overdue \(-n) days"
        case -1: return "Overdue 1 day"
        case 0: return "Due today"
        case 1: return "Due tomorrow"
        case 2...6: return "Due " + d.formatted(.dateTime.weekday(.abbreviated))
        default: return "Due " + d.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    /// The built-in questions it still needs answered. Only when it's due: its length is estimated and its first step
    /// comes from the AI's breakdown.
    enum Question: String { case due }
    var openQuestions: [Question] {
        guard !(skipped ?? false), !isDone else { return [] }
        return due == nil ? [.due] : []
    }
    var needsAnswers: Bool { !openQuestions.isEmpty || !(ai_questions ?? []).isEmpty }

    /// What the planner and the AI see about it beyond its title: notes, first step, answers.
    var details: String {
        var parts: [String] = []
        if let n = notes, !n.isEmpty { parts.append(n) }
        if let f = first_step, !f.isEmpty { parts.append("First step: \(f)") }
        parts += (qa ?? []).map { "\($0.q) \($0.a)" }
        return parts.joined(separator: " · ")
    }
}

struct TaskListDoc: Codable {
    var tasks: [ListTask] = []

    static func load() -> TaskListDoc {
        guard let d = try? Data(contentsOf: Paths.tasks) else { return TaskListDoc() }
        if let doc = try? JSONDecoder().decode(TaskListDoc.self, from: d) { return doc }
        try? d.write(to: Paths.dir.appendingPathComponent("tasks.unreadable.json"))   // keep a copy rather than lose it
        return TaskListDoc()
    }
    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        if let d = try? enc.encode(self) { try? d.write(to: Paths.tasks) }
    }
}

enum TaskList {
    /// Open tasks in the order they matter: overdue, due today, starred, due within 3 days, then by due date (undated
    /// last), oldest first.
    static func ranked(_ tasks: [ListTask], now: Date = Date()) -> [ListTask] {
        func key(_ t: ListTask) -> (Int, Int, String) {
            let n = t.daysLeft(from: now)
            let tier = (n.map { $0 < 0 } ?? false) ? 0 : n == 0 ? 1 : t.isStarred ? 2 : (n.map { $0 <= 3 } ?? false) ? 3 : 4
            return (tier, n ?? Int.max, t.created ?? "")
        }
        return tasks.filter { !$0.isDone }.sorted { key($0) < key($1) }
    }

    /// What fits in `minutes` of free time, most important first (see ranked), with the break after each. A task
    /// that doesn't fit is passed over for a smaller one further down. Tasks without a length count as 45 minutes.
    static func fill(_ tasks: [ListTask], planned: Set<String>, minutes: Int, breakAfter: (Int) -> Int = { _ in 5 },
                     now: Date = Date()) -> [ListTask] {
        var left = minutes, out: [ListTask] = []
        for t in ranked(tasks, now: now) where !planned.contains(t.id) {
            let m = t.length
            guard m <= left else { continue }   // the day's last session needs no break after it
            out.append(t); left -= m + breakAfter(m)
        }
        return out
    }

    /// The task worth a nudge right now, if any: due today (or overdue) and not on today's plan; in the evening, due
    /// tomorrow and not on tomorrow's plan. Each one once a day (`nudged`).
    static func nudge(_ tasks: [ListTask], today plannedToday: Set<String>, tomorrow plannedTomorrow: Set<String>,
                      nudged: Set<String>, now: Date = Date()) -> (task: ListTask, tomorrow: Bool)? {
        let evening = Calendar.current.component(.hour, from: now) >= 18
        for t in ranked(tasks, now: now) where !nudged.contains(t.id) {
            guard let n = t.daysLeft(from: now) else { continue }
            if n <= 0 && !plannedToday.contains(t.id) { return (t, false) }
            if n == 1 && evening && !plannedTomorrow.contains(t.id) { return (t, true) }
        }
        return nil
    }

    // MARK: typing tasks in

    /// "sell fridge due fri 30m", "* policy memo by 12/5 2h": the title, plus a due date, a length and a star if you
    /// typed them. Several lines = several tasks; an indented line (or "- ") under one is its notes.
    static func parse(_ text: String, now: Date = Date()) -> [ListTask] {
        var out: [ListTask] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let indented = raw.first.map { $0 == " " || $0 == "\t" } ?? false
            if !out.isEmpty, indented || line.hasPrefix("- ") || line.hasPrefix("• ") {
                let note = line.trimmingCharacters(in: CharacterSet(charactersIn: "-• "))
                let i = out.count - 1
                out[i].notes = [out[i].notes ?? "", note].filter { !$0.isEmpty }.joined(separator: "\n")
                continue
            }
            if let t = parseLine(line, now: now) { out.append(t) }
        }
        return out
    }

    static func parseLine(_ line: String, now: Date = Date()) -> ListTask? {
        var s = " " + line + " "
        var t = ListTask(id: Todo.newId(), title: "", created: today(now))
        if s.trimmingCharacters(in: .whitespaces).hasPrefix("*") { t.starred = true; s = s.replacingOccurrences(of: #"^\s*\*\s*"#, with: " ", options: .regularExpression) }
        if s.hasSuffix("! ") { t.starred = true; s = String(s.dropLast(2)) + " " }
        // A length: "30m", "45 min", "1.5h", "2 hours".
        if let r = s.range(of: #"(?i)\s(\d+(?:\.\d+)?)\s?(m|min|mins|minutes|h|hr|hrs|hour|hours)(?=\s)"#, options: .regularExpression) {
            let m = String(s[r]).trimmingCharacters(in: .whitespaces)
            let num = Double(m.prefix { "0123456789.".contains($0) }) ?? 0
            let hours = m.lowercased().contains("h")
            let minutes = Int((hours ? num * 60 : num).rounded())
            if (5...600).contains(minutes) { t.minutes = minutes; t.estimated = false; s.replaceSubrange(r, with: " ") }
        }
        // How hard: "easy", "medium" or "hard" as the last word.
        if let r = s.range(of: #"(?i)\s(easy|medium|hard)\s*$"#, options: .regularExpression) {
            t.effort = ["easy": 1, "medium": 2, "hard": 3][String(s[r]).trimmingCharacters(in: .whitespaces).lowercased()]
            s.replaceSubrange(r, with: " ")
        }
        // A due date: "due fri", "by tomorrow", "due 12/5", "by dec 5".
        if let r = s.range(of: #"(?i)\s(due|by)\s+(today|tonight|tomorrow|tmrw|next week|mon(day)?|tue(s|sday)?|wed(nesday)?|thu(r|rs|rsday)?|fri(day)?|sat(urday)?|sun(day)?|\d{1,2}/\d{1,2}|(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{1,2})(?=\s)"#,
                           options: .regularExpression) {
            let words = String(s[r]).trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
            if words.count == 2, let d = dueDate(words[1], now: now) { t.due = DateFormatter.ymd.string(from: d); s.replaceSubrange(r, with: " ") }
        }
        t.title = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return t.title.isEmpty ? nil : t
    }

    /// "fri" → this coming Friday (today counts), "12/5" → Dec 5 (next year if it's gone by), "dec 5", "next week".
    static func dueDate(_ text: String, now: Date = Date()) -> Date? {
        let cal = Calendar.current, base = Stats.day(of: now), w = text.lowercased().trimmingCharacters(in: .whitespaces)
        switch w {
        case "today", "tonight": return base
        case "tomorrow", "tmrw": return cal.date(byAdding: .day, value: 1, to: base)
        case "next week": return cal.date(byAdding: .day, value: 7, to: base)
        default: break
        }
        let days = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        if let i = days.firstIndex(where: { w.hasPrefix($0) }) {
            let ahead = (i + 1 - cal.component(.weekday, from: base) + 7) % 7
            return cal.date(byAdding: .day, value: ahead, to: base)
        }
        var month = 0, day = 0
        let parts = w.replacingOccurrences(of: ".", with: "").split(whereSeparator: { $0 == "/" || $0 == " " }).map(String.init)
        guard parts.count == 2 else { return nil }
        if let m = Int(parts[0]), let d = Int(parts[1]) { month = m; day = d }
        else if let m = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].firstIndex(where: { parts[0].hasPrefix($0) }),
                let d = Int(parts[1]) { month = m + 1; day = d }
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        let year = cal.component(.year, from: base)
        guard let d = cal.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        return d < base ? cal.date(byAdding: .year, value: 1, to: d) : d
    }
}

/// Generous task lengths: how long something like it really takes, times `generosity`, so a plan built from them
/// holds up. The AI's estimates get the same padding (see Engine.breakDown).
enum Estimate {
    static let generosity = 1.75

    /// Padded and rounded up to 5 minutes.
    static func padded(_ realistic: Int) -> Int { max(10, Int((Double(realistic) * generosity / 5).rounded(.up)) * 5) }

    /// A guess from the words: "email" is quick, a pset or an essay takes a while, "lectures 11,12,13,14" is four
    /// lectures. Already padded.
    static func minutes(_ title: String, notes: String = "") -> Int {
        let t = (title + " " + notes).lowercased()
        func has(_ words: [String]) -> Bool { words.contains { t.range(of: "\\b\($0)", options: .regularExpression) != nil } }
        // "lectures 11,12,13,14" or "lecture 5,6,7": that many lectures.
        if has(["lecture"]), let r = t.range(of: #"lectures?\s+([\d.,\s-]+)"#, options: .regularExpression) {
            let count = t[r].split(whereSeparator: { !$0.isNumber }).count
            if count > 1 { return padded(count * 30) }
        }
        let realistic: Int
        if has(["final", "exam", "midterm", "study for"]) { realistic = 150 }
        else if has(["pset", "problem set", "homework", "assignment", "practice", "essay", "paper", "memo", "statement", "application", "thesis", "project"]) { realistic = 90 }
        else if has(["review", "read", "lecture", "write", "draft", "study", "notes", "plan"]) { realistic = 45 }
        else if has(["resume", "cv", "edit", "update", "clean", "organize", "move", "sell"]) { realistic = 30 }
        else if has(["email", "reply", "text", "call", "register", "registration", "pay", "book", "schedule", "submit", "sign", "order"]) { realistic = 15 }
        else { realistic = 30 }
        return padded(realistic)
    }
}
