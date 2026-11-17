import AppKit
import EventKit
import ServiceManagement
import SwiftUI

// One-time setup, like Opal or ScreenZen: pick what distracts you, how strict lockin is, grant the macOS
// permissions in one place, set a daily goal. Runs on first launch (and again from General → Run setup again).
@MainActor
final class SetupWindow {
    static let shared = SetupWindow()
    static let version = 1                       // bump to show setup again after a big change
    private static let key = "setupVersionDone"
    private var window: KeyPanel?

    static var needed: Bool { UserDefaults.standard.integer(forKey: key) < version }
    static func markDone() { UserDefaults.standard.set(version, forKey: key) }

    func open(step: SetupStep = .welcome) {
        Engine.shared.card = nil
        window?.close()
        let w = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SetupView(start: step) { [weak self] in self?.close() }.environmentObject(Engine.shared))
        w.center()
        window = w
        w.show()
    }
    func close() { window?.close(); window = nil }
}

enum SetupStep: Int, CaseIterable { case welcome, distractions, strictness, access, goal, done }

// MARK: - Permissions

/// The macOS permissions lockin uses, checked live (they can change in System Settings at any time).
enum Access: Equatable {
    case granted, denied, notAsked, notRunning, notInstalled

    /// Apps lockin reads with AppleScript: browsers (open tab) and terminals (Claude Code folder).
    static let scriptable = ["Dia", "Google Chrome", "Arc", "Safari", "Brave Browser", "Microsoft Edge", "Vivaldi",
                             "Opera", "Chromium", "iTerm2", "Terminal"]
    private static let bundleIDs = ["Dia": "company.thebrowser.dia", "Google Chrome": "com.google.Chrome",
                                    "Arc": "company.thebrowser.Browser", "Safari": "com.apple.Safari",
                                    "Brave Browser": "com.brave.Browser", "Microsoft Edge": "com.microsoft.edgemac",
                                    "Vivaldi": "com.vivaldi.Vivaldi", "Opera": "com.operasoftware.Opera",
                                    "Chromium": "org.chromium.Chromium", "iTerm2": "com.googlecode.iterm2",
                                    "Terminal": "com.apple.Terminal"]

    static func installed(_ app: String) -> URL? {
        bundleIDs[app].flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }
    static func isRunning(_ app: String) -> Bool {
        bundleIDs[app].map { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty } ?? false
    }
    static var installedScriptable: [String] { scriptable.filter { installed($0) != nil } }

    /// Can lockin script this app? Never prompts unless `ask` is true. Blocks briefly, so call off the main thread.
    nonisolated static func automation(_ app: String, ask: Bool = false) -> Access {
        guard let id = bundleIDs[app] else { return .notInstalled }
        let target = NSAppleEventDescriptor(bundleIdentifier: id)
        guard let desc = target.aeDesc else { return .notAsked }
        let status = AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .notRunning
        default: return .notAsked      // errAEEventWouldRequireUserConsent
        }
    }

    static var calendar: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    static var loginItem: Bool { SMAppService.mainApp.status == .enabled }

    static func openPrivacy(_ pane: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(u) }
    }
}

/// Live permission state for the Access step, refreshed every couple of seconds while it's on screen.
@MainActor
final class AccessModel: ObservableObject {
    @Published var apps: [String: Access] = [:]
    @Published var calendar = Access.calendar
    @Published var login = Access.loginItem
    @Published var asking: String?
    let list = Access.installedScriptable
    var browsers: [String] { list.filter { !Detect.terminals.contains($0) } }
    var terminals: [String] { list.filter { Detect.terminals.contains($0) } }
    private var timer: Timer?

    /// Terminals are optional (only for Claude Code folders), so they don't count here.
    var allGood: Bool { calendar == .granted && browsers.allSatisfy { apps[$0] == .granted } }

    func startWatching() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in Task { @MainActor in self.refresh() } }
    }
    func stopWatching() { timer?.invalidate(); timer = nil }

    func refresh() {
        calendar = Access.calendar
        login = Access.loginItem
        let list = self.list
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Dictionary(uniqueKeysWithValues: list.map { ($0, Access.automation($0)) })
            DispatchQueue.main.async { if self.asking == nil { self.apps = r } }
        }
    }

    /// macOS only asks while the app is running, so open it in the background first, then ask.
    func allow(_ app: String) {
        if apps[app] == .denied { Access.openPrivacy("Privacy_Automation"); return }
        asking = app
        let ask = {
            DispatchQueue.global(qos: .userInitiated).async {
                var s = Access.automation(app, ask: true)
                for _ in 0..<20 where s == .notRunning {      // still launching
                    Thread.sleep(forTimeInterval: 0.5); s = Access.automation(app, ask: true)
                }
                DispatchQueue.main.async { self.asking = nil; self.apps[app] = s }
            }
        }
        if Access.isRunning(app) == false, let url = Access.installed(app) {
            let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = false; cfg.hides = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in ask() }
        } else { ask() }
    }

    func allowAll() {
        let todo = browsers.filter { apps[$0] != .granted && apps[$0] != .denied }
        Task {
            if calendar == .notAsked { await allowCalendar() }
            for a in todo {
                allow(a)
                while asking != nil { try? await Task.sleep(nanoseconds: 300_000_000) }
            }
        }
    }

    func allowCalendar() async {
        if calendar == .denied { Access.openPrivacy("Privacy_Calendars"); return }
        _ = try? await EKEventStore().requestFullAccessToEvents()
        calendar = Access.calendar
    }

    func setLogin(_ on: Bool) {
        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        login = Access.loginItem
    }
}

// MARK: - The distraction catalog

/// Common distractions as one-tap tiles. Each tile stands for a few sites and/or apps.
struct DistractionPick: Identifiable {
    var name: String
    var icon: String
    var sites: [String] = []
    var apps: [String] = []
    var id: String { name }

    static let catalog: [DistractionPick] = [
        .init(name: "YouTube", icon: "play.rectangle.fill", sites: ["youtube.com"]),
        .init(name: "Reddit", icon: "bubble.left.and.bubble.right.fill", sites: ["reddit.com"]),
        .init(name: "X / Twitter", icon: "at", sites: ["x.com", "twitter.com"]),
        .init(name: "Instagram", icon: "camera.fill", sites: ["instagram.com"]),
        .init(name: "TikTok", icon: "music.note", sites: ["tiktok.com"]),
        .init(name: "Facebook", icon: "person.2.fill", sites: ["facebook.com"]),
        .init(name: "Netflix", icon: "film.fill", sites: ["netflix.com"]),
        .init(name: "Streaming", icon: "tv.fill", sites: ["hulu.com", "max.com", "primevideo.com", "disneyplus.com"], apps: ["TV"]),
        .init(name: "Twitch", icon: "dot.radiowaves.left.and.right", sites: ["twitch.tv"]),
        .init(name: "Sports", icon: "sportscourt.fill", sites: ["espn.com"]),
        .init(name: "Games", icon: "gamecontroller.fill", sites: ["roblox.com", "chess.com"], apps: ["Steam", "Roblox", "RobloxPlayer"]),
        .init(name: "Discord", icon: "message.fill", sites: ["discord.com"], apps: ["Discord"]),
        .init(name: "Messages", icon: "message.badge.fill", apps: ["Messages", "WhatsApp"]),
        .init(name: "News", icon: "newspaper.fill", sites: ["news.google.com", "cnn.com", "nytimes.com"], apps: ["News"]),
        .init(name: "Shopping", icon: "cart.fill", sites: ["amazon.com", "ebay.com"]),
    ]
    static var allSites: Set<String> { Set(catalog.flatMap(\.sites)) }
    static var allApps: Set<String> { Set(catalog.flatMap(\.apps)) }
}

// MARK: - The view

struct SetupView: View {
    @EnvironmentObject var e: Engine
    @StateObject private var m = SettingsModel()
    @StateObject private var access = AccessModel()
    @State var step: SetupStep
    var onClose: () -> Void

    init(start: SetupStep, onClose: @escaping () -> Void) {
        _step = State(initialValue: start)
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            if step != .welcome && step != .done { progress.padding(.top, 34) }
            Group {
                switch step {
                case .welcome: welcome
                case .distractions: distractions
                case .strictness: strictness
                case .access: accessStep
                case .goal: goal
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            footer
        }
        .frame(width: 640, height: 600)
        .background(VisualEffect(material: .underWindowBackground))
        .onChange(of: step) { _, s in
            m.save(includeKey: false)
            if s == .access { access.startWatching() } else { access.stopWatching() }
        }
        .onAppear { if step == .access { access.startWatching() } }
        .onDisappear { access.stopWatching(); m.save(includeKey: false) }
    }

    // MARK: pieces

    private var progress: some View {
        let steps = SetupStep.allCases.filter { $0 != .welcome && $0 != .done }
        return HStack(spacing: 6) {
            ForEach(steps, id: \.rawValue) { s in
                Capsule().fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.primary.opacity(0.12))
                    .frame(width: s == step ? 26 : 14, height: 5)
            }
        }
        .animation(.spring(duration: 0.3), value: step)
    }

    private func header(_ title: String, _ sub: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 26, weight: .bold)).tracking(-0.4).multilineTextAlignment(.center)
            Text(sub).font(.system(size: 13.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 440)
        }
        .padding(.top, 26).padding(.bottom, 20)
    }

    private var footer: some View {
        HStack {
            if step != .welcome && step != .done {
                Button("Back") { go(-1) }.buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 13))
            }
            Spacer()
            switch step {
            case .welcome: bigButton("Let's go") { go(1) }
            case .access:
                if !access.allGood { Button("Skip for now") { go(1) }.buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 13)).padding(.trailing, 10) }
                bigButton("Continue") { go(1) }
            case .done: EmptyView()
            default: bigButton("Continue") { go(1) }
            }
        }
        .padding(.horizontal, 32).padding(.bottom, 26).padding(.top, 8)
    }

    private func bigButton(_ t: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: 14, weight: .semibold)).padding(.horizontal, 22).padding(.vertical, 9)
                .foregroundStyle(.white).background(Capsule().fill(Color.accentColor))
        }
        .buttonStyle(.plain).keyboardShortcut(.defaultAction)
    }

    private func go(_ d: Int) {
        guard let s = SetupStep(rawValue: step.rawValue + d) else { return }
        withAnimation(.easeOut(duration: 0.22)) { step = s }
    }

    // MARK: steps

    private var welcome: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "scope").font(.system(size: 54, weight: .light)).foregroundStyle(Color.accentColor)
            Text("Set up lockin once").font(.system(size: 30, weight: .bold)).tracking(-0.5)
            Text("About 2 minutes. After this you won't have to think about it again.")
                .font(.system(size: 14)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                bullet("hand.raised.fill", "Pick what pulls you off task")
                bullet("shield.lefthalf.filled", "Choose how strict lockin is")
                bullet("checkmark.shield.fill", "Allow access in one place")
                bullet("flame.fill", "Set a daily goal for your streak")
            }
            .padding(.top, 10)
            Spacer()
        }
    }
    private func bullet(_ icon: String, _ t: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 22)
            Text(t).font(.system(size: 14))
        }
    }

    private var distractions: some View {
        VStack(spacing: 0) {
            header("What pulls you off task?", "These get covered during a focus block. Tap to turn one on or off.")
            ScrollView {
                VStack(spacing: 18) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                        ForEach(DistractionPick.catalog) { p in tile(p) }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Anything else? Add a site or app").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        TokenList(items: extrasBinding, placeholder: "e.g. pokernow.club or Slack")
                    }
                }
                .padding(.horizontal, 40).padding(.bottom, 10)
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
                Image(systemName: p.icon).font(.system(size: 14)).frame(width: 20)
                    .foregroundStyle(on ? Color.white : .secondary)
                Text(p.name).font(.system(size: 13, weight: .medium)).foregroundStyle(on ? Color.white : .primary).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 13))
                    .foregroundStyle(on ? Color.white : Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, 12).frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? Color.accentColor : Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var strictness: some View {
        VStack(spacing: 0) {
            header("How strict should lockin be?", "What happens when you open one of those during a focus block. Breaks are never covered.")
            VStack(spacing: 10) {
                choice("nudge", "bell.fill", "Nudge me", "A reminder drops out of the notch. Nothing gets in your way.")
                choice("cover", "rectangle.inset.filled", "Cover it", "A blurred cover with Back to work. \"Give me 5 min\" unlocks after \(Int(Engine.snoozeWait)) seconds, \(Engine.snoozesPerBlock) times per block.", recommended: true)
                choice("hard", "lock.fill", "Cover, no passes", "Same cover, no way around it until the block ends.")
            }
            .padding(.horizontal, 56)
            Toggle("Play a soft sound for starts, check-ins and finishing", isOn: $m.sounds)
                .toggleStyle(.switch).controlSize(.small).font(.system(size: 12.5)).padding(.top, 22)
        }
    }

    private func choice(_ id: String, _ icon: String, _ title: String, _ sub: String, recommended: Bool = false) -> some View {
        let on = m.blocking == id
        return Button { withAnimation(.easeOut(duration: 0.12)) { m.blocking = id } } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon).font(.system(size: 17)).frame(width: 34, height: 34)
                    .foregroundStyle(on ? Color.white : Color.accentColor)
                    .background(RoundedRectangle(cornerRadius: 9).fill(on ? Color.accentColor : Color.accentColor.opacity(0.12)))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 14, weight: .semibold))
                        if recommended {
                            Text("Recommended").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        }
                    }
                    Text(sub).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: on ? "largecircle.fill.circle" : "circle").font(.system(size: 16))
                    .foregroundStyle(on ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(on ? 0.08 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var accessStep: some View {
        VStack(spacing: 0) {
            header("Allow access, once", "macOS asks for each app separately. Click Allow on each row and say OK. lockin never stores what it sees.")
            ScrollView {
                VStack(spacing: 8) {
                    if !access.browsers.isEmpty {
                        group("See the open tab", "To tell YouTube from your homework doc, and to cover the right tab.") {
                            ForEach(access.browsers, id: \.self) { a in
                                permRow(icon: appIcon(a), name: a, state: access.apps[a] ?? .notAsked, busy: access.asking == a) { access.allow(a) }
                            }
                        }
                    }
                    group("Plan around your calendar", "Read-only. Your events stay on your Mac.") {
                        permRow(icon: appIcon("Calendar"), name: "Calendar", state: access.calendar, busy: false) {
                            Task { await access.allowCalendar() }
                        }
                    }
                    if !access.terminals.isEmpty {
                        group("Optional: Claude Code in the terminal", "Lets a Claude Code session in a project folder count as on task.") {
                            ForEach(access.terminals, id: \.self) { a in
                                permRow(icon: appIcon(a), name: a, state: access.apps[a] ?? .notAsked, busy: access.asking == a) { access.allow(a) }
                            }
                        }
                    }
                    group("Start with your Mac", "So the timer and covers are there without remembering to open lockin.") {
                        HStack(spacing: 10) {
                            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 24, height: 24)
                            Text("Open lockin at login").font(.system(size: 13))
                            Spacer()
                            Toggle("", isOn: Binding(get: { access.login }, set: { access.setLogin($0) })).toggleStyle(.switch).controlSize(.small).labelsHidden()
                        }
                        .padding(.vertical, 4)
                    }
                    if !access.allGood {
                        Button { access.allowAll() } label: {
                            Label("Allow all", systemImage: "checkmark.shield").font(.system(size: 12.5, weight: .medium))
                        }
                        .buttonStyle(.bordered).padding(.top, 4)
                    }
                }
                .padding(.horizontal, 48).padding(.bottom, 10)
            }
        }
    }

    private func group<C: View>(_ title: String, _ sub: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(sub).font(.system(size: 11.5)).foregroundStyle(.secondary)
            VStack(spacing: 0) { content() }.padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func permRow(icon: NSImage, name: String, state: Access, busy: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: icon).resizable().frame(width: 24, height: 24)
            Text(name).font(.system(size: 13))
            Spacer()
            if busy {
                ProgressView().controlSize(.small)
            } else if state == .granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(.green)
            } else if state == .denied {
                Button("Turn on in Settings", action: action).controlSize(.small)
            } else {
                Button("Allow", action: action).controlSize(.small).buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 5)
    }

    private func appIcon(_ name: String) -> NSImage {
        if let u = Access.installed(name) { return NSWorkspace.shared.icon(forFile: u.path) }
        if name == "Calendar", let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            return NSWorkspace.shared.icon(forFile: u.path)
        }
        return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
    }

    private var goal: some View {
        VStack(spacing: 0) {
            header("Set a daily goal", "A day counts toward your streak once you hit it. Start small. You can raise it later.")
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Text("Focused minutes a day").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    HStack(spacing: 8) { ForEach([15, 25, 45, 60, 90], id: \.self) { v in pill("\(fmtMinutes(v))", m.statsGoal == v) { m.statsGoal = v } } }
                }
                VStack(spacing: 10) {
                    Text("Days a week").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    HStack(spacing: 8) { ForEach(3...7, id: \.self) { v in pill("\(v)", m.weekGoal == v) { m.weekGoal = v } } }
                }
                Toggle("Remind me at \(m.streakReminderAt.formatted(date: .omitted, time: .shortened)) if today hasn't counted yet", isOn: $m.streakReminderOn)
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 12.5))
            }
        }
    }

    private func pill(_ t: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: 13.5, weight: .semibold)).frame(minWidth: 52).padding(.horizontal, 12).padding(.vertical, 9)
                .foregroundStyle(on ? Color.white : .primary)
                .background(Capsule().fill(on ? Color.accentColor : Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }

    private var done: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.seal.fill").font(.system(size: 54)).foregroundStyle(.green)
            Text("You're set").font(.system(size: 30, weight: .bold)).tracking(-0.5)
            VStack(alignment: .leading, spacing: 8) {
                summary("hand.raised.fill", "\(m.distractingSites.count + m.distractingApps.count) distractions, \(m.blocking == "nudge" ? "nudged" : m.blocking == "hard" ? "covered with no passes" : "covered")")
                summary("checkmark.shield.fill", access.allGood ? "All access allowed" : "Some access skipped. lockin still works, just sees less")
                summary("flame.fill", "Goal: \(fmtMinutes(m.statsGoal)) a day, \(m.weekGoal) days a week")
            }
            .padding(.vertical, 6)
            Text("Change any of this later in the lockin window under Setup.").font(.system(size: 12)).foregroundStyle(.secondary)
            VStack(spacing: 10) {
                bigButton("Start a \(fmtMinutes(m.statsGoal)) block") {
                    finish()
                    if let p = e.cfg.blocks.first { e.startBlock(p, minutes: m.statsGoal, task: nil) }
                }
                Button("Not now") { finish() }.buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 13))
            }
            .padding(.top, 8)
            Spacer()
        }
        .onAppear { SetupWindow.markDone() }
    }
    private func summary(_ icon: String, _ t: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 20)
            Text(t).font(.system(size: 13.5))
        }
    }

    private func finish() {
        m.save(includeKey: false)
        SetupWindow.markDone()
        onClose()
    }
}
