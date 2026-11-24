import AppKit
import SwiftUI

/// Every section of the main window. Today and Stats are daily; Setup is how lockin behaves.
enum PlannerTab: String, CaseIterable, Identifiable {
    case plan, stats, apps, blocking, day, ai
    var id: String { rawValue }
    var title: String {
        switch self {
        case .plan: return "Today"
        case .stats: return "Stats"
        case .apps: return "Lock-in apps"
        case .blocking: return "Blocking"
        case .day: return "Your day"
        case .ai: return "AI planner"
        }
    }
    var icon: String {
        switch self {
        case .plan: return "sun.max"
        case .stats: return "chart.bar"
        case .apps: return "square.grid.2x2"
        case .blocking: return "lock"
        case .day: return "calendar"
        case .ai: return "sparkles"
        }
    }
    /// One line under the title of a setup page: what it's for.
    var blurb: String {
        switch self {
        case .apps: return "The few apps you work in. A session allows only these; everything else gets covered."
        case .blocking: return "What counts as a distraction, and how hard lockin holds the line."
        case .day: return "The morning screen, your goal, sessions that start on time, and your calendar."
        case .ai: return "Optional. Turns a messy brain dump into a timed plan and edits it as your day changes."
        default: return ""
        }
    }
    static let daily: [PlannerTab] = [.plan, .stats]
    static let setup: [PlannerTab] = [.apps, .blocking, .day, .ai]
}

/// The one lockin window: a sidebar with Today and Stats on top, setup below.
struct MainView: View {
    @EnvironmentObject var e: Engine
    @StateObject private var settings = SettingsModel()

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar.navigationSplitViewColumnWidth(min: 176, ideal: 186, max: 214)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 720, minHeight: 520)
        .tint(Theme.accent)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 22, height: 22)
                Text("lockin").font(.system(size: 15, weight: .bold)).tracking(-0.3)
            }
            .padding(.horizontal, 10).padding(.bottom, 14)
            ForEach(PlannerTab.daily) { t in row(t) }
            Text("SETUP").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
                .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 4)
            ForEach(PlannerTab.setup) { t in row(t) }
            Spacer()
            SidebarStreak()
            Button { NSApp.terminate(nil) } label: {
                Label("Quit lockin", systemImage: "power").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.top, 38).padding(.bottom, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SkinWash(strength: 1.1).ignoresSafeArea())
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
        case .plan: TodayView()
        case .stats: StatsPage()
        default:
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(e.plannerTab.title).font(.system(size: 26, weight: .bold)).tracking(-0.4)
                    Text(e.plannerTab.blurb).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28).padding(.top, 34).padding(.bottom, 6)
                switch e.plannerTab {
                case .apps: AppsTab(m: settings)
                case .blocking: BlockingTab(m: settings)
                case .ai: AITab(m: settings)
                default: DayTab(m: settings)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(AppBackground())
            .onDisappear { settings.save(includeKey: false) }
        }
    }
}

/// The streak and today's minutes at the bottom of the sidebar.
struct SidebarStreak: View {
    @EnvironmentObject var e: Engine
    var body: some View {
        let st = e.stats()
        let level = Rewards.load(goal: st.goal).level
        HStack(spacing: 10) {
            LevelEmblem(level: level, size: 28, pips: false)
            VStack(alignment: .leading, spacing: 1) {
                Text(Rewards.title(level)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    Text("Lv \(level) ·").font(.system(size: 10.5, weight: .medium))
                    StreakFire(streak: st.streak, size: 12)
                    Text("\(st.streak) days").font(.system(size: 10.5)).monospacedDigit()
                }
                .foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.05)))
        .padding(.bottom, 6)
        .onTapGesture { e.plannerTab = .stats }
    }
}
