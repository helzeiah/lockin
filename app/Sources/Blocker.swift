import AppKit
import Combine
import SwiftUI

/// The cover's window: borderless and non-activating, but it takes the keyboard while it's up, so typing and
/// shortcuts can't reach the page or app underneath (the app you were in stays the front app).
final class BlockerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) {}
}

// Covers a distracting tab or app with real macOS blur. The tab stays open underneath; the app keeps running
// (in Locked mode a covered app is hidden a moment later).
@MainActor
final class BlockerController {
    static let shared = BlockerController()
    private var panel: BlockerPanel!
    private var subs = Set<AnyCancellable>()

    func start() {
        panel = BlockerPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: BlockerView().environmentObject(Engine.shared))
        host.sizingOptions = []
        panel.contentView = host
        Engine.shared.$blocked
            .map { b -> NSRect? in b.map { $0.frame ?? (NSScreen.main?.visibleFrame ?? .zero) } }
            .removeDuplicates()
            .sink { [weak self] frame in
                guard let self else { return }
                if let f = frame {
                    self.panel.setFrame(f, display: true)
                    if !self.panel.isVisible {
                        self.panel.alphaValue = 0; self.panel.orderFrontRegardless(); self.panel.makeKey()
                        NSAnimationContext.runAnimationGroup { $0.duration = 0.16; self.panel.animator().alphaValue = 1 }
                    }
                } else if self.panel.isVisible {
                    NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; self.panel.animator().alphaValue = 0 },
                                                         completionHandler: { Task { @MainActor in if Engine.shared.blocked == nil { self.panel.orderOut(nil) } } })
                }
            }
            .store(in: &subs)
    }
}

/// The cover: real blur over the window, the card on top.
struct BlockerView: View {
    var body: some View {
        ZStack {
            VisualEffect(material: .fullScreenUI)
            Color.black.opacity(0.22)
            BlockerCard()
        }
    }
}

/// "YouTube" for youtube.com (from the distraction tiles), else the domain's first part, capitalized.
func siteDisplayName(_ site: String) -> String {
    let base = site.lowercased().replacingOccurrences(of: "www.", with: "").components(separatedBy: ".").first ?? site
    for pick in DistractionPick.catalog where pick.sites.contains(where: { $0.lowercased() == site.lowercased() }) {
        if let part = pick.name.components(separatedBy: " / ").first(where: { $0.lowercased() == base }) { return part }
    }
    return base.prefix(1).uppercased() + base.dropFirst()
}

struct BlockerCard: View {
    @EnvironmentObject var e: Engine

    private var kind: Blocked.Kind { e.blocked?.kind ?? .site }
    private var isSite: Bool { !(e.blocked?.site ?? "").isEmpty }
    private var thing: String { isSite ? siteDisplayName(e.blocked?.site ?? "") : (e.blocked?.app ?? "This app") }
    private var title: String {
        switch kind {
        case .strict: return "Not part of this session"
        case .earn: return "Earn it first"
        default: return "\(thing) can wait"
        }
    }
    private var detail: String {
        let doing = e.block?.task ?? "this session"
        switch kind {
        case .earn:
            let need = max(1, e.goal - e.todayMinutes)
            return "\(need) more focused minute\(need == 1 ? "" : "s") today and \(thing) is yours."
        case .strict:
            let apps = (e.block?.apps ?? []).prefix(3).joined(separator: ", ")
            return apps.isEmpty ? "You're locked in on \(doing)." : "This session is for \(apps). Head back and keep going."
        default:
            return "You're locked in on \(doing)."
        }
    }
    private var isBrowser: Bool { Detect.browsers[e.blocked?.app ?? ""] != nil }
    private var footnote: String {
        let tab = isBrowser && isSite ? "The tab stays open. " : ""
        if e.locked {
            return kind == .site || isSite ? tab + "Locked mode: no passes." : "Locked mode: it gets hidden in a moment."
        }
        let left = e.passesLeft
        let scope = kind == .earn ? "today" : "this session"
        return left == 0 ? tab + "No passes left \(scope)." : tab + "A pass counts in your stats · \(left) left \(scope)."
    }

    var body: some View {
            VStack(spacing: 0) {
                ring.padding(.bottom, 18)
                Text(title).font(.system(size: 21, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.top, 6).padding(.bottom, 22)
                primary
                HStack(spacing: 8) {
                    if isBrowser && isSite {
                        Button { e.closeBlockedTab() } label: { Text("Close tab").frame(maxWidth: .infinity) }
                    } else {
                        Button { e.hideBlockedApp() } label: { Text("Hide app").frame(maxWidth: .infinity) }
                    }
                    if e.passesLeft > 0 {
                        let wait = e.snoozeWaitLeft
                        Button { e.takePass() } label: {
                            Text(wait > 0 ? "Give me 5 min (\(wait))" : "Give me 5 min").monospacedDigit().frame(maxWidth: .infinity)
                        }
                        .disabled(wait > 0)
                    }
                }
                .buttonStyle(SecondaryButtonStyle(large: true)).padding(.top, 8)
                if e.canAddBlockedApp, let app = e.blocked?.app {
                    let wait = e.snoozeWaitLeft
                    Button { e.addBlockedAppToSession() } label: {
                        Text(wait > 0 ? "Need it for work? Add \(app) to this session (\(wait))" : "Need it for work? Add \(app) to this session")
                            .font(.system(size: 12)).monospacedDigit()
                    }
                    .buttonStyle(.plain).foregroundStyle(wait > 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.accent))
                    .disabled(wait > 0).padding(.top, 12)
                }
                Text(footnote).font(.system(size: 11.5)).foregroundStyle(.tertiary).multilineTextAlignment(.center).padding(.top, 14)
            }
            .padding(30)
            .frame(width: 390)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
            .tint(Theme.accent)
    }

    @ViewBuilder private var ring: some View {
        if kind == .earn {
            GoalRing(minutes: e.todayMinutes, goal: e.goal, size: 66)
        } else {
            ZStack {
                Ring(progress: e.progress, color: Theme.accent, size: 66, width: 4)
                Text(fmtTime(e.remaining)).font(Theme.number(13)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var primary: some View {
        if kind == .earn {
            VStack(spacing: 7) {
                Button {
                    e.blocked = nil
                    if let t = e.nextTodo { e.startTodo(t) } else { e.startQuick(minutes: max(25, e.goal - e.todayMinutes)) }
                } label: {
                    Label("Lock in now", systemImage: "lock.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(large: true)).keyboardShortcut(.defaultAction)
                Text(e.nextTodo.map { "Starts \($0.task) · \($0.left) min" } ?? "Starts a \(max(25, e.goal - e.todayMinutes))-minute session with your lock-in apps")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        } else {
            Button { e.backToWork() } label: { Text("Back to work").frame(maxWidth: .infinity) }
                .buttonStyle(PrimaryButtonStyle(large: true)).keyboardShortcut(.defaultAction)
        }
    }
}
