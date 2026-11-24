import Foundation

/// A task typed into the plan box: what it is, how long, and when (24h "HH:MM"), if you said.
struct ParsedTask: Equatable {
    var task: String
    var minutes: Int?
    var start: String?
}

/// Turns one line of planning into tasks, no AI involved:
///   "leetcode 45, co-op web ui 90 at 2pm, essay intro 30m @ 9:15"
/// Tasks are split on new lines, commas, semicolons and bullets. A length is "45", "45m", "45 min", "1.5h", "1h30"
/// or "2 hours"; a time is "at 2", "at 2:30pm", "@ 14:00", "9:15am" or "3pm". "At 2" with no am/pm means the
/// afternoon (1-7 become 1-7 PM). Pure Foundation, so tests compile it on its own.
enum PlanParser {
    static func parse(_ text: String) -> [ParsedTask] {
        text.components(separatedBy: CharacterSet(charactersIn: "\n,;•")).compactMap(parseOne)
    }

    /// Words before a bare number that make it part of the task ("chapter 15", "pset 4"), not a length.
    private static let countWords: Set<String> = ["chapter", "ch", "pset", "problem", "problems", "hw", "homework", "lab",
                                                  "lecture", "week", "unit", "part", "section", "question", "questions", "q",
                                                  "page", "pages", "p", "lesson", "module", "day", "level", "round", "set",
                                                  "exercise", "exercises", "ex", "task", "issue", "pr", "ticket", "#", "no"]

    static func parseOne(_ raw: String) -> ParsedTask? {
        var s = " " + raw.trimmingCharacters(in: .whitespacesAndNewlines) + " "
        // list markers: "- ", "* ", "1. ", "2) "
        s = replace(s, #"^\s*(?:[-*]|\d{1,2}[.)])\s+"#, with: " ")
        var start: String?
        var minutes: Int?

        // Times first, so "2pm" isn't read as a length.
        let timePatterns = [
            #"(?i)(?:\bat|@)\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.|a|p)?\b"#,   // at 2, at 2:30pm, @ 14:00
            #"(?i)\b(\d{1,2}):(\d{2})\s*(am|pm|a\.m\.|p\.m\.)?(?=\s|$)"#,                 // 9:15, 9:15am
            #"(?i)\b(\d{1,2})\s*(am|pm|a\.m\.|p\.m\.)(?=\s|$)"#,                          // 3pm
        ]
        for (i, p) in timePatterns.enumerated() where start == nil {
            guard let m = firstMatch(p, in: s) else { continue }
            let h = Int(group(m, 1, s) ?? "") ?? -1
            let min = i == 2 ? 0 : Int(group(m, 2, s) ?? "0") ?? 0
            let ampm = (group(m, i == 2 ? 2 : 3, s) ?? "").lowercased().replacingOccurrences(of: ".", with: "")
            if let t = clock(h, min, ampm) {
                start = t
                s = (s as NSString).replacingCharacters(in: m.range, with: " ")
            }
        }

        // Lengths: hours (with optional minutes), then minutes with a unit, then a bare trailing number.
        if let m = firstMatch(#"(?i)\b(\d+(?:\.\d+)?)\s*(?:h|hr|hrs|hour|hours)(?![a-z])(?:\s*(\d{1,2})\s*(?:m|min|mins|minutes)?\b)?"#, in: s) {
            let h = Double(group(m, 1, s) ?? "") ?? 0
            let extra = Int(group(m, 2, s) ?? "") ?? 0
            minutes = Int((h * 60).rounded()) + extra
            s = (s as NSString).replacingCharacters(in: m.range, with: " ")
        } else if let m = firstMatch(#"(?i)\b(\d{1,3})\s*(?:m|min|mins|minute|minutes)\b"#, in: s) {
            minutes = Int(group(m, 1, s) ?? "")
            s = (s as NSString).replacingCharacters(in: m.range, with: " ")
        } else if let m = firstMatch(#"(?:^|\s)(\S+)\s+(\d{2,3})\s*$"#, in: s),
                  let n = Int(group(m, 2, s) ?? ""), n >= 10, n <= 300, n % 5 == 0,
                  !countWords.contains((group(m, 1, s) ?? "").lowercased()) {
            minutes = n
            let r = m.range(at: 2)
            s = (s as NSString).replacingCharacters(in: r, with: " ")
        }

        // What's left is the task. Drop joining words left at the edges ("for", "from", "-", ":").
        var task = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        for _ in 0..<3 {
            task = replace(task, #"(?i)^(?:for|from|at|-|–|—|:)\s+|\s+(?:for|from|at|-|–|—|:)$"#, with: "")
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–—:")))
        }
        guard !task.isEmpty else { return nil }
        if let m = minutes { minutes = min(max(m, 5), 480) }
        return ParsedTask(task: String(task.prefix(120)), minutes: minutes, start: start)
    }

    /// "HH:MM", reading a bare 1-7 as the afternoon. nil for impossible times.
    static func clock(_ h: Int, _ m: Int, _ ampm: String) -> String? {
        guard (0...59).contains(m) else { return nil }
        var hour = h
        if ampm.hasPrefix("p") { guard (1...12).contains(h) else { return nil }; hour = h == 12 ? 12 : h + 12 }
        else if ampm.hasPrefix("a") { guard (1...12).contains(h) else { return nil }; hour = h == 12 ? 0 : h }
        else {
            guard (0...23).contains(h) else { return nil }
            if (1...7).contains(h) { hour = h + 12 }
        }
        return String(format: "%02d:%02d", hour, m)
    }

    // MARK: regex helpers
    private static func firstMatch(_ pattern: String, in s: String) -> NSTextCheckingResult? {
        (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    }
    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String? {
        guard i < m.numberOfRanges, let r = Range(m.range(at: i), in: s) else { return nil }
        return String(s[r])
    }
    private static func replace(_ s: String, _ pattern: String, with t: String) -> String {
        s.replacingOccurrences(of: pattern, with: t, options: .regularExpression)
    }
}

// MARK: - Edits without AI

/// One thing typed into the plan box: a new task, or an edit to the plan.
///   "done leetcode" / "leetcode done"      mark it done
///   "remove emails" / "drop" / "cancel"     take it off the plan
///   "move essay to 3pm" / "push essay to 4" change its time
///   "push essay to tomorrow"                move it to tomorrow
///   "make essay 30 min"                     change its length
///   "free at 8" / "starting at 3pm"         re-time what's left, starting then
/// Anything else is a new task. Which task an edit means is decided against the plan (by its words).
enum PlanCommand: Equatable {
    case add(ParsedTask)
    case done(String)
    case remove(String)
    case move(String, start: String)
    case tomorrow(String)
    case resize(String, minutes: Int)
    case startFrom(String)
}

extension PlanParser {
    static func commands(_ text: String) -> [PlanCommand] {
        text.components(separatedBy: CharacterSet(charactersIn: "\n,;•")).compactMap(command)
    }

    static func command(_ raw: String) -> PlanCommand? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        func m(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let r = re.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) else { return nil }
            return (0..<r.numberOfRanges).map { i in Range(r.range(at: i), in: lower).map { String(lower[$0]) } ?? "" }
        }
        func q(_ text: String) -> String {
            text.replacingOccurrences(of: #"^(?:the|my)\s+"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }
        if let g = m(#"^(?:i'?m\s+)?(?:free|available|back|starting|start)\s+(?:at|from|after|around)\s+(.+)$"#), let t = time(g[1]) {
            return .startFrom(t)
        }
        if let g = m(#"^(?:done|finished|did|completed|complete)\s+(?:with\s+)?(.+)$"#) { return .done(q(g[1])) }
        if let g = m(#"^(.+?)\s+(?:is\s+)?(?:done|finished|completed|complete)$"#) { return .done(q(g[1])) }
        if let g = m(#"^(?:remove|drop|delete|cancel|scrap|skip)\s+(.+)$"#) { return .remove(q(g[1])) }
        if let g = m(#"^(?:move|push|bump|punt|save)\s+(.+?)\s+(?:to|for|till|until)\s+tomorrow$"#) { return .tomorrow(q(g[1])) }
        if let g = m(#"^(?:move|push|bump|reschedule|shift)\s+(.+?)\s+(?:to|at|till|until)\s+(.+)$"#), let t = time(g[2]) {
            return .move(q(g[1]), start: t)
        }
        if let g = m(#"^(?:make|change|set)\s+(.+?)\s+(?:to\s+)?(\d+(?:\.\d+)?)\s*(m|min|mins|minutes|h|hr|hrs|hour|hours)$"#),
           let n = Double(g[2]) {
            let minutes = g[3].hasPrefix("h") ? Int((n * 60).rounded()) : Int(n)
            return .resize(q(g[1]), minutes: min(max(minutes, 5), 480))
        }
        return parseOne(s).map(PlanCommand.add)
    }

    /// "8", "8pm", "8:30", "14:00" as "HH:MM" (a bare 1-7 means the afternoon).
    static func time(_ text: String) -> String? {
        parseOne("t at " + text.trimmingCharacters(in: .whitespaces))?.start
    }
}
