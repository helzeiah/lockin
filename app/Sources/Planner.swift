import AppKit
import SwiftUI

// The lockin window: Today (or Tomorrow), Stats and setup.
@MainActor
final class Planner {
    static let shared = Planner()
    private var window: KeyPanel?

    func open(tab: PlannerTab = .plan, day: PlanDay? = nil) {
        let e = Engine.shared
        e.card = nil      // one thing at a time
        e.statsShown = false
        e.plannerTab = tab
        if let day { e.planDay = day }
        e.reloadTodos()
        if let w = window { w.show(); return }
        let w = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 860, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 720, height: 520)
        w.contentView = NSHostingView(rootView: MainView().environmentObject(e))
        w.center()
        window = w
        w.show()
    }
}

/// A regular-looking window that opens without activating the app, and activates it only while you type.
///
/// Clicking into a text field makes lockin the frontmost app, because dictation apps (Spokenly, Superwhisper, ...)
/// and other assistive tools insert text into the *frontmost* app; otherwise they'd type into the app behind lockin.
/// Activating an accessory app normally swaps the menu bar to its own menus, and on a notched Mac with a full menu bar
/// macOS then hides status items, lockin's icon included. So the main menu is empty (`minimalMainMenu`) and this
/// window handles ⌘X/C/V/A/Z, ⌘W and ⌘Q itself. When the last lockin window closes, the app you were in comes back.
class KeyPanel: NSPanel {
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask.union(.nonactivatingPanel), backing: backing, defer: flag)
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        isFloatingPanel = false
        level = .normal
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    func show() { orderFrontRegardless(); makeKey() }

    private var editingText: Bool { firstResponder is NSText || firstResponder is NSTextField }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let ok = super.makeFirstResponder(responder)
        if ok, editingText { TypingFocus.begin() }
        return ok
    }

    // Clicking back into a field that already had focus doesn't change the first responder, so also catch the click.
    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        if event.type == .leftMouseDown || event.type == .keyDown, editingText { TypingFocus.begin() }
    }

    // A non-activating panel reports itself as a system dialog; some tools skip those. It's a normal window here.
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .standardWindow }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        var action: Selector?
        switch (mods, key) {
        case (.command, "x"): action = #selector(NSText.cut(_:))
        case (.command, "c"): action = #selector(NSText.copy(_:))
        case (.command, "v"): action = #selector(NSText.paste(_:))
        case (.command, "a"): action = #selector(NSText.selectAll(_:))
        case (.command, "z"): action = Selector(("undo:"))
        case ([.command, .shift], "z"): action = Selector(("redo:"))
        case (.command, "w"): action = #selector(NSWindow.performClose(_:))
        case (.command, "q"): action = #selector(NSApplication.terminate(_:))
        default: break
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func close() {
        super.close()
        TypingFocus.end()
    }
}

/// Makes lockin the frontmost app while you type in its windows, then gives the front back to the app you were in.
/// While typing it's also a regular app (Dock icon, ⌘-Tab): dictation apps like Spokenly ignore accessory apps when
/// deciding which app you're in. The menu bar stays empty either way, so no status items get pushed off.
@MainActor
enum TypingFocus {
    private static var previous: NSRunningApplication?

    static func begin() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        guard !NSApp.isActive else { return }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() { previous = front }
        NSApp.activate(ignoringOtherApps: true)
    }

    static func end() {
        DispatchQueue.main.async {
            guard !NSApp.windows.contains(where: { $0 is KeyPanel && $0.isVisible }) else { return }
            if NSApp.isActive { previous?.activate() }
            previous = nil
            if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

// MARK: - Today

struct TodayView: View {
    @EnvironmentObject var e: Engine
    @State private var hoverId: String?
    @State private var editingId: String?
    @State private var backlogOpen = false

    private var day: PlanDay { e.planDay }
    private var items: [Todo] { e.list(day) }
    private var dayDate: Date { day == .today ? Stats.today : tomorrowDate() }
    private var events: [CalEvent] { day == .today ? e.events.filter { !$0.allDay } : [] }
    private var entries: [PlanEntry] { PlanEntry.merge(todos: items, events: events) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if day == .today, e.block != nil { SessionBanner().padding(.horizontal, 22).padding(.bottom, 10) }
            // The day's questions scroll with the plan, so the window never grows taller than the screen.
            ScrollView {
                VStack(spacing: 0) {
                    DayShapeCard(day: day).padding(.horizontal, 12).padding(.bottom, 12)
                    if entries.isEmpty { empty } else { timeline }
                }
                .padding(.horizontal, 16).padding(.bottom, 12)
            }
            if day == .today && !e.backlog.isEmpty { backlogSection }
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppBackground())
        .onChange(of: e.planDay) { _, _ in editingId = nil }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(dayDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    dayTab(.today, "Today", count: 0)
                    dayTab(.tomorrow, "Tomorrow", count: e.tomorrow.count)
                }
            }
            Spacer()
            if day == .today {
                let st = e.stats()
                HStack(spacing: 18) {
                    StreakBadge(streak: st.streak)
                    GoalRing(minutes: st.todayMinutes, goal: st.goal, size: 50)
                }
            }
        }
        .padding(.horizontal, 28).padding(.top, 36).padding(.bottom, 16)
    }

    /// "Today  Tomorrow" as big titles; the one you're on is bright.
    private func dayTab(_ d: PlanDay, _ title: String, count: Int) -> some View {
        let on = day == d
        return Button { withAnimation(.easeOut(duration: 0.15)) { e.planDay = d } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(title).font(.system(size: 28, weight: .bold)).tracking(-0.5)
                    .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                if !on && count > 0 {
                    Text("\(count)").font(Theme.number(13)).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(on ? "" : "Plan \(title.lowercased())")
    }

    // MARK: timeline

    private var timeline: some View {
        LazyVStack(spacing: 2) {
            let nextId = day == .today ? e.nextTodo?.id : nil
            ForEach(entries, id: \.id) { entry in
                switch entry {
                case .todo(let t):
                    if editingId == t.id { TodoEditor(t: t, day: day) { editingId = nil }.padding(.vertical, 4) }
                    else { TodoRow(t: t, day: day, isNext: t.id == nextId, hoverId: $hoverId, editingId: $editingId) }
                case .event(let ev): EventRow(ev: ev)
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: day == .today ? "sun.max" : "moon.stars").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            Text(day == .today ? "Nothing planned yet" : "Plan tomorrow tonight").font(.system(size: 16, weight: .semibold))
            Text(day == .today ? "Type what you'll lock in on below, all in one line.\nlockin picks the times and the apps for each one."
                               : "Whatever you add here is waiting on your morning screen,\nso the day starts with a plan instead of a blank page.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }

    // MARK: backlog

    private func dayLabel(_ d: String?) -> String {
        guard let d, let date = DateFormatter.ymd.date(from: d) else { return "" }
        if Calendar.current.isDate(date, inSameDayAs: Calendar.current.date(byAdding: .day, value: -1, to: Stats.today) ?? date) { return "yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }

    private var backlogSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button { withAnimation(.easeOut(duration: 0.15)) { backlogOpen.toggle() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(backlogOpen ? 90 : 0))
                        Text("From earlier").font(.system(size: 12, weight: .semibold))
                        Text("\(e.backlog.count)").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if backlogOpen { Button("Clear") { e.clearBacklog() }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            }
            if backlogOpen {
                ScrollView {
                    VStack(spacing: 1) { ForEach(e.backlog) { t in backlogRow(t) } }
                }
                .frame(maxHeight: 130)
            }
        }
        .padding(.horizontal, 26).padding(.top, 6)
    }

    private func backlogRow(_ t: Todo) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Color.secondary.opacity(0.5)).frame(width: 5, height: 5)
            Text(t.task).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text("\(t.minutes)m · \(dayLabel(t.from))").font(.system(size: 11, design: .rounded)).foregroundStyle(.tertiary)
            Button { e.addFromBacklog(t) } label: { Label("Today", systemImage: "plus").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(SecondaryButtonStyle()).disabled(e.planning)
            Button { e.dropFromBacklog(t.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.tertiary).help("Drop it")
        }
        .padding(.vertical, 3).padding(.horizontal, 8)
    }

    // MARK: composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if e.cfg.aiOn, !e.chat.isEmpty, day == .today {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(e.chat.suffix(2).enumerated()), id: \.offset) { _, m in
                        HStack {
                            if m.role != "planner" { Spacer(minLength: 80) }
                            Text(m.text).font(.system(size: 12.5)).padding(.horizontal, 11).padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(m.role != "planner" ? Color.primary.opacity(0.07) : Theme.accent.opacity(0.16)))
                                .foregroundStyle(m.role != "planner" ? .secondary : .primary)
                            if m.role == "planner" { Spacer(minLength: 80) }
                        }
                    }
                }
            }
            if let err = e.planError { Text("Couldn't update the plan: \(err)").font(.system(size: 12)).foregroundStyle(Theme.danger) }
            QuickAddField(day: day, autoFocus: items.isEmpty,
                          placeholder: items.isEmpty ? "leetcode 45, co-op web ui 90 at 2pm, essay intro 30" : "Add more, or edit: done leetcode, essay at 3pm, free at 8…")
            HStack {
                summary
                Spacer()
                if e.listTasks.contains(where: { t in !t.isDone && !items.contains { $0.task_id == t.id } }) {
                    Button("Fill from to-do list") { e.fillFromList(day) }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Theme.accent)
                        .disabled(e.planning).help("Fill the free time with the most important tasks on your to-do list")
                }
                if !items.isEmpty { Button("Clear \(day == .today ? "today" : "tomorrow")") { e.clearDay(day) }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 18)
    }

    @ViewBuilder private var summary: some View {
        let open = items.filter { !$0.isDone }
        if !open.isEmpty {
            let mins = open.reduce(0) { $0 + $1.left }
            let end = open.compactMap { t -> Date? in parseHHMM(t.start ?? "").map { $0.addingTimeInterval(Double(t.left * 60)) } }.max()
            Text("\(open.count) session\(open.count == 1 ? "" : "s") · \(fmtMinutes(mins))" + (end.map { day == .today ? " · done around \($0.formatted(date: .omitted, time: .shortened))" : "" } ?? ""))
                .font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// The running session, on top of Today.
struct SessionBanner: View {
    @EnvironmentObject var e: Engine
    var body: some View {
        if let b = e.block {
            HStack(spacing: 14) {
                Ring(progress: e.progress, color: e.isBreak ? Theme.flame : (e.drifting ? Theme.danger : Theme.accent), size: 38, width: 4,
                     track: Color.primary.opacity(0.1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.isBreak ? "Break" : (b.task ?? "Locked in")).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text("\(fmtTime(e.remaining)) left").font(Theme.number(12, .medium)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if !e.isBreak { AppIconRow(apps: b.apps ?? [], size: 18, max: 5) }
                if e.isBreak || !e.locked {
                    Button(e.isBreak ? "End break" : "End early") { e.stopBlock(completed: false) }.buttonStyle(SecondaryButtonStyle())
                } else {
                    HoldButton(label: "Hold to end early", seconds: 2, tint: Theme.danger) { e.stopBlock(completed: false) }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.accent.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.accent.opacity(0.25)))
        }
    }
}

struct TodoRow: View {
    @EnvironmentObject var e: Engine
    let t: Todo
    let day: PlanDay
    var isNext: Bool
    @Binding var hoverId: String?
    @Binding var editingId: String?
    @State private var picking = false

    private var hover: Bool { hoverId == t.id }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            TimeButton(t: t, label: t.isDone ? "" : (clockLabel(t.start).isEmpty ? "anytime" : clockLabel(t.start)))
                .frame(width: 66, alignment: .trailing)
            Button { e.setDone(t.id, !t.isDone) } label: {
                ZStack {
                    Circle().strokeBorder(t.isDone ? Theme.accent : Color.secondary.opacity(0.5), lineWidth: 1.5)
                    if t.isDone {
                        Circle().fill(Theme.accent)
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.black.opacity(0.85))
                    }
                }
                .frame(width: 20, height: 20).padding(4).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(t.isDone ? "Mark not done" : "Mark done")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(t.task).font(.system(size: 14, weight: isNext ? .semibold : .medium))
                        .strikethrough(t.isDone).foregroundStyle(t.isDone ? .tertiary : .primary).lineLimit(1)
                    if t.isRoutine { Image(systemName: "repeat").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).help(e.routine(for: t)?.daysLabel ?? "Repeats") }
                }
                HStack(spacing: 8) {
                    Text(!t.isDone && (t.spent ?? 0) > 0 ? "\(t.left) of \(t.minutes) min left" : "\(t.minutes) min")
                    if !t.block.isEmpty { Text(t.block).foregroundStyle(.tertiary) }
                    if let why = t.why, !why.isEmpty { Text(why).foregroundStyle(.tertiary) }
                }
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { editingId = t.id }
            Button { picking = true } label: {
                AppIconRow(apps: t.apps ?? [], size: 17)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Color.primary.opacity(0.06) : .clear))
            }
            .buttonStyle(.plain).help("Apps this session allows")
            .popover(isPresented: $picking, arrowEdge: .bottom) {
                AppPicker(selected: Binding(get: { t.apps ?? [] }, set: { e.updateTodo(t.id, apps: $0) }))
            }
            if hover {
                Button { editingId = t.id } label: { Image(systemName: "pencil").font(.system(size: 11.5)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Edit")
                Button { e.deleteTodo(t.id) } label: { Image(systemName: "trash").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove")
            }
            if day == .today && !t.isDone && (isNext || hover) && e.block == nil {
                Button("Lock in") { e.startTodo(t); NSApp.keyWindow?.close() }
                    .buttonStyle(PrimaryButtonStyle()).opacity(isNext || hover ? 1 : 0)
            }
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hover ? Color.primary.opacity(0.045) : .clear))
        .onHover { hoverId = $0 ? t.id : (hoverId == t.id ? nil : hoverId) }
        .animation(.easeOut(duration: 0.12), value: hoverId)
    }
}

struct EventRow: View {
    @EnvironmentObject var e: Engine
    let ev: CalEvent
    @State private var hover = false
    var body: some View {
        let ignored = e.isIgnored(ev)
        HStack(spacing: 12) {
            Text(ev.start.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(.tertiary)
                .frame(width: 66, alignment: .trailing)
            Image(systemName: "calendar").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.info)
                .frame(width: 20, height: 20).padding(4)
            VStack(alignment: .leading, spacing: 3) {
                Text(ev.title).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                Text("Calendar · until \(ev.end.formatted(date: .omitted, time: .shortened))" + (ignored ? " · won't ask" : ev.recurring ? " · repeats" : ""))
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hover && ev.end > Date() {
                if !ignored {
                    Button("Don't ask for this") { e.ignoreEvent(ev.title) }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                if e.block == nil {
                    Button("Lock in") {
                        let mins = max(5, Int(ev.end.timeIntervalSince(max(Date(), ev.start)) / 60))
                        e.startSession(task: ev.title, minutes: mins)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .opacity(ignored ? 0.6 : 1)
        .onHover { hover = $0 }
    }
}

// MARK: - Adding

/// The one box for planning. Without AI it reads "leetcode 45, co-op 90 at 2pm" itself (and shows what it read as you
/// type); with the AI planner on, the same text goes to the AI, which can also edit the plan ("free at 8 now").
struct QuickAddField: View {
    @EnvironmentObject var e: Engine
    var day: PlanDay
    var autoFocus = false
    var placeholder = "Add a session…"
    @State private var text = ""
    @FocusState private var focused: Bool

    private var preview: [PlanCommand] { e.cfg.aiOn ? [] : PlanParser.commands(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .bottom, spacing: 10) {
                Image(systemName: "plus").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent).padding(.bottom, 3)
                TextField(placeholder, text: $text, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...4)
                    .focused($focused).onSubmit(send)
                if e.planning {
                    ProgressView().controlSize(.small).padding(.bottom, 2)
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.black.opacity(0.85))
                            .frame(width: 26, height: 26).background(Circle().fill(text.isEmpty ? Color.secondary.opacity(0.35) : Theme.accent))
                    }
                    .buttonStyle(.plain).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty).keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(focused ? Theme.accent.opacity(0.7) : Theme.hairline, lineWidth: 1))
            if !preview.isEmpty {
                PlanPreviewChips(commands: preview, day: day)
            } else if let note = e.planNote {
                Label(note, systemImage: "checkmark.circle.fill").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text(e.planning ? (e.cfg.aiOn ? "Planning…" : "Adding…")
                     : e.cfg.aiOn ? "Return sends it to the AI planner · it sees your plan and calendar"
                                  : "Return applies it · try: done leetcode · essay at 3pm · push emails to tomorrow · free at 8")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
        }
        .onAppear { if autoFocus { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focused = true } } }
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !e.planning else { return }
        text = ""
        if e.cfg.aiOn { e.sendToPlanner(t, day: day) } else { e.applyTyped(t, day: day) }
    }
}

/// What the plan box will do with what you've typed, as chips (no AI): add, done, move, tomorrow, remove, re-time.
struct PlanPreviewChips: View {
    @EnvironmentObject var e: Engine
    var commands: [PlanCommand]
    var day: PlanDay
    /// How a typed line will be applied, as a chip: icon, text, detail.
    private func chip(_ c: PlanCommand) -> (String, String, String) {
        switch c {
        case .add(let p):
            if let s = p.start, p.minutes == nil, let t = e.match(p.task, in: e.list(day), open: true) { return ("clock.arrow.circlepath", t.task, "→ \(clockLabel(e.adjusted(s, day)))") }
            return ("plus", p.task, [p.minutes.map { "\($0)m" } ?? "45m", p.start.map(clockLabel) ?? (day == .today ? "next open" : "")].filter { !$0.isEmpty }.joined(separator: " · "))
        case .done(let q): return ("checkmark", e.match(q, in: e.list(day), open: true)?.task ?? q, "done")
        case .remove(let q): return ("xmark", e.match(q, in: e.list(day), open: false)?.task ?? q, "remove")
        case .move(let q, let s): return ("clock.arrow.circlepath", e.match(q, in: e.list(day), open: true)?.task ?? q, "→ \(clockLabel(e.adjusted(s, day)))")
        case .tomorrow(let q): return ("arrow.right", e.match(q, in: e.todos, open: true)?.task ?? q, "→ tomorrow")
        case .resize(let q, let m): return ("timer", e.match(q, in: e.list(day), open: true)?.task ?? q, "\(m) min")
        case .startFrom(let s): return ("arrow.down.to.line", "Re-time what's left", "from \(clockLabel(e.adjusted(s, day)))")
        }
    }


    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(commands.enumerated()), id: \.offset) { _, c in
                let (icon, title, detail) = chip(c)
                HStack(spacing: 5) {
                    Image(systemName: icon).font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.accent)
                    Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    Text(detail).font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Theme.accent.opacity(0.14)))
            }
        }
    }
}

// MARK: - Editing

/// Edit a session by hand: what, how long, when, which apps, whether it repeats, and which day.
struct TodoEditor: View {
    @EnvironmentObject var e: Engine
    let t: Todo
    var day: PlanDay
    var onClose: () -> Void
    @State private var task: String
    @State private var minutes: Int
    @State private var start: Date
    @State private var timed: Bool
    @State private var apps: [String]
    @State private var repeatDays: Set<Int>
    @FocusState private var taskFocused: Bool

    init(t: Todo, day: PlanDay, onClose: @escaping () -> Void) {
        self.t = t; self.day = day; self.onClose = onClose
        let s = parseHHMM(t.start ?? "")
        _task = State(initialValue: t.task)
        _minutes = State(initialValue: t.minutes)
        _start = State(initialValue: s ?? Date())
        _timed = State(initialValue: s != nil)
        _apps = State(initialValue: t.apps ?? [])
        _repeatDays = State(initialValue: Set(Engine.shared.routine(for: t)?.days ?? []))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("What are you doing? e.g. Problem set 4", text: $task)
                .textFieldStyle(.roundedBorder).focused($taskFocused).onSubmit(save)
            HStack(spacing: 14) {
                Stepper("\(minutes) min", value: $minutes, in: 5...240, step: 5).fixedSize()
                if timed {
                    DatePicker("", selection: $start, displayedComponents: .hourAndMinute).labelsHidden().fixedSize()
                    Button("Any time") { timed = false }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Theme.accent)
                } else {
                    Button("Set a time") { timed = true }.controlSize(.small)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Apps this session allows").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                AppChips(apps: $apps)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Repeat").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                RepeatPicker(days: $repeatDays)
            }
            HStack(spacing: 10) {
                Button(day == .today ? "Move to tomorrow" : "Move to today") { save(); e.move(t.id, to: day == .today ? .tomorrow : .today) }
                    .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onClose).controlSize(.small).keyboardShortcut(.cancelAction)
                Button("Save", action: save).buttonStyle(PrimaryButtonStyle())
                    .disabled(task.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.hairline))
        .onAppear { taskFocused = true }
    }

    private func save() {
        let text = task.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        e.updateTodo(t.id, task: text, start: timed ? hhmm(start) : "", minutes: minutes, apps: apps)
        let wasRepeating = Set(e.routine(for: t)?.days ?? [])
        if repeatDays != wasRepeating || (!repeatDays.isEmpty && t.isRoutine) {
            var updated = t; updated.task = text; updated.minutes = minutes; updated.start = timed ? hhmm(start) : ""; updated.apps = apps
            e.setRepeat(updated, days: repeatDays.isEmpty ? nil : Array(repeatDays))
        }
        onClose()
    }
}

/// Days a session repeats on: quick presets plus a toggle per weekday.
struct RepeatPicker: View {
    @Binding var days: Set<Int>
    private let symbols = Calendar.current.veryShortWeekdaySymbols   // S M T W T F S
    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Button("Never") { days = [] }
                Button("Every day") { days = Set(1...7) }
                Button("Weekdays") { days = [2, 3, 4, 5, 6] }
                Button("Weekends") { days = [1, 7] }
            } label: { Text(label).font(.system(size: 12)) }
                .menuStyle(.borderlessButton).fixedSize()
            ForEach(1...7, id: \.self) { d in
                let on = days.contains(d)
                Button { if on { days.remove(d) } else { days.insert(d) } } label: {
                    Text(symbols[d - 1]).font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
                        .foregroundStyle(on ? Color.black.opacity(0.85) : .secondary)
                        .background(Circle().fill(on ? Theme.accent : Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
            }
        }
    }
    private var label: String {
        if days.isEmpty { return "Never" }
        if days.count == 7 { return "Every day" }
        if days == [2, 3, 4, 5, 6] { return "Weekdays" }
        if days == [1, 7] { return "Weekends" }
        return "Custom"
    }
}

/// The apps as removable chips with icons, plus "Add app".
struct AppChips: View {
    @Binding var apps: [String]
    @State private var picking = false
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(apps, id: \.self) { a in
                HStack(spacing: 5) {
                    AppIconView(name: a, size: 15)
                    Text(a).font(.system(size: 12))
                    Button { apps.removeAll { $0 == a } } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 6).padding(.trailing, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            Button { picking = true } label: {
                Label("Add app", systemImage: "plus").font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().strokeBorder(Theme.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            .popover(isPresented: $picking, arrowEdge: .bottom) { AppPicker(selected: $apps) }
        }
    }
}

/// Search installed apps and tick the ones you want. Work apps and running apps are on top.
struct AppPicker: View {
    @Binding var selected: [String]
    @State private var query = ""
    private var names: [String] {
        let suggested = InstalledApps.suggested
        let rest = InstalledApps.all.map(\.name).filter { !suggested.contains($0) }
        let all = selected.filter { !suggested.contains($0) && !rest.contains($0) } + suggested + rest
        guard !query.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(query) || InstalledApps.display(for: $0).localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search apps", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(names, id: \.self) { n in
                        let on = selected.contains(n)
                        Button { if on { selected.removeAll { $0 == n } } else { selected.append(n) } } label: {
                            HStack(spacing: 8) {
                                AppIconView(name: n, size: 18)
                                Text(n).font(.system(size: 12.5))
                                if InstalledApps.display(for: n) != n {
                                    Text(InstalledApps.display(for: n)).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                                }
                                Spacer()
                                if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent) }
                            }
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.accent.opacity(0.1) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 280)
            Text("\(selected.count) selected · everything else gets covered").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(12).frame(width: 290)
    }
}

// The time on a plan row: click it to change when it starts.
struct TimeButton: View {
    @EnvironmentObject var e: Engine
    let t: Todo
    let label: String
    @State private var editing = false
    @State private var pick = Date()

    var body: some View {
        Button { pick = parseHHMM(t.start ?? "") ?? Date(); editing = true } label: {
            Text(label).font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
        }
        .buttonStyle(.plain).disabled(t.isDone).help("Change the start time")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                DatePicker("Starts", selection: $pick, displayedComponents: .hourAndMinute)
                HStack {
                    Button("Soonest") {
                        let id = t.id, m = t.minutes
                        DispatchQueue.global(qos: .userInitiated).async {
                            let s = soonestSlot(minutes: m, skip: id)
                            DispatchQueue.main.async { if let d = parseHHMM(s) { pick = d } }
                        }
                    }
                    Button("Any time") { e.updateTodo(t.id, start: ""); editing = false }
                    Spacer()
                    Button("Save") { e.updateTodo(t.id, start: hhmm(pick)); editing = false }.buttonStyle(PrimaryButtonStyle())
                }
                .controlSize(.small)
            }
            .padding(14).frame(width: 270)
        }
    }
}

/// "When do you want a longer break, and when do you want to be done?", asked once for each day you plan (the morning
/// screen, the planner), starting from your last answer. Once answered it's a one-line summary you click to change.
struct DayShapeCard: View {
    @EnvironmentObject var e: Engine
    let day: PlanDay
    @State private var editing = false
    @State private var breaks: [EditBreak] = []
    @State private var finish = Date()
    @State private var hasFinish = true
    @State private var level: Commitment?

    struct EditBreak: Identifiable { let id = UUID(); var start: Date; var minutes: Int }

    private var shape: DayShape? { e.shape(day) }
    private var dayDate: Date { day == .today ? Date() : tomorrowDate() }

    var body: some View {
        Group { if shape == nil || editing { form } else { summary } }
            .onAppear(perform: load)
            .onChange(of: day) { _, _ in editing = false; load() }
    }

    private var summary: some View {
        Button { load(); editing = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "cup.and.saucer").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(shape?.summary ?? "").font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Text("Change").font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Change your breaks and finish time")
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How much can you commit to \(day == .today ? "today" : "tomorrow")?")
                .font(.system(size: 14, weight: .semibold))
            HStack(spacing: 8) {
                ForEach(Commitment.allCases, id: \.self) { c in
                    Button { level = level == c ? nil : c } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).font(.system(size: 13, weight: .semibold))
                            Text(c.blurb).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(level == c ? Theme.accent.opacity(0.18) : Color.primary.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(level == c ? Theme.accent.opacity(0.7) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("When do you want a longer break, and when do you want to be done?")
                .font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            ForEach($breaks) { $b in
                HStack(spacing: 8) {
                    Text("Break at").font(.system(size: 12.5)).foregroundStyle(.secondary).frame(width: 116, alignment: .leading)
                    DatePicker("", selection: $b.start, displayedComponents: .hourAndMinute).labelsHidden()
                    Picker("", selection: $b.minutes) {   // up to an afternoon off (a movie with friends, then back to it)
                        ForEach([15, 30, 45, 60, 90, 120, 150, 180, 240, 300, 360], id: \.self) { Text(fmtMinutes($0)).tag($0) }
                    }
                    .labelsHidden().frame(width: 120)
                    Button { breaks.removeAll { $0.id == b.id } } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove this break")
                }
            }
            Button { breaks.append(EditBreak(start: nextBreakStart, minutes: 60)) } label: {
                Label(breaks.isEmpty ? "Add a break" : "Add another break", systemImage: "plus").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            HStack(spacing: 8) {
                Toggle("Finish work at", isOn: $hasFinish).toggleStyle(.checkbox).font(.system(size: 12.5)).fixedSize().frame(width: 116, alignment: .leading)
                DatePicker("", selection: $finish, displayedComponents: .hourAndMinute).labelsHidden().disabled(!hasFinish)
            }
            HStack {
                if shape == nil { Button("Skip") { e.setShape(DayShape(), day: day) }.buttonStyle(SecondaryButtonStyle()) }
                else { Button("Cancel") { editing = false }.buttonStyle(SecondaryButtonStyle()) }
                Spacer()
                Button(day == .today ? "Plan my day" : "Plan tomorrow", action: save).buttonStyle(PrimaryButtonStyle())
                    .help("Fits your plan to this and fills the free time from your to-do list")
            }
            .controlSize(.small)
        }
    }

    /// An hour after the last break, else 12:30.
    private var nextBreakStart: Date {
        breaks.last.map { $0.start.addingTimeInterval(Double($0.minutes + 60) * 60) } ?? parseHHMM("12:30", on: dayDate) ?? dayDate
    }

    /// The day's answer, else your last one, else a lunch hour and a 6pm finish.
    private func load() {
        let s = shape ?? DayShape.last ?? DayShape(breaks: [.init(start: "12:30", minutes: 60)], finish: "18:00")
        breaks = s.breaks.compactMap { b in parseHHMM(b.start, on: dayDate).map { EditBreak(start: $0, minutes: b.minutes) } }
        hasFinish = s.finish != nil
        level = shape?.level   // asked fresh each day: how today feels isn't how yesterday did
        finish = parseHHMM(s.finish ?? "18:00", on: dayDate) ?? dayDate
    }

    private func save() {
        let list = breaks.sorted { $0.start < $1.start }.map { DayShape.Break(start: hhmm($0.start), minutes: $0.minutes) }
        e.setShape(DayShape(breaks: list, finish: hasFinish ? hhmm(finish) : nil, level: level), day: day)
        e.fillFromList(day)   // the day gets built from your to-do list, around what's already planned
        editing = false
    }
}
