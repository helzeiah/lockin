import SwiftUI

// Levels, badges and skins, all worked out from log.jsonl, so there's nothing extra to store or sync.
//   XP only counts real work: 1 per active minute (on task, typing, clicking or scrolling), half for away time on
//   offline-ok tasks, +10 for a finished session that was mostly active, +25 for each day real work hit the goal.
//   Sessions must carry a valid signature (Integrity), so hand-edited log lines earn nothing.
//   Levels get steeper as you go (level L starts at 50·L·(L−1) XP). Skins unlock by level.

struct Badge: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let how: String
    var earned: Date? = nil
}

enum SkinPattern: String { case none, aurora, carbon, diamond, circuit, embers, prism, hazard, vault }

struct Skin: Identifiable, Hashable {
    let id: String
    let name: String
    let level: Int
    let colors: [Color]
    var pattern: SkinPattern = .none
    var color: Color { colors[0] }
    var fancy: Bool { pattern != .none }

    static let all: [Skin] = [
        Skin(id: "green", name: "Lockin green", level: 1, colors: [Color(red: 0.21, green: 0.84, blue: 0.48)]),
        Skin(id: "ocean", name: "Ocean", level: 3, colors: [Color(red: 0.25, green: 0.66, blue: 1.0)]),
        Skin(id: "sunset", name: "Sunset", level: 5, colors: [Color(red: 1.0, green: 0.55, blue: 0.25)]),
        Skin(id: "lockdown", name: "Lockdown", level: 6, colors: [Color(red: 1.0, green: 0.78, blue: 0.1), Color(red: 1.0, green: 0.6, blue: 0.05)], pattern: .hazard),
        Skin(id: "violet", name: "Violet", level: 7, colors: [Color(red: 0.66, green: 0.48, blue: 1.0)]),
        Skin(id: "aurora", name: "Aurora", level: 9, colors: [Color(red: 0.25, green: 0.95, blue: 0.65), Color(red: 0.2, green: 0.75, blue: 1.0), Color(red: 0.72, green: 0.45, blue: 1.0)], pattern: .aurora),
        Skin(id: "carbon", name: "Carbon", level: 11, colors: [Color(red: 0.86, green: 0.88, blue: 0.92), Color(red: 0.55, green: 0.58, blue: 0.64)], pattern: .carbon),
        Skin(id: "bullion", name: "Bullion", level: 13, colors: [Color(red: 1.0, green: 0.86, blue: 0.4), Color(red: 0.85, green: 0.6, blue: 0.15)], pattern: .diamond),
        Skin(id: "vault", name: "Vault", level: 14, colors: [Color(red: 0.85, green: 0.89, blue: 0.94), Color(red: 0.5, green: 0.56, blue: 0.64)], pattern: .vault),
        Skin(id: "circuit", name: "Circuit", level: 15, colors: [Color(red: 0.2, green: 1.0, blue: 0.95), Color(red: 0.15, green: 0.6, blue: 1.0)], pattern: .circuit),
        Skin(id: "inferno", name: "Inferno", level: 18, colors: [Color(red: 1.0, green: 0.85, blue: 0.3), Color(red: 1.0, green: 0.45, blue: 0.1), Color(red: 0.9, green: 0.15, blue: 0.2)], pattern: .embers),
        Skin(id: "prism", name: "Prism", level: 20, colors: [Color(red: 1.0, green: 0.45, blue: 0.55), Color(red: 1.0, green: 0.8, blue: 0.35), Color(red: 0.4, green: 1.0, blue: 0.6), Color(red: 0.35, green: 0.7, blue: 1.0), Color(red: 0.75, green: 0.5, blue: 1.0)], pattern: .prism),
    ]
    /// The equipped skin, if you've unlocked it (your level is remembered whenever rewards are worked out).
    static var current: Skin {
        let id = UserDefaults.standard.string(forKey: "skin") ?? "green"
        let level = max(1, UserDefaults.standard.integer(forKey: "rewardLevel"))
        guard let s = all.first(where: { $0.id == id }), s.level <= level else { return all[0] }
        return s
    }
    @MainActor static func equip(_ id: String) {
        UserDefaults.standard.set(id, forKey: "skin")
        Engine.shared.objectWillChange.send()
    }
    static func noteLevel(_ level: Int) { UserDefaults.standard.set(level, forKey: "rewardLevel") }
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
                guard Integrity.valid(obj) else { break }      // unsigned or edited: no XP
                let active = obj["active_min"] as? Int ?? 0, offline = obj["offline_min"] as? Int ?? 0
                let m = active + offline / 2                   // what this session proved
                let planned = obj["planned_min"] as? Int ?? m
                let done = obj["completed"] as? Bool == true && m >= max(5, planned / 2)
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
        Skin.noteLevel(r.level)
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

// MARK: - Level emblems

/// The rank emblem. Each title band adds something, so a rookie and a legend look nothing alike:
///   Rookie: open padlock · Focused: closed padlock · Locked In: padlock on a shield
///   Deep Worker: a chain wrapped across the shield · Machine: chains wrapped around it in an X and across the lock
///   Untouchable: sparks and the strongest glow · Legend: all gold, a crown and laurels
/// The shield is the same size at every rank; only what's added changes.
struct LevelEmblem: View {
    var level: Int
    var size: CGFloat = 56
    var pips = false

    static func band(_ level: Int) -> Int {
        switch level { case ..<3: return 0; case ..<5: return 1; case ..<8: return 2; case ..<12: return 3; case ..<16: return 4; case ..<20: return 5; default: return 6 }
    }
    static let bandStarts = [1, 3, 5, 8, 12, 16, 20]
    static let gold = Color(red: 1.0, green: 0.8, blue: 0.28)

    var body: some View {
        let b = LevelEmblem.band(level)
        let metal: Color = b >= 6 ? LevelEmblem.gold : Theme.accent
        let s = size
        VStack(spacing: s * 0.06) {
            ZStack {
                if b >= 6 {   // Legend: a soft gold glow, laurels on both sides
                    RadialGradient(colors: [metal.opacity(0.26), .clear], center: .center, startRadius: 1, endRadius: s * 0.7)
                        .frame(width: s * 1.6, height: s * 1.4)
                    HStack(spacing: s * 0.74) { Image(systemName: "laurel.leading"); Image(systemName: "laurel.trailing") }
                        .font(.system(size: s * 0.58, weight: .medium))
                        .foregroundStyle(LinearGradient(colors: [metal, metal.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                        .offset(y: s * 0.02)
                }
                if b >= 2 {   // the shield: dark face, metal rim
                    Image(systemName: "shield.fill").font(.system(size: s * 0.66)).foregroundStyle(Color(white: 0.06))
                    Image(systemName: "shield").font(.system(size: s * 0.66, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: [metal, metal.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                }
                Padlock(size: s * (b >= 2 ? 0.3 : 0.42), color: b >= 6 ? metal : nil, open: b == 0)
                    .offset(y: b >= 2 ? -s * 0.03 : 0)
                if b == 3 {   // one chain, wrapped diagonally across the shield and around its edges
                    ChainStrand(color: metal, size: s, from: CGPoint(x: 0.4, y: -0.17), to: CGPoint(x: -0.4, y: 0.21))
                }
                if b >= 4 {   // chains wrapped around it: an X, and a band across the lock
                    ChainStrand(color: metal, size: s, from: CGPoint(x: -0.4, y: -0.05), to: CGPoint(x: 0.38, y: 0.28))
                    ChainStrand(color: metal, size: s, from: CGPoint(x: 0.4, y: -0.05), to: CGPoint(x: -0.38, y: 0.28))
                    ChainStrand(color: metal, size: s, from: CGPoint(x: -0.42, y: 0.04), to: CGPoint(x: 0.42, y: 0.04))
                }
                if b == 5 {   // Untouchable: sparks at the top corners
                    ForEach([-1.0, 1.0], id: \.self) { side in
                        Image(systemName: "sparkle").font(.system(size: s * 0.15, weight: .bold)).foregroundStyle(.white)
                            .shadow(color: metal, radius: s * 0.05).offset(x: side * s * 0.37, y: -s * 0.37)
                    }
                }
                if b >= 6 {
                    Image(systemName: "crown.fill").font(.system(size: s * 0.24))
                        .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.92, blue: 0.6), metal], startPoint: .top, endPoint: .bottom))
                        .shadow(color: metal.opacity(0.7), radius: s * 0.05).offset(y: -s * 0.43)
                }
            }
            .frame(width: s * (b >= 6 ? 1.65 : 1.15), height: s * 1.08)
            .shadow(color: metal.opacity([0, 0, 0.15, 0.3, 0.5, 0.7, 0.45][b]), radius: s * [0, 0, 0.06, 0.1, 0.15, 0.2, 0.16][b])
            if pips {
                let start = LevelEmblem.bandStarts[b]
                let count = b < 6 ? LevelEmblem.bandStarts[b + 1] - start : 5
                HStack(spacing: s * 0.05) {
                    ForEach(0..<count, id: \.self) { i in
                        Circle().fill(i <= level - start ? metal : Color.primary.opacity(0.15)).frame(width: s * 0.07, height: s * 0.07)
                    }
                }
            }
        }
        .help("Level \(level) · \(Rewards.title(level))")
    }
}

/// The padlock: silver (gold for Legend, gray and open for Rookie), with a keyhole.
struct Padlock: View {
    var size: CGFloat
    var color: Color? = nil
    var open = false
    var body: some View {
        let face: AnyShapeStyle = open ? AnyShapeStyle(Color.gray)
            : color.map { c in AnyShapeStyle(LinearGradient(colors: [Color(red: 1, green: 0.93, blue: 0.62), c], startPoint: .top, endPoint: .bottom)) }
            ?? AnyShapeStyle(LinearGradient(colors: [.white, Color(white: 0.7)], startPoint: .top, endPoint: .bottom))
        ZStack {
            Image(systemName: open ? "lock.open.fill" : "lock.fill").font(.system(size: size, weight: .bold)).foregroundStyle(face)
            if !open { Capsule().fill(Color.black.opacity(0.5)).frame(width: size * 0.11, height: size * 0.24).offset(y: size * 0.2) }
        }
        .shadow(color: .black.opacity(0.55), radius: size * 0.06, y: size * 0.03)
    }
}

/// A chain from one point to another (in units of the emblem size): small links that interlock, face-on links over
/// edge-on ones.
struct ChainStrand: View {
    var color: Color
    var size: CGFloat
    var from: CGPoint
    var to: CGPoint
    var body: some View {
        let dx = to.x - from.x, dy = to.y - from.y
        let n = max(2, Int((sqrt(dx * dx + dy * dy) / 0.086).rounded()))
        let angle = atan2(Double(dy), Double(dx))
        let point = { (i: Int) -> CGSize in
            let t = (CGFloat(i) + 0.5) / CGFloat(n)
            return CGSize(width: (from.x + dx * t) * size, height: (from.y + dy * t) * size)
        }
        let shade = LinearGradient(colors: [color, color.opacity(0.72)], startPoint: .top, endPoint: .bottom)
        ZStack {
            ForEach(Array(stride(from: 1, to: n, by: 2)), id: \.self) { i in      // edge-on links, behind
                Capsule().fill(shade).overlay(Capsule().fill(Color.black.opacity(0.22)))
                    .frame(width: size * 0.13, height: size * 0.04)
                    .rotationEffect(.radians(angle)).offset(point(i))
            }
            ForEach(Array(stride(from: 0, to: n, by: 2)), id: \.self) { i in      // face-on links, on top
                Capsule().stroke(shade, lineWidth: size * 0.03)
                    .frame(width: size * 0.15, height: size * 0.085)
                    .rotationEffect(.radians(angle)).offset(point(i))
            }
        }
        .shadow(color: .black.opacity(0.6), radius: max(0.5, size * 0.015))
    }
}

// MARK: - Streak fire

/// A flame silhouette: a round belly and a curling tip. `sway` moves the tip sideways, `stretch` makes it taller,
/// `lean` tilts the body. Animating these out of step is what makes it look alive.
struct FlameShape: Shape {
    var sway: CGFloat = 0
    var stretch: CGFloat = 1
    var lean: CGFloat = 0
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        let top = r.maxY - h * stretch
        let tip = CGPoint(x: r.midX + sway * w, y: top)
        let bottom = CGPoint(x: r.midX + lean * w * 0.3, y: r.maxY)
        var p = Path()
        p.move(to: bottom)
        p.addCurve(to: CGPoint(x: r.minX + w * 0.04 + lean * w, y: r.maxY - h * 0.42),
                   control1: CGPoint(x: bottom.x - w * 0.46, y: r.maxY),
                   control2: CGPoint(x: r.minX - w * 0.04 + lean * w, y: r.maxY - h * 0.2))
        p.addCurve(to: tip,
                   control1: CGPoint(x: r.minX + w * 0.1 + lean * w, y: r.maxY - h * 0.66),
                   control2: CGPoint(x: tip.x - w * 0.16, y: top + h * 0.3))
        p.addCurve(to: CGPoint(x: r.maxX - w * 0.04 + lean * w, y: r.maxY - h * 0.4),
                   control1: CGPoint(x: tip.x + w * 0.1, y: top + h * 0.22),
                   control2: CGPoint(x: r.maxX - w * 0.02 + lean * w, y: r.maxY - h * 0.62))
        p.addCurve(to: bottom,
                   control1: CGPoint(x: r.maxX + w * 0.04 + lean * w, y: r.maxY - h * 0.18),
                   control2: CGPoint(x: bottom.x + w * 0.46, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// How the fire looks at a streak length: colors, and how hard it burns (0 = just lit ... 6 = a year).
struct FireStyle {
    var outer: [Color], mid: [Color], core: [Color], glow: Color, ember: Color
    var power: Int
    var prism = false

    static func of(_ streak: Int) -> FireStyle {
        func c(_ hex: Int) -> Color { Color(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255) }
        switch streak {
        case 365...:   // a year: prism fire, cycling through every color
            return FireStyle(outer: [c(0xFF3B6B), c(0xFFB020)], mid: [c(0x36E0A0), c(0x2CA8FF)], core: [.white, c(0xF2E6FF)], glow: c(0xFF6BD5), ember: .white, power: 6, prism: true)
        case 200...:   // emerald
            return FireStyle(outer: [c(0x00A86B), c(0x19E68C)], mid: [c(0x4DFFB0), c(0xB8FFDF)], core: [.white, c(0xE6FFF4)], glow: c(0x19E68C), ember: c(0xCFFFE9), power: 5)
        case 100...:   // violet
            return FireStyle(outer: [c(0x6A0DFF), c(0xB23BFF)], mid: [c(0xD45CFF), c(0xFF8DF0)], core: [.white, c(0xFFE0FB)], glow: c(0xB23BFF), ember: c(0xF5CCFF), power: 4)
        case 60...:    // blue
            return FireStyle(outer: [c(0x0B3DFF), c(0x1E8BFF)], mid: [c(0x25B4FF), c(0x7FE3FF)], core: [.white, c(0xD6F6FF)], glow: c(0x2C8CFF), ember: c(0xCDEFFF), power: 3)
        case 30...:    // inferno: orange-red, white-hot core
            return FireStyle(outer: [c(0xE8160F), c(0xFF5A00)], mid: [c(0xFF7A00), c(0xFFC400)], core: [.white, c(0xFFF2A8)], glow: c(0xFF5A0D), ember: c(0xFFE08A), power: 2)
        case 7...:     // burning
            return FireStyle(outer: [c(0xFF4D14), c(0xFF8F00)], mid: [c(0xFF9E00), c(0xFFD11F)], core: [c(0xFFF5B8), c(0xFFE066)], glow: c(0xFF6A0D), ember: c(0xFFC74D), power: 1)
        default:       // just lit
            return FireStyle(outer: [c(0xFF4D14), c(0xFF8F00)], mid: [c(0xFF9E00), c(0xFFD11F)], core: [c(0xFFF5B8), c(0xFFE066)], glow: c(0xFF6A0D), ember: c(0xFFC74D), power: 0)
        }
    }
}

/// The streak flame. Out (gray) at 0, smoldering at 1-2, lit at 3, burning from a week; past a month it turns into
/// an inferno, then blue at 60 days, violet at 100, emerald at 200 and prism fire at a year, fiercer each time.
struct StreakFire: View {
    var streak: Int
    var size: CGFloat = 22
    var fixedTime: Double? = nil      // render one frame (previews and screenshots) instead of animating

    var body: some View {
        Group {
            if streak < 3 { unlit }
            else if let t = fixedTime { fire(t) }
            else { TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in fire(ctx.date.timeIntervalSinceReferenceDate) } }
        }
        .frame(width: size, height: size)
        .help(streak == 0 ? "No streak. Hit today's goal to light it." : streak < 3 ? "\(streak)-day streak. 3 days lights the fire." : "\(streak)-day streak")
    }

    private var unlit: some View {
        ZStack(alignment: .bottom) {
            FlameShape().stroke(Color.gray.opacity(streak == 0 ? 0.45 : 0.6), style: StrokeStyle(lineWidth: max(1, size * 0.07), lineJoin: .round))
                .frame(width: size * 0.62, height: size * 0.84)
            if streak > 0 {
                Circle().fill(Color(red: 1, green: 0.45, blue: 0.1)).frame(width: size * 0.16, height: size * 0.16)
                    .shadow(color: .orange, radius: size * 0.12).padding(.bottom, size * 0.12)
            }
        }
        .frame(width: size, height: size, alignment: .bottom)
    }

    private func fire(_ time: Double) -> some View {
        let st = FireStyle.of(streak), p = st.power
        let amp: CGFloat = [0.6, 1, 1.25, 1.35, 1.45, 1.55, 1.65][p]
        let t = time * [1, 1, 1.25, 1.35, 1.45, 1.55, 1.65][p]          // fiercer fires flicker faster
        let s1 = CGFloat(sin(t * 2.4)), s2 = CGFloat(sin(t * 5.3 + 1.1)), s3 = CGFloat(sin(t * 8.9 + 0.3)), s4 = CGFloat(sin(t * 3.7 + 2.2))
        let w = size * (p >= 2 ? 0.66 : 0.74), h = size * 0.96
        let outer = LinearGradient(colors: st.outer, startPoint: .bottom, endPoint: .top)
        let tongues = p >= 4 ? 3 : p >= 2 ? 2 : p == 1 ? 1 : 0
        return ZStack(alignment: .bottom) {
            if p >= 1 {
                Embers(t: t, count: [0, 6, 10, 12, 14, 16, 20][p], color: st.ember)
                    .frame(width: size * 1.15, height: size * 1.6).offset(y: -size * 0.35)
            }
            ForEach(0..<tongues, id: \.self) { k in        // tongues of flame breaking off and rising
                let life = CGFloat((t * 0.85 + Double(k) / Double(max(1, tongues))).truncatingRemainder(dividingBy: 1))
                let side: CGFloat = k % 2 == 0 ? -1 : 1
                FlameShape(sway: 0.12 * s2 * side, stretch: 1)
                    .fill(outer)
                    .frame(width: w * 0.3, height: h * 0.32)
                    .scaleEffect(1 - life * 0.55)
                    .offset(x: side * w * (0.12 + 0.06 * CGFloat(k)) + CGFloat(sin(t * 3 + Double(k))) * w * 0.05, y: -h * (0.42 + 0.44 * life))
                    .opacity(Double(1 - life) * 0.9)
            }
            if p >= 2 {   // side flames leaning out: it's spreading
                ForEach([-1.0, 1.0], id: \.self) { side in
                    FlameShape(sway: CGFloat(side) * (0.12 + 0.05 * s3), stretch: 0.9 + 0.08 * s4, lean: CGFloat(side) * 0.08)
                        .fill(outer).frame(width: w * 0.55, height: h * (0.58 + 0.04 * CGFloat(p)))
                        .offset(x: CGFloat(side) * w * 0.3)
                }
            }
            FlameShape(sway: amp * (0.08 * s1 + 0.03 * s2), stretch: 0.96 + amp * (0.035 * s2 + 0.02 * s3), lean: amp * 0.03 * s4)
                .fill(outer).frame(width: w, height: h)
            FlameShape(sway: amp * (0.1 * s4 + 0.04 * s3), stretch: 0.94 + amp * 0.05 * s1, lean: -amp * 0.03 * s2)
                .fill(LinearGradient(colors: st.mid, startPoint: .bottom, endPoint: .top)).frame(width: w * 0.66, height: h * 0.7)
            if p >= 1 {
                FlameShape(sway: 0.08 * s3, stretch: 0.92 + 0.06 * s4)
                    .fill(LinearGradient(colors: st.core, startPoint: .bottom, endPoint: .top)).frame(width: w * 0.38, height: h * 0.4)
                    .padding(.bottom, h * 0.02)
            }
        }
        .frame(width: size, height: size, alignment: .bottom)
        .hueRotation(.degrees(st.prism ? time * 60 : 0))
        .shadow(color: st.glow.opacity([0.4, 0.7, 0.8, 0.85, 0.9, 0.9, 0.9][p]), radius: size * [0.15, 0.28, 0.38, 0.42, 0.46, 0.5, 0.55][p])
        .shadow(color: p >= 2 ? st.glow.opacity(0.35 + 0.15 * Double(s1)) : .clear, radius: size * 0.6)
    }
}

/// Sparks drifting up out of the fire.
struct Embers: View {
    var t: Double
    var count: Int
    var color: Color
    var body: some View {
        Canvas { ctx, sz in
            for i in 0..<count {
                let seed = Double(i) * 12.9898
                let speed = 0.5 + (sin(seed) + 1) * 0.35
                let phase = (t * speed + Double(i) / Double(count)).truncatingRemainder(dividingBy: 1)
                let x = sz.width / 2 + CGFloat(sin(seed * 3 + t * 2.2)) * sz.width * 0.28 * CGFloat(phase)
                let y = sz.height * CGFloat(1 - phase)
                let r = CGFloat(2.2 * (1 - phase) + 0.6)
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(color.opacity(1 - phase)))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Skin patterns

/// A skin's texture, drawn with Canvas: carbon weave, diamond plate, circuit traces, embers, prism bands, aurora.
struct PatternView: View {
    var skin: Skin
    var body: some View {
        Canvas { ctx, sz in
            let c = skin.colors
            switch skin.pattern {
            case .none: break
            case .aurora:
                for (i, col) in c.enumerated() {
                    var p = Path()
                    let y0 = sz.height * (0.25 + 0.25 * CGFloat(i))
                    p.move(to: CGPoint(x: 0, y: y0))
                    stride(from: 0.0, through: Double(sz.width), by: 8).forEach { x in
                        p.addLine(to: CGPoint(x: x, y: Double(y0) + sin(x / 40 + Double(i)) * 14))
                    }
                    ctx.stroke(p, with: .color(col.opacity(0.35)), style: StrokeStyle(lineWidth: 18, lineCap: .round))
                }
            case .carbon:
                let s: CGFloat = 6
                for y in stride(from: 0, to: sz.height, by: s) {
                    for x in stride(from: 0, to: sz.width, by: s) {
                        let odd = (Int(x / s) + Int(y / s)) % 2 == 0
                        ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s / 2)), with: .color(.white.opacity(odd ? 0.07 : 0.025)))
                        ctx.fill(Path(CGRect(x: x, y: y + s / 2, width: s, height: s / 2)), with: .color(.white.opacity(odd ? 0.025 : 0.07)))
                    }
                }
            case .diamond:
                let s: CGFloat = 14
                for y in stride(from: 0, to: sz.height, by: s) {
                    for x in stride(from: 0, to: sz.width, by: s) {
                        let shift = Int(y / s) % 2 == 0 ? 0 : s / 2
                        let r = CGRect(x: x + shift, y: y + 3, width: 7, height: 2.5)
                        let spin = CGAffineTransform(translationX: -r.midX, y: -r.midY).concatenating(CGAffineTransform(rotationAngle: .pi / 4))
                            .concatenating(CGAffineTransform(translationX: r.midX, y: r.midY))
                        ctx.fill(Path(roundedRect: r, cornerRadius: 1.2).applying(spin), with: .color(c[0].opacity(0.22)))
                    }
                }
            case .circuit:
                var p = Path()
                for i in 0..<Int(sz.width / 22) + 1 {
                    let x = CGFloat(i) * 22 + 6
                    let turn = CGFloat((i * 37) % 60) + 20
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: turn))
                    p.addLine(to: CGPoint(x: x + 11, y: turn + 11)); p.addLine(to: CGPoint(x: x + 11, y: sz.height))
                    ctx.fill(Path(ellipseIn: CGRect(x: x + 8.5, y: turn + 8.5, width: 5, height: 5)), with: .color(c[0].opacity(0.5)))
                }
                ctx.stroke(p, with: .color(c[0].opacity(0.22)), lineWidth: 1.2)
            case .embers:
                for i in 0..<Int(sz.width * sz.height / 900) {
                    let seed = Double(i) * 78.233
                    let x = CGFloat((sin(seed) + 1) / 2) * sz.width, y = CGFloat((cos(seed * 1.7) + 1) / 2) * sz.height
                    let r = CGFloat(1 + (sin(seed * 3) + 1))
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(c[i % c.count].opacity(0.45)))
                }
            case .hazard:     // security tape: diagonal amber stripes
                let w: CGFloat = 16
                for i in stride(from: -Int(sz.height / w) - 2, through: Int(sz.width / w) + 2, by: 2) {
                    var p = Path()
                    let x = CGFloat(i) * w
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x + w, y: 0))
                    p.addLine(to: CGPoint(x: x + w - sz.height, y: sz.height)); p.addLine(to: CGPoint(x: x - sz.height, y: sz.height))
                    ctx.fill(p, with: .color(c[0].opacity(0.06)))
                }
            case .vault:      // brushed steel, rivets, and a combination dial in the corner
                var y: CGFloat = 0, k = 0
                while y < sz.height {
                    ctx.fill(Path(CGRect(x: 0, y: y, width: sz.width, height: 1)), with: .color(.white.opacity(k % 3 == 0 ? 0.035 : 0.015)))
                    y += 3; k += 1
                }
                for yy in stride(from: CGFloat(18), to: sz.height, by: 64) {
                    for xx in stride(from: CGFloat(18), to: sz.width, by: 64) {
                        ctx.fill(Path(ellipseIn: CGRect(x: xx - 2.5, y: yy - 2.5, width: 5, height: 5)), with: .color(.white.opacity(0.14)))
                        ctx.fill(Path(ellipseIn: CGRect(x: xx - 1.4, y: yy - 2, width: 2, height: 2)), with: .color(.white.opacity(0.22)))
                    }
                }
                guard sz.width > 420 else { break }   // the dial only on big panels, not the sidebar
                let o = CGPoint(x: sz.width - 46, y: sz.height - 46)
                for rr in [CGFloat(54), CGFloat(38)] {
                    ctx.stroke(Path(ellipseIn: CGRect(x: o.x - rr, y: o.y - rr, width: rr * 2, height: rr * 2)), with: .color(c[0].opacity(0.16)), lineWidth: 1.2)
                }
                for i in 0..<60 {
                    let a = Double(i) / 60 * 2 * Double.pi
                    let inner: CGFloat = i % 5 == 0 ? 43 : 48
                    var p = Path()
                    p.move(to: CGPoint(x: o.x + CGFloat(cos(a)) * inner, y: o.y + CGFloat(sin(a)) * inner))
                    p.addLine(to: CGPoint(x: o.x + CGFloat(cos(a)) * 54, y: o.y + CGFloat(sin(a)) * 54))
                    ctx.stroke(p, with: .color(c[0].opacity(0.18)), lineWidth: 1)
                }
            case .prism:
                let w: CGFloat = 26
                for i in -Int(sz.height / w)...Int(sz.width / w) + 2 {
                    var p = Path()
                    let x = CGFloat(i) * w
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x + w, y: 0))
                    p.addLine(to: CGPoint(x: x + w - sz.height, y: sz.height)); p.addLine(to: CGPoint(x: x - sz.height, y: sz.height))
                    ctx.fill(p, with: .color(c[(i % c.count + c.count) % c.count].opacity(0.13)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// The current skin washed over a background: a soft tint of its colors plus its texture. The default skin adds
/// nothing, so lockin looks clean until you unlock and pick something.
struct SkinWash: View {
    var strength: Double = 1
    var body: some View {
        let s = Skin.current
        if s.id != "green" {
            ZStack {
                LinearGradient(colors: [s.color.opacity(0.14 * strength), (s.colors.last ?? s.color).opacity(0.05 * strength)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if s.fancy { PatternView(skin: s).opacity(min(1, 0.65 * strength)) }
            }
            .allowsHitTesting(false)
        }
    }
}

/// A lockin window's background: the system material with the skin over it.
struct AppBackground: View {
    var body: some View { ZStack { VisualEffect(material: .underWindowBackground); SkinWash() } }
}

// MARK: - Rewards views

/// Level emblem, title and the bar to the next level.
struct LevelCard: View {
    var r: Rewards
    var body: some View {
        HStack(spacing: 18) {
            LevelEmblem(level: r.level, size: 60)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(r.title).font(.system(size: 18, weight: .bold))
                    Text("Level \(r.level)").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(r.intoLevel) / \(r.levelSize) XP").font(Theme.number(12, .medium)).foregroundStyle(.secondary).monospacedDigit()
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(Theme.accentFill).frame(width: max(6, g.size.width * Double(r.intoLevel) / Double(max(1, r.levelSize))))
                    }
                }
                .frame(height: 7)
                let next = (r.level + 1...r.level + 40).first { Rewards.title($0) != r.title }
                Text("\(r.xp) XP total · \(r.earnedCount) of \(r.badges.count) badges" + (next.map { " · \(Rewards.title($0)) at level \($0)" } ?? ""))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text("XP only counts real work: typing, clicking or scrolling on task. Idle time and mouse jigglers earn nothing.")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(ZStack { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card); SkinWash(strength: 1.3) }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
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
                        .foregroundStyle(on ? Theme.accentFill : AnyShapeStyle(Color.secondary.opacity(0.5)))
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

/// Your skins. Nothing changes until you equip one: unlocked skins get an Equip button, locked ones show their level.
struct SkinPicker: View {
    var level: Int
    @State private var current = Skin.current.id
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
            ForEach(Skin.all) { s in card(s) }
        }
    }
    /// Locked skins you're close to (the next two) show what they look like; the rest stay a mystery until you're near.
    private var nearby: Set<String> { Set(Skin.all.filter { $0.level > level }.prefix(2).map(\.id)) }

    private func card(_ s: Skin) -> some View {
        let open = level >= s.level, on = current == s.id, revealed = open || nearby.contains(s.id)
        return VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if revealed {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(s.colors.count > 1 ? AnyShapeStyle(LinearGradient(colors: s.colors, startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(s.color))
                    if s.fancy { PatternView(skin: s).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous)).blendMode(.overlay) }
                } else {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.08))
                    Text("?").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(.tertiary)
                }
                if !open && revealed {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.black.opacity(0.55))
                    Image(systemName: "lock.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(height: 50)
            VStack(alignment: .leading, spacing: 1) {
                Text(revealed ? s.name : "Mystery skin").font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(revealed ? .primary : .tertiary)
                Text(open ? (s.fancy ? "Pattern" : "Color") : revealed ? "Unlocks at level \(s.level)" : "Get closer to see it")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Group {
                if on {
                    Label("Equipped", systemImage: "checkmark").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background(Capsule().strokeBorder(Theme.accent.opacity(0.6)))
                } else if open {
                    Button { Skin.equip(s.id); current = s.id } label: { Text("Equip").frame(maxWidth: .infinity) }
                        .buttonStyle(SecondaryButtonStyle())
                } else {
                    Label("Level \(s.level)", systemImage: "lock.fill").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1.5))
        .opacity(open ? 1 : revealed ? 0.8 : 0.55)
        .help(open ? s.name : revealed ? "Unlocks at level \(s.level)" : "A mystery skin at level \(s.level)")
    }
}
