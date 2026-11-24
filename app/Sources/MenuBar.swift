import AppKit
import SwiftUI

// The menu-bar popover: what's running (or next), one-click lock-in, your streak, and the way to everything else.
struct MenuContent: View {
    @EnvironmentObject var e: Engine

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            current.padding(14)
            Divider()
            if let app = Detect.denied.sorted().first {
                Button { closePopover(); SetupWindow.shared.open(step: .access) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.flame).font(.system(size: 14))
                        Text("lockin can't see \(app) tabs").font(.system(size: 12.5)).lineLimit(1)
                        Spacer()
                        Text("Fix").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowStyle()).padding(.horizontal, 6).padding(.vertical, 4)
                Divider()
            }
            if e.block == nil {
                if let n = e.nextTodo { upNext(n); Divider() }
                quick
                Divider()
            }
            HStack(spacing: 2) {
                footerButton("Today", "sun.max") { Planner.shared.open(tab: .plan, day: .today) }
                footerButton("Stats", "chart.bar") { Planner.shared.open(tab: .stats) }
                Spacer()
                iconButton("Settings", "gearshape") { SettingsWindow.open() }
                iconButton("Quit lockin", "power") { quit() }
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
        }
        .frame(width: 300)
        .background(SkinWash(strength: 1.3))
        .tint(Theme.accent)
    }

    @ViewBuilder private var current: some View {
        if let b = e.block {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Ring(progress: e.progress, color: e.isBreak ? Theme.flame : e.drifting ? Theme.danger : Theme.accent, size: 34, width: 3.5)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(e.isBreak ? "Break" : (b.task ?? "Locked in")).font(.system(size: 13.5, weight: .semibold)).lineLimit(2)
                        if e.isBreak { Text("Back soon").font(.system(size: 11.5)).foregroundStyle(.secondary) }
                        else { AppIconRow(apps: b.apps ?? [], size: 14, max: 6) }
                    }
                    Spacer()
                    Text(fmtTime(e.remaining)).font(Theme.number(20)).monospacedDigit()
                }
                HStack(spacing: 8) {
                    if e.locked && !e.isBreak {
                        HoldButton(label: "Hold to end early", seconds: 2, tint: Theme.danger) { closePopover(); e.stopBlock(completed: false) }
                    } else {
                        Button(e.isBreak ? "End break" : "End early") { closePopover(); e.stopBlock(completed: false) }.buttonStyle(SecondaryButtonStyle())
                    }
                    Button("+5 min") { closePopover(); e.addFive() }.buttonStyle(SecondaryButtonStyle())
                    Spacer()
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.todos.isEmpty ? "Nothing planned yet" : "Not locked in").font(.system(size: 13.5, weight: .semibold))
                        Text(e.todos.isEmpty ? "Plan your day in one line" : "\(e.todos.filter { !$0.isDone }.count) sessions left today")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                StreakStrip()
            }
        }
    }

    private func upNext(_ n: Todo) -> some View {
        Button { closePopover(); e.startTodo(n) } label: {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill").foregroundStyle(.black.opacity(0.85)).font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24).background(Circle().fill(Theme.accent))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Up next" + (clockLabel(n.start).isEmpty ? "" : " · \(clockLabel(n.start))")).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(n.task).font(.system(size: 13, weight: .medium)).lineLimit(1)
                }
                Spacer()
                AppIconRow(apps: n.apps ?? [], size: 14, max: 3)
                Text("\(n.left)m").font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RowStyle()).padding(.horizontal, 6).padding(.vertical, 6)
    }

    /// No task, just a length: your lock-in apps only.
    private var quick: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Lock in now").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                ForEach([25, 45, 60, 90], id: \.self) { m in
                    Button("\(m)") { closePopover(); e.startQuick(minutes: m) }
                        .buttonStyle(ChipStyle(primary: m == 25)).disabled((e.cfg.lockin_apps ?? []).isEmpty)
                }
            }
            HStack(spacing: 6) {
                AppIconRow(apps: e.cfg.lockin_apps ?? [], size: 14, max: 5)
                Text((e.cfg.lockin_apps ?? []).isEmpty ? "Pick your lock-in apps in Setup" : "Everything else gets covered")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func quit() {
        if e.block?.kind == "focus" && e.locked {
            let a = NSAlert()
            a.messageText = "Quit lockin mid-session?"
            a.informativeText = "The session picks back up when lockin opens again, and the quit shows in your recap."
            a.addButton(withTitle: "Keep going"); a.addButton(withTitle: "Quit")
            guard a.runModal() == .alertSecondButtonReturn else { return }
        }
        NSApp.terminate(nil)
    }

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
            .foregroundStyle(primary ? Color.black.opacity(0.85) : Color.primary)
            .background(Capsule().fill(primary ? Theme.accent : Color.primary.opacity(configuration.isPressed ? 0.15 : 0.08)))
    }
}

/// Today, the streak and this week in one line; click it for the stats drop-down.
struct StreakStrip: View {
    @EnvironmentObject var e: Engine
    @State private var st = Stats()
    var body: some View {
        Button { closePopover(); e.showStats() } label: {
            HStack(spacing: 14) {
                Label("\(st.todayMinutes)/\(st.goal) min", systemImage: "target")
                    .foregroundStyle(st.todayMinutes >= st.goal ? Theme.accent : .primary)
                Label("\(st.streak)", systemImage: "flame.fill").foregroundStyle(st.streak > 0 ? Theme.flame : .secondary)
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

/// The menu-bar icon: the app icon's ring. Free, it's the plain mark (a template, so it follows the menu bar). In a
/// session the ring fills with your progress in the island's colors: your skin while locked in, red when you drift
/// (with a !), orange on a break (with pause bars). Drawn in one color so it reads on light and dark menu bars.
enum MenuIcon {
    enum Mode: Hashable { case free, locked, drifting, onBreak }
    private static var cache: [String: NSImage] = [:]

    @MainActor static func image(for e: Engine) -> NSImage {
        let mode: Mode = e.block == nil ? .free : e.drifting ? .drifting : e.isBreak ? .onBreak : .locked
        let tint = mode == .drifting ? "red" : mode == .onBreak ? "orange" : "green"
        return image(mode, progress: e.progress, color: NSColor(tintColor(tint)), key: Skin.current.id)
    }

    static func image(_ mode: Mode, progress: Double, color: NSColor, key: String = "") -> NSImage {
        let steps = 48, step = mode == .free ? 0 : Int((min(1, max(0, progress)) * Double(steps)).rounded())
        let id = "\(mode)-\(step)-\(key)"
        if let img = cache[id] { return img }
        let side: CGFloat = 17
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            NSGraphicsContext.current?.cgContext.scaleBy(x: side / 16, y: side / 16)   // drawn on a 16×16 grid
            let ink = mode == .free ? NSColor.black : color
            let c = NSPoint(x: 8, y: 8), r: CGFloat = 6.1, w: CGFloat = 1.55
            func arc(_ fraction: Double, _ color: NSColor) {
                guard fraction > 0.001 else { return }
                let p = NSBezierPath()
                p.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 90 - 360 * CGFloat(min(fraction, 0.9999)), clockwise: true)
                p.lineWidth = w; p.lineCapStyle = .round
                color.setStroke(); p.stroke()
            }
            func pill(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
                ink.setFill(); NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: width / 2, yRadius: width / 2).fill()
            }
            if mode == .free {
                arc(0.83, ink)                     // the app icon: an open ring and a dot
            } else {
                arc(1, ink.withAlphaComponent(0.3))   // track
                arc(Double(step) / Double(steps), ink)
            }
            switch mode {
            case .free, .locked: ink.setFill(); NSBezierPath(ovalIn: NSRect(x: 8 - 1.45, y: 8 - 1.45, width: 2.9, height: 2.9)).fill()
            case .drifting: pill(7.25, 7.0, 1.5, 4.4); ink.setFill(); NSBezierPath(ovalIn: NSRect(x: 7.15, y: 4.15, width: 1.7, height: 1.7)).fill()
            case .onBreak: pill(5.9, 5.6, 1.45, 4.8); pill(8.65, 5.6, 1.45, 4.8)
            }
            return true
        }
        img.isTemplate = mode == .free
        img.accessibilityDescription = "lockin"
        cache[id] = img
        return img
    }
}
