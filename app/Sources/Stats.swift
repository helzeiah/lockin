import Charts
import Foundation
import SwiftUI

// Stats from log.jsonl: minutes focused per day, streaks, the week, where the time went, and the accountability
// record (sessions kept vs. ended early, skipped mornings, passes). Every finished session logs `focused_min`, so
// history goes back to the first one ever run.

struct StatsDay: Identifiable, Hashable {
    var date: Date          // start of the day (local midnight)
    var minutes: Int
    var id: Date { date }
}

struct Stats {
    static let dayStartsAt = 4          // a session that ends before 4am counts for the night before
    var days: [Date: Int] = [:]         // focused minutes by day
    var kept: [Date: Int] = [:]         // sessions that ran to the end
    var endedEarly: [Date: Int] = [:]   // sessions stopped early (or by quitting lockin)
    var skips: [Date: Int] = [:]        // mornings skipped on the morning screen
    var passes: [Date: Int] = [:]       // "Give me 5 min" taken
    var byBlock: [(name: String, minutes: Int)] = []
    var first: Date?
    var goal: Int = 25                  // minutes for a day to count toward the streak
    var weekGoal: Int = 5               // counted days wanted per week

    static func load(goal: Int = 25, weekGoal: Int = 5, live: ActiveBlock? = nil, now: Date = Date()) -> Stats {
        var s = Stats(goal: goal, weekGoal: weekGoal)
        var blocks: [String: Int] = [:]
        let parse = DateFormatter(); parse.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let text = try? String(contentsOf: Paths.log, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard line.contains("\"block_end\"") || line.contains("\"gate_skipped\"") || line.contains("\"pass\""),
                      let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      let ts = (obj["ts"] as? String).flatMap(parse.date(from:)) else { continue }
                let d = Stats.day(of: ts)
                switch obj["type"] as? String {
                case "block_end":
                    let m = (obj["focused_min"] as? Int) ?? 0
                    s.add(m, at: ts)
                    if m > 0 { blocks[(obj["name"] as? String) ?? "Other", default: 0] += m }
                    if obj["completed"] as? Bool == true { s.kept[d, default: 0] += 1 }
                    else if obj["how"] as? String != "replaced" { s.endedEarly[d, default: 0] += 1 }
                case "gate_skipped": s.skips[d, default: 0] += 1
                case "pass": s.passes[d, default: 0] += 1
                default: break
                }
            }
        }
        // the block running right now counts toward today as it goes
        if let b = live, b.kind == "focus" {
            let m = max(0, Int((now.timeIntervalSince1970 - b.started - b.offSeconds) / 60))
            if m > 0 { s.add(m, at: now); blocks[b.name, default: 0] += m }
        }
        s.byBlock = blocks.map { ($0.key, $0.value) }.sorted { $0.minutes > $1.minutes }
        return s
    }

    static func day(of t: Date) -> Date {
        Calendar.current.startOfDay(for: t.addingTimeInterval(-Double(dayStartsAt) * 3600))
    }
    static var today: Date { day(of: Date()) }

    private mutating func add(_ m: Int, at t: Date) {
        let d = Stats.day(of: t)
        days[d, default: 0] += m
        if first == nil || d < first! { first = d }
    }

    func minutes(_ d: Date) -> Int { days[d] ?? 0 }
    func keptCount(_ d: Date) -> Int { kept[d] ?? 0 }
    func ended(_ d: Date) -> Int { (kept[d] ?? 0) + (endedEarly[d] ?? 0) }
    /// Sums over this week so far.
    private func weekSum(_ m: [Date: Int]) -> Int { week.reduce(0) { $0 + (m[$1.date] ?? 0) } }
    var weekKept: Int { weekSum(kept) }
    var weekEndedEarly: Int { weekSum(endedEarly) }
    var weekSkips: Int { weekSum(skips) }
    var weekPasses: Int { weekSum(passes) }
    /// Share of all sessions ever that ran to the end, 0-100 (nil before the first one).
    var keptRate: Int? {
        let k = kept.values.reduce(0, +), e = endedEarly.values.reduce(0, +)
        return k + e == 0 ? nil : k * 100 / (k + e)
    }
    func counts(_ d: Date) -> Bool { minutes(d) >= goal }
    var total: Int { days.values.reduce(0, +) }
    var todayMinutes: Int { minutes(Stats.today) }

    /// Days in a row that reached the goal. Today doesn't break it until it's over.
    var streak: Int {
        let cal = Calendar.current
        var d = counts(Stats.today) ? Stats.today : cal.date(byAdding: .day, value: -1, to: Stats.today)!
        var n = 0
        while counts(d) { n += 1; d = cal.date(byAdding: .day, value: -1, to: d)! }
        return n
    }
    var best: Int {
        guard let f = first else { return 0 }
        let cal = Calendar.current
        var d = f, run = 0, best = 0
        while d <= Stats.today {
            if counts(d) { run += 1; best = max(best, run) } else { run = 0 }
            d = cal.date(byAdding: .day, value: 1, to: d)!
        }
        return best
    }
    /// The last `n` days, oldest first, ending today.
    func last(_ n: Int) -> [StatsDay] {
        let cal = Calendar.current
        return (0..<n).reversed().map { i in
            let d = cal.date(byAdding: .day, value: -i, to: Stats.today)!
            return StatsDay(date: d, minutes: minutes(d))
        }
    }
    /// This calendar week (from the locale's first weekday) so far.
    var week: [StatsDay] {
        let cal = Calendar.current
        let start = cal.dateInterval(of: .weekOfYear, for: Stats.today)?.start ?? Stats.today
        var out: [StatsDay] = [], d = start
        while d <= Stats.today { out.append(StatsDay(date: d, minutes: minutes(d))); d = cal.date(byAdding: .day, value: 1, to: d)! }
        return out
    }
    var weeksSinceFirst: Int {
        guard let f = first else { return 0 }
        return (Calendar.current.dateComponents([.day], from: f, to: Stats.today).day ?? 0) / 7 + 1
    }
    var weekMinutes: Int { week.reduce(0) { $0 + $1.minutes } }
    var weekDaysCounted: Int { week.filter { $0.minutes >= goal }.count }
    /// 0...4 shade for the grid.
    func level(_ m: Int) -> Int { m == 0 ? 0 : m < goal ? 1 : m < 2 * goal ? 2 : m < 3 * goal ? 3 : 4 }
}

/// "45 min", "1 hr", "1 hr 3 min"
func fmtMinutes(_ m: Int) -> String {
    let h = m / 60, r = m % 60
    if h == 0 { return "\(m) min" }
    return r == 0 ? "\(h) hr" : "\(h) hr \(r) min"
}
/// The same, split over two lines for the label on top of a narrow bar.
func barLabel(_ m: Int) -> String {
    let h = m / 60, r = m % 60
    if h == 0 { return "\(m) min" }
    return r == 0 ? "\(h) hr" : "\(h) hr\n\(r) min"
}

// MARK: shared pieces

/// Greens for the grid, dim to bright. Same green as the progress ring at the top.
func heatColor(_ level: Int, dark: Bool) -> Color {
    let g = tintColor("green")
    switch level {
    case 0: return dark ? Color.white.opacity(0.07) : Color.black.opacity(0.06)
    case 1: return g.opacity(0.28)
    case 2: return g.opacity(0.5)
    case 3: return g.opacity(0.75)
    default: return g
    }
}

/// GitHub-style grid: one column per week, Sunday/Monday at the top per locale. Empty squares are missed days.
struct HeatGrid: View {
    var stats: Stats
    var weeks: Int
    var cell: CGFloat = 11
    var gap: CGFloat = 3
    var dark: Bool
    var showLabels = true

    private var columns: [[Date?]] {
        let cal = Calendar.current
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: Stats.today)?.start ?? Stats.today
        let start = cal.date(byAdding: .day, value: -7 * (weeks - 1), to: thisWeek)!
        return (0..<weeks).map { w in
            (0..<7).map { i in
                let d = cal.date(byAdding: .day, value: w * 7 + i, to: start)!
                return d > Stats.today ? nil : d
            }
        }
    }

    var body: some View {
        let cols = columns
        VStack(alignment: .leading, spacing: 4) {
            if showLabels {
                HStack(spacing: gap) {
                    ForEach(Array(cols.enumerated()), id: \.offset) { i, col in
                        let d = col.first ?? nil
                        let newMonth = d.map { i == 0 || Calendar.current.component(.day, from: $0) <= 7 } ?? false
                        Text(newMonth ? d!.formatted(.dateTime.month(.abbreviated)) : "")
                            .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                            .fixedSize().frame(width: cell, alignment: .leading)
                    }
                }
            }
            HStack(alignment: .top, spacing: gap) {
                ForEach(Array(cols.enumerated()), id: \.offset) { _, col in
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { i in
                            if let d = col[i] {
                                let m = stats.minutes(d)
                                let before = stats.first.map { d < $0 } ?? true
                                RoundedRectangle(cornerRadius: cell * 0.24, style: .continuous)
                                    .fill(before ? heatColor(0, dark: dark).opacity(0.5) : heatColor(stats.level(m), dark: dark))
                                    .overlay {
                                        if d == Stats.today {
                                            RoundedRectangle(cornerRadius: cell * 0.24, style: .continuous)
                                                .strokeBorder(dark ? Color.white.opacity(0.7) : Color.black.opacity(0.45), lineWidth: 1)
                                        }
                                    }
                                    .frame(width: cell, height: cell)
                                    .help("\(d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())): \(before ? "before lockin" : (m == 0 ? "no focus" : fmtMinutes(m)))")
                            } else {
                                Color.clear.frame(width: cell, height: cell)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct HeatLegend: View {
    var dark: Bool
    var body: some View {
        HStack(spacing: 3) {
            Text("less").font(.system(size: 9.5)).foregroundStyle(.secondary)
            ForEach(0..<5, id: \.self) { l in
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(heatColor(l, dark: dark)).frame(width: 9, height: 9)
            }
            Text("more").font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
    }
}

/// Bars for focused minutes per day; days that reached the goal are full green.
struct DayBars: View {
    var days: [StatsDay]
    var goal: Int
    var compact = false

    var body: some View {
        let peak = max(goal * 2, (days.map(\.minutes).max() ?? 0))
        let top = Int(Double(peak) * 1.35)   // headroom for the labels on top of the bars
        Chart {
            ForEach(days) { d in
                BarMark(x: .value("Day", d.date, unit: .day), y: .value("Minutes", d.minutes))
                    .foregroundStyle(d.minutes >= goal ? tintColor("green") : tintColor("green").opacity(0.4))
                    .cornerRadius(compact ? 2.5 : 4)
                    .annotation(position: .top, spacing: 3) {
                        if d.minutes > 0 {
                            Text(barLabel(d.minutes))
                                .font(.system(size: compact ? 8.5 : 9.5, weight: .semibold, design: .rounded)).monospacedDigit()
                                .multilineTextAlignment(.center).lineSpacing(-1)
                                .foregroundStyle(.secondary).fixedSize()
                        }
                    }
            }
            if !compact {
                RuleMark(y: .value("Goal", goal))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("\(goal) min goal").font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }
            }
        }
        .chartYScale(domain: 0...Double(top))
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { v in
                AxisValueLabel {
                    if let d = v.as(Date.self) {
                        Text(compact ? String(d.formatted(.dateTime.weekday(.narrow))) : d.formatted(.dateTime.weekday(.narrow).day()))
                            .font(.system(size: compact ? 9 : 10))
                    }
                }
            }
        }
        .chartYAxis {
            if compact { AxisMarks { _ in } } else {
                AxisMarks(values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.18))
                    AxisValueLabel {
                        if let m = v.as(Int.self) { Text(m >= 60 && m % 60 == 0 ? "\(m / 60) hr" : "\(m) min").font(.system(size: 9.5)) }
                    }
                }
            }
        }
    }
}

// MARK: the Stats page

struct StatsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day())).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Text("Your focus").font(.system(size: 28, weight: .bold)).tracking(-0.5)
            }
            .padding(.horizontal, 28).padding(.top, 36).padding(.bottom, 18)
            StatsView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VisualEffect(material: .underWindowBackground))
    }
}

struct StatsView: View {
    @EnvironmentObject var e: Engine
    @Environment(\.colorScheme) private var scheme
    @State private var stats = Stats()
    @State private var rewards = Rewards()

    init() {}

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    LevelCard(r: rewards)
                    tiles
                    if stats.total == 0 {
                        Label("Finish a session and it shows up here. A day counts once you hit \(stats.goal) minutes.", systemImage: "sparkles")
                            .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                    section("Last 14 days") { DayBars(days: stats.last(14), goal: stats.goal).frame(height: 150) }
                    section("Every day since you started", trailing: AnyView(HeatLegend(dark: scheme == .dark))) {
                        // As many weeks as fit the width (your whole history at least), GitHub-style
                        let avail = geo.size.width - 56
                        let fit = Int((avail + 4) / 18)
                        let weeks = min(53, max(12, fit, stats.weeksSinceFirst + 1))
                        let cell = min(20, max(9, (avail - CGFloat(weeks - 1) * 4) / CGFloat(weeks)))
                        let grid = HeatGrid(stats: stats, weeks: weeks, cell: cell, gap: 4, dark: scheme == .dark)
                        ViewThatFits(in: .horizontal) {
                            grid
                            ScrollView(.horizontal, showsIndicators: false) { grid }.defaultScrollAnchor(.trailing)
                        }
                    }
                    section("This week, on the record") { record }
                    section("Badges · \(rewards.earnedCount) of \(rewards.badges.count)") { BadgeGrid(badges: rewards.badges) }
                    section("Skins") { SkinPicker(level: rewards.level) }
                    if !stats.byBlock.isEmpty { section("Where the time went") { blockSplit } }
                }
                .padding(.horizontal, 28).padding(.bottom, 24)
            }
        }
        .onAppear { reload() }
        .onReceive(e.$block) { _ in reload() }
    }

    private func reload() {
        stats = Stats.load(goal: e.cfg.stats_goal ?? 25, weekGoal: e.cfg.stats_week_goal ?? 5, live: e.block)
        rewards = Rewards.load(goal: e.cfg.stats_goal ?? 25)
    }

    private var tiles: some View {
        HStack(spacing: 10) {
            tile(fmtMinutes(stats.todayMinutes), "today · goal \(stats.goal) min", accent: stats.todayMinutes >= stats.goal)
            tile("\(stats.streak)", "day streak · best \(stats.best)", icon: stats.streak > 0 ? "flame.fill" : nil, accent: stats.streak > 0)
            tile("\(stats.weekDaysCounted)/\(stats.weekGoal)", "days this week · \(fmtMinutes(stats.weekMinutes))", accent: stats.weekDaysCounted >= stats.weekGoal)
            tile(stats.keptRate.map { "\($0)%" } ?? "–", "sessions kept, all time", accent: (stats.keptRate ?? 0) >= 80)
        }
    }

    /// Kept vs. ended early, skipped mornings and passes this week: the honest part.
    private var record: some View {
        HStack(spacing: 10) {
            recordItem("\(stats.weekKept)", "kept", icon: "checkmark.circle.fill", tint: Theme.accent)
            recordItem("\(stats.weekEndedEarly)", "ended early", icon: "stop.circle.fill", tint: stats.weekEndedEarly > 0 ? Theme.danger : .secondary)
            recordItem("\(stats.weekSkips)", stats.weekSkips == 1 ? "morning skipped" : "mornings skipped", icon: "sunrise.fill", tint: stats.weekSkips > 0 ? Theme.flame : .secondary)
            recordItem("\(stats.weekPasses)", stats.weekPasses == 1 ? "pass taken" : "passes taken", icon: "hourglass", tint: .secondary)
        }
    }
    private func recordItem(_ value: String, _ label: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(Theme.number(16)).monospacedDigit()
                Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.card))
    }

    private func tile(_ value: String, _ label: String, icon: String? = nil, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Theme.flame) }
                Text(value).font(Theme.number(22)).monospacedDigit()
                    .foregroundStyle(accent ? Theme.accent : .primary)
            }
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
    }

    private func section<C: View>(_ title: String, trailing: AnyView? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                Spacer()
                if let trailing { trailing }
            }
            content()
        }
    }

    private var blockSplit: some View {
        let total = max(1, stats.byBlock.reduce(0) { $0 + $1.minutes })
        return VStack(alignment: .leading, spacing: 10) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(stats.byBlock, id: \.name) { b in
                        let share = CGFloat(b.minutes) / CGFloat(total)
                        colorFor(block: b.name).frame(width: max(3, g.size.width * share - 2))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            VStack(spacing: 6) {
                ForEach(stats.byBlock, id: \.name) { b in
                    HStack(spacing: 8) {
                        Circle().fill(colorFor(block: b.name)).frame(width: 7, height: 7)
                        Text(b.name).font(.system(size: 12.5))
                        Spacer()
                        Text(fmtMinutes(b.minutes)).font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
                        let pct = b.minutes * 100 / total
                        Text("\(pct)%").font(.system(size: 11, design: .rounded)).monospacedDigit()
                            .foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
    }
}

// MARK: the notch drop-down

/// Drops out of the notch: today, the streak, this week's bars and the last few months at a glance.
struct NotchStats: View {
    @EnvironmentObject var e: Engine
    var stats: Stats

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("TODAY").font(.system(size: 9.5, weight: .semibold)).tracking(0.7).foregroundStyle(.white.opacity(0.45))
                    Text(fmtMinutes(stats.todayMinutes)).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(stats.todayMinutes >= stats.goal ? tintColor("green") : .white)
                }
                Spacer()
                chip(icon: "flame.fill", tint: stats.streak > 0 ? tintColor("orange") : .white.opacity(0.35),
                     value: "\(stats.streak)", label: stats.streak == 1 ? "day" : "days")
                chip(icon: "calendar", tint: tintColor("blue"), value: "\(stats.weekDaysCounted)/\(stats.weekGoal)", label: "this week")
                    .padding(.leading, 8)
            }
            DayBars(days: stats.last(7), goal: stats.goal, compact: true)
                .frame(height: 64)
                .environment(\.colorScheme, .dark)
            HStack(alignment: .bottom) {
                HeatGrid(stats: stats, weeks: 14, cell: 10, gap: 3, dark: true, showLabels: false)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    Text("best streak \(stats.best)").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
                    Button("Open stats") { e.statsShown = false; Planner.shared.open(tab: .stats) }
                        .buttonStyle(PillButtonStyle(primary: true))
                }
            }
        }
    }

    private func chip(icon: String, tint: Color, value: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.system(size: 13.5, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(label).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.07)))
    }
}
