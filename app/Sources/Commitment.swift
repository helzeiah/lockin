import Foundation

/// How much you can take on today, asked when you plan the day. It sets how big sessions are: tiny steps on a day
/// when starting feels impossible, long unbroken blocks on a day you've got room for them.
enum Commitment: String, CaseIterable, Codable {
    case small, medium, large

    /// The session lengths this level aims for (minutes): tasks longer than the top get cut into even pieces.
    var range: ClosedRange<Int> {
        switch self {
        case .small: return 5...10
        case .medium: return 25...45
        case .large: return 60...90
        }
    }
    var title: String { rawValue.capitalized }
    var blurb: String {
        switch self {
        case .small: return "Tiny 5–10 min steps"
        case .medium: return "25–45 min sessions"
        case .large: return "60–90 min deep blocks"
        }
    }

    /// A task's steps (the AI's breakdown) made into sessions for this level, `total` minutes in all: one after
    /// another, as many as fit under the top of the range together, each named by its first step ("…" when it holds
    /// more). Step lengths are scaled to `total`, so the pieces keep the task's generous length.
    func group(_ steps: [ListTask.Step], total: Int) -> [(task: String, minutes: Int)] {
        let sum = steps.reduce(0) { $0 + max(1, $1.minutes) }
        guard sum > 0 else { return [] }
        let scale = Double(total) / Double(sum)
        var out: [(task: String, minutes: Int, count: Int)] = []
        for s in steps {
            let m = max(1, Int((Double(max(1, s.minutes)) * scale).rounded()))
            if let last = out.last, last.minutes + m <= range.upperBound {
                out[out.count - 1] = (last.task, last.minutes + m, last.count + 1)
            } else {
                out += pieces(m).map { (s.task, $0, 1) }   // a step too long for the level is cut too
            }
        }
        return out.map { ($0.count > 1 ? $0.task + " …" : $0.task, max(5, Int((Double($0.minutes) / 5).rounded()) * 5)) }
    }

    /// A task this long cut into sessions: as few as fit under the top of the range, as even as possible, in
    /// 5-minute steps. A task already short enough stays whole.
    func pieces(_ minutes: Int) -> [Int] {
        guard minutes > range.upperBound else { return [minutes] }
        let n = Int((Double(minutes) / Double(range.upperBound)).rounded(.up))
        let each = max(5, Int((Double(minutes) / Double(n) / 5).rounded()) * 5)
        var out = Array(repeating: min(each, range.upperBound), count: n - 1)
        let rest = minutes - out.reduce(0, +)
        if rest > range.upperBound { out += pieces(rest) } else if rest > 0 { out.append(rest) }
        return out
    }
}

extension Todo {
    /// The whole task a piece belongs to (its name before it was cut up).
    var wholeTask: String { whole ?? task }
    /// How hard a task this long probably is, 1 (easy) to 3 (hard), when you haven't said.
    static func weight(_ minutes: Int) -> Int { minutes >= 60 ? 3 : minutes >= 30 ? 2 : 1 }
}

extension TodoDoc {
    /// One task cut into sessions for this level (see Commitment.pieces). `steps` (the AI's, for small days) name and
    /// size the pieces; otherwise they're "Task (2/4)", and the first is your first step when you've said what it is.
    static func cut(_ t: Todo, _ level: Commitment, steps: [(task: String, minutes: Int)] = [], firstStep: String? = nil) -> [Todo] {
        let names = steps.map(\.task)
        let sizes = steps.isEmpty ? level.pieces(t.left) : steps.map { max(5, $0.minutes) }
        guard sizes.count > 1 else { return [t] }
        let group = t.group ?? t.id
        return sizes.enumerated().map { i, m in
            var p = t
            p.id = i == 0 ? t.id : Todo.newId()
            p.minutes = m; p.spent = 0
            p.group = group; p.whole = t.wholeTask; p.part = i + 1; p.parts = sizes.count
            p.start = i == 0 ? t.start : ""
            p.pinned = i == 0 ? t.pinned : nil
            if i < names.count { p.task = names[i] }
            else if i == 0, let f = firstStep, !f.isEmpty { p.task = "\(t.wholeTask): \(f)" }
            else { p.task = "\(t.wholeTask) (\(i + 1)/\(sizes.count))" }
            return p
        }
    }

    /// Today's open sessions re-cut for a new level: pieces of one task you haven't started are joined back up, then
    /// everything's cut for the level. Finished and started pieces stay as they are; repeats and calendar sessions
    /// aren't touched.
    static func recut(_ items: [Todo], _ level: Commitment, keep: String? = nil) -> [Todo] {
        var out: [Todo] = [], joined: [String: Int] = [:]
        for t in items {
            let loose = !t.isDone && (t.spent ?? 0) == 0 && t.source == nil && t.id != keep
            guard loose else { out.append(t); continue }
            if let g = t.group, let i = joined[g] {   // a later piece: back into the first one
                out[i].minutes += t.minutes
                continue
            }
            var w = t
            if let g = t.group { w.task = t.wholeTask; w.group = nil; w.whole = nil; w.part = nil; w.parts = nil; joined[g] = out.count }
            out.append(w)
        }
        return out.flatMap { t in
            (!t.isDone && (t.spent ?? 0) == 0 && t.source == nil && t.id != keep && t.part == nil) ? cut(t, level) : [t]
        }
    }

    /// Hardest work first while you're fresh: open sessions ordered by how time-sensitive they are (overdue or due
    /// today, then tomorrow, then the rest), then how hard, then how long. Pieces of one task stay in order.
    /// `daysLeft` is when a session's to-do list task is due.
    static func prioritized(_ items: [Todo], daysLeft: (Todo) -> Int?) -> [Todo] {
        func urgency(_ t: Todo) -> Int { daysLeft(t).map { $0 <= 0 ? 0 : $0 == 1 ? 1 : 2 } ?? 2 }
        // A task's pieces sort by the whole task: its total length and its first piece's place.
        var total: [String: Int] = [:]
        for t in items { if let g = t.group { total[g, default: 0] += t.minutes } }
        func key(_ t: Todo) -> (Int, Int, Int) {
            let length = t.group.flatMap { total[$0] } ?? t.minutes
            return (urgency(t), -(t.effort ?? Todo.weight(length)), -length)
        }
        let indexed = items.enumerated().map { ($0.offset, $0.element) }
        return indexed.sorted { a, b in
            let ka = key(a.1), kb = key(b.1)
            if ka != kb { return ka < kb }
            if let ga = a.1.group, ga == b.1.group { return (a.1.part ?? 0) < (b.1.part ?? 0) }
            return a.0 < b.0
        }.map(\.1)
    }
}
