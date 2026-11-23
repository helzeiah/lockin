import AppKit
import Combine
import SwiftUI

// Geometry of the top of the screen: exact notch size from macOS when there is one.
struct TopGeo {
    var screen: NSScreen
    var notch: Bool
    var notchWidth: CGFloat
    var barHeight: CGFloat

    // the screen the island lives on: where the mouse is (that's the menu bar you're looking at)
    static func activeScreen() -> NSScreen {
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
    static func current() -> TopGeo { of(activeScreen()) }
    static func of(_ s: NSScreen) -> TopGeo {
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            return TopGeo(screen: s, notch: true, notchWidth: s.frame.width - l.width - r.width, barHeight: s.safeAreaInsets.top)
        }
        return TopGeo(screen: s, notch: false, notchWidth: 0, barHeight: max(24, s.frame.maxY - s.visibleFrame.maxY))
    }
}

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class IslandGeo: ObservableObject {
    static let shared = IslandGeo()
    @Published var geo = TopGeo.current()
    /// The menu-bar icon sits right of the notch where the time would go (a crowded bar), so draw the time on the left.
    @Published var timeOnLeft = false
}

@MainActor
final class IslandController {
    static let shared = IslandController()
    private var panel: IslandPanel!
    private var subs = Set<AnyCancellable>()
    let size = NSSize(width: 600, height: 460)

    func start() {
        panel = IslandPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        let host = NSHostingView(rootView: IslandView().environmentObject(Engine.shared).environmentObject(IslandGeo.shared))
        host.sizingOptions = []   // don't let SwiftUI shrink the window to its content; we keep it centered
        panel.contentView = host
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in   // follow you to the other screen
            Task { @MainActor in
                if TopGeo.activeScreen() != IslandGeo.shared.geo.screen { IslandController.shared.position() }
                else { IslandController.shared.avoidStatusItem() }
            }
        }
        position()
        let e = Engine.shared
        Publishers.CombineLatest3(e.$block.map { $0 != nil }, e.$card.map { $0 != nil }, e.$statsShown)
            .map { $0 || $1 || $2 }
            .removeDuplicates()
            .sink { [weak self] v in self?.setVisible(v) }
            .store(in: &subs)
        // the stats drop-down closes when you click anywhere else
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor in if Engine.shared.statsShown { Engine.shared.statsShown = false } }
        }
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.position() }.store(in: &subs)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in self?.position() }.store(in: &subs)
    }

    func position() {
        let g = TopGeo.current()
        IslandGeo.shared.geo = g
        panel.setFrame(NSRect(x: g.screen.frame.midX - size.width / 2, y: g.screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
        avoidStatusItem()
    }

    /// Keep the right wing off our own menu-bar icon (the icon nearest the notch on a full menu bar).
    func avoidStatusItem() {
        let g = IslandGeo.shared.geo
        guard g.notch, let icon = statusItemFrame() else { IslandGeo.shared.timeOnLeft = false; return }
        let rightWing = NSRect(x: g.screen.frame.midX + g.notchWidth / 2, y: g.screen.frame.maxY - g.barHeight,
                               width: IslandView.wingMax + 16, height: g.barHeight)
        let left = icon.intersects(rightWing)
        if IslandGeo.shared.timeOnLeft != left { IslandGeo.shared.timeOnLeft = left }
    }

    private func setVisible(_ v: Bool) {
        if v { position(); panel.orderFrontRegardless() }
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let e = Engine.shared
                if e.block == nil && e.card == nil && !e.statsShown { self.panel.orderOut(nil) }
            }
        }
    }
}

/// Hangs from the top edge like part of the bezel: the top corners flare outward into the screen edge ("ears"),
/// the bottom corners are rounded. Content sits between the ears.
struct NotchShape: Shape {
    var radius: CGFloat
    var ear: CGFloat = 7
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(radius, ear) }
        set { radius = newValue.first; ear = newValue.second }
    }
    func path(in r: CGRect) -> Path {
        let e = min(ear, r.width / 4), rad = min(radius, (r.height - e) / 2, (r.width - 2 * e) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - e, y: r.minY + e), control: CGPoint(x: r.maxX - e, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - e, y: r.maxY - rad))
        p.addQuadCurve(to: CGPoint(x: r.maxX - e - rad, y: r.maxY), control: CGPoint(x: r.maxX - e, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + e + rad, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX + e, y: r.maxY - rad), control: CGPoint(x: r.minX + e, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + e, y: r.minY + e))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY), control: CGPoint(x: r.minX + e, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct IslandView: View {
    @EnvironmentObject var e: Engine
    @EnvironmentObject var g: IslandGeo
    @State private var hover = false

    static let wingMax: CGFloat = 66
    static let ear: CGFloat = 7
    private var geo: TopGeo { g.geo }
    private var ringColor: Color { e.isBreak ? tintColor("orange") : e.drifting ? tintColor("red") : tintColor("green") }
    private let spring = Animation.spring(response: 0.38, dampingFraction: 0.82)

    var body: some View {
        VStack(spacing: 0) {
            if e.statsShown { shell(StatsDropdown().padding(.horizontal, 20).padding(.bottom, 18).frame(width: 420), radius: 26, band: true) }
            else if let c = e.card { shell(expanded(c), radius: 26, band: true) }
            else if e.block != nil {
                if geo.notch && g.timeOnLeft { compactLeft } else { compact }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .animation(spring, value: e.card?.id)
        .animation(spring, value: e.statsShown)
        .animation(spring, value: hover)
        .animation(spring, value: e.flash)
        .animation(spring, value: e.block?.started)
    }

    /// Black, with a hairline on the lower edge so it reads as an object on dark wallpapers too.
    /// `band` reserves the menu-bar height at the top (the notch sits there).
    private func shell<V: View>(_ v: V, radius: CGFloat, band: Bool = false) -> some View {
        v.padding(.top, band ? max(0, geo.barHeight - 4) : 0)
        .padding(.horizontal, IslandView.ear)
        .background(NotchShape(radius: radius, ear: IslandView.ear).fill(Color.black))
        .overlay(NotchShape(radius: radius, ear: IslandView.ear).stroke(Color.white.opacity(0.08), lineWidth: 1).mask(
            LinearGradient(colors: [.clear, .clear, .white], startPoint: .top, endPoint: .bottom)))
        .clipShape(NotchShape(radius: radius, ear: IslandView.ear))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .contentShape(NotchShape(radius: radius, ear: IslandView.ear))
        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.9, anchor: .top)),
                                removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))))
    }

    private var timeText: some View {
        Text(fmtTime(e.remaining)).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
            .foregroundStyle(e.drifting ? tintColor("red") : .white)
            .contentTransition(.numericText(countsDown: true))
    }

    private var ring: some View {
        Ring(progress: e.progress, color: ringColor, size: 15, width: 2.6)
            .overlay { if e.drifting { PulseDot(color: tintColor("red")) } }
    }

    /// What drops out under the wings: a check-in message, or (on hover) the task and quick controls.
    @ViewBuilder private var dropRow: some View {
        if let f = e.flash {
            HStack(spacing: 8) {
                Image(systemName: f.icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(tintColor(f.tint))
                Text(f.text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 11)
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else if hover, let b = e.block {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(e.isBreak ? tintColor("orange") : colorFor(block: b.name)).frame(width: 7, height: 7)
                    Text(e.isBreak ? "Break" : (b.task ?? b.name)).font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92)).lineLimit(1)
                    Spacer(minLength: 6)
                    iconButton("plus", help: "Add 5 minutes") { e.addFive() }
                    iconButton("stop.fill", help: e.locked && !e.isBreak ? "End early" : "Stop") {
                        if e.locked && !e.isBreak { e.perform(.confirmStop) } else { e.stopBlock(completed: false) }
                    }
                }
                GeometryReader { gr in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.12))
                        Capsule().fill(ringColor).frame(width: max(4, gr.size.width * e.progress))
                    }
                }
                .frame(height: 3)
            }
            .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 12)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func iconButton(_ name: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white.opacity(0.75))
                .frame(width: 22, height: 22).background(Circle().fill(.white.opacity(0.1)))
        }
        .buttonStyle(.plain).help(help)
    }

    private var open: Bool { hover || e.flash != nil }

    // Notched Mac: ring on the left wing, time on the right wing, the notch untouched in between.
    // Hover (or a check-in) drops a row out under all three.
    @ViewBuilder private var compact: some View {
        if geo.notch {
            let wing: CGFloat = open ? IslandView.wingMax + 10 : 52
            shell(VStack(spacing: 0) {
                HStack(spacing: 0) {
                    HStack { ring; Spacer(minLength: 0) }.padding(.leading, 12).frame(width: wing)
                    Color.clear.frame(width: geo.notchWidth)
                    HStack { Spacer(minLength: 0); timeText }.padding(.trailing, 12).frame(width: wing)
                }
                .frame(height: geo.barHeight)
                dropRow
            }
            .frame(width: 2 * wing + geo.notchWidth), radius: open ? 18 : 11)
            .onHover { hover = $0 }
            .onTapGesture { e.tapIsland() }
        } else {
            shell(VStack(spacing: 0) {
                HStack(spacing: 8) {
                    ring
                    if open, let b = e.block, e.flash == nil {
                        Text(e.isBreak ? "Break" : (b.task ?? b.name)).font(.system(size: 12, weight: .medium))
                            .lineLimit(1).foregroundStyle(.white.opacity(0.85)).frame(maxWidth: 220)
                            .transition(.opacity)
                    }
                    timeText
                }
                .padding(.horizontal, 13).frame(height: geo.barHeight)
                if e.flash != nil { dropRow }
            }, radius: 13)
            .onHover { hover = $0 }
            .onTapGesture { e.tapIsland() }
        }
    }

    // Crowded menu bar: ring and time both on the left wing, nothing drawn to the right of the notch, so the
    // menu-bar icons there stay visible and clickable. The clear spacer keeps the notch gap centered.
    private var compactLeft: some View {
        let wing = 2 * IslandView.wingMax + 12
        return HStack(alignment: .top, spacing: 0) {
            shell(VStack(spacing: 0) {
                HStack(spacing: 0) {
                    HStack(spacing: 8) { ring; timeText; Spacer(minLength: 0) }.padding(.leading, 13).frame(width: wing)
                    Color.clear.frame(width: geo.notchWidth)
                }
                .frame(height: geo.barHeight)
                dropRow
            }
            .frame(width: wing + geo.notchWidth), radius: open ? 18 : 11)
            .onHover { hover = $0 }
            .onTapGesture { e.tapIsland() }
            Color.clear.frame(width: wing, height: geo.barHeight).allowsHitTesting(false)
        }
    }

    private func expanded(_ c: Card) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: c.icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(tintColor(c.tint))
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tintColor(c.tint).opacity(c.tint == "white" ? 0.1 : 0.16)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    if !c.subtitle.isEmpty {
                        Text(c.subtitle).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(3)
                    }
                    if let at = c.countdown {
                        let secs = max(0, Int(at.timeIntervalSince(e.now).rounded(.up)))
                        Text("Starts in \(secs)s").font(.system(size: 11.5, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(Theme.accent).contentTransition(.numericText(countsDown: true))
                    }
                }
                Spacer(minLength: 8)
                if e.block != nil && ["lock.fill", "eye.fill", "moon.zzz.fill"].contains(c.icon) {
                    ZStack {
                        Ring(progress: e.progress, color: ringColor, size: 30, width: 3)
                        Text("\(Int(e.progress * 100))").font(.system(size: 9, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                Button { e.perform(.dismiss) } label: {   // every card can be closed
                    Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                        .frame(width: 22, height: 22).background(Circle().fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain).help("Close")
            }
            if !c.lines.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(c.lines.enumerated()), id: \.offset) { i, l in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            if l.bullet {
                                Circle().fill(l.deadline ? tintColor("orange") : (l.calendar || l.trailing == "classes" ? Color.purple : tintColor("blue")))
                                    .frame(width: 6, height: 6).offset(y: -1)
                            }
                            if c.lines.contains(where: { !$0.time.isEmpty }) && l.bullet {   // time column, kept aligned
                                Text(l.time).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                                    .foregroundStyle(.white.opacity(0.75)).frame(width: 58, alignment: .leading)
                            }
                            Text(l.text).font(.system(size: 13)).foregroundStyle(.white.opacity(l.bullet ? 0.92 : 0.6))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 6)
                            if !l.trailing.isEmpty && l.trailing != "classes" {
                                Text(l.trailing).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.5))
                            }
                        }
                        .padding(.vertical, 6)
                        .overlay(alignment: .top) { if i > 0 && l.bullet { Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5) } }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05)))
            }
            if !c.buttons.isEmpty {
                HStack(spacing: 8) {
                    Spacer()
                    ForEach(c.buttons, id: \.self) { b in
                        Button(b.label) { e.perform(b.action) }.buttonStyle(PillButtonStyle(primary: b.primary))
                    }
                }
            }
        }
        .padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 16)
        .frame(width: max(420, geo.notchWidth + 160))
    }
}

/// The stats drop-down; reads the log each time it opens.
struct StatsDropdown: View {
    @EnvironmentObject var e: Engine
    @State private var stats = Stats()
    var body: some View {
        NotchStats(stats: stats)
            .padding(.top, 6)
            .onAppear { stats = Stats.load(goal: e.cfg.stats_goal ?? 25, weekGoal: e.cfg.stats_week_goal ?? 5, live: e.block) }
    }
}

/// A soft red pulse around the ring while you're drifting.
struct PulseDot: View {
    var color: Color
    @State private var on = false
    var body: some View {
        Circle().stroke(color, lineWidth: 1.5)
            .scaleEffect(on ? 1.9 : 1).opacity(on ? 0 : 0.8)
            .onAppear { withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { on = true } }
    }
}
