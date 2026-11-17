import AppKit
import SwiftUI

/// Every section of the main window. "Focus" is what you use every day; "Setup" is how lockin behaves.
enum PlannerTab: String, CaseIterable, Identifiable {
    case plan, stats, blocks, distractions, ai, general
    var id: String { rawValue }
    var title: String {
        switch self {
        case .plan: return "Today"
        case .stats: return "Stats"
        case .blocks: return "Focus blocks"
        case .distractions: return "Distractions"
        case .ai: return "AI planner"
        case .general: return "General"
        }
    }
    var icon: String {
        switch self {
        case .plan: return "sun.max"
        case .stats: return "chart.bar"
        case .blocks: return "square.stack.3d.up"
        case .distractions: return "hand.raised"
        case .ai: return "sparkles"
        case .general: return "gearshape"
        }
    }
    /// One line under the title of a setup page: what it's for.
    var blurb: String {
        switch self {
        case .blocks: return "The kinds of work you do, and what counts as on task for each."
        case .distractions: return "What gets covered or nudged while a block runs."
        case .ai: return "Optional. Turns a messy brain dump into a timed plan."
        case .general: return "Check-ins, your streak goal, and the daily rhythm."
        default: return ""
        }
    }
    static let focus: [PlannerTab] = [.plan, .stats]
    static let setup: [PlannerTab] = [.blocks, .distractions, .ai, .general]
}

/// The one lockin window: a sidebar with Today and Stats on top, setup below.
struct MainView: View {
    @EnvironmentObject var e: Engine
    @StateObject private var settings = SettingsModel()

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar.navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 210)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 680, minHeight: 500)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(PlannerTab.focus) { t in row(t) }
            Text("SETUP").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
                .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 4)
            ForEach(PlannerTab.setup) { t in row(t) }
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Label("Quit lockin", systemImage: "power").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.top, 34).padding(.bottom, 10)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ t: PlannerTab) -> some View {
        let on = e.plannerTab == t
        return Button { e.plannerTab = t } label: {
            Label(t.title, systemImage: t.icon)
                .font(.system(size: 13, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? Color.primary.opacity(0.1) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var detail: some View {
        switch e.plannerTab {
        case .plan, .stats:
            PlannerView()
        default:
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(e.plannerTab.title).font(.system(size: 26, weight: .bold)).tracking(-0.4)
                    Text(e.plannerTab.blurb).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 6)
                switch e.plannerTab {
                case .blocks: BlocksTab(m: settings)
                case .distractions: DistractionsTab(m: settings)
                case .ai: AITab(m: settings)
                default: GeneralTab(m: settings)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(VisualEffect(material: .underWindowBackground))
            .onDisappear { settings.save(includeKey: false) }
        }
    }
}
