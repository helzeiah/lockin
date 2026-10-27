import AppKit
import Combine
import SwiftUI

// Covers a distracting tab with real macOS blur. The tab stays open underneath.
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

    private var title: String { e.blocked?.strict == true ? "Not part of this block" : "\(siteName) can wait" }
    private var detail: String {
        let doing = e.block?.task ?? e.block?.name ?? "a focus block"
        guard e.blocked?.strict == true else { return "You're in the middle of \(doing)." }
        let allowed = (e.preset?.apps ?? []).prefix(3).joined(separator: ", ")
        return allowed.isEmpty ? "You're in the middle of \(doing)." : "This block is for \(allowed). Head back and keep going."
    }
    private var isBrowser: Bool { Detect.browsers[e.blocked?.app ?? ""] != nil }

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
                    if isBrowser { Button { e.closeBlockedTab() } label: { Text("Close tab").frame(maxWidth: .infinity).padding(.vertical, 6) } }
                    Button { e.snoozeSite() } label: { Text("Give me 5 min").frame(maxWidth: .infinity).padding(.vertical, 6) }
                }
                .buttonStyle(.bordered).controlSize(.large).padding(.top, 8)
                Text(isBrowser ? "The tab stays open. Taking 5 counts as a drift." : "Taking 5 counts as a drift.").font(.system(size: 11.5)).foregroundStyle(.tertiary).padding(.top, 14)
            }
            .padding(30)
            .frame(width: 380)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
        }
    }
}
