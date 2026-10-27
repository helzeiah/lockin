import AppKit
import ServiceManagement
import SwiftUI

// Native settings window. Edits config.json in place (keeps any keys it doesn't know about).
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func open() {
        Engine.shared.card = nil
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Focus Settings"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 560, height: 460)
        w.contentView = NSHostingView(rootView: SettingsView(model: SettingsModel()))
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class SettingsModel: ObservableObject {
    @Published var driftSeconds: Double
    @Published var renudgeSeconds: Double
    @Published var breakMinutes: Int
    @Published var macAwayMinutes: Double
    @Published var morningHour: Int
    @Published var recapAt: Date
    @Published var dayEnd: Date
    @Published var idleNudgeMinutes: Double
    @Published var activeFrom: Int
    @Published var activeTo: Int
    @Published var distractingSites: [String]
    @Published var distractingApps: [String]
    @Published var blockSites: [String]
    @Published var alwaysOkApps: [String]
    @Published var blocks: [Preset]
    @Published var menuStyle: String
    @Published var aiProvider: String
    @Published var aiModel: String
    @Published var aiBaseURL: String
    @Published var aboutMe: String
    @Published var apiKeyDraft = ""
    @Published var hasKey = Keychain.get() != nil
    @Published var testResult: (ok: Bool, text: String)?
    @Published var testing = false
    @Published var saved = false

    private var raw: [String: Any]

    init() {
        raw = (try? JSONSerialization.jsonObject(with: Data(contentsOf: Paths.config))) as? [String: Any] ?? [:]
        let c = Config.load() ?? Config(distractions: Distractions(apps: [], sites: []), block_sites: [], blocks: [])
        driftSeconds = c.drift_seconds ?? 30
        renudgeSeconds = c.renudge_seconds ?? 120
        breakMinutes = c.break_minutes ?? 5
        macAwayMinutes = (c.mac_away_seconds ?? 180) / 60
        morningHour = c.morning_hour ?? 5
        recapAt = SettingsModel.time(c.recap_at ?? "21:00")
        dayEnd = SettingsModel.time(raw["day_end"] as? String ?? "23:30")
        idleNudgeMinutes = c.idle_nudge_minutes ?? 40
        activeFrom = c.active_hours?.first ?? 8
        activeTo = c.active_hours?.last ?? 23
        distractingSites = c.distractions.sites
        distractingApps = c.distractions.apps
        blockSites = c.block_sites
        alwaysOkApps = c.always_ok_apps ?? []
        blocks = c.blocks
        menuStyle = c.menu_style ?? "both"
        let ai = raw["ai"] as? [String: Any] ?? [:]
        aiProvider = (ai["provider"] as? String).map { $0 == "none" ? "" : $0 } ?? ""
        aiModel = ai["model"] as? String ?? ""
        aiBaseURL = ai["base_url"] as? String ?? ""
        aboutMe = raw["about_me"] as? String ?? ""
    }

    static let providers: [(id: String, name: String)] = [
        ("", "None: plan by hand"), ("claude-code", "Claude Code (your Claude subscription)"),
        ("anthropic", "Claude API key"), ("openai", "OpenAI API key"),
        ("openai-compatible", "Other (OpenRouter, Gemini, Ollama, LM Studio…)")]
    static let defaultModels = ["claude-code": "sonnet", "anthropic": "claude-opus-5-5", "openai": "gpt-5-mini",
                                "openai-compatible": "e.g. llama3.1 or google/gemini-2.5-flash"]
    var needsKey: Bool { aiProvider == "anthropic" || aiProvider == "openai" || aiProvider == "openai-compatible" }

    func testAI() {
        save()
        testing = true; testResult = nil
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
    static func hhmm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    func save() {
        raw["drift_seconds"] = driftSeconds
        raw["renudge_seconds"] = renudgeSeconds
        raw["break_minutes"] = breakMinutes
        raw["mac_away_seconds"] = macAwayMinutes * 60
        raw["morning_hour"] = morningHour
        raw["recap_at"] = SettingsModel.hhmm(recapAt)
        raw["day_end"] = SettingsModel.hhmm(dayEnd)
        raw["idle_nudge_minutes"] = idleNudgeMinutes
        raw["active_hours"] = [activeFrom, activeTo]
        raw["distractions"] = ["sites": distractingSites, "apps": distractingApps]
        raw["block_sites"] = blockSites
        raw["always_ok_apps"] = alwaysOkApps
        raw["menu_style"] = menuStyle
        // "None" keeps the AI off; the planner then works by hand only.
        raw["ai"] = ["provider": aiProvider.isEmpty ? "none" : aiProvider, "model": aiModel.trimmingCharacters(in: .whitespaces),
                     "base_url": aiBaseURL.trimmingCharacters(in: .whitespaces)]
        raw["about_me"] = aboutMe.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { Keychain.set(key); apiKeyDraft = ""; hasKey = true }
        raw["blocks"] = blocks.map { b -> [String: Any] in
            ["name": b.name, "minutes": b.minutes, "sites": b.sites ?? [], "apps": b.apps ?? [], "projects": b.projects ?? [],
             "offline_ok": b.offline_ok ?? false, "any_claude": b.any_claude ?? false, "terminal_ok": b.terminal_ok ?? true,
             "strict": b.strict ?? false]
        }
        if let d = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: Paths.config)
        }
        Task { @MainActor in Engine.shared.reloadConfig() }
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self.saved = false }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        VStack(spacing: 0) {
            TabView {
                GeneralTab(m: model).tabItem { Label("General", systemImage: "gearshape") }
                BlocksTab(m: model).tabItem { Label("Focus blocks", systemImage: "square.stack.3d.up") }
                DistractionsTab(m: model).tabItem { Label("Distractions", systemImage: "hand.raised") }
                AITab(m: model).tabItem { Label("AI planner", systemImage: "sparkles") }
            }
            .padding(.top, 6)
            Divider()
            HStack {
                Text(model.saved ? "Saved" : "Changes apply as soon as you save.")
                    .font(.system(size: 12)).foregroundStyle(model.saved ? .green : .secondary)
                    .animation(.easeOut(duration: 0.15), value: model.saved)
                Spacer()
                Button("Save") { model.save() }.keyboardShortcut("s", modifiers: .command).buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(minWidth: 560, minHeight: 460)
    }
}

struct GeneralTab: View {
    @ObservedObject var m: SettingsModel
    var body: some View {
        Form {
            Section("Staying on task") {
                LabeledContent("Nudge me after") {
                    Stepper("\(Int(m.driftSeconds)) seconds off task", value: $m.driftSeconds, in: 10...300, step: 10)
                }
                LabeledContent("Remind again every") {
                    Stepper("\(Int(m.renudgeSeconds / 60)) min", value: $m.renudgeSeconds, in: 60...900, step: 60)
                }
                LabeledContent("Away from Mac counts after") {
                    Stepper("\(Int(m.macAwayMinutes)) min", value: $m.macAwayMinutes, in: 1...15, step: 1)
                }
                LabeledContent("Break length") {
                    Stepper("\(m.breakMinutes) min", value: $m.breakMinutes, in: 1...30)
                }
            }
            Section("App") {
                Picker("Menu shows", selection: $m.menuStyle) {
                    Text("Quick focus and my blocks").tag("both")
                    Text("Quick focus only").tag("quick")
                    Text("My blocks only").tag("blocks")
                }
                Toggle("Open Focus when I log in", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { on in try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister(); m.objectWillChange.send() }))
            }
            Section("Daily rhythm") {
                Picker("Morning plan after", selection: $m.morningHour) {
                    ForEach(3..<12) { h in Text("\(h):00 AM").tag(h) }
                }
                DatePicker("Evening recap", selection: $m.recapAt, displayedComponents: .hourAndMinute)
                DatePicker("Plan my day until", selection: $m.dayEnd, displayedComponents: .hourAndMinute)
            }
            Section("When no timer is running") {
                LabeledContent("Suggest the next to-do every") {
                    Stepper("\(Int(m.idleNudgeMinutes)) min", value: $m.idleNudgeMinutes, in: 10...180, step: 5)
                }
                Picker("Only between", selection: $m.activeFrom) { ForEach(5..<14) { h in Text(hourLabel(h)).tag(h) } }
                Picker("and", selection: $m.activeTo) { ForEach(16..<25) { h in Text(hourLabel(h % 24)).tag(h) } }
            }
        }
        .formStyle(.grouped)
    }
    private func hourLabel(_ h: Int) -> String {
        let d = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date()
        return d.formatted(date: .omitted, time: .shortened)
    }
}

struct BlocksTab: View {
    @ObservedObject var m: SettingsModel
    @State private var selection: String?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(m.blocks) { b in
                        HStack(spacing: 8) {
                            Circle().fill(colorFor(block: b.name)).frame(width: 8, height: 8)
                            Text(b.name)
                            Spacer()
                            Text("\(b.minutes)m").foregroundStyle(.secondary).font(.system(size: 11, design: .rounded))
                        }
                        .tag(b.name)
                    }
                }
                .listStyle(.sidebar)
                HStack(spacing: 0) {
                    Button { addBlock() } label: { Image(systemName: "plus").frame(width: 24, height: 22) }
                    Button { removeBlock() } label: { Image(systemName: "minus").frame(width: 24, height: 22) }.disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless).padding(6)
            }
            .frame(minWidth: 170, maxWidth: 220)

            if let i = m.blocks.firstIndex(where: { $0.name == selection }) {
                BlockEditor(block: $m.blocks[i], onRename: { selection = $0 })
            } else {
                Text("Select a focus block").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { selection = selection ?? m.blocks.first?.name }
    }

    private func addBlock() {
        var name = "New block", n = 2
        while m.blocks.contains(where: { $0.name == name }) { name = "New block \(n)"; n += 1 }
        m.blocks.append(Preset(name: name, minutes: 45))
        selection = name
    }
    private func removeBlock() {
        m.blocks.removeAll { $0.name == selection }
        selection = m.blocks.first?.name
    }
}

struct BlockEditor: View {
    @Binding var block: Preset
    var onRename: (String) -> Void
    var body: some View {
        Form {
            Section {
                TextField("Name", text: Binding(get: { block.name }, set: { block.name = $0; onRename($0) }))
                Stepper("Default length: \(block.minutes) min", value: $block.minutes, in: 10...180, step: 5)
            }
            Section {
                Toggle("Only allow these apps and sites", isOn: Binding(get: { block.strict ?? false }, set: { block.strict = $0 }))
            } footer: {
                Text("Anything else gets covered with a reminder to go back, not just the sites on your distraction list.")
            }
            Section {
                Toggle("Count time away from the Mac as focus", isOn: Binding(get: { block.offline_ok ?? false }, set: { block.offline_ok = $0 }))
                Toggle("Terminal counts as on task", isOn: Binding(get: { block.terminal_ok ?? true }, set: { block.terminal_ok = $0 }))
                Toggle("Any Claude Code session counts as on task", isOn: Binding(get: { block.any_claude ?? false }, set: { block.any_claude = $0 }))
            } footer: {
                Text("Away time is for iPad, paper or textbook work. Otherwise more than a few minutes away counts as drifting.")
            }
            Section("On-task websites") { TokenList(items: Binding(get: { block.sites ?? [] }, set: { block.sites = $0 }), placeholder: "e.g. leetcode.com") }
            Section("On-task apps") { TokenList(items: Binding(get: { block.apps ?? [] }, set: { block.apps = $0 }), placeholder: "e.g. CLion") }
            Section {
                TokenList(items: Binding(get: { block.projects ?? [] }, set: { block.projects = $0 }), placeholder: "e.g. blockpilot")
            } header: { Text("Claude Code project folders") } footer: {
                Text("A Claude session in a folder whose name contains one of these counts as on task.")
            }
        }
        .formStyle(.grouped)
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
                     ? "Everything works without AI: add blocks in Plan my day and Focus suggests the soonest open time."
                     : "The AI turns a messy brain dump into a timed plan and edits it when you say things like \"free at 8 now\". It sees your to-dos, today's calendar and the text you type. Nothing else.")
            }
            if !m.aiProvider.isEmpty {
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
                                .foregroundStyle(r.ok ? .green : .orange).font(.system(size: 12)).lineLimit(2)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct DistractionsTab: View {
    @ObservedObject var m: SettingsModel
    var body: some View {
        Form {
            Section {
                TokenList(items: $m.blockSites, placeholder: "e.g. youtube.com")
            } header: { Text("Cover these sites during a block") } footer: {
                Text("A cover goes over the page; the tab stays open so you don't lose your place.")
            }
            Section("Count as drifting") { TokenList(items: $m.distractingSites, placeholder: "e.g. reddit.com") }
            Section("Distracting apps") { TokenList(items: $m.distractingApps, placeholder: "e.g. Discord") }
            Section {
                TokenList(items: $m.alwaysOkApps, placeholder: "e.g. Spotify")
            } header: { Text("Always fine") } footer: { Text("Never counted as drifting, in any block.") }
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
