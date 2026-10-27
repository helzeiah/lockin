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
    let size = NSSize(width: 560, height: 420)

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
        Publishers.CombineLatest(e.$block.map { $0 != nil }, e.$card.map { $0 != nil })
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] active, card in self?.setVisible(active || card) }
            .store(in: &subs)
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
        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { if Engine.shared.block == nil && Engine.shared.card == nil { self.panel.orderOut(nil) } } }
    }
}

struct IslandShape: Shape {
    var radius: CGFloat
    var animatableData: CGFloat { get { radius } set { radius = newValue } }
    func path(in r: CGRect) -> Path {  // flat top (it hangs from the screen edge), rounded bottom
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.maxX - radius, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - radius), control: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

struct IslandView: View {
    @EnvironmentObject var e: Engine
    @EnvironmentObject var g: IslandGeo
    @State private var hover = false

    private var geo: TopGeo { g.geo }
    private var ringColor: Color { e.isBreak ? tintColor("orange") : e.drifting ? tintColor("red") : tintColor("green") }
    private let spring = Animation.spring(response: 0.34, dampingFraction: 0.84)

    var body: some View {
        VStack(spacing: 0) {
            if let c = e.card { pill(expanded(c), radius: 24) }
            else if e.block != nil {
                if geo.notch && g.timeOnLeft { compactLeft } else { pill(compact, radius: geo.notch ? 10 : 12) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .animation(spring, value: e.card?.id)
        .animation(spring, value: hover)
        .animation(spring, value: e.block?.started)
    }

    static let wingMax: CGFloat = 64

    private func pill<V: View>(_ v: V, radius: CGFloat) -> some View {
        v.background(IslandShape(radius: radius).fill(Color.black))
            .clipShape(IslandShape(radius: radius))
            .contentShape(Rectangle())
    }

    private var timeText: some View {
        Text(fmtTime(e.remaining)).font(.system(size: 12.5, weight: .semibold, design: .rounded)).monospacedDigit()
            .foregroundStyle(e.drifting ? tintColor("red") : .white)
    }

    // Crowded menu bar: ring and time both on the left wing, nothing drawn to the right of the notch,
    // so the menu-bar icons there stay visible and clickable. The clear spacer keeps the notch gap centered.
    private var compactLeft: some View {
        HStack(spacing: 0) {
            pill(HStack(spacing: 0) {
                HStack(spacing: 7) { Ring(progress: e.progress, color: ringColor, size: 14); timeText; Spacer(minLength: 0) }
                    .padding(.leading, 13).frame(width: 2 * IslandView.wingMax + 12)
                Color.clear.frame(width: geo.notchWidth)
            }
            .frame(height: geo.barHeight)
            .onHover { hover = $0 }
            .onTapGesture { e.tapIsland() }, radius: 10)
            Color.clear.frame(width: 2 * IslandView.wingMax + 12, height: geo.barHeight).allowsHitTesting(false)
        }
    }

    // Minimal: ring on the left wing, time on the right wing, the notch untouched in between.
    @ViewBuilder private var compact: some View {
        let wing: CGFloat = hover ? IslandView.wingMax : 50
        Group {
            if geo.notch {
                HStack(spacing: 0) {
                    HStack { Ring(progress: e.progress, color: ringColor, size: 14); Spacer(minLength: 0) }
                        .padding(.leading, 13).frame(width: wing)
                    Color.clear.frame(width: geo.notchWidth)
                    Text(fmtTime(e.remaining)).font(.system(size: 12.5, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(e.drifting ? tintColor("red") : .white)
                        .frame(width: wing, alignment: .trailing).padding(.trailing, 12)
                }
            } else {
                HStack(spacing: 8) {
                    Ring(progress: e.progress, color: ringColor, size: 14)
                    if hover, let b = e.block {
                        Text(e.isBreak ? "Break" : (b.task ?? b.name)).font(.system(size: 12, weight: .medium))
                            .lineLimit(1).foregroundStyle(.white.opacity(0.85)).frame(maxWidth: 220)
                            .transition(.opacity)
                    }
                    Text(fmtTime(e.remaining)).font(.system(size: 12.5, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(e.drifting ? tintColor("red") : .white)
                }
                .padding(.horizontal, 13)
            }
        }
        .frame(height: geo.barHeight)
        .onHover { hover = $0 }
        .onTapGesture { e.tapIsland() }
    }

    private func expanded(_ c: Card) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Color.clear.frame(height: max(0, geo.barHeight - 6))   // the notch / menu-bar band
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: c.icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(tintColor(c.tint))
                    .frame(width: 22).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    if !c.subtitle.isEmpty {
                        Text(c.subtitle).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(3)
                    }
                }
                Spacer(minLength: 8)
                if e.block != nil && (c.icon == "scope" || c.icon == "eye.fill") {
                    Ring(progress: e.progress, color: ringColor, size: 26, width: 3)
                }
                Button { e.perform(.dismiss) } label: {   // every card can be closed
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.55))
                        .frame(width: 22, height: 22).background(Circle().fill(.white.opacity(0.1)))
                }
                .buttonStyle(.plain).help("Close")
            }
            if !c.lines.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(c.lines.enumerated()), id: \.offset) { i, l in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            if l.bullet {
                                Circle().fill(l.deadline ? tintColor("orange") : (l.trailing == "classes" ? Color.purple : tintColor("blue")))
                                    .frame(width: 6, height: 6).offset(y: -1)
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
                .padding(.leading, 33)
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
        .padding(.horizontal, 18).padding(.bottom, 16)
        .frame(width: max(400, geo.notchWidth + 140))
        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top)),
                                removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))))
    }
}
