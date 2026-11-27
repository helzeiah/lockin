import AppKit
import SwiftUI

/// The morning screen. The first time you're at the Mac each day, your day covers every display until you start it:
/// lock in on the first session, start the day (sessions then start on their own at their times), or hold Skip and
/// say why. Skips are logged and show up in the recap and Stats.
@MainActor
final class Gate {
    static let shared = Gate()
    private var windows: [NSWindow] = []
    var isShown: Bool { !windows.isEmpty }

    func show() {
        let e = Engine.shared
        if let w = windows.first as? KeyPanel { w.show(); return }
        e.card = nil; e.statsShown = false; e.blocked = nil; e.gateShown = true
        e.planDay = .today
        e.reloadTodos(); e.refreshEvents()
        let main = NSScreen.screens.first ?? NSScreen.main      // the display with the menu bar
        for screen in NSScreen.screens {
            let isMain = screen == main
            let w = GatePanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
            w.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: isMain ? AnyView(GateView().environmentObject(e)) : AnyView(GateDim()))
            host.sizingOptions = []   // exactly the screen, however long the plan on it gets
            w.contentView = host
            w.alphaValue = 0
            w.orderFrontRegardless()
            if isMain { w.makeKey() }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.35; w.animator().alphaValue = 1 }
            windows.append(w)
        }
    }

    func close() {
        let ws = windows
        windows = []
        Engine.shared.gateShown = false
        for w in ws {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; w.animator().alphaValue = 0 },
                                                 completionHandler: { Task { @MainActor in w.orderOut(nil) } })
        }
        TypingFocus.end()
    }
}

/// Full screen and borderless. Takes typing (the plan box, dictation apps included) and ignores ⌘W, ⌘Q, ⌘H, ⌘M
/// and Esc, so the way past it is one of its buttons.
final class GatePanel: KeyPanel {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if mods == .command, ["w", "q", "h", "m"].contains(key) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func cancelOperation(_ sender: Any?) {}
}

struct GateView: View {
    @EnvironmentObject var e: Engine
    @State private var st = Stats()
    @State private var skipping = false
    @State private var reason = ""
    @FocusState private var reasonFocused: Bool

    /// Now, or $LOCKIN_NOW (ISO 8601) when set, so screenshots can show the morning version.
    static var now: Date {
        ProcessInfo.processInfo.environment["LOCKIN_NOW"].flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
    }
    private var greeting: String {
        let h = Calendar.current.component(.hour, from: GateView.now)
        return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }
    private var open: [Todo] { e.todos.filter { !$0.isDone } }
    private var first: Todo? { e.nextTodo }
    private var upcomingEvents: [CalEvent] {
        e.events.filter { !$0.allDay && $0.end > Date() && !e.isIgnored($0) }
    }

    var body: some View {
        ZStack {
            VisualEffect(material: .fullScreenUI)
            Color.black.opacity(0.6)
            SkinWash(strength: 1.4)
            ScrollView {
                VStack(spacing: 0) {
                    header.padding(.top, 70)
                    plan.padding(.top, 30)
                    actions.padding(.top, 22)
                    skip.padding(.top, 38).padding(.bottom, 40)
                }
                .frame(width: 600)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
        }
        .environment(\.colorScheme, .dark)
        .tint(Theme.accent)
        .onAppear { st = e.stats() }
    }

    // MARK: pieces

    private var header: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 54, height: 54)
            Text(GateView.now.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                .font(.system(size: 12, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
            Text(greeting).font(.system(size: 40, weight: .bold)).tracking(-0.8)
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    StreakFire(streak: st.streak, size: 15)
                    Text(st.streak > 0 ? "\(st.streak)-day streak" : "No streak yet").font(.system(size: 12.5, weight: .medium))
                }
                .padding(.horizontal, 12).padding(.vertical, 6).background(Capsule().fill(.white.opacity(0.08)))
                pill(icon: "clock.arrow.circlepath", tint: .secondary, text: yesterdayLine)
                pill(icon: "target", tint: Theme.accent, text: "Goal \(fmtMinutes(st.goal))")
            }
        }
    }

    private var yesterdayLine: String {
        guard let y = Calendar.current.date(byAdding: .day, value: -1, to: Stats.today) else { return "" }
        let m = st.minutes(y), ended = st.ended(y), kept = st.keptCount(y)
        if m == 0 && ended == 0 { return "Yesterday: nothing" }
        return "Yesterday: \(fmtMinutes(m))" + (ended > 0 ? " · \(kept)/\(ended) kept" : "")
    }

    private func pill(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(tint)
            Text(text).font(.system(size: 12.5, weight: .medium)).monospacedDigit()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(.white.opacity(0.08)))
    }

    private var plan: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(text: "Today's plan")
                Spacer()
                if !open.isEmpty {
                    let mins = open.reduce(0) { $0 + $1.left }
                    Text("\(open.count) session\(open.count == 1 ? "" : "s") · \(fmtMinutes(mins))")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            LevelPicker(day: .today)
            DayShapeCard(day: .today)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.05)))
            if open.isEmpty && upcomingEvents.isEmpty {
                Text("Nothing planned yet. What are you locking in on today?")
                    .font(.system(size: 14)).foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                VStack(spacing: 2) {
                    ForEach(entries, id: \.id) { entry in
                        switch entry {
                        case .todo(let t): GateRow(t: t, isNext: t.id == first?.id)
                        case .event(let ev): GateEventRow(ev: ev)
                        }
                    }
                }
            }
            QuickAddField(day: .today, autoFocus: open.isEmpty,
                          placeholder: open.isEmpty ? "leetcode 45, co-op web ui 90 at 2pm, essay intro 30" : "Add more…")
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.08)))
    }

    private var entries: [PlanEntry] { PlanEntry.merge(todos: open, events: upcomingEvents) }

    @ViewBuilder private var actions: some View {
        if let f = first {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Button { lockIn(f) } label: {
                        Label("Lock in: \(f.task.prefix(28))\(f.task.count > 28 ? "…" : "") · \(f.left) min", systemImage: "lock.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle(large: true))
                    Button("Start my day") { startDay() }.buttonStyle(SecondaryButtonStyle(large: true))
                }
                Text(startDayNote).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } else {
            Text("Add at least one session to start your day.").font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
    }

    private var startDayNote: String {
        guard e.cfg.auto_start ?? true, let next = open.first(where: { parseHHMM($0.start ?? "").map { $0 > Date() } ?? false }) else {
            return "Start my day closes this. Lock in from the menu bar whenever you're ready."
        }
        return "Start my day closes this. \(next.task) starts by itself at \(clockLabel(next.start))."
    }

    @ViewBuilder private var skip: some View {
        if skipping {
            VStack(spacing: 10) {
                Text("Why are you skipping today?").font(.system(size: 13, weight: .semibold))
                TextField("e.g. sick, travel day, day off", text: $reason)
                    .textFieldStyle(.plain).font(.system(size: 13.5))
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.07)))
                    .frame(width: 340).focused($reasonFocused).onSubmit(skipDay)
                HStack(spacing: 10) {
                    Button("Never mind") { skipping = false; reason = "" }.buttonStyle(SecondaryButtonStyle())
                    Button("Skip today", action: skipDay).buttonStyle(SecondaryButtonStyle())
                        .disabled(reason.trimmingCharacters(in: .whitespaces).count < 3)
                }
                Text("It shows in your recap and stats.").font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
            .onAppear { reasonFocused = true }
        } else {
            VStack(spacing: 8) {
                HoldButton(label: "Hold to skip today", seconds: 3) { withAnimation(.easeOut(duration: 0.2)) { skipping = true } }
                Text("Skipping is allowed. It's just on the record.").font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: actions

    private func lockIn(_ t: Todo) {
        e.passGate(how: "lock_in")
        Gate.shared.close()
        e.startTodo(t)
    }
    private func startDay() {
        e.passGate(how: "start_day")
        Gate.shared.close()
    }
    private func skipDay() {
        let r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.count >= 3 else { return }
        e.passGate(how: "skip", reason: r)
        Gate.shared.close()
    }
}

/// A session on the morning screen: time, task, its apps, length; hover to remove it.
struct GateRow: View {
    @EnvironmentObject var e: Engine
    let t: Todo
    var isNext = false
    @State private var hover = false
    var body: some View {
        HStack(spacing: 12) {
            Text(clockLabel(t.start).isEmpty ? "—" : clockLabel(t.start))
                .font(Theme.number(12.5, .medium)).monospacedDigit().foregroundStyle(.secondary).frame(width: 66, alignment: .trailing)
            Circle().fill(isNext ? Theme.accent : Color.white.opacity(0.25)).frame(width: 7, height: 7)
            HStack(spacing: 6) {
                Text(t.task).font(.system(size: 14, weight: isNext ? .semibold : .regular)).lineLimit(1)
                if t.isRoutine { Image(systemName: "repeat").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            AppIconRow(apps: t.apps ?? [], size: 15)
            Text("\(t.left)m").font(Theme.number(12, .medium)).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
            Button { e.deleteTodo(t.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).opacity(hover ? 1 : 0).help("Remove")
        }
        .padding(.vertical, 8).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover ? Color.white.opacity(0.05) : .clear))
        .onHover { hover = $0 }
    }
}

struct GateEventRow: View {
    let ev: CalEvent
    var body: some View {
        HStack(spacing: 12) {
            Text(ev.start.formatted(date: .omitted, time: .shortened))
                .font(Theme.number(12.5, .medium)).monospacedDigit().foregroundStyle(.tertiary).frame(width: 66, alignment: .trailing)
            Image(systemName: "calendar").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.info).frame(width: 7)
            Text(ev.title).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Text("until \(ev.end.formatted(date: .omitted, time: .shortened))").font(.system(size: 12)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8).padding(.horizontal, 8)
    }
}

/// The other displays while the morning screen is up.
struct GateDim: View {
    var body: some View {
        ZStack {
            VisualEffect(material: .fullScreenUI)
            Color.black.opacity(0.72)
            VStack(spacing: 10) {
                Image(systemName: "lock.fill").font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.accent)
                Text("Your day is on your main display").font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.75))
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// Today's sessions and calendar events on one timeline.
enum PlanEntry {
    case todo(Todo), event(CalEvent)
    var id: String { switch self { case .todo(let t): return "t" + t.id; case .event(let e): return "e" + e.id } }
    var sortKey: (Int, String) {
        switch self {
        case .todo(let t): return (t.start ?? "").isEmpty ? (t.isDone ? 0 : 2, "") : (1, t.start ?? "")
        case .event(let e): return (1, e.startHHMM)
        }
    }
    static func merge(todos: [Todo], events: [CalEvent]) -> [PlanEntry] {
        let all = todos.map(PlanEntry.todo) + events.map(PlanEntry.event)
        return all.enumerated().sorted { a, b in
            a.element.sortKey != b.element.sortKey ? a.element.sortKey < b.element.sortKey : a.offset < b.offset
        }.map(\.element)
    }
}
