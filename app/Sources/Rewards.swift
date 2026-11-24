import SwiftUI

// Levels, badges and skins, all worked out from log.jsonl, so there's nothing extra to store or sync.
//   XP: 1 per focused minute, +10 for a session you finished, +25 for each day that counted.
//   Levels get steeper as you go (level L starts at 50·L·(L−1) XP). Skins unlock by level.

struct Badge: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let how: String
    var earned: Date? = nil
}

struct Skin: Identifiable, Hashable {
    let id: String
    let name: String
    let level: Int
    let color: Color
    static let all: [Skin] = [
        Skin(id: "green", name: "Lockin green", level: 1, color: Color(red: 0.21, green: 0.84, blue: 0.48)),
        Skin(id: "ocean", name: "Ocean", level: 3, color: Color(red: 0.25, green: 0.66, blue: 1.0)),
        Skin(id: "sunset", name: "Sunset", level: 5, color: Color(red: 1.0, green: 0.55, blue: 0.25)),
        Skin(id: "violet", name: "Violet", level: 8, color: Color(red: 0.66, green: 0.48, blue: 1.0)),
        Skin(id: "rose", name: "Rose", level: 10, color: Color(red: 1.0, green: 0.42, blue: 0.62)),
        Skin(id: "gold", name: "Gold", level: 12, color: Color(red: 1.0, green: 0.80, blue: 0.25)),
        Skin(id: "ice", name: "Ice", level: 16, color: Color(red: 0.62, green: 0.92, blue: 1.0)),
    ]
    static var current: Skin {
        let id = UserDefaults.standard.string(forKey: "skin") ?? "green"
        return all.first { $0.id == id } ?? all[0]
    }
}

struct Rewards {
    var xp = 0
    var badges: [Badge] = []

    static func levelStart(_ level: Int) -> Int { 50 * level * (level - 1) }
    var level: Int { var l = 1; while xp >= Rewards.levelStart(l + 1) { l += 1 }; return l }
    var intoLevel: Int { xp - Rewards.levelStart(level) }
    var levelSize: Int { Rewards.levelStart(level + 1) - Rewards.levelStart(level) }
    var title: String { Rewards.title(level) }
    var earnedCount: Int { badges.filter { $0.earned != nil }.count }

    static func title(_ level: Int) -> String {
        switch level {
        case ..<3: return "Rookie"
        case ..<5: return "Focused"
        case ..<8: return "Locked In"
        case ..<12: return "Deep Worker"
        case ..<16: return "Machine"
        case ..<20: return "Untouchable"
        default: return "Legend"
        }
    }

    static func load(goal: Int = 25) -> Rewards {
        var r = Rewards()
        let parse = DateFormatter(); parse.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        var dayMinutes: [Date: Int] = [:], kept = 0, totalMin = 0, firstSession: Date?
        var earned: [String: Date] = [:]
        func earn(_ id: String, _ at: Date) { if earned[id] == nil { earned[id] = at } }
        var gateDays: [Date: Bool] = [:]       // day -> passed without skipping
        let text = (try? String(contentsOf: Paths.log, encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n") {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let ts = (obj["ts"] as? String).flatMap(parse.date(from:)) else { continue }
            let day = Stats.day(of: ts)
            switch obj["type"] as? String {
            case "block_end":
                let m = obj["focused_min"] as? Int ?? 0
                let done = obj["completed"] as? Bool == true
                r.xp += m + (done ? 10 : 0)
                totalMin += m
                let before = dayMinutes[day, default: 0]
                dayMinutes[day] = before + m
                if before < goal && before + m >= goal { r.xp += 25 }
                guard done else { break }
                kept += 1
                firstSession = firstSession ?? ts
                earn("first", ts)
                if kept >= 10 { earn("kept10", ts) }
                if kept >= 50 { earn("kept50", ts) }
                if kept >= 200 { earn("kept200", ts) }
                if m >= 120 { earn("marathon", ts) }
                let hour = Calendar.current.component(.hour, from: ts.addingTimeInterval(-Double(m * 60)))
                if hour < 8 && hour >= 4 { earn("early", ts) }
                if hour >= 22 || hour < 4 { earn("night", ts) }
                if totalMin >= 600 { earn("hours10", ts) }
                if totalMin >= 6000 { earn("hours100", ts) }
                if dayMinutes[day, default: 0] >= 240 { earn("bigday", ts) }
            case "perfect_day": earn("perfect", ts)
            case "gate_passed": if gateDays[day] == nil { gateDays[day] = true }
            case "gate_skipped": gateDays[day] = false
            default: break
            }
        }
        // Streak badges: days in a row that hit the goal.
        let cal = Calendar.current
        var run = 0, prev: Date?
        for d in dayMinutes.keys.sorted() where dayMinutes[d, default: 0] >= goal {
            run = (prev.map { cal.date(byAdding: .day, value: 1, to: $0) == d } ?? false) ? run + 1 : 1
            prev = d
            for (n, id) in [(3, "streak3"), (7, "streak7"), (30, "streak30"), (100, "streak100")] where run >= n { earn(id, d) }
        }
        // Seven mornings in a row on the morning screen without skipping.
        var gateRun = 0, gatePrev: Date?
        for d in gateDays.keys.sorted() {
            guard gateDays[d] == true else { gateRun = 0; gatePrev = nil; continue }
            gateRun = (gatePrev.map { cal.date(byAdding: .day, value: 1, to: $0) == d } ?? false) ? gateRun + 1 : 1
            gatePrev = d
            if gateRun >= 7 { earn("mornings7", d) }
        }
        r.badges = Rewards.catalog.map { var b = $0; b.earned = earned[b.id]; return b }
        return r
    }

    static let catalog: [Badge] = [
        Badge(id: "first", name: "First lock-in", icon: "lock.fill", how: "Finish your first session"),
        Badge(id: "streak3", name: "Habit forming", icon: "flame", how: "3-day streak"),
        Badge(id: "streak7", name: "Full week", icon: "flame.fill", how: "7-day streak"),
        Badge(id: "streak30", name: "Month strong", icon: "flame.circle.fill", how: "30-day streak"),
        Badge(id: "streak100", name: "Centurion", icon: "crown.fill", how: "100-day streak"),
        Badge(id: "kept10", name: "Ten kept", icon: "checkmark.seal", how: "Finish 10 sessions"),
        Badge(id: "kept50", name: "Fifty kept", icon: "checkmark.seal.fill", how: "Finish 50 sessions"),
        Badge(id: "kept200", name: "Relentless", icon: "bolt.fill", how: "Finish 200 sessions"),
        Badge(id: "hours10", name: "10 hours", icon: "clock", how: "10 hours focused"),
        Badge(id: "hours100", name: "100 hours", icon: "clock.fill", how: "100 hours focused"),
        Badge(id: "marathon", name: "Marathon", icon: "figure.run", how: "Finish a 2-hour session"),
        Badge(id: "bigday", name: "Big day", icon: "sun.max.fill", how: "4 hours focused in one day"),
        Badge(id: "early", name: "Early bird", icon: "sunrise.fill", how: "Lock in before 8 AM"),
        Badge(id: "night", name: "Night owl", icon: "moon.stars.fill", how: "Lock in after 10 PM"),
        Badge(id: "perfect", name: "Perfect day", icon: "star.fill", how: "Finish every session you planned"),
        Badge(id: "mornings7", name: "No excuses", icon: "sunrise.circle.fill", how: "7 mornings in a row, no skips"),
    ]
}

// MARK: - Views

/// Level, title and the bar to the next level.
struct LevelCard: View {
    var r: Rewards
    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.16))
                Text("\(r.level)").font(Theme.number(24, .bold)).foregroundStyle(Theme.accent)
            }
            .frame(width: 56, height: 56)
            .shadow(color: r.level >= 10 ? Theme.accent.opacity(0.6) : .clear, radius: 10)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(r.title).font(.system(size: 17, weight: .bold))
                    Text("Level \(r.level)").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(r.intoLevel) / \(r.levelSize) XP").font(Theme.number(12, .medium)).foregroundStyle(.secondary).monospacedDigit()
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(Theme.accent).frame(width: max(6, g.size.width * Double(r.intoLevel) / Double(max(1, r.levelSize))))
                    }
                }
                .frame(height: 7)
                let next = (r.level + 1...r.level + 40).first { Rewards.title($0) != r.title }
                Text("\(r.xp) XP total · \(r.earnedCount) of \(r.badges.count) badges" + (next.map { " · \(Rewards.title($0)) at level \($0)" } ?? ""))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
    }
}

struct BadgeGrid: View {
    var badges: [Badge]
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(badges) { b in
                let on = b.earned != nil
                VStack(spacing: 6) {
                    Image(systemName: on ? b.icon : "lock.fill").font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(on ? Theme.accent : Color.secondary.opacity(0.5))
                        .shadow(color: on ? Theme.accent.opacity(0.5) : .clear, radius: 6)
                        .frame(height: 26)
                    Text(b.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(on ? .primary : .secondary)
                    Text(on ? b.earned!.formatted(.dateTime.month(.abbreviated).day()) : b.how)
                        .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(2).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).frame(height: 92).padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? Theme.accent.opacity(0.08) : Theme.card))
                .help(b.how)
            }
        }
    }
}

/// Pick a skin; locked ones show the level that unlocks them.
struct SkinPicker: View {
    var level: Int
    @State private var current = Skin.current.id
    var body: some View {
        HStack(spacing: 10) {
            ForEach(Skin.all) { s in
                let open = level >= s.level
                Button {
                    guard open else { return }
                    UserDefaults.standard.set(s.id, forKey: "skin"); current = s.id
                    Engine.shared.objectWillChange.send()
                } label: {
                    VStack(spacing: 5) {
                        ZStack {
                            Circle().fill(open ? s.color : s.color.opacity(0.18)).frame(width: 30, height: 30)
                            if !open { Image(systemName: "lock.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary) }
                            if current == s.id { Circle().strokeBorder(Color.primary, lineWidth: 2).frame(width: 36, height: 36) }
                        }
                        .frame(width: 38, height: 38)
                        Text(open ? s.name : "Lvl \(s.level)").font(.system(size: 10)).foregroundStyle(open ? .secondary : .tertiary).lineLimit(1)
                    }
                    .frame(width: 70)
                }
                .buttonStyle(.plain).help(open ? s.name : "Unlocks at level \(s.level)")
            }
        }
    }
}
