import AppKit
import Combine
import SwiftUI

// Covers a distracting tab or app with real macOS blur. The tab stays open underneath; the app keeps running.
@MainActor
final class BlockerController {
    static let shared = BlockerController()
    private var panel: NSPanel!
    private var subs = Set<AnyCancellable>()

    func start() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
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
                    if !self.panel.isVisible { self.panel.alphaValue = 0; self.panel.orderFrontRegardless()
                        NSAnimationContext.runAnimationGroup { $0.duration = 0.16; self.panel.animator().alphaValue = 1 } }
                } else if self.panel.isVisible {
                    NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; self.panel.animator().alphaValue = 0 },
                                                         completionHandler: { Task { @MainActor in if Engine.shared.blocked == nil { self.panel.orderOut(nil) } } })
                }
            }
            .store(in: &subs)
    }
}

struct BlockerView: View {
    @EnvironmentObject var e: Engine
    private var siteName: String {
        let s = e.blocked?.site ?? ""
        let base = s.replacingOccurrences(of: ".com", with: "").replacingOccurrences(of: ".tv", with: "")
        return base.prefix(1).uppercased() + base.dropFirst()
    }

    private var title: String {
        switch e.blocked?.kind {
        case .strict: return "Not part of this block"
        case .app: return "\(e.blocked?.app ?? "This app") can wait"
        default: return "\(siteName) can wait"
        }
    }
    private var detail: String {
        let doing = e.block?.task ?? e.block?.name ?? "a focus block"
        guard e.blocked?.strict == true else { return "You're in the middle of \(doing)." }
        let allowed = (e.preset?.apps ?? []).prefix(3).joined(separator: ", ")
        return allowed.isEmpty ? "You're in the middle of \(doing)." : "This block is for \(allowed). Head back and keep going."
    }
    private var isBrowser: Bool { Detect.browsers[e.blocked?.app ?? ""] != nil }
    private var canSnooze: Bool { e.snoozesLeft > 0 }
    private var footnote: String {
        let tab = isBrowser && e.blocked?.kind != .app ? "The tab stays open. " : ""
        switch e.blockingMode {
        case "nudge": return tab + "Taking 5 counts as a drift."
        case "hard": return tab + "Blocking is set to Hard, so there are no 5-minute passes."
        default:
            let left = e.snoozesLeft
            return left == 0 ? tab + "No more 5-minute passes this block."
                             : tab + "Taking 5 counts as a drift · \(left) left this block."
        }
    }

    var body: some View {
        ZStack {
            VisualEffect(material: .fullScreenUI)
            Color.black.opacity(0.18)
            VStack(spacing: 0) {
                ZStack {
                    Ring(progress: e.progress, color: tintColor("green"), size: 66, width: 4)
                    Text(fmtTime(e.remaining)).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 18)
                Text(title).font(.system(size: 20, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.top, 6).padding(.bottom, 22)
                Button { e.backToWork() } label: {
                    Text("Back to work").font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                HStack(spacing: 8) {
                    if isBrowser && e.blocked?.kind != .app {
                        Button { e.closeBlockedTab() } label: { Text("Close tab").frame(maxWidth: .infinity).padding(.vertical, 6) }
                    } else {
                        Button { e.hideBlockedApp() } label: { Text("Hide app").frame(maxWidth: .infinity).padding(.vertical, 6) }
                    }
                    if canSnooze {
                        // Friction: the pass only unlocks after a short countdown, shown on the button.
                        let wait = e.snoozeWaitLeft
                        Button { e.snoozeSite() } label: {
                            Text(wait > 0 ? "Give me 5 min (\(wait))" : "Give me 5 min").monospacedDigit()
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .disabled(wait > 0)
                    }
                }
                .buttonStyle(.bordered).controlSize(.large).padding(.top, 8)
                Text(footnote).font(.system(size: 11.5)).foregroundStyle(.tertiary).multilineTextAlignment(.center).padding(.top, 14)
            }
            .padding(30)
            .frame(width: 380)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
        }
    }
}
