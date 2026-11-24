import SwiftUI

// The look: dark-first, one accent (the app icon's green), rounded numerals, quiet secondary text.
enum Theme {
    static var accent: Color { Skin.current.color }                  // the icon's green unless you've unlocked a skin
    /// The skin as a fill: its gradient for pattern skins, else the plain color.
    static var accentFill: AnyShapeStyle {
        let s = Skin.current
        return s.colors.count > 1 ? AnyShapeStyle(LinearGradient(colors: s.colors, startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(s.color)
    }
    static var accentRing: AnyShapeStyle {
        let s = Skin.current
        return s.colors.count > 1 ? AnyShapeStyle(AngularGradient(colors: s.colors + [s.colors[0]], center: .center)) : AnyShapeStyle(s.color)
    }
    static let flame = Color(red: 1.0, green: 0.62, blue: 0.04)
    static let danger = Color(red: 1.0, green: 0.33, blue: 0.30)
    static let info = Color(red: 0.36, green: 0.66, blue: 1.0)
    static let card = Color.primary.opacity(0.05)
    static let hairline = Color.primary.opacity(0.08)
    static func number(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font { .system(size: size, weight: weight, design: .rounded) }
}

func tintColor(_ name: String) -> Color {
    switch name {
    case "green": return Theme.accent
    case "orange": return Theme.flame
    case "red": return Theme.danger
    case "blue": return Theme.info
    default: return .white
    }
}

struct Ring: View {
    var progress: Double
    var color: Color
    var size: CGFloat = 14
    var width: CGFloat = 2.4
    var track: Color = Color.white.opacity(0.18)
    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: width)
            Circle().trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(color == Theme.accent ? Theme.accentRing : AnyShapeStyle(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: progress)
        }
        .frame(width: size, height: size)
    }
}

/// Today's focused minutes against the daily goal, with the minutes in the middle.
struct GoalRing: View {
    var minutes: Int
    var goal: Int
    var size: CGFloat = 46
    var body: some View {
        ZStack {
            Ring(progress: Double(minutes) / Double(max(1, goal)), color: Theme.accent, size: size, width: size * 0.1,
                 track: Color.primary.opacity(0.1))
            VStack(spacing: -1) {
                Text("\(minutes)").font(Theme.number(size * 0.3)).monospacedDigit()
                Text("/\(goal)").font(Theme.number(size * 0.17, .medium)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .help(minutes >= goal ? "Today counts" : "\(goal - minutes) more focused minutes and today counts")
    }
}

/// The streak: a flame and the number of days in a row.
struct StreakBadge: View {
    var streak: Int
    var body: some View {
        HStack(spacing: 5) {
            StreakFire(streak: streak, size: 22)
            VStack(alignment: .leading, spacing: -1) {
                Text("\(streak)").font(Theme.number(17)).monospacedDigit()
                Text(streak == 1 ? "day" : "days").font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .help(streak > 0 ? "\(streak)-day streak" : "No streak yet: hit today's goal to start one")
    }
}

/// Primary action: accent fill, dark text (white on this green would be hard to read).
struct PrimaryButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 14.5 : 12.5, weight: .semibold))
            .padding(.horizontal, large ? 22 : 13).padding(.vertical, large ? 10 : 6)
            .foregroundStyle(Color.black.opacity(enabled ? 0.88 : 0.5))
            .background(Capsule().fill(Theme.accentFill).opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Secondary action: a quiet tinted capsule.
struct SecondaryButtonStyle: ButtonStyle {
    var large = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 14 : 12.5, weight: .medium))
            .padding(.horizontal, large ? 18 : 12).padding(.vertical, large ? 10 : 6)
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08)))
    }
}

/// Buttons on the black notch: white primary, translucent secondary.
struct PillButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 13).padding(.vertical, 6.5)
            .foregroundStyle(primary ? Color.black : Color.white)
            .background(Capsule().fill(primary ? Theme.accent : Color.white.opacity(configuration.isPressed ? 0.24 : 0.13)))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView(); v.material = material; v.blendingMode = blending; v.state = .active; return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

/// One accent, in steps: the first task rule gets the full green, later ones lighter shades.
@MainActor func colorFor(block: String) -> Color {
    let names = Engine.shared.cfg.blocks.map { $0.name.lowercased() }
    let b = block.lowercased()
    guard let i = names.firstIndex(of: b) ?? names.firstIndex(where: { b.contains($0) || $0.contains(b) }) else { return Theme.accent.opacity(0.45) }
    return Theme.accent.opacity([1, 0.75, 0.55, 0.4, 0.3][i % 5])
}

/// An app's icon by name (installed or running), with its name on hover.
struct AppIconView: View {
    var name: String
    var size: CGFloat = 16
    var body: some View {
        Image(nsImage: InstalledApps.icon(for: name)).resizable().interpolation(.high)
            .frame(width: size, height: size).help(name)
    }
}

/// A short row of app icons; "+3" when there are more than fit.
struct AppIconRow: View {
    var apps: [String]
    var size: CGFloat = 16
    var max = 4
    var body: some View {
        HStack(spacing: 3) {
            ForEach(apps.prefix(max), id: \.self) { AppIconView(name: $0, size: size) }
            if apps.count > max {
                Text("+\(apps.count - max)").font(.system(size: size * 0.62, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Press and hold to confirm something you shouldn't do on a whim (skip the day, end a session early).
struct HoldButton: View {
    var label: String
    var seconds: Double = 3
    var tint: Color = .secondary
    var action: () -> Void
    @State private var progress: Double = 0
    @State private var holding = false

    var body: some View {
        HStack(spacing: 7) {
            Ring(progress: progress, color: tint, size: 13, width: 2, track: Color.primary.opacity(0.15))
            Text(holding ? "Keep holding…" : label).font(.system(size: 12.5, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(Color.primary.opacity(holding ? 0.1 : 0.05)))
        .contentShape(Capsule())
        .onLongPressGesture(minimumDuration: seconds, maximumDistance: 40, pressing: { down in
            holding = down
            if down { withAnimation(.linear(duration: seconds)) { progress = 1 } }
            else { withAnimation(.easeOut(duration: 0.2)) { progress = 0 } }
        }, perform: {
            holding = false; progress = 0
            action()
        })
        .help("Press and hold for \(Int(seconds)) seconds")
    }
}

/// Small uppercase heading for a section.
struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
    }
}
