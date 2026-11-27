import AppKit
import Combine
import EventKit
import ServiceManagement
import SwiftUI

// Setup pages for the main window. Edits config.json in place: each save re-reads the file and writes only the keys
// these pages own, so repeating sessions and calendar choices made elsewhere are never overwritten.
@MainActor
enum SettingsWindow {
    static func open(_ tab: PlannerTab = .apps) { Planner.shared.open(tab: tab) }
}

final class SettingsModel: ObservableObject {
    @Published var driftSeconds: Double
    @Published var renudgeSeconds: Double
    @Published var breakMinutes: Int
    @Published var breakRatio: Int             // the session ÷ this; 0 = always breakMinutes
    @Published var macAwayMinutes: Double
    @Published var morningHour: Int
    @Published var recapAt: Date
    @Published var dayEnd: Date
    @Published var idleNudgeMinutes: Double
    @Published var activeFrom: Int
    @Published var activeTo: Int
    @Published var distractingSites: [String]
    @Published var distractingApps: [String]
    @Published var alwaysOkApps: [String]
    @Published var blocks: [Preset]
    @Published var blocking: String
    @Published var coverSound: Bool
    @Published var sounds: Bool
    @Published var checkIns: Bool
    @Published var statsGoal: Int
    @Published var weekGoal: Int
    @Published var streakReminderOn: Bool
    @Published var streakReminderAt: Date
    @Published var lockinApps: [String]
    @Published var morningGate: Bool
    @Published var earnFreeTime: Bool
    @Published var freePasses: Int
    @Published var autoStart: Bool
    @Published var calendarAsk: Bool
    @Published var aiProvider: String
    @Published var aiModel: String
    @Published var aiBaseURL: String
    @Published var aboutMe: String
    @Published var apiKeyDraft = ""
    @Published var hasKey = Keychain.get() != nil
    @Published var testResult: (ok: Bool, text: String)?
    @Published var testing = false
    private var saving = false
    private var autosave: AnyCancellable?

    init() {
        let raw = (try? JSONSerialization.jsonObject(with: Data(contentsOf: Paths.config))) as? [String: Any] ?? [:]
        let c = Config.load() ?? .empty
        driftSeconds = c.drift_seconds ?? 30
        renudgeSeconds = c.renudge_seconds ?? 120
        breakMinutes = c.break_minutes ?? 5
        breakRatio = c.breakRatio
        macAwayMinutes = (c.mac_away_seconds ?? 180) / 60
        morningHour = c.morning_hour ?? 5
        recapAt = SettingsModel.time(c.recap_at ?? "21:00")
        dayEnd = SettingsModel.time(raw["day_end"] as? String ?? "23:30")
        idleNudgeMinutes = c.idle_nudge_minutes ?? 40
        activeFrom = c.active_hours?.first ?? 8
        activeTo = c.active_hours?.last ?? 23
        // one list in the UI: everything distracting gets covered
        distractingSites = c.block_sites + c.distractions.sites.filter { !c.block_sites.contains($0) }
        distractingApps = c.distractions.apps
        alwaysOkApps = c.always_ok_apps ?? []
        blocks = c.blocks
        blocking = (c.blocking ?? "hard") == "hard" ? "hard" : "cover"
        coverSound = c.cover_sound ?? true
        sounds = c.sounds ?? true
        checkIns = c.check_ins ?? true
        statsGoal = c.stats_goal ?? 25
        weekGoal = c.stats_week_goal ?? 5
        streakReminderOn = !(c.streak_reminder ?? "20:00").isEmpty
        streakReminderAt = SettingsModel.time((c.streak_reminder ?? "").isEmpty ? "20:00" : c.streak_reminder!)
        lockinApps = c.lockin_apps ?? []
        morningGate = c.morning_gate ?? true
        earnFreeTime = c.earn_free_time ?? true
        freePasses = c.free_passes ?? 3
        autoStart = c.auto_start ?? true
        calendarAsk = (c.calendar_mode ?? "ask") != "off"
        let ai = raw["ai"] as? [String: Any] ?? [:]
        aiProvider = (ai["provider"] as? String).map { $0 == "none" ? "" : $0 } ?? ""
        aiModel = ai["model"] as? String ?? ""
        aiBaseURL = ai["base_url"] as? String ?? ""
        aboutMe = raw["about_me"] as? String ?? ""
        // Changes save themselves a moment after you stop editing. No Save button.
        autosave = objectWillChange.debounce(for: .seconds(0.6), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save(includeKey: false) }
    }

    static let providers: [(id: String, name: String)] = [
        ("", "None: plan by hand"), ("apple", "Apple Intelligence (on this Mac, free)"), ("claude-code", "Claude Code (your Claude subscription)"),
        ("anthropic", "Claude API key"), ("openai", "OpenAI API key"),
        ("openai-compatible", "Other (OpenRouter, Gemini, Ollama, LM Studio…)")]
    static let defaultModels = ["claude-code": "sonnet", "anthropic": "claude-opus-5-5", "openai": "gpt-5-mini",
                                "openai-compatible": "e.g. llama3.1 or google/gemini-2.5-flash"]
    var needsKey: Bool { aiProvider == "anthropic" || aiProvider == "openai" || aiProvider == "openai-compatible" }

    func testAI() {
        save()
        testing = true; testResult = nil
        if aiProvider == "apple" {
            Task { @MainActor in
                do {
                    _ = try await AppleAI.plan(prompt: "Plan one item: test 10 minutes at 09:00. Reply \"ok\".")
                    self.testResult = (true, "Apple Intelligence is working.")
                } catch { self.testResult = (false, error.localizedDescription) }
                self.testing = false
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let out = runCoach(["test"])
            let obj = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any]
            DispatchQueue.main.async {
                self.testing = false
                if obj?["ok"] as? Bool == true { self.testResult = (true, "Connected to \(obj?["model"] as? String ?? "the AI").") }
                else { self.testResult = (false, obj?["error"] as? String ?? "No answer from the helper script.") }
            }
        }
    }

    static func time(_ s: String) -> Date {
        let p = s.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: p.first ?? 0, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
    }

    func save(includeKey: Bool = true) {
        guard !saving else { return }
        saving = true; defer { saving = false }
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if includeKey, !key.isEmpty { Keychain.set(key); apiKeyDraft = ""; hasKey = true }
        editConfig { raw in
            raw["drift_seconds"] = driftSeconds
            raw["renudge_seconds"] = renudgeSeconds
            raw["break_minutes"] = breakMinutes
            raw["break_ratio"] = breakRatio
            raw["mac_away_seconds"] = macAwayMinutes * 60
            raw["morning_hour"] = morningHour
            raw["recap_at"] = hhmm(recapAt)
            raw["day_end"] = hhmm(dayEnd)
            raw["idle_nudge_minutes"] = idleNudgeMinutes
            raw["active_hours"] = [activeFrom, activeTo]
            raw["distractions"] = ["sites": distractingSites, "apps": distractingApps]
            raw["block_sites"] = distractingSites
            raw["always_ok_apps"] = alwaysOkApps
            raw["blocking"] = blocking
            raw["cover_sound"] = coverSound
            raw["sounds"] = sounds
            raw["check_ins"] = checkIns
            raw["stats_goal"] = statsGoal
            raw["stats_week_goal"] = weekGoal
            raw["streak_reminder"] = streakReminderOn ? hhmm(streakReminderAt) : ""
            raw["lockin_apps"] = lockinApps
            raw["morning_gate"] = morningGate
            raw["earn_free_time"] = earnFreeTime
            raw["free_passes"] = freePasses
            raw["auto_start"] = autoStart
            raw["calendar_mode"] = calendarAsk ? "ask" : "off"
            // "None" keeps the AI off; the planner then works by hand only.
            raw["ai"] = ["provider": aiProvider.isEmpty ? "none" : aiProvider, "model": aiModel.trimmingCharacters(in: .whitespaces),
                         "base_url": aiBaseURL.trimmingCharacters(in: .whitespaces)]
            raw["about_me"] = aboutMe.trimmingCharacters(in: .whitespacesAndNewlines)
            raw["blocks"] = blocks.map { b -> [String: Any] in
                ["name": b.name, "minutes": b.minutes, "sites": b.sites ?? [], "apps": b.apps ?? [], "projects": b.projects ?? [],
                 "offline_ok": b.offline_ok ?? false, "any_claude": b.any_claude ?? false, "terminal_ok": b.terminal_ok ?? true,
                 "strict": b.strict ?? false]
            }
        }
        Task { @MainActor in Engine.shared.reloadConfig() }
    }
}

// MARK: - Shared pieces (setup and settings)

/// Pick your lock-in apps from big icons: installed work apps and what's running, plus "More apps…".
struct AppGrid: View {
    @Binding var selected: [String]
    var columns = 4
    var limit = 16
    @State private var picking = false

    private var tiles: [String] {
        let distracting = Engine.shared.cfg.distractions.apps.map { $0.lowercased() }
        let suggested = Array(InstalledApps.suggested.filter { a in !distracting.contains { a.lowercased().contains($0) } }.prefix(limit))
        return selected.filter { !suggested.contains($0) } + suggested
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                ForEach(tiles, id: \.self) { name in tile(name) }
            }
            HStack {
                Button { picking = true } label: { Label("More apps…", systemImage: "magnifyingglass").font(.system(size: 12.5, weight: .medium)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
                    .popover(isPresented: $picking, arrowEdge: .bottom) { AppPicker(selected: $selected) }
                Spacer()
                Text(selected.isEmpty ? "Pick at least one" : "\(selected.count) selected").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }

    private func tile(_ name: String) -> some View {
        let on = selected.contains(name)
        return Button {
            withAnimation(.easeOut(duration: 0.12)) { if on { selected.removeAll { $0 == name } } else { selected.append(name) } }
        } label: {
            VStack(spacing: 6) {
                AppIconView(name: name, size: 34)
                Text(name).font(.system(size: 11.5, weight: on ? .semibold : .regular)).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity).frame(height: 76)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? Theme.accent.opacity(0.15) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? Theme.accent : .clear, lineWidth: 1.5))
            .overlay(alignment: .topTrailing) {
                if on {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(Theme.accent)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(2)).padding(6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Common distractions as one-tap tiles, plus anything else you add.
struct DistractionGrid: View {
    @ObservedObject var m: SettingsModel
    var columns = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                ForEach(DistractionPick.catalog) { p in tile(p) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Anything else? Add a site or an app").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                TokenList(items: extrasBinding, placeholder: "e.g. espn.com or Steam")
            }
        }
    }

    private func isOn(_ p: DistractionPick) -> Bool {
        p.sites.contains(where: m.distractingSites.contains) || p.apps.contains(where: m.distractingApps.contains)
    }
    private func toggle(_ p: DistractionPick) {
        if isOn(p) {
            m.distractingSites.removeAll(where: p.sites.contains); m.distractingApps.removeAll(where: p.apps.contains)
        } else {
            m.distractingSites += p.sites.filter { !m.distractingSites.contains($0) }
            m.distractingApps += p.apps.filter { !m.distractingApps.contains($0) }
        }
    }
    /// Sites and apps on your lists that aren't one of the tiles. Anything with a dot is a site.
    private var extrasBinding: Binding<[String]> {
        Binding(get: {
            m.distractingSites.filter { !DistractionPick.allSites.contains($0) } + m.distractingApps.filter { !DistractionPick.allApps.contains($0) }
        }, set: { new in
            let old = Set(m.distractingSites.filter { !DistractionPick.allSites.contains($0) } + m.distractingApps.filter { !DistractionPick.allApps.contains($0) })
            for x in old where !new.contains(x) { m.distractingSites.removeAll { $0 == x }; m.distractingApps.removeAll { $0 == x } }
            for x in new where !old.contains(x) {
                if x.contains(".") { m.distractingSites.append(x.lowercased()) } else { m.distractingApps.append(x) }
            }
        })
    }

    private func tile(_ p: DistractionPick) -> some View {
        let on = isOn(p)
        return Button { withAnimation(.easeOut(duration: 0.12)) { toggle(p) } } label: {
            HStack(spacing: 9) {
                Image(systemName: p.icon).font(.system(size: 14)).frame(width: 20).foregroundStyle(on ? Color.black.opacity(0.8) : .secondary)
                Text(p.name).font(.system(size: 13, weight: .medium)).foregroundStyle(on ? Color.black.opacity(0.85) : .primary).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 13))
                    .foregroundStyle(on ? Color.black.opacity(0.7) : Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, 12).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? Theme.accent : Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Locked or Strict, as two big choices.
struct StrictnessChoice: View {
    @ObservedObject var m: SettingsModel
    var body: some View {
        VStack(spacing: 10) {
            choice("hard", "lock.fill", "Locked", "No way around it. Apps outside the session get hidden, distracting tabs stay covered until the session ends.", recommended: true)
            choice("cover", "lock.open.fill", "Strict", "Same covers, plus \(Engine.snoozesPerBlock) passes per session (\"Give me 5 min\"), each after a \(Int(Engine.snoozeWait))-second wait.")
        }
    }
    private func choice(_ id: String, _ icon: String, _ title: String, _ sub: String, recommended: Bool = false) -> some View {
        let on = m.blocking == id
        return Button { withAnimation(.easeOut(duration: 0.12)) { m.blocking = id } } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold)).frame(width: 34, height: 34)
                    .foregroundStyle(on ? Color.black.opacity(0.85) : Theme.accent)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? Theme.accent : Theme.accent.opacity(0.12)))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 14, weight: .semibold))
                        if recommended {
                            Text("Recommended").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Theme.accent.opacity(0.12)))
                        }
                    }
                    Text(sub).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: on ? "largecircle.fill.circle" : "circle").font(.system(size: 16))
                    .foregroundStyle(on ? Theme.accent : Color.secondary.opacity(0.5))
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(on ? 0.07 : 0.035)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? Theme.accent : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pages

struct AppsTab: View {
    @ObservedObject var m: SettingsModel
    @State private var openRule: Int?        // by position, so renaming a rule doesn't close it mid-typing

    var body: some View {
        Form {
            Section {
                AppGrid(selected: $m.lockinApps, columns: 5, limit: 20)
            } header: { Text("Your lock-in apps") } footer: {
                Text("Every session allows these unless its task says otherwise. Finder, System Settings and your always-fine apps never get covered.")
            }
            Section {
                ForEach(m.blocks.indices, id: \.self) { i in
                    let rule = ruleBinding(i)
                    DisclosureGroup(isExpanded: Binding(get: { openRule == i }, set: { openRule = $0 ? i : nil })) {
                        RuleEditor(rule: rule) { openRule = nil; if i < m.blocks.count { m.blocks.remove(at: i) } }
                    } label: {
                        HStack(spacing: 10) {
                            Text(rule.wrappedValue.name).font(.system(size: 13, weight: .medium))
                            Text(TaskMatch.words(rule.wrappedValue.name).sorted().joined(separator: ", ")).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            AppIconRow(apps: rule.wrappedValue.apps ?? [], size: 16, max: 5)
                        }
                    }
                }
                Button { addRule() } label: { Label("Add a task rule", systemImage: "plus") }.buttonStyle(.plain).foregroundStyle(Theme.accent)
            } header: { Text("Task rules") } footer: {
                Text("A task that mentions a rule's words gets that rule's apps, sites and Claude Code folders. Without a rule, lockin reuses what you allowed last time for a similar task.")
            }
        }
        .formStyle(.grouped)
    }

    /// A binding that survives the rule being deleted while its row is still on screen.
    private func ruleBinding(_ i: Int) -> Binding<Preset> {
        Binding(get: { i < m.blocks.count ? m.blocks[i] : Preset(name: "", minutes: 45) },
                set: { if i < m.blocks.count { m.blocks[i] = $0 } })
    }

    private func addRule() {
        var name = "New rule", n = 2
        while m.blocks.contains(where: { $0.name == name }) { name = "New rule \(n)"; n += 1 }
        m.blocks.append(Preset(name: name, minutes: 45, apps: []))
        openRule = m.blocks.count - 1
    }
}

/// One task rule: the words it matches, its apps, extra sites and Claude Code folders.
struct RuleEditor: View {
    @Binding var rule: Preset
    var onDelete: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Tasks that mention") {
                TextField("e.g. leetcode, interview prep", text: $rule.name)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Apps").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                AppChips(apps: Binding(get: { rule.apps ?? [] }, set: { rule.apps = $0 }))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Sites to allow even if they're on your distraction list").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                TokenList(items: Binding(get: { rule.sites ?? [] }, set: { rule.sites = $0 }), placeholder: "e.g. youtube.com/watch?v= for lectures")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Claude Code folders that count (empty = any)").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                TokenList(items: Binding(get: { rule.projects ?? [] }, set: { rule.projects = $0 }), placeholder: "e.g. my-project")
            }
            Toggle("Time away from the Mac counts (paper, iPad, reading)", isOn: Binding(get: { rule.offline_ok ?? false }, set: { rule.offline_ok = $0 }))
            HStack { Spacer(); Button("Delete rule", role: .destructive, action: onDelete).controlSize(.small) }
        }
        .padding(.vertical, 6)
    }
}

struct BlockingTab: View {
    @ObservedObject var m: SettingsModel
    var body: some View {
        Form {
            Section("During a session") { StrictnessChoice(m: m) }
            Section {
                Toggle("Keep distractions covered until today counts", isOn: $m.earnFreeTime)
                if m.earnFreeTime {
                    LabeledContent("5-minute passes a day") {
                        if m.blocking == "hard" { Text("None (Locked)").foregroundStyle(.secondary) }
                        else { Stepper("\(m.freePasses)", value: $m.freePasses, in: 0...10) }
                    }
                }
            } header: { Text("Earn your free time") } footer: {
                Text("Outside sessions, the distractions below stay covered until you've focused \(fmtMinutes(m.statsGoal)) today. Breaks are never covered.")
            }
            Section("Distractions") { DistractionGrid(m: m) }
            Section {
                TokenList(items: $m.alwaysOkApps, placeholder: "e.g. Spotify")
            } header: { Text("Always fine") } footer: { Text("Never covered, in any session.") }
            Section { Toggle("Play a soft sound when something gets covered", isOn: $m.coverSound) }
        }
        .formStyle(.grouped)
    }
}

struct DayTab: View {
    @EnvironmentObject var e: Engine
    @ObservedObject var m: SettingsModel
    @State private var advanced = false
    @State private var calendarAllowed = CalendarFeed.allowed

    /// "A 25-min session earns a 5-min break, 90 min earns 18."
    private var breakExample: String {
        let r = Double(m.breakRatio)
        func b(_ minutes: Int) -> Int { max(1, Int((Double(minutes) / r).rounded())) }
        return "Based on how long you were locked in: 25 min earns a \(b(25))-min break, 90 min earns \(b(90))."
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show my day full screen the first time I use my Mac each day", isOn: $m.morningGate)
                Picker("Not before", selection: $m.morningHour) { ForEach(3..<12) { h in Text("\(h):00 AM").tag(h) } }
                HStack {
                    Spacer()
                    Button("Show it now") { Gate.shared.show() }.controlSize(.small)
                }
            } header: { Text("Morning screen") } footer: {
                Text("To get past it: lock in, start your day, or hold Skip and say why. Skips show up in your recap and stats.")
            }
            Section("Sessions") {
                Toggle("Start planned sessions at their time (15-second countdown)", isOn: $m.autoStart)
                Picker("Breaks", selection: $m.breakRatio) {
                    ForEach(3...6, id: \.self) { r in Text("Your session ÷ \(r)").tag(r) }
                    Text("Always the same length").tag(0)
                }
                if m.breakRatio == 0 {
                    LabeledContent("Break length") { Stepper("\(m.breakMinutes) min", value: $m.breakMinutes, in: 1...30) }
                } else {
                    Text(breakExample).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Toggle("Halfway and last-minute check-ins", isOn: $m.checkIns)
                Toggle("Soft sounds", isOn: $m.sounds)
            }
            Section("Goal and streak") {
                LabeledContent("A day counts after") { Stepper("\(m.statsGoal) min focused", value: $m.statsGoal, in: 10...240, step: 5) }
                LabeledContent("Weekly goal") { Stepper("\(m.weekGoal) days", value: $m.weekGoal, in: 1...7) }
                Toggle("Remind me in the evening if today hasn't counted", isOn: $m.streakReminderOn)
                if m.streakReminderOn { DatePicker("Remind me at", selection: $m.streakReminderAt, displayedComponents: .hourAndMinute) }
                DatePicker("Recap and plan tomorrow at", selection: $m.recapAt, displayedComponents: .hourAndMinute)
            }
            Section {
                Toggle("Ask to lock in when a calendar event starts", isOn: $m.calendarAsk)
                if !calendarAllowed {
                    HStack {
                        Text("lockin can't see your calendar yet.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Allow") {
                            Task {
                                if EKEventStore.authorizationStatus(for: .event) == .notDetermined { _ = try? await EKEventStore().requestFullAccessToEvents() }
                                else { Access.openPrivacy("Privacy_Calendars") }
                                calendarAllowed = CalendarFeed.allowed; e.refreshEvents()
                            }
                        }
                        .controlSize(.small)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Never ask about").font(.system(size: 12))
                    TokenList(items: Binding(get: { e.cfg.calendar_ignore ?? [] }, set: { new in
                        editConfig { $0["calendar_ignore"] = new }; e.reloadConfig()
                    }), placeholder: "an event's title, e.g. Lunch")
                }
            } header: { Text("Calendar") } footer: {
                Text("Events show on Today. When one starts, lockin asks before locking in, never on its own. Repeating events are asked about too, until you say \"Never for this\".")
            }
            Section {
                if e.routines.isEmpty {
                    Text("None yet. Open a session on Today and set Repeat.").foregroundStyle(.secondary)
                } else {
                    ForEach(e.routines) { r in
                        HStack(spacing: 10) {
                            Image(systemName: "repeat").foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.task)
                                Text("\(r.daysLabel) · \(clockLabel(r.start)) · \(r.minutes) min").font(.system(size: 11.5)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            AppIconRow(apps: r.apps ?? [], size: 15)
                            Button { e.deleteRoutine(r.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Stop repeating")
                        }
                    }
                }
            } header: { Text("Repeating sessions") } footer: { Text("These land on your plan by themselves on their days.") }
            Section {
                Toggle("Open lockin when I log in", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { on in try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister(); m.objectWillChange.send() }))
                HStack {
                    Text("Setup")
                    Spacer()
                    Button("Run setup again") { SetupWindow.shared.open(step: .apps) }
                    Button("Check permissions") { SetupWindow.shared.open(step: .access) }
                }
                DisclosureGroup("More options", isExpanded: $advanced) {
                    LabeledContent("Nudge me after") { Stepper("\(Int(m.driftSeconds)) sec off task", value: $m.driftSeconds, in: 10...300, step: 10) }
                    LabeledContent("Remind again every") { Stepper("\(Int(m.renudgeSeconds / 60)) min", value: $m.renudgeSeconds, in: 60...900, step: 60) }
                    LabeledContent("Away from Mac counts after") { Stepper("\(Int(m.macAwayMinutes)) min", value: $m.macAwayMinutes, in: 1...15, step: 1) }
                    LabeledContent("With no session, suggest the next one every") { Stepper("\(Int(m.idleNudgeMinutes)) min", value: $m.idleNudgeMinutes, in: 10...180, step: 5) }
                    Picker("Only between", selection: $m.activeFrom) { ForEach(5..<14) { h in Text(hourLabel(h)).tag(h) } }
                    Picker("and", selection: $m.activeTo) { ForEach(16..<25) { h in Text(hourLabel(h % 24)).tag(h) } }
                    DatePicker("Plan my day until", selection: $m.dayEnd, displayedComponents: .hourAndMinute)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { calendarAllowed = CalendarFeed.allowed }
    }
    private func hourLabel(_ h: Int) -> String {
        let d = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date()
        return d.formatted(date: .omitted, time: .shortened)
    }
}

struct AITab: View {
    @ObservedObject var m: SettingsModel
    var body: some View {
        Form {
            Section {
                Picker("AI", selection: $m.aiProvider) {
                    ForEach(SettingsModel.providers, id: \.id) { p in Text(p.name).tag(p.id) }
                }
            } footer: {
                Text(m.aiProvider.isEmpty
                     ? "Everything works without AI: type \"leetcode 45, essay 30 at 2pm\" and lockin times it, or edit with \"done leetcode\", \"essay at 3pm\", \"free at 8\"."
                     : m.aiProvider == "apple"
                     ? "Apple's on-device model plans your day. Free, private, works offline. It sees your plan, today's calendar and what you type, and none of it leaves your Mac."
                     : "The AI turns a brain dump into a timed plan and edits it when you say things like \"free at 8 now\". It sees your plan, today's calendar and what you type. Nothing else.")
            }
            if m.aiProvider == "apple" {
                let st = AppleAI.status
                Section {
                    Label(st.text, systemImage: st.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(st.ok ? Theme.accent : Theme.flame)
                    if !st.ok { Button("Open Apple Intelligence settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!) } }
                    HStack {
                        Button(m.testing ? "Testing…" : "Test it") { m.testAI() }.disabled(m.testing || !st.ok)
                        if let r = m.testResult {
                            Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(r.ok ? Theme.accent : Theme.flame).font(.system(size: 12)).lineLimit(2)
                        }
                    }
                } header: { Text("Apple Intelligence") }
            }
            if !m.aiProvider.isEmpty && m.aiProvider != "apple" {
                Section("Model") {
                    TextField("Model", text: $m.aiModel, prompt: Text(SettingsModel.defaultModels[m.aiProvider] ?? ""))
                    if m.aiProvider == "openai-compatible" || m.aiProvider == "openai" {
                        TextField("Base URL", text: $m.aiBaseURL,
                                  prompt: Text(m.aiProvider == "openai" ? "https://api.openai.com/v1" : "e.g. https://openrouter.ai/api/v1 or http://localhost:11434/v1"))
                    }
                }
                if m.needsKey {
                    Section {
                        SecureField(m.hasKey ? "Saved in Keychain. Paste a new key to replace it" : "Paste your API key", text: $m.apiKeyDraft)
                            .onSubmit { m.save() }
                        if m.hasKey {
                            Button("Remove saved key", role: .destructive) { Keychain.set(nil); m.hasKey = false }
                        }
                    } header: { Text("API key") } footer: {
                        Text(m.aiProvider == "openai-compatible" ? "Leave empty for local servers like Ollama. Keys are stored in your macOS Keychain, never in a file."
                                                                 : "Stored in your macOS Keychain, never in a file.")
                    }
                } else if m.aiProvider == "claude-code" {
                    Section { Text("Uses the `claude` command you're signed in to. No key needed.").foregroundStyle(.secondary) }
                }
                Section {
                    TextEditor(text: $m.aboutMe).font(.system(size: 12.5)).frame(minHeight: 60)
                } header: { Text("About you") } footer: {
                    Text("Optional. A line or two helps the planner, e.g. \"Junior studying CS, part-time job Tue/Thu, gym most evenings.\"")
                }
                Section {
                    HStack {
                        Button(m.testing ? "Testing…" : "Save and test") { m.testAI() }.disabled(m.testing)
                        if let r = m.testResult {
                            Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(r.ok ? Theme.accent : Theme.flame).font(.system(size: 12)).lineLimit(2)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// Editable list of short strings: chips with remove buttons plus an add field.
struct TokenList: View {
    @Binding var items: [String]
    var placeholder: String
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !items.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(items, id: \.self) { item in
                        HStack(spacing: 4) {
                            Text(item).font(.system(size: 12))
                            Button { items.removeAll { $0 == item } } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
            }
            HStack {
                TextField(placeholder, text: $draft).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Add", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.vertical, 2)
    }
    private func add() {
        let t = draft.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !items.contains(t) else { draft = ""; return }
        items.append(t); draft = ""
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? 400, subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(bounds.width, subviews)
        for (i, p) in r.points.enumerated() { subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified) }
    }
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var pts: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            pts.append(CGPoint(x: x, y: y)); x += sz.width + spacing; rowH = max(rowH, sz.height); maxX = max(maxX, x)
        }
        return (CGSize(width: maxX, height: y + rowH), pts)
    }
}
