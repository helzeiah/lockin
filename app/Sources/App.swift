import AppKit
import SwiftUI

@main
struct FocusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var e = Engine.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(e)
        } label: {
            Image(systemName: e.block == nil ? "scope" : (e.drifting ? "exclamationmark.circle" : "timer"))
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // focus://start?block=Study&minutes=25&task=...  focus://stop  focus://plan  focus://today  focus://recap
    func application(_ app: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            let e = Engine.shared
            for u in urls {
                let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                switch u.host ?? "" {
                case "start":
                    if let p = e.presetFor(q["block"] ?? "") ?? e.cfg.blocks.first {
                        e.startBlock(p, minutes: Int(q["minutes"] ?? ""), task: q["task"].flatMap { $0.isEmpty ? nil : $0 })
                    }
                case "next": if let t = e.nextTodo { e.startTodo(t) }
                case "stop": e.stopBlock(completed: false)
                case "plan": Planner.shared.open()
                case "today": e.showPlan()
                case "recap": e.showRecap()
                default: break
                }
            }
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        Task { @MainActor in
            Engine.shared.start()
            IslandController.shared.start()
            BlockerController.shared.start()
        }
    }
}

// Close the menu-bar popover (it's the key window while open).
@MainActor func closePopover() {
    for w in NSApp.windows where w.className.contains("MenuBarExtra") || w.className.contains("StatusBarWindow") { w.orderOut(nil) }
    if let k = NSApp.keyWindow, k.className.contains("MenuBarExtra") { k.orderOut(nil) }
}

// The menu-bar popover.
struct MenuContent: View {
    @EnvironmentObject var e: Engine
    @State private var expanded: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            current.padding(14)
            Divider()
            if e.block == nil, let n = e.nextTodo {
                Button { closePopover(); e.startTodo(n) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.right.circle.fill").foregroundStyle(Color.accentColor).font(.system(size: 16))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Up next").font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(n.task).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        }
                        Spacer()
                        Text("\(n.minutes)m").font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowStyle()).padding(.horizontal, 6).padding(.vertical, 6)
                Divider()
            }
            let style = e.cfg.menu_style ?? "both"
            if style != "blocks" { QuickFocus() }
            if style == "both" && !e.cfg.blocks.isEmpty { Divider() }
            if style != "quick" && !e.cfg.blocks.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text("My blocks").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
                    ForEach(e.cfg.blocks) { p in presetRow(p) }
                }
                .padding(.bottom, 6)
            }
            Divider()
            VStack(alignment: .leading, spacing: 1) {
                menuRow("Plan my day…", "list.bullet.rectangle") { Planner.shared.open() }
                menuRow("Today's plan", "sun.max") { e.showPlan() }
                menuRow("How today's going", "chart.bar") { e.showRecap() }
                menuRow("Settings…", "gearshape") { SettingsWindow.shared.open() }
                menuRow("Quit Focus", "power") { NSApp.terminate(nil) }
            }
            .padding(6)
        }
        .frame(width: 300)
    }

    @ViewBuilder private var current: some View {
        if let b = e.block {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Ring(progress: e.progress, color: e.isBreak ? tintColor("orange") : e.drifting ? tintColor("red") : tintColor("green"), size: 34, width: 3.5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.isBreak ? "Break" : (b.task ?? b.name)).font(.system(size: 13.5, weight: .semibold)).lineLimit(2)
                        Text(e.isBreak ? "Back soon" : b.name).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(fmtTime(e.remaining)).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                HStack(spacing: 8) {
                    Button("Stop") { closePopover(); e.stopBlock(completed: false) }.controlSize(.regular)
                    Button("+5 min") { closePopover(); e.addFive() }.controlSize(.regular)
                    Spacer()
                }
            }
        } else {
            HStack(spacing: 12) {
                Image(systemName: "scope").font(.system(size: 22, weight: .light)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No timer running").font(.system(size: 13.5, weight: .semibold))
                    Text(e.todos.isEmpty ? "Plan your day, then start a block" : "\(e.todos.filter { !$0.isDone }.count) to-dos left today")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func presetRow(_ p: Preset) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(colorFor(block: p.name)).frame(width: 8, height: 8)
                Text(p.name).font(.system(size: 13))
                Spacer()
                ForEach([25, p.minutes, 90].reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }, id: \.self) { m in
                    Button("\(m)") { closePopover(); e.startBlock(p, minutes: m) }
                        .buttonStyle(ChipStyle(primary: m == p.minutes))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 5)
        }
    }

    private func menuRow(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: { closePopover(); action() }) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary)
                Text(title).font(.system(size: 13))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RowStyle())
    }
}

// A block with no name: pick a length and the apps you'll use. Anything else gets covered while it runs.
struct QuickFocus: View {
    @EnvironmentObject var e: Engine
    @State private var apps: [String] = []
    @State private var choosing = false

    private var running: [String] {
        let names = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }.compactMap(\.localizedName).filter { $0 != "Focus" }
        return Array(Set(names + apps)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Quick focus").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                ForEach([25, 45, 60, 90], id: \.self) { m in
                    Button("\(m)") { closePopover(); e.startQuick(minutes: m, apps: apps) }
                        .buttonStyle(ChipStyle(primary: m == 25)).disabled(apps.isEmpty)
                }
            }
            Button { withAnimation(.easeOut(duration: 0.15)) { choosing.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "app.badge.checkmark").foregroundStyle(.secondary)
                    Text(apps.isEmpty ? "Choose the apps you'll use" : apps.joined(separator: ", "))
                        .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(choosing ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if choosing {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(running, id: \.self) { name in
                            Toggle(name, isOn: Binding(get: { apps.contains(name) },
                                                       set: { on in if on { apps.append(name) } else { apps.removeAll { $0 == name } } }))
                                .toggleStyle(.checkbox).font(.system(size: 12))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                Text("Everything else gets covered until the timer ends.").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .onAppear {
            let saved = e.quickApps.filter { n in NSWorkspace.shared.runningApplications.contains { $0.localizedName == n } }
            apps = saved.isEmpty ? (e.lastExternalApp.isEmpty ? [] : [e.lastExternalApp]) : saved
        }
    }
}

struct RowStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(hover || configuration.isPressed ? Color.primary.opacity(0.08) : .clear))
            .onHover { hover = $0 }
    }
}

struct ChipStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11.5, weight: .semibold, design: .rounded)).monospacedDigit()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(primary ? Color.white : Color.primary)
            .background(Capsule().fill(primary ? Color.accentColor : Color.primary.opacity(configuration.isPressed ? 0.15 : 0.08)))
    }
}
