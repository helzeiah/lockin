import AppKit
import SwiftUI

// "Plan my day": today's focus blocks on a timeline, added by hand or by talking to the AI planner.
@MainActor
final class Planner {
    static let shared = Planner()
    private var window: KeyPanel?

    func open() {
        Engine.shared.card = nil      // one thing at a time
        Engine.shared.reloadTodos()
        if let w = window { w.show(); return }
        let w = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 460, height: 480)
        w.contentView = NSHostingView(rootView: PlannerView().environmentObject(Engine.shared))
        w.center()
        window = w
        w.show()
    }
}

/// A regular-looking window that never activates the app. Activating an accessory app swaps the menu bar to its
/// own menus, and on a notched Mac with a full menu bar macOS then hides status items, the lockin icon included.
/// It still becomes key, so text fields, popovers and keyboard shortcuts work.
final class KeyPanel: NSPanel {
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
}

struct PlannerView: View {
    @EnvironmentObject var e: Engine
    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var hoverId: String?

    private var dateLine: String { Date().formatted(.dateTime.weekday(.wide).month(.wide).day()) }
    private var hasPlan: Bool { !e.todos.isEmpty }

    var body: some View {
        ZStack {
            VisualEffect(material: .underWindowBackground)
            VStack(spacing: 0) {
                header
                if hasPlan { timeline } else { empty }
                if !e.backlog.isEmpty { backlogSection }
                ManualAdd().frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.top, 8)
                composer
            }
        }
        .frame(minWidth: 460, minHeight: 480)
        .onAppear { focused = e.cfg.aiOn }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            controls
            titleRow
        }
        .padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 16)
    }

    // The menu bar's core controls, in case macOS hides the icon on a crowded menu bar.
    private var controls: some View {
        HStack(spacing: 14) {
            Spacer()
            Menu {
                let quick = e.quickApps.isEmpty ? (e.lastExternalApp.isEmpty ? [] : [e.lastExternalApp]) : e.quickApps
                Section(quick.isEmpty ? "Quick focus" : "Quick focus: \(quick.joined(separator: ", "))") {
                    ForEach([25, 45, 60, 90], id: \.self) { m in
                        Button("\(m) min") { e.startQuick(minutes: m, apps: quick); NSApp.keyWindow?.close() }.disabled(quick.isEmpty)
                    }
                }
                if !e.cfg.blocks.isEmpty {
                    Section("My blocks") {
                        ForEach(e.cfg.blocks) { p in
                            Button("\(p.name) · \(p.minutes) min") { e.startBlock(p); NSApp.keyWindow?.close() }
                        }
                    }
                }
            } label: { Label("Start a block", systemImage: "timer") }
                .menuStyle(.borderlessButton).fixedSize()
            Button { SettingsWindow.shared.open() } label: { Image(systemName: "gearshape") }.help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit lockin")
        }
        .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(.secondary)
        .frame(height: 22)
    }

    private var titleRow: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(dateLine).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Text("Plan my day").font(.system(size: 26, weight: .bold)).tracking(-0.4)
            }
            Spacer()
            if hasPlan { summary }
        }
    }

    private var summary: some View {
        let open = e.todos.filter { !$0.isDone }
        let mins = open.reduce(0) { $0 + $1.minutes }
        let end = open.compactMap { t -> Date? in startDate(t).map { $0.addingTimeInterval(Double(t.minutes * 60)) } }.max()
        return VStack(alignment: .trailing, spacing: 2) {
            Text(open.isEmpty ? "All done" : "\(mins / 60 > 0 ? "\(mins / 60)h " : "")\(mins % 60)m left")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            if let end { Text("done around \(end.formatted(date: .omitted, time: .shortened))").font(.system(size: 11.5)).foregroundStyle(.secondary) }
        }
    }

    private func startDate(_ t: Todo) -> Date? {
        guard let s = t.start, s.count >= 4 else { return nil }
        let p = s.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2 else { return nil }
        return Calendar.current.date(bySettingHour: p[0], minute: p[1], second: 0, of: Date())
    }

    private var timeline: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                let nextId = e.nextTodo?.id
                ForEach(e.todos) { t in row(t, isNext: t.id == nextId) }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
    }

    private func row(_ t: Todo, isNext: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            TimeButton(t: t, label: t.isDone ? "" : (startDate(t)?.formatted(date: .omitted, time: .shortened) ?? "later"))
                .frame(width: 62, alignment: .trailing)
            Button { e.setDone(t.id, !t.isDone) } label: {
                ZStack {
                    Circle().strokeBorder(t.isDone ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 1.5)
                    if t.isDone {
                        Circle().fill(Color.accentColor)
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 20, height: 20)
                .padding(4)                       // bigger target
                .contentShape(Rectangle())        // the empty middle counts as part of the button
            }
            .buttonStyle(.plain)
            .help(t.isDone ? "Mark not done" : "Mark done")
            VStack(alignment: .leading, spacing: 3) {
                Text(t.task).font(.system(size: 14, weight: .medium))
                    .strikethrough(t.isDone).foregroundStyle(t.isDone ? .tertiary : .primary)
                HStack(spacing: 8) {
                    HStack(spacing: 5) { Circle().fill(colorFor(block: t.block)).frame(width: 7, height: 7); Text(t.block) }
                    Text("\(t.minutes) min")
                    if let why = t.why, !why.isEmpty { Text(why).foregroundStyle(.tertiary) }
                }
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if hoverId == t.id {
                Button { e.deleteTodo(t.id) } label: { Image(systemName: "trash").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove")
            }
            if !t.isDone && (isNext || hoverId == t.id) {
                Button("Start") { e.startTodo(t); NSApp.keyWindow?.close() }   // starting = done planning
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(isNext ? .accentColor : .gray)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hoverId == t.id ? Color.primary.opacity(0.05) : .clear))
        .onHover { hoverId = $0 ? t.id : (hoverId == t.id ? nil : hoverId) }
        .animation(.easeOut(duration: 0.12), value: hoverId)
    }

    @State private var backlogOpen = true
    private func dayLabel(_ d: String?) -> String {
        guard let d, let date = DateFormatter.ymd.date(from: d) else { return "" }
        if Calendar.current.isDateInYesterday(date) { return "yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }

    // Leftovers from earlier days: visible while planning, never nudged about.
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
                if backlogOpen {
                    Button("Clear") { e.clearBacklog() }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            if backlogOpen {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(e.backlog) { t in
                            HStack(spacing: 10) {
                                Circle().fill(colorFor(block: t.block)).frame(width: 6, height: 6)
                                Text(t.task).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 6)
                                Text("\(t.minutes)m · \(dayLabel(t.from))").font(.system(size: 11, design: .rounded)).foregroundStyle(.tertiary)
                                Button { e.addFromBacklog(t) } label: { Label("Today", systemImage: "plus").font(.system(size: 11, weight: .semibold)) }
                                    .buttonStyle(.bordered).controlSize(.mini).disabled(e.planning)
                                Button { e.dropFromBacklog(t.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                                    .buttonStyle(.plain).foregroundStyle(.tertiary).help("Drop it")
                            }
                            .padding(.vertical, 4).padding(.horizontal, 8)
                        }
                    }
                }
                .frame(maxHeight: 130)
            }
        }
        .padding(.horizontal, 24).padding(.top, 6)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "sun.max").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            Text("Nothing planned yet").font(.system(size: 15, weight: .semibold))
            Text("Add blocks yourself below, or tell the AI what's on your plate\nand it'll fit everything around your calendar.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var composer: some View {
        if e.cfg.aiOn { aiComposer } else {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.tertiary)
                Text("Want to plan by chatting instead? Turn on the AI planner in Settings.").foregroundStyle(.tertiary)
                Button("Settings…") { SettingsWindow.shared.open() }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                Spacer()
                if hasPlan { Button("Clear day") { e.clearDay() }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 18)
        }
    }

    private var aiComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !e.chat.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(e.chat.suffix(3).enumerated()), id: \.offset) { _, m in
                        HStack {
                            if m.role != "planner" { Spacer(minLength: 60) }
                            Text(m.text).font(.system(size: 12.5)).padding(.horizontal, 11).padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(m.role != "planner" ? Color.primary.opacity(0.07) : Color.accentColor.opacity(0.16)))
                                .foregroundStyle(m.role != "planner" ? .secondary : .primary)
                            if m.role == "planner" { Spacer(minLength: 60) }
                        }
                    }
                }
            }
            if let err = e.planError {
                Text("Couldn't update the plan: \(err)").font(.system(size: 12)).foregroundStyle(.red)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(hasPlan ? "Tell me what changed: \"finished the stats hw\", \"free at 8 now\"…"
                                  : "What do you need to get done today? Messy is fine.", text: $text, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...5)
                    .focused($focused)
                    .onSubmit(send)
                if e.planning {
                    ProgressView().controlSize(.small).padding(.bottom, 2)
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 26, height: 26).background(Circle().fill(text.isEmpty ? Color.secondary.opacity(0.4) : Color.accentColor))
                    }
                    .buttonStyle(.plain).disabled(text.isEmpty).keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(focused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: 1))
            HStack {
                Text(e.planning ? (hasPlan ? "Updating your plan…" : "Lining up your day…") : "Return to send · the AI sees your calendar and plan")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                Spacer()
                if hasPlan { Button("Clear day") { e.clearDay() }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 18)
    }

    private func send() {
        let t = text
        guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        text = ""
        e.sendToPlanner(t)
    }
}

// "+ Add a block": task, focus mode, length and start, pre-filled with the soonest open time. No AI involved.
struct ManualAdd: View {
    @EnvironmentObject var e: Engine
    @State private var open = false
    @State private var task = ""
    @State private var block = ""
    @State private var minutes = 45
    @State private var start = Date()
    @State private var suggested = true     // start still holds the suggestion (not picked by hand)
    @State private var noRoom = false
    @FocusState private var taskFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if open { form } else {
                Button { openForm() } label: {
                    Label("Add a block", systemImage: "plus").font(.system(size: 12.5, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("What are you doing? e.g. Problem set 4", text: $task)
                .textFieldStyle(.roundedBorder).focused($taskFocused).onSubmit(add)
            HStack(spacing: 12) {
                Picker("", selection: $block) { ForEach(e.cfg.blocks) { b in Text(b.name).tag(b.name) } }
                    .labelsHidden().frame(maxWidth: 170)
                    .onChange(of: block) { _, b in
                        if let p = e.presetFor(b) { minutes = p.minutes }
                        refreshSuggestion()
                    }
                Stepper("\(minutes) min", value: $minutes, in: 5...240, step: 5)
                    .onChange(of: minutes) { _, _ in refreshSuggestion() }
                    .fixedSize()
                DatePicker("", selection: Binding(get: { start }, set: { start = $0; suggested = false }), displayedComponents: .hourAndMinute)
                    .labelsHidden().fixedSize()
            }
            HStack(spacing: 10) {
                Text(noRoom ? "Nothing open before the end of the day" : suggested ? "Soonest open time" : "Your time")
                    .font(.system(size: 11.5)).foregroundStyle(noRoom ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                if !suggested { Button("Use soonest") { suggested = true; refreshSuggestion() }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Color.accentColor) }
                Spacer()
                Button("Cancel") { open = false }.controlSize(.small)
                Button("Add", action: add).buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(task.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func openForm() {
        task = ""; suggested = true
        if block.isEmpty || e.presetFor(block) == nil { block = e.cfg.blocks.first?.name ?? "" }
        minutes = e.presetFor(block)?.minutes ?? 45
        open = true; taskFocused = true
        refreshSuggestion()
    }

    private func refreshSuggestion() {
        guard suggested else { return }
        let m = minutes
        DispatchQueue.global(qos: .userInitiated).async {
            let s = soonestSlot(minutes: m)
            DispatchQueue.main.async {
                guard suggested, m == minutes else { return }
                noRoom = s.isEmpty
                if let d = parseHHMM(s) { start = d }
            }
        }
    }

    private func add() {
        let t = task.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        e.addTodo(task: t, block: block, minutes: minutes, start: hhmm(start))
        task = ""; suggested = true; refreshSuggestion(); taskFocused = true   // ready for the next one
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
                    Button("Unschedule") { e.updateTodo(t.id, start: ""); editing = false }
                    Spacer()
                    Button("Save") { e.updateTodo(t.id, start: hhmm(pick)); editing = false }.buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
            .padding(14).frame(width: 260)
        }
    }
}

func parseHHMM(_ s: String) -> Date? {
    let p = s.split(separator: ":").compactMap { Int($0) }
    guard p.count == 2 else { return nil }
    return Calendar.current.date(bySettingHour: p[0], minute: p[1], second: 0, of: Date())
}
func hhmm(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
    return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
}

extension DateFormatter {
    static let ymd: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
}
