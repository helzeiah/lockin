import AppKit
import SwiftUI

/// The running to-do list: everything you need to do, with due dates, lengths and stars, until it's done. Planning a
/// day pulls from it; lockin asks a few questions about each task so it can plan it well.
struct TasksView: View {
    @EnvironmentObject var e: Engine
    @State private var text = ""
    @State private var editingId: String?
    @State private var hoverId: String?
    @State private var showDone = false
    @State private var questionsHidden = false
    @State private var effort = 0                // difficulty for what you add next; 0 = not set
    @FocusState private var addFocused: Bool

    private var open: [ListTask] { TaskList.ranked(e.listTasks) }
    private var finished: [ListTask] { e.listTasks.filter(\.isDone).sorted { ($0.done ?? "") > ($1.done ?? "") } }
    /// The next task with questions waiting: the newest first, so what you just added gets asked about right away.
    private var asking: ListTask? {
        e.listTasks.filter { !$0.isDone && ($0.needsAnswers || (e.cfg.aiOn && $0.ai_questions == nil && !($0.skipped ?? false))) }
            .max { ($0.created ?? "", -(e.listTasks.firstIndex(of: $0) ?? 0)) < ($1.created ?? "", -(e.listTasks.firstIndex(of: $1) ?? 0)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            addField.padding(.horizontal, 24).padding(.bottom, 12)
            if let t = asking, !questionsHidden {
                TaskQuestionsCard(t: t, waiting: e.listTasks.filter(\.needsAnswers).count) { questionsHidden = true }
                    .padding(.horizontal, 24).padding(.bottom, 12)
            }
            if let err = e.listError { Text(err).font(.system(size: 12)).foregroundStyle(Theme.danger).padding(.horizontal, 28).padding(.bottom, 6) }
            if e.listTasks.isEmpty { empty } else { list }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppBackground())
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text(subtitle).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Text("To-do").font(.system(size: 28, weight: .bold)).tracking(-0.5)
            }
            Spacer()
            if questionsHidden, asking != nil {
                Button("Questions") { questionsHidden = false }.buttonStyle(SecondaryButtonStyle()).help("Answer lockin's questions about your tasks")
            }
        }
        .padding(.horizontal, 28).padding(.top, 36).padding(.bottom, 14)
    }

    private var subtitle: String {
        let due = open.filter { ($0.daysLeft() ?? 99) <= 7 }.count
        return "\(open.count) open" + (due > 0 ? " · \(due) due this week" : "")
    }

    private var addField: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill").font(.system(size: 16)).foregroundStyle(Theme.accent)
                TextField("Add a task: sell fridge due fri 30m", text: $text, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...6)
                    .focused($addFocused).onSubmit(add)
                Picker("", selection: $effort) {
                    Text("Difficulty").tag(0)
                    ForEach(1...3, id: \.self) { Text(ListTask.effortNames[$0]!).tag($0) }
                }
                .labelsHidden().fixedSize().help("How hard it is to get into. Harder tasks get planned earlier in the day")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
            Text("\"due fri\", \"by 12/5\", \"30m\", a leading * (star) and \"hard\" or \"easy\" at the end work. Paste a list to add one task per line.")
                .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.leading, 4)
        }
    }

    private func add() {
        guard !e.addListTasks(text, effort: effort == 0 ? nil : effort).isEmpty else { return }
        text = ""; questionsHidden = false; addFocused = true
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "checklist").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            Text("Nothing on your list").font(.system(size: 16, weight: .semibold))
            Text("Add everything you need to do, with due dates if they have them.\nWhen you plan a day, lockin suggests what to work on.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Open tasks in sections (overdue, due today, starred, coming up, anytime), then the finished ones, folded.
    private var sections: [(String, [ListTask])] {
        func tier(_ t: ListTask) -> Int {
            guard let n = t.daysLeft() else { return t.isStarred ? 2 : 4 }
            return n < 0 ? 0 : n == 0 ? 1 : t.isStarred ? 2 : 3
        }
        let names = ["Overdue", "Due today", "Starred", "Coming up", "Anytime"]
        return names.indices.compactMap { i in
            let l = open.filter { tier($0) == i }
            return l.isEmpty ? nil : (names[i], l)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(sections, id: \.0) { name, tasks in
                    SectionLabel(text: name).padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 2)
                    ForEach(tasks) { row($0) }
                }
                if !finished.isEmpty {
                    Button { withAnimation(.easeOut(duration: 0.15)) { showDone.toggle() } } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(showDone ? 90 : 0))
                            Text("Completed (\(finished.count))").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 14)
                    }
                    .buttonStyle(.plain)
                    if showDone { ForEach(finished.prefix(50)) { row($0) } }
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 16)
        }
    }

    @ViewBuilder private func row(_ t: ListTask) -> some View {
        if editingId == t.id { ListTaskEditor(t: t) { editingId = nil }.padding(.vertical, 4) }
        else { ListTaskRow(t: t, hoverId: $hoverId, editingId: $editingId) }
    }
}

/// A task on the list: done circle, title, its notes, due date and length; star, plan-today and remove on hover.
struct ListTaskRow: View {
    @EnvironmentObject var e: Engine
    let t: ListTask
    @Binding var hoverId: String?
    @Binding var editingId: String?
    private var hover: Bool { hoverId == t.id }
    private var onToday: Bool { e.todos.contains { $0.task_id == t.id && !$0.isDone } }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { e.setListDone(t.id, !t.isDone) } label: {
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
                Text(t.title).font(.system(size: 14, weight: .medium)).strikethrough(t.isDone)
                    .foregroundStyle(t.isDone ? .tertiary : .primary).lineLimit(2)
                // Notes on one line, the first step on the next; answers to the AI's questions live in the editor.
                if let n = t.notes, !n.isEmpty {
                    Text(n.split(whereSeparator: \.isNewline).joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                if let f = t.first_step, !f.isEmpty, !t.isDone {
                    Label(f, systemImage: "arrow.turn.down.right").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        .help("First step: \(f)")
                }
                if !t.isDone, chips {
                    HStack(spacing: 6) {
                        if !t.dueLabel().isEmpty { chip(t.dueLabel(), icon: "clock", tint: dueTint) }
                        chip((t.minutes == nil || t.estimated == true ? "~" : "") + fmtMinutes(t.length), icon: "hourglass", tint: .secondary)
                            .help(t.minutes == nil || t.estimated == true ? "Estimated generously. Click the task to set it yourself" : "How long it takes")
                        effortChip
                        if onToday { chip("On today's plan", icon: "sun.max", tint: Theme.accent) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { editingId = t.id }
            if !t.isDone && hover && !onToday {
                Button("Today") { e.planFromList([t], day: .today) }.buttonStyle(SecondaryButtonStyle()).disabled(e.planning)
                    .help("Put it on today's plan at the soonest open time")
            }
            if hover {
                Button { e.deleteListTask(t.id) } label: { Image(systemName: "trash").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove")
            }
            if !t.isDone {
                Button { e.updateListTask(t.id) { $0.starred = !$0.isStarred } } label: {
                    Image(systemName: t.isStarred ? "star.fill" : "star").font(.system(size: 13))
                        .foregroundStyle(t.isStarred ? Theme.flame : Color.secondary.opacity(hover ? 0.8 : 0.35))
                }
                .buttonStyle(.plain).help(t.isStarred ? "Unstar" : "Star: one of the few that matter most")
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hover ? Color.primary.opacity(0.045) : .clear))
        .onHover { hoverId = $0 ? t.id : (hoverId == t.id ? nil : hoverId) }
        .animation(.easeOut(duration: 0.12), value: hoverId)
    }

    private var chips: Bool { true }

    /// Its difficulty, click to change (only on hover while it isn't set).
    @ViewBuilder private var effortChip: some View {
        if t.effort != nil || hover {
            Menu {
                ForEach(1...3, id: \.self) { n in Button(ListTask.effortNames[n]!) { e.updateListTask(t.id) { $0.effort = n } } }
                if t.effort != nil { Divider(); Button("Not set") { e.updateListTask(t.id) { $0.effort = nil } } }
            } label: {
                chip(t.effort.flatMap { ListTask.effortNames[$0] } ?? "Difficulty", icon: "flame",
                     tint: t.effort == 3 ? Theme.flame : t.effort == nil ? Color.secondary.opacity(0.6) : .secondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("How hard it is to get into. Harder tasks get planned earlier in the day")
        }
    }
    private var dueTint: Color {
        guard let n = t.daysLeft() else { return .secondary }
        return n < 0 ? Theme.danger : n <= 1 ? Theme.flame : .secondary
    }
    private func chip(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9.5, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().strokeBorder(tint.opacity(0.35)))
    }
}

/// Click a task to change it: title, notes, due date, length, first step.
struct ListTaskEditor: View {
    @EnvironmentObject var e: Engine
    let t: ListTask
    let onClose: () -> Void
    @State private var title = ""
    @State private var notes = ""
    @State private var hasDue = false
    @State private var due = Date()
    @State private var minutes = 0
    @State private var firstStep = ""
    @State private var effort = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Task", text: $title).textFieldStyle(.plain).font(.system(size: 14, weight: .semibold))
            TextField("Notes", text: $notes, axis: .vertical).textFieldStyle(.plain).font(.system(size: 12.5)).lineLimit(1...5)
            HStack(spacing: 14) {
                Toggle("Due", isOn: $hasDue).toggleStyle(.checkbox)
                DatePicker("", selection: $due, displayedComponents: .date).labelsHidden().disabled(!hasDue)
                Picker("Length", selection: $minutes) {
                    Text("Estimate (~\(fmtMinutes(t.minutes ?? t.length)))").tag(0)
                    ForEach([15, 30, 45, 60, 90, 120, 180, 240], id: \.self) { Text(fmtMinutes($0)).tag($0) }
                }
                .frame(width: 170)
                Picker("Difficulty", selection: $effort) {
                    Text("Not set").tag(0)
                    ForEach(1...3, id: \.self) { Text(ListTask.effortNames[$0]!).tag($0) }
                }
                .frame(width: 170)
            }
            .font(.system(size: 12.5))
            TextField("First step", text: $firstStep).textFieldStyle(.plain).font(.system(size: 12.5))
            if let qa = t.qa, !qa.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your answers").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(Array(qa.enumerated()), id: \.offset) { _, x in
                        Text("\(x.q) \(x.a)").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            if let steps = t.steps, !steps.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Steps (from the AI)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                        Text("\(i + 1). \(s.task) · \(s.minutes) min").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else if e.breakingDown == t.id {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Breaking it into steps…").font(.system(size: 11.5)).foregroundStyle(.secondary) }
            }
            HStack {
                Button("Delete") { e.deleteListTask(t.id); onClose() }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Theme.danger)
                Spacer()
                Button("Cancel", action: onClose).controlSize(.small).keyboardShortcut(.cancelAction)
                Button("Save", action: save).buttonStyle(PrimaryButtonStyle()).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.hairline))
        .onAppear {
            title = t.title; notes = t.notes ?? ""; hasDue = t.dueDate != nil; due = t.dueDate ?? Stats.today
            minutes = t.estimated == true ? 0 : (t.minutes ?? 0); firstStep = t.first_step ?? ""; effort = t.effort ?? 0
        }
    }

    private func save() {
        let name = title.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        e.updateListTask(t.id) { x in
            x.title = name
            x.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            x.due = hasDue ? DateFormatter.ymd.string(from: due) : (x.due == nil ? nil : "")
            if minutes > 0 { x.minutes = minutes; x.estimated = false }   // a length you set replaces the estimate
            x.effort = effort > 0 ? effort : nil
            let step = firstStep.trimmingCharacters(in: .whitespaces)
            x.first_step = step.isEmpty ? x.first_step : step
        }
        onClose()
    }
}

/// lockin's questions about a task, one at a time: when it's due, then (with the AI planner on) a few questions about
/// that task in particular. Every one can be skipped. Its length and first step aren't asked: they're estimated.
struct TaskQuestionsCard: View {
    @EnvironmentObject var e: Engine
    let t: ListTask
    let waiting: Int
    let onHide: () -> Void
    @State private var answer = ""
    @State private var picking = false
    @State private var pick = Date()
    @FocusState private var answerFocused: Bool

    private var basic: ListTask.Question? { t.openQuestions.first }
    private var aiQuestion: String? { t.ai_questions?.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("About \u{201C}\(t.title)\u{201D}", systemImage: "questionmark.bubble")
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if waiting > 1 { Text("\(waiting - 1) more after this").font(.system(size: 11)).foregroundStyle(.tertiary) }
                Button("Not now", action: onHide).buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            content
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.accent.opacity(0.25)))
        .onChange(of: t.id) { _, _ in answer = "" }
        .task(id: "\(t.id)-\(basic?.rawValue ?? "")-\(t.ai_questions == nil)") {
            // The basics are answered: let the AI ask about this task in particular.
            if basic == nil, t.ai_questions == nil, e.cfg.aiOn { e.askAI(about: t.id) }
        }
    }

    @ViewBuilder private var content: some View {
        switch basic {
        case .due?:
            question("When is it due?")
            HStack(spacing: 6) {
                ForEach(["Today", "Tomorrow", "Fri", "Next week"], id: \.self) { w in
                    Button(w) { setDue(TaskList.dueDate(w, now: Date())) }.buttonStyle(SecondaryButtonStyle())
                }
                Button("Pick a date…") { picking = true }.buttonStyle(SecondaryButtonStyle())
                    .popover(isPresented: $picking) {
                        VStack(spacing: 8) {
                            DatePicker("", selection: $pick, in: Stats.today..., displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()
                            Button("Set") { picking = false; setDue(pick) }.buttonStyle(PrimaryButtonStyle())
                        }
                        .padding(12)
                    }
                Button("No due date") { e.updateListTask(t.id) { $0.due = "" } }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case nil:
            if let q = aiQuestion {
                question(q)
                answerField("Your answer") { a in e.answerAI(t.id, question: q, answer: a) }
            } else if e.askingAI == t.id {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Thinking of questions about this task…").font(.system(size: 12.5)).foregroundStyle(.secondary) }
            } else {
                Text("That's everything for this one.").font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
        }
        if basic != nil || aiQuestion != nil {
            Button("Stop asking about this one") { e.updateListTask(t.id) { $0.skipped = true; $0.ai_questions = [] } }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    private func question(_ q: String) -> some View {
        Text(q).font(.system(size: 14.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
    }

    /// A text answer with Save and Skip (an empty answer is a skip).
    private func answerField(_ placeholder: String, save: @escaping (String) -> Void) -> some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $answer).textFieldStyle(.plain).font(.system(size: 13))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
                .focused($answerFocused)
                .onSubmit { save(answer.trimmingCharacters(in: .whitespacesAndNewlines)); answer = "" }
            Button("Skip") { save(""); answer = "" }.buttonStyle(SecondaryButtonStyle())
            Button("Save") { save(answer.trimmingCharacters(in: .whitespacesAndNewlines)); answer = "" }
                .buttonStyle(PrimaryButtonStyle()).disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onAppear { answerFocused = true }
    }

    private func setDue(_ d: Date?) {
        guard let d else { return }
        e.updateListTask(t.id) { $0.due = DateFormatter.ymd.string(from: d) }
    }
}
