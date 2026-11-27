import Foundation

/// The running to-do list: adding and finishing tasks, putting them on a day's plan, nudges when something's due, and
/// the questions lockin asks about each task.
extension Engine {
    /// Changes the list on disk and here.
    func editList(_ change: (inout [ListTask]) -> Void) {
        var d = TaskListDoc.load()
        change(&d.tasks)
        d.save(); listTasks = d.tasks
    }

    /// Sessions finished elsewhere (a session's timer, the AI planner) tick their list task off too.
    func syncListFromPlan(_ d: TodoDoc) {
        var list = TaskListDoc.load()
        let finished = Set((d.items + (d.tomorrow ?? [])).filter(\.isDone).compactMap(\.task_id))
        var changed = false
        for i in list.tasks.indices where finished.contains(list.tasks[i].id) && !list.tasks[i].isDone {
            list.tasks[i].done = today(); changed = true
        }
        if changed { list.save() }
        listTasks = list.tasks
    }

    /// Adds what you typed or pasted (see TaskList.parse), newest on top, with `effort` where you didn't type one.
    /// Returns the new tasks.
    @discardableResult func addListTasks(_ text: String, effort: Int? = nil) -> [ListTask] {
        let new = TaskList.parse(text).map { t in
            var t = t
            t.effort = t.effort ?? effort
            if t.minutes == nil { t.minutes = Estimate.minutes(t.title, notes: t.notes ?? ""); t.estimated = true }   // until the AI's is in
            return t
        }
        if !new.isEmpty { editList { $0.insert(contentsOf: new, at: 0) }; breakDownNext() }
        return new
    }

    func updateListTask(_ id: String, _ change: (inout ListTask) -> Void) {
        editList { list in if let i = list.firstIndex(where: { $0.id == id }) { change(&list[i]) } }
    }

    func deleteListTask(_ id: String) { editList { $0.removeAll { $0.id == id } } }

    /// Finishing a task (or taking that back). Its sessions on today's and tomorrow's plan follow (`plan`).
    func setListDone(_ id: String, _ done: Bool, plan: Bool = true) {
        updateListTask(id) { $0.done = done ? today() : nil }
        guard plan else { return }
        for t in todos + tomorrow where t.task_id == id && t.isDone != done { setDone(t.id, done) }
    }

    /// Puts list tasks on a day's plan, then arranges the day (see arrangeDay). Their apps come from their words, the
    /// same as anything you type in. With a level set, a task the AI broke into steps becomes pieces made of them.
    func planFromList(_ tasks: [ListTask], day: PlanDay) {
        let fresh = tasks.filter { t in !t.isDone && !list(day).contains { $0.task_id == t.id } }
        guard !fresh.isEmpty else { return }
        let cfg = self.cfg, level = level(day)
        planning = true
        Task.detached(priority: .userInitiated) {
            let history = TaskMatch.history()
            var added: [Todo] = []
            for t in fresh {
                let match = TaskMatch.apps(for: t.title, cfg: cfg, history: history)
                let item = Todo(id: Todo.newId(), task: t.title, block: match.rule ?? "", minutes: t.length, start: "",
                                apps: match.apps, task_id: t.id, effort: t.effort)
                added += level.map { l in
                    let steps = l.group(t.steps ?? [], total: t.length)
                    return TodoDoc.cut(item, l, steps: steps.count > 1 ? steps : [], firstStep: t.first_step)
                } ?? [item]
            }
            let pieces = added
            await MainActor.run {
                var d = TodoDoc.load()
                d.edit(day) { $0 += pieces }
                d.save(); self.reloadTodos()
                self.arrangeDay(day)
                self.planning = false
                self.showPlanNote("Added \(fresh.count) from your to-do list" + (day == .tomorrow ? " to tomorrow" : "")
                                  + (pieces.count > fresh.count ? " in \(pieces.count) pieces" : ""))
            }
        }
    }

    /// Builds a day around how much you can commit to: sessions cut to the day's level (`recut` also joins up pieces
    /// you haven't started, for a new level), then the most time-sensitive, hardest and longest first while you're
    /// fresh, easier ones as the day goes on. Today they're timed one after another from now, around your calendar,
    /// breaks and finish time; times you set yourself and repeats stay put. Tomorrow's are just put in that order.
    /// `reorder: false` (after the AI plans) only cuts to the level: the AI's order and times stay, pieces follow
    /// the piece before them.
    func arrangeDay(_ day: PlanDay, recut: Bool = false, reorder: Bool = true) {
        var d = TodoDoc.load()
        var list = d.list(day)
        let keep = day == .today ? block?.todoId : nil
        if let level = level(day) {
            list = recut ? TodoDoc.recut(list, level, keep: keep)
                         : list.flatMap { t in t.part == nil && !t.isDone && (t.spent ?? 0) == 0 && t.source == nil && t.id != keep
                                                ? TodoDoc.cut(t, level, firstStep: listTasks.first { $0.id == t.task_id }?.first_step) : [t] }
        }
        if reorder {
            let due = Dictionary(listTasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let offset = day == .today ? 0 : 1
            list = TodoDoc.prioritized(list) { t in t.task_id.flatMap { due[$0]?.daysLeft() }.map { $0 - offset } }
        }
        if day == .today, Calendar.current.isDate(Stats.day(of: Date()), inSameDayAs: Date()) {
            let (now, busy, end) = bounds(.today)
            list = TodoDoc.retimed(list, from: planAnchor, busy: busy, dayEnd: end, now: now, keep: keep, breakAfter: cfg.breakAfter, pack: reorder)
        }
        d.edit(day) { $0 = list }
        d.save(); reloadTodos()
    }

    // MARK: the smallest step

    /// The one smallest thing you could do on a task right now, under 5 minutes. With the AI planner on, the AI writes
    /// it from the task, its steps and how far you've got; otherwise (or if the AI can't) it's the task's first step.
    func smallestStep(task: String, taskId: String?, spent: Int) async -> String {
        let lt = taskId.flatMap { id in listTasks.first { $0.id == id } }
        let fallback = (lt?.first_step).flatMap { $0.isEmpty ? nil : $0 } ?? "Open what you need for \u{201C}\(task)\u{201D} and spend two minutes on the very first bit"
        guard cfg.aiOn else { return fallback }
        let info: [String: Any] = ["task": task, "details": lt?.details ?? "", "spent": spent, "steps": (lt?.steps ?? []).map(\.task)]
        guard let input = (try? JSONSerialization.data(withJSONObject: info)).flatMap({ String(data: $0, encoding: .utf8) }) else { return fallback }
        let apple = cfg.ai?.provider == "apple"
        let step: String? = await Task.detached(priority: .userInitiated) {
            if apple {   // Apple Intelligence runs in the app; the helper writes the prompt
                let p = (try? JSONSerialization.jsonObject(with: Data(runCoach(["tprompt"], input: input).utf8))) as? [String: Any]
                guard let prompt = p?["prompt"] as? String else { return nil }
                return (try? await AppleAI.questions(prompt: prompt))?.first
            }
            let o = (try? JSONSerialization.jsonObject(with: Data(runCoach(["tiny"], input: input).utf8))) as? [String: Any]
            return o?["step"] as? String
        }.value
        return step.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? fallback
    }

    // MARK: the AI's breakdown

    /// With the AI planner on, every open task gets broken down once, in the background, one at a time: 5-15 minute
    /// steps, its first step, and a generous length (the AI's realistic total × Estimate.generosity, unless you set
    /// one). Runs after a task is added and every minute until the list is done.
    func breakDownNext() {
        guard cfg.aiOn, breakingDown == nil,
              let t = listTasks.first(where: { !$0.isDone && $0.steps == nil && !($0.skipped ?? false) }) else { return }
        breakingDown = t.id
        let cfg = self.cfg
        Task.detached(priority: .utility) {
            let steps = await Engine.aiBreakdown(t, cfg: cfg)
            await MainActor.run {
                self.breakingDown = nil
                self.updateListTask(t.id) { x in
                    x.steps = steps   // [] when the AI couldn't: tried, so it isn't asked again and again
                    guard !steps.isEmpty else { return }
                    if (x.first_step ?? "").isEmpty { x.first_step = steps[0].task }
                    if x.minutes == nil || x.estimated == true {
                        x.minutes = Estimate.padded(steps.reduce(0) { $0 + $1.minutes }); x.estimated = true
                    }
                }
                self.breakDownNext()
            }
        }
    }

    /// The AI's steps for a task, 5-15 minutes each, covering all of it ([] if it can't).
    nonisolated static func aiBreakdown(_ t: ListTask, cfg: Config) async -> [ListTask.Step] {
        var items: [[String: Any]] = []
        if cfg.ai?.provider == "apple" {   // Apple Intelligence runs in the app; the helper writes the prompt
            let p = (try? JSONSerialization.jsonObject(with: Data(runCoach(["bprompt", t.id]).utf8))) as? [String: Any]
            guard let prompt = p?["prompt"] as? String, let answer = try? await AppleAI.plan(prompt: prompt) else { return [] }
            items = ((try? JSONSerialization.jsonObject(with: Data(answer.utf8))) as? [String: Any])?["items"] as? [[String: Any]] ?? []
        } else {
            items = ((try? JSONSerialization.jsonObject(with: Data(runCoach(["breakdown", t.id]).utf8))) as? [String: Any])?["steps"] as? [[String: Any]] ?? []
        }
        return items.prefix(40).compactMap { s in
            let name = String((s["task"] as? String ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(120))
            let m = (s["minutes"] as? Int) ?? Int(s["minutes"] as? Double ?? 10)
            return name.isEmpty ? nil : ListTask.Step(task: name, minutes: min(max(m, 5), 20))
        }
    }

    /// Builds the day from your to-do list: its free time (see freeMinutes) filled with the most important tasks, then
    /// cut to the day's level and arranged hardest first. With the AI planner on, the AI makes the plan from the list.
    func fillFromList(_ day: PlanDay) {
        if cfg.aiOn {
            sendToPlanner("Plan \(day == .today ? "the rest of today" : "tomorrow") from my to-do list: fill the free time with what matters most, hardest first.", day: day)
            return
        }
        let picks = TaskList.fill(listTasks, planned: Set(list(day).compactMap(\.task_id)), minutes: freeMinutes(day), breakAfter: cfg.breakAfter)
        if picks.isEmpty {
            showPlanNote(listTasks.contains { !$0.isDone } ? "Your day's already full" : "Your to-do list is empty")
            return
        }
        planFromList(picks, day: day)
    }

    /// The minutes a day still has for more sessions: from now (tomorrow: the start of your active hours) to your
    /// finish time, less calendar events, breaks, and what's already planned with its breaks.
    func freeMinutes(_ day: PlanDay) -> Int {
        let (now, busy, end) = bounds(day)
        let first = (cfg.active_hours ?? [8, 23])[0]
        let start = day == .today ? planAnchor : (Calendar.current.date(bySettingHour: first, minute: 0, second: 0, of: now) ?? now)
        guard end > start else { return 0 }
        var free = end.timeIntervalSince(start) / 60
        for (a, b) in busy { free -= max(0, min(b, end).timeIntervalSince(max(a, start)) / 60) }
        for t in list(day) where !t.isDone && t.id != block?.todoId { free -= Double(t.left + cfg.breakAfter(t.left)) }
        return max(0, Int(free))
    }

    /// Locks in on a list task right now: its session on today's plan, else a new one starting now.
    func startFromList(_ t: ListTask) {
        if let p = todos.first(where: { $0.task_id == t.id && !$0.isDone }) { startTodo(p); return }
        let match = TaskMatch.apps(for: t.title, cfg: cfg)
        let item = Todo(id: Todo.newId(), task: t.title, block: match.rule ?? "", minutes: t.length, start: hhmm(Date()),
                        apps: match.apps, task_id: t.id)
        var d = TodoDoc.load()
        d.items.append(item); d.sortItems(); d.save(); reloadTodos()
        startTodo(item)
    }

    /// Once a day for each task that's due: today (or overdue) and not on today's plan, or in the evening, due
    /// tomorrow and not on tomorrow's. Only after the morning screen, between sessions, while you're at the Mac.
    func dueNudge() {
        guard block == nil, card == nil, !gateShown, Detect.idleSeconds() < 120, AppState.load().plan_shown == today() else { return }
        let h = Calendar.current.component(.hour, from: Date()), hours = cfg.active_hours ?? [8, 23]
        guard h >= hours[0], h < hours[1] else { return }
        let key = "dueNudged-" + today()
        var nudged = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        guard let n = TaskList.nudge(listTasks, today: Set(todos.compactMap(\.task_id)), tomorrow: Set(tomorrow.compactMap(\.task_id)),
                                     nudged: nudged) else { return }
        nudged.insert(n.task.id); UserDefaults.standard.set(Array(nudged), forKey: key)
        let t = n.task, len = t.minutes.map { " · \(fmtMinutes($0))" } ?? ""
        play("Purr", volume: 0.3)
        if n.tomorrow {
            show(Card(icon: "calendar.badge.exclamationmark", tint: "orange", title: t.title, subtitle: "Due tomorrow, not on tomorrow's plan yet\(len)",
                      buttons: [CardButton(label: "Later", action: .dismiss),
                                CardButton(label: "Plan for tomorrow", action: .planListTaskTomorrow(t.id), primary: true)]), close: 30)
        } else {
            show(Card(icon: "exclamationmark.circle.fill", tint: (t.daysLeft() ?? 0) < 0 ? "red" : "orange", title: t.title,
                      subtitle: "\(t.dueLabel()), not on today's plan yet\(len)",
                      buttons: [CardButton(label: "Later", action: .dismiss), CardButton(label: "Plan it", action: .planListTask(t.id)),
                                CardButton(label: "Lock in now", action: .startListTask(t.id), primary: true)]), close: 30)
        }
    }

    // MARK: the AI's questions

    /// Asks the AI planner for up to 3 questions about a task that would help plan it (what's involved, what it
    /// depends on, what "done" means). They wait on the task until you answer or skip them.
    func askAI(about id: String) {
        guard cfg.aiOn, askingAI == nil, listTasks.contains(where: { $0.id == id }) else { return }
        askingAI = id; listError = nil
        let apple = cfg.ai?.provider == "apple"
        Task.detached(priority: .userInitiated) {
            var questions: [String] = [], failed: String?
            do {
                if apple {   // Apple Intelligence runs in the app; the helper writes the prompt
                    let p = (try? JSONSerialization.jsonObject(with: Data(runCoach(["qprompt", id]).utf8))) as? [String: Any]
                    guard let prompt = p?["prompt"] as? String else { throw AppleAI.failure(p?["error"] as? String ?? "couldn't build the prompt") }
                    questions = try await AppleAI.questions(prompt: prompt)
                } else {
                    let o = (try? JSONSerialization.jsonObject(with: Data(runCoach(["questions", id]).utf8))) as? [String: Any]
                    if let e = o?["error"] as? String { throw AppleAI.failure(e) }
                    guard let q = o?["questions"] as? [String] else { throw AppleAI.failure("no answer from the AI") }
                    questions = q
                }
            } catch { failed = error.localizedDescription }
            let clean = questions.map { String($0.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(160)) }.filter { !$0.isEmpty }
            let error = failed
            await MainActor.run {
                self.askingAI = nil
                if let failed = error { self.listError = "Couldn't ask the AI: \(failed)" }   // and move on to the next task
                self.updateListTask(id) { $0.ai_questions = Array(clean.prefix(3)) }
            }
        }
    }

    /// Your answer to one of the AI's questions (empty = skip it). Answers stay with the task for planning.
    func answerAI(_ id: String, question: String, answer: String) {
        updateListTask(id) { t in
            t.ai_questions = (t.ai_questions ?? []).filter { $0 != question }
            let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !a.isEmpty { t.qa = (t.qa ?? []) + [.init(q: question, a: a)] }
        }
    }
}
