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

    /// Adds what you typed or pasted (see TaskList.parse), newest on top. Returns the new tasks.
    @discardableResult func addListTasks(_ text: String) -> [ListTask] {
        let new = TaskList.parse(text)
        if !new.isEmpty { editList { $0.insert(contentsOf: new, at: 0) } }
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

    /// Puts list tasks on a day's plan, in the order given. Today they get the soonest open times; their apps come
    /// from their words, the same as anything you type in.
    func planFromList(_ tasks: [ListTask], day: PlanDay) {
        let fresh = tasks.filter { t in !t.isDone && !list(day).contains { $0.task_id == t.id } }
        guard !fresh.isEmpty else { return }
        let cfg = self.cfg
        planning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let history = TaskMatch.history()
            for t in fresh {
                let minutes = t.minutes ?? 45
                let start = day == .today ? soonestSlot(minutes: minutes) : ""
                let match = TaskMatch.apps(for: t.title, cfg: cfg, history: history)
                DispatchQueue.main.sync {
                    var d = TodoDoc.load()
                    d.edit(day) { $0.append(Todo(id: Todo.newId(), task: t.title, block: match.rule ?? "", minutes: minutes, start: start,
                                                 apps: match.apps, task_id: t.id)) }
                    d.save(); self.reloadTodos()
                }
            }
            Task { @MainActor in
                self.planning = false
                self.showPlanNote("Added \(fresh.count) from your to-do list" + (day == .tomorrow ? " to tomorrow" : ""))
            }
        }
    }

    /// Locks in on a list task right now: its session on today's plan, else a new one starting now.
    func startFromList(_ t: ListTask) {
        if let p = todos.first(where: { $0.task_id == t.id && !$0.isDone }) { startTodo(p); return }
        let match = TaskMatch.apps(for: t.title, cfg: cfg)
        let item = Todo(id: Todo.newId(), task: t.title, block: match.rule ?? "", minutes: t.minutes ?? 45, start: hhmm(Date()),
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
