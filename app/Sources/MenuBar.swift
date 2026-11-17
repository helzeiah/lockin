import AppKit
import SwiftUI

// The menu-bar popover.
struct MenuContent: View {
    @EnvironmentObject var e: Engine
    @State private var expanded: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            current.padding(14)
            Divider()
            if let app = Detect.denied.sorted().first {
                Button { closePopover(); SetupWindow.shared.open(step: .access) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 14))
                        Text("lockin can't see \(app) tabs").font(.system(size: 12.5)).lineLimit(1)
                        Spacer()
                        Text("Fix").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.accentColor)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowStyle()).padding(.horizontal, 6).padding(.vertical, 4)
                Divider()
            }
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
            // the main window's sections, one click each
            HStack(spacing: 2) {
                footerButton("Today", "sun.max") { Planner.shared.open(tab: .plan) }
                footerButton("Stats", "chart.bar") { Planner.shared.open(tab: .stats) }
                Spacer()
                iconButton("Settings", "gearshape") { SettingsWindow.open() }
                iconButton("Quit lockin", "power") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
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
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "scope").font(.system(size: 22, weight: .light)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No timer running").font(.system(size: 13.5, weight: .semibold))
                        Text(e.todos.isEmpty ? "Plan your day, then start a block" : "\(e.todos.filter { !$0.isDone }.count) to-dos left today")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                StreakStrip()
            }
        }
    }

    private func presetRow(_ p: Preset) -> some View { PresetRow(p: p) }

    private func footerButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: { closePopover(); action() }) {
            Label(title, systemImage: icon).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
        .buttonStyle(RowStyle())
    }
    private func iconButton(_ help: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: { closePopover(); action() }) {
            Image(systemName: icon).font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
        .buttonStyle(RowStyle()).help(help)
    }

}

// A block with no name: pick a length and the apps you'll use. Anything else gets covered while it runs.
struct QuickFocus: View {
    @EnvironmentObject var e: Engine
    @State private var apps: [String] = []
    @State private var choosing = false

    private var running: [String] {
        let names = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }.compactMap(\.localizedName).filter { $0 != selfAppName }
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

/// Today, the streak and this week in one line; click it for the stats drop-down.
struct StreakStrip: View {
    @EnvironmentObject var e: Engine
    @State private var st = Stats()
    var body: some View {
        Button { closePopover(); e.showStats() } label: {
            HStack(spacing: 14) {
                Label(fmtMinutes(st.todayMinutes) + " today", systemImage: "timer")
                    .foregroundStyle(st.todayMinutes >= st.goal ? tintColor("green") : .primary)
                Label("\(st.streak)", systemImage: "flame.fill").foregroundStyle(st.streak > 0 ? tintColor("orange") : .secondary)
                Label("\(st.weekDaysCounted)/\(st.weekGoal) days", systemImage: "calendar")
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
            }
            .font(.system(size: 11.5, weight: .medium)).monospacedDigit().lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear { st = e.stats() }
    }
}

/// A saved block: click the row to start it at its usual length; hover for a shorter or longer run.
struct PresetRow: View {
    @EnvironmentObject var e: Engine
    let p: Preset
    @State private var hover = false
    var body: some View {
        HStack(spacing: 10) {
            Button { closePopover(); e.startBlock(p) } label: {
                HStack(spacing: 10) {
                    Circle().fill(colorFor(block: p.name)).frame(width: 8, height: 8)
                    Text(p.name).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 6)
                    if !hover {
                        Text("\(p.minutes) min").font(.system(size: 11.5, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if hover {
                ForEach([25, p.minutes, 90].reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }, id: \.self) { m in
                    Button("\(m)") { closePopover(); e.startBlock(p, minutes: m) }
                        .buttonStyle(ChipStyle(primary: m == p.minutes))
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.primary.opacity(0.07) : .clear))
        .padding(.horizontal, 6)
        .onHover { hover = $0 }
    }
}
