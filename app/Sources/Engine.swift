import AppKit
import Combine
import Foundation

enum CardAction: Hashable { case dismiss, backToIt, snoozeDrift, startBreak, startNext, startTen, openPlanner, stop, addFive }

/// The cover's target: a distracting site, or (strict blocks) any app or page outside the block.
struct Blocked: Equatable { var site: String; var app: String; var frame: NSRect?; var strict: Bool }

struct CardLine: Hashable { var text: String; var trailing: String = ""; var deadline = false; var bullet = true }
struct CardButton: Hashable { var label: String; var action: CardAction; var primary = false }
struct Card: Identifiable, Equatable {
    let id = UUID()
    var icon: String           // SF Symbol name
    var tint: String = "white" // white | green | orange | red | blue
    var title: String
    var subtitle: String = ""
    var lines: [CardLine] = []
    var buttons: [CardButton] = []
    var autoClose: Double? = nil
}

@MainActor
final class Engine: ObservableObject {
    static let shared = Engine()

    @Published var cfg: Config
    @Published var block: ActiveBlock?
    @Published var now = Date()
    @Published var drifting = false
    @Published var card: Card?
    @Published var todos: [Todo] = []
    @Published var chat: [ChatMsg] = []
    @Published var backlog: [Todo] = []
    private var lastDay = today()
    @Published var planning = false
    @Published var planError: String?
    @Published var blocked: Blocked? = nil
    /// The app you were last in, other than Focus itself (the menu's popover makes Focus the front app).
    @Published var lastExternalApp = ""

    private var timers: [Timer] = []
    private var driftSince: Date?
    private var lastNudge: Date?
    private var snoozeUntil = Date.distantPast
    private var snoozedSites: [String: Date] = [:]
    private var lastOnTask: (app: String, url: String)?
    private var lastIdleNudge = Date().addingTimeInterval(-30 * 60)
    private var lastBlockEnd = Date.distantPast
    private var closeTask: DispatchWorkItem?
    private var checking = false

    var preset: Preset? {
        guard let b = block else { return nil }
        if let apps = b.apps {   // quick focus: only the picked apps; a picked terminal also allows its Claude sessions
            let term = apps.contains { Detect.terminals.contains($0) }
            return Preset(name: b.name, minutes: b.minutes, sites: [], apps: apps, any_claude: term, terminal_ok: term, strict: true)
        }
        return presetFor(b.name)
    }
    var isBreak: Bool { block?.kind == "break" }
    var remaining: Double { (block?.ends ?? 0) - now.timeIntervalSince1970 }
    var progress: Double {
        guard let b = block else { return 0 }
        return min(1, max(0, 1 - remaining / Double(b.minutes * 60)))
    }
    var nextTodo: Todo? { todos.first { !$0.isDone } }

    init() {
        cfg = Config.load() ?? Config(distractions: Distractions(apps: [], sites: []), block_sites: [], blocks: [])
        reloadTodos()
        if let a = AppState.load().active, a.ends > Date().timeIntervalSince1970 { block = a }
    }

    func start() {
        timers = [
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in Task { @MainActor in self.tick() } },
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in Task { @MainActor in self.check() } },
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Task { @MainActor in self.minute() } },
        ]
        let nc = NSWorkspace.shared.notificationCenter
        lastExternalApp = Detect.frontApp() == "Focus" ? "" : Detect.frontApp()
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let name = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.localizedName ?? ""
            Task { @MainActor in if !name.isEmpty, name != "Focus" { self.lastExternalApp = name } }
        }
        for n in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Task { @MainActor in self.morningCheck() } }
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            Task { @MainActor in self.morningCheck() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.morningCheck() }
    }

    func reloadConfig() { if let c = Config.load() { cfg = c } }
    func reloadTodos() {
        let d = TodoDoc.load()      // rolls yesterday's leftovers into the backlog
        todos = d.items
        chat = d.chat ?? []
        backlog = d.backlog ?? []
    }

    // Back into today at the soonest open time; no AI needed.
    func addFromBacklog(_ t: Todo) {
        DispatchQueue.global(qos: .userInitiated).async {
            let start = soonestSlot(minutes: t.minutes)
            Task { @MainActor in self.moveFromBacklog(t, start: start) }
        }
    }
    private func moveFromBacklog(_ t: Todo, start: String) {
        var d = TodoDoc.load()
        d.backlog?.removeAll { $0.id == t.id }
        var item = t; item.from = nil; item.start = start; item.done = false; item.why = ""
        d.items.append(item); d.sortItems(); d.save(); reloadTodos()
    }

    // MARK: manual planning (works without any AI)
    func addTodo(task: String, block: String, minutes: Int, start: String) {
        var d = TodoDoc.load()
        if d.date?.isEmpty ?? true { d.date = today() }
        d.items.append(Todo(id: String(UUID().uuidString.prefix(8)).lowercased(), task: task, block: block, minutes: minutes, start: start))
        d.sortItems(); d.save(); reloadTodos()
    }
    func updateTodo(_ id: String, start: String? = nil, minutes: Int? = nil) {
        var d = TodoDoc.load()
        guard let i = d.items.firstIndex(where: { $0.id == id }) else { return }
        if let start { d.items[i].start = start }
        if let minutes { d.items[i].minutes = minutes }
        d.sortItems(); d.save(); reloadTodos()
    }
    func deleteTodo(_ id: String) { var d = TodoDoc.load(); d.items.removeAll { $0.id == id }; d.save(); reloadTodos() }
    func dropFromBacklog(_ id: String) {
        var d = TodoDoc.load(); d.backlog?.removeAll { $0.id == id }; d.save(); reloadTodos()
    }
    func clearBacklog() { var d = TodoDoc.load(); d.backlog = []; d.save(); reloadTodos() }

    func presetFor(_ name: String) -> Preset? {
        cfg.blocks.first { $0.name == name } ??
        cfg.blocks.first { $0.name.lowercased().contains(name.lowercased().split(separator: " ").first.map(String.init) ?? name.lowercased()) }
    }

    // MARK: blocks
    func startBlock(_ p: Preset, minutes: Int? = nil, task: String? = nil, todoId: String? = nil, apps: [String]? = nil) {
        if block?.kind == "focus" { stopBlock(completed: false, silent: true) }
        let m = minutes ?? p.minutes
        let t = Date().timeIntervalSince1970
        block = ActiveBlock(kind: "focus", name: p.name, task: task, todoId: todoId, started: t, ends: t + Double(m * 60), minutes: m,
                            offSeconds: 0, apps: apps)
        driftSince = nil; lastNudge = nil; snoozeUntil = .distantPast; snoozedSites = [:]; lastOnTask = nil; drifting = false
        appendLog(["type": "block_start", "name": p.name, "minutes": m, "task": task ?? ""])
        persist()
        show(Card(icon: "scope", tint: "green", title: task ?? p.name, subtitle: "\(m) minutes · phone away, one thing at a time"), close: 2.6)
    }

    /// A block with no name: just a length and the apps you'll use. Everything else gets covered.
    func startQuick(minutes: Int, apps: [String]) {
        UserDefaults.standard.set(apps, forKey: "quickApps")
        startBlock(Preset(name: "Focus", minutes: minutes), minutes: minutes, task: apps.isEmpty ? nil : apps.joined(separator: ", "), apps: apps)
        if let first = apps.first { lastOnTask = (first, "") }
    }
    var quickApps: [String] { UserDefaults.standard.stringArray(forKey: "quickApps") ?? [] }

    func startTodo(_ t: Todo, minutes: Int? = nil) {
        guard let p = presetFor(t.block) ?? cfg.blocks.first else { return }
        startBlock(p, minutes: minutes ?? t.minutes, task: t.task, todoId: minutes == nil ? t.id : nil)
    }

    func startBreak() {
        let m = cfg.break_minutes ?? 5, t = Date().timeIntervalSince1970
        block = ActiveBlock(kind: "break", name: "Break", task: nil, todoId: nil, started: t, ends: t + Double(m * 60), minutes: m, offSeconds: 0)
        blocked = nil; persist()
    }

    func addFive() { if var b = block { b.ends += 300; b.minutes += 5; block = b; persist() } }

    func stopBlock(completed: Bool, silent: Bool = false) {
        guard let b = block else { return }
        block = nil; blocked = nil; drifting = false; lastBlockEnd = Date(); persist()
        if b.kind == "break" {
            if !silent {
                let n = nextTodo
                show(Card(icon: "cup.and.saucer.fill", tint: "orange", title: "Break's over",
                          subtitle: n.map { "Next: \($0.task)" } ?? "Ready for another block?",
                          buttons: [CardButton(label: "Not yet", action: .dismiss)] + (n != nil ? [CardButton(label: "Start next", action: .startNext, primary: true)] : [CardButton(label: "Plan my day", action: .openPlanner, primary: true)])))
            }
            return
        }
        let elapsed = Int((Date().timeIntervalSince1970 - b.started) / 60)
        let focused = max(0, elapsed - Int(b.offSeconds / 60))
        appendLog(["type": "block_end", "name": b.name, "task": b.task ?? "", "completed": completed, "planned_min": b.minutes,
                   "elapsed_min": elapsed, "focused_min": focused])
        if completed, let id = b.todoId { setDone(id, true) }
        guard !silent else { return }
        if completed {
            NSSound(named: "Glass")?.play()
            show(Card(icon: "checkmark.circle.fill", tint: "green", title: b.task ?? b.name,
                      subtitle: "Done · \(focused) min focused",
                      buttons: [CardButton(label: "Skip break", action: .startNext), CardButton(label: "Break \(cfg.break_minutes ?? 5) min", action: .startBreak, primary: true)]))
        } else {
            show(Card(icon: "stop.circle.fill", tint: "white", title: "Stopped", subtitle: "\(elapsed) min in. That still counts."), close: 2.5)
        }
    }

    private func persist() { var s = AppState.load(); s.active = block; s.save() }

    // MARK: cards
    func show(_ c: Card, close: Double? = nil) {
        closeTask?.cancel()
        card = c
        if let close = close ?? c.autoClose {
            let w = DispatchWorkItem { [weak self] in Task { @MainActor in if self?.card?.id == c.id { self?.card = nil } } }
            closeTask = w
            DispatchQueue.main.asyncAfter(deadline: .now() + close, execute: w)
        }
    }

    func perform(_ a: CardAction) {
        card = nil
        switch a {
        case .dismiss, .backToIt: break
        case .snoozeDrift: snoozeUntil = Date().addingTimeInterval(300); driftSince = nil; lastNudge = nil; drifting = false
        case .startBreak: startBreak()
        case .startNext: if let t = nextTodo { startTodo(t) } else { Planner.shared.open() }
        case .startTen: if let t = nextTodo { startTodo(t, minutes: 10) }
        case .openPlanner: Planner.shared.open()
        case .stop: stopBlock(completed: false)
        case .addFive: addFive()
        }
    }

    func tapIsland() {
        guard let b = block else { return }
        if card != nil { card = nil; return }
        show(Card(icon: isBreak ? "cup.and.saucer.fill" : "scope", tint: isBreak ? "orange" : (drifting ? "red" : "green"),
                  title: isBreak ? "Break" : (b.task ?? b.name), subtitle: "\(fmtTime(remaining)) left · \(b.name)",
                  buttons: [CardButton(label: "Stop", action: .stop), CardButton(label: "+5 min", action: .addFive),
                            CardButton(label: "Keep going", action: .dismiss, primary: true)]), close: 6)
    }

    // MARK: loop
    private func tick() {
        now = Date()
        if let b = block, now.timeIntervalSince1970 >= b.ends { stopBlock(completed: b.kind == "focus") }
    }

    private func check() {
        guard let b = block, b.kind == "focus", let p = preset, !checking else { if block == nil || isBreak { blocked = nil }; return }
        checking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let ctx = Detect.context()
            let idle = Detect.idleSeconds()
            let frame = Detect.windowFrame(of: ctx.app)
            Task { @MainActor in self.evaluate(ctx, idle: idle, frame: frame, preset: p); self.checking = false }
        }
    }

    private func classify(_ c: FrontContext, _ p: Preset) -> (String, String?) {
        if anyIn(c.app, cfg.distractions.apps) != nil { return ("off", c.app) }
        if Detect.browsers[c.app] != nil {
            if anyIn(c.url + " " + c.title, p.sites) != nil { return ("on", nil) }   // block's own sites first
            if let hit = anyIn(c.url + " " + c.title, cfg.distractions.sites) { return ("off", hit) }
            return ("neutral", nil)
        }
        if let proj = c.project {
            if p.any_claude == true || anyIn(proj, p.projects) != nil { return ("on", nil) }
            return ("off", "Claude session in \((proj as NSString).lastPathComponent)")
        }
        if Detect.terminals.contains(c.app) {
            return p.terminal_ok ?? true ? ("on", nil) : ("off", "\(c.app) isn't part of \(p.short)")
        }
        if anyIn(c.app, p.apps) != nil || anyIn(c.app, cfg.always_ok_apps) != nil { return ("on", nil) }
        return ("neutral", nil)
    }

    private func evaluate(_ c: FrontContext, idle: Double, frame: NSRect?, preset p: Preset) {
        guard var b = block, b.kind == "focus" else { return }
        // cover distracting sites (tab stays open underneath)
        // a site the block explicitly allows wins over the cover (e.g. a NeetCode video on YouTube during LeetCode)
        let allowed = anyIn(c.url + " " + c.title, p.sites) != nil
        var (state, what) = classify(c, p)
        if Detect.browsers[c.app] != nil, !allowed, let site = anyIn(c.url, cfg.block_sites), (snoozedSites[site] ?? .distantPast) < Date() {
            if blocked?.site != site { appendLog(["type": "blocked", "name": b.name, "what": site]) }
            blocked = Blocked(site: site, app: c.app, frame: frame, strict: false)
        } else if strictViolation(c, p, state), (snoozedSites["app:" + c.app] ?? .distantPast) < Date() {
            // "only these apps" blocks: anything else gets the cover too
            if blocked?.app != c.app { appendLog(["type": "blocked", "name": b.name, "what": c.app]) }
            blocked = Blocked(site: "", app: c.app, frame: frame, strict: true)
            if state != "off" { state = "off"; what = "\(c.app) isn't part of this block" }
        } else if blocked != nil { blocked = nil }

        if state == "on", anyIn(c.app, cfg.always_ok_apps) == nil { lastOnTask = (c.app, c.url) }
        if p.offline_ok == true {
            if idle > (cfg.away_seconds ?? 45), state == "off" { state = "on" }
        } else if idle > (cfg.mac_away_seconds ?? 180) {
            state = "off"; what = "Away from your Mac for \(Int(idle / 60)) min"
        } else if idle > (cfg.away_seconds ?? 45), state == "off" { state = "neutral" }

        guard state == "off", Date() >= snoozeUntil else {
            if state != "off" { driftSince = nil; lastNudge = nil; drifting = false }
            return
        }
        b.offSeconds += 2; block = b
        if driftSince == nil { driftSince = Date() }
        let away = what?.hasPrefix("Away") ?? false
        let offFor = Date().timeIntervalSince(driftSince!)
        drifting = offFor >= (away ? 0 : (cfg.drift_seconds ?? 30))
        let due = lastNudge == nil ? drifting : Date().timeIntervalSince(lastNudge!) >= (cfg.renudge_seconds ?? 120)
        if due, blocked == nil {
            if lastNudge == nil { appendLog(["type": "drift", "name": b.name, "what": what ?? ""]) }
            lastNudge = Date()
            show(Card(icon: "eye.fill", tint: "red", title: what ?? "Off task",
                      subtitle: "\(fmtTime(remaining)) left in \(b.task ?? b.name)",
                      buttons: [CardButton(label: "5 more min", action: .snoozeDrift), CardButton(label: "Back to it", action: .backToIt, primary: true)]), close: 8)
        }
    }

    /// In a strict block, is the front app/page outside the allowed list? A browser you picked is fine on any page
    /// that isn't a distraction; Focus's own windows and always-fine apps never count.
    private func strictViolation(_ c: FrontContext, _ p: Preset, _ state: String) -> Bool {
        guard p.strict == true, state != "on", !c.app.isEmpty, c.app != "Focus",
              anyIn(c.app, cfg.always_ok_apps) == nil else { return false }
        if Detect.browsers[c.app] != nil, state == "neutral", anyIn(c.app, p.apps) != nil { return false }
        return true
    }

    // MARK: blocker actions
    func snoozeSite() {
        guard let b = blocked else { return }
        let key = b.strict ? "app:" + b.app : b.site
        snoozedSites[key] = Date().addingTimeInterval(300)
        appendLog(["type": "drift", "name": block?.name ?? "", "what": "\(b.strict ? b.app : b.site) (took 5)"])
        blocked = nil
    }
    func closeBlockedTab() {
        guard let app = blocked?.app else { return }
        Detect.osa(Detect.browsers[app] == "safari" ? "tell application \"Safari\" to close current tab of front window"
                                                   : "tell application \"\(app)\" to close active tab of front window")
        blocked = nil
    }
    func backToWork() {
        let app = blocked?.app ?? Detect.frontApp()
        blocked = nil
        if Detect.browsers[app] == "chromium", let sites = preset?.sites, !sites.isEmpty {
            let keys = sites.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }.joined(separator: ",")
            let src = """
            set keys to {\(keys)}
            tell application "\(app)"
              repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                  set i to i + 1
                  repeat with k in keys
                    if (URL of t) contains (k as text) then
                      set active tab index of w to i
                      set index of w to 1
                      return "ok"
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            return "none"
            """
            if Detect.osa(src) == "ok" { return }
        }
        if let last = lastOnTask, last.app != app {
            NSWorkspace.shared.runningApplications.first { $0.localizedName == last.app }?.activate()
            return
        }
        if lastOnTask == nil, let p = preset, let target = NSWorkspace.shared.runningApplications.first(where: { r in
            r.activationPolicy == .regular && anyIn(r.localizedName ?? "", p.apps) != nil && r.localizedName != app }) {
            target.activate()   // nothing on task yet this block: jump to one of its apps
            return
        }
        if let last = lastOnTask, !last.url.isEmpty, Detect.browsers[app] != nil {
            Detect.osa("tell application \"\(app)\" to set URL of active tab of front window to \"\(last.url)\"")
            return
        }
        if Detect.browsers[app] == "chromium" { Detect.osa("tell application \"\(app)\" to make new tab at end of tabs of front window") }
    }

    // MARK: to-dos
    func setDone(_ id: String, _ done: Bool) {
        var d = TodoDoc.load()
        if let i = d.items.firstIndex(where: { $0.id == id }) { d.items[i].done = done }
        d.save(); reloadTodos()
    }
    func clearDay() { var d = TodoDoc.load(); d.items = []; d.chat = []; d.date = today(); d.save(); reloadTodos() }

    func sendToPlanner(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !planning else { return }
        planning = true; planError = nil
        chat.append(ChatMsg(role: "user", text: t))
        DispatchQueue.global(qos: .userInitiated).async {
            let out = runCoach(["todos"], input: t)
            Task { @MainActor in
                self.planning = false
                let obj = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any]
                if let err = obj?["error"] as? String { self.planError = err } else if obj == nil { self.planError = "no answer from the AI" }
                self.reloadTodos()
            }
        }
    }

    // MARK: morning plan, nudges, recap
    func planLines() -> [CardLine] {
        let text = runCoach(["plan"])
        var lines: [CardLine] = []
        for raw in text.split(separator: "\n").map({ String($0).trimmingCharacters(in: .whitespaces) }) where !raw.isEmpty && raw != "Today's plan" {
            if raw.hasPrefix("• ") {
                var t = String(raw.dropFirst(2)), trailing = "", deadline = false
                if let r = t.range(of: #"\s*\((\d+) min\)$"#, options: .regularExpression) {
                    trailing = String(t[r]).trimmingCharacters(in: CharacterSet(charactersIn: " ()")); t.removeSubrange(r)
                }
                if let r = t.range(of: " due ") {
                    deadline = true; trailing = String(t[r.upperBound...]).replacingOccurrences(of: "in ", with: "")
                    t = String(t[..<r.lowerBound]).replacingOccurrences(of: ": coding test", with: "").replacingOccurrences(of: ":", with: "")
                }
                if t.hasPrefix("Classes: ") { t = String(t.dropFirst(9)); trailing = "classes" }
                lines.append(CardLine(text: t, trailing: trailing, deadline: deadline))
            } else { lines.append(CardLine(text: raw, bullet: false)) }
        }
        return lines
    }

    func showPlan(morning: Bool = false) {
        let h = Calendar.current.component(.hour, from: Date())
        let title = morning ? "Good morning" : (h < 12 ? "Today" : h < 18 ? "Rest of today" : "Tonight")
        let n = nextTodo
        show(Card(icon: morning || h < 18 ? "sun.max.fill" : "moon.fill", tint: "orange", title: title, lines: planLines(),
                  buttons: [CardButton(label: n == nil ? "Later" : "Plan my day", action: n == nil ? .dismiss : .openPlanner),
                            n.map { CardButton(label: "Start: \($0.task.prefix(24))\($0.task.count > 24 ? "…" : "")", action: .startNext, primary: true) }
                              ?? CardButton(label: "Plan my day", action: .openPlanner, primary: true)], autoClose: 30))
    }

    func showRecap() {
        let text = runCoach(["recap"]).replacingOccurrences(of: "Recap: ", with: "")
        let lines = text.split(separator: "\n").map { CardLine(text: String($0), bullet: false) }
        show(Card(icon: "chart.bar.fill", tint: "blue", title: "Today", lines: lines, buttons: [CardButton(label: "Nice", action: .dismiss, primary: true)]))
    }

    private func minute() {
        if today() != lastDay { lastDay = today(); reloadTodos() }   // midnight: fresh day, leftovers to backlog
        morningCheck(); idleNudge()
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        if f.string(from: Date()) == (cfg.recap_at ?? "21:00") { showRecap() }
    }

    func morningCheck() {
        var s = AppState.load()
        guard s.plan_shown != today(), Calendar.current.component(.hour, from: Date()) >= (cfg.morning_hour ?? 5),
              Detect.idleSeconds() < 90 else { return }
        s.plan_shown = today(); s.save()
        reloadTodos()
        showPlan(morning: true)
    }

    private func idleNudge() {
        guard block == nil, card == nil else { return }
        let h = Calendar.current.component(.hour, from: Date()), hours = cfg.active_hours ?? [8, 23]
        guard h >= hours[0], h < hours[1], Detect.idleSeconds() < 60 else { return }
        let gap = (cfg.idle_nudge_minutes ?? 40) * 60
        guard Date().timeIntervalSince(lastIdleNudge) >= gap, Date().timeIntervalSince(lastBlockEnd) >= gap else { return }
        if anyIn(Detect.frontApp(), ["zoom.us", "Microsoft Teams", "FaceTime", "Webex"]) != nil { return }
        lastIdleNudge = Date()
        if let n = nextTodo {
            let left = todos.filter { !$0.isDone }.count
            show(Card(icon: "arrow.right.circle.fill", tint: "blue", title: n.task,
                      subtitle: "Up next · \(n.minutes) min · \(left) left today. Hard to start? Do 10 minutes.",
                      buttons: [CardButton(label: "Later", action: .dismiss), CardButton(label: "Just 10 min", action: .startTen),
                                CardButton(label: "Start", action: .startNext, primary: true)]), close: 25)
        } else {
            show(Card(icon: "list.bullet.rectangle.fill", tint: "blue", title: "What's on your plate today?",
                      subtitle: "Tell the planner and it'll line your day up around your classes.",
                      buttons: [CardButton(label: "Later", action: .dismiss), CardButton(label: "Plan my day", action: .openPlanner, primary: true)]), close: 25)
        }
    }
}
