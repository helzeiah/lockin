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
