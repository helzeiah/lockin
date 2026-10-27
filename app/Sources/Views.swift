import SwiftUI

// Shared pieces: the progress ring (the app's one bit of color) and pill buttons.
func tintColor(_ name: String) -> Color {
    switch name {
    case "green": return Color(red: 0.20, green: 0.78, blue: 0.35)
    case "orange": return Color(red: 1.0, green: 0.62, blue: 0.04)
    case "red": return Color(red: 1.0, green: 0.27, blue: 0.23)
    case "blue": return Color(red: 0.25, green: 0.61, blue: 1.0)
    default: return .white
    }
}

struct Ring: View {
    var progress: Double
    var color: Color
    var size: CGFloat = 14
    var width: CGFloat = 2.4
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: width)
            Circle().trim(from: 0, to: max(0.001, progress))
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: progress)
        }
        .frame(width: size, height: size)
    }
}

struct PillButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 13).padding(.vertical, 6.5)
            .foregroundStyle(primary ? Color.black : Color.white)
            .background(Capsule().fill(primary ? Color.white : Color.white.opacity(configuration.isPressed ? 0.24 : 0.13)))
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

/// A block's color: its position in Settings, so every block gets its own and it never changes between launches.
let blockPalette: [Color] = [.blue, .purple, .orange, .teal, .pink, .green, .yellow, .indigo, .mint, .red]
@MainActor func colorFor(block: String) -> Color {
    let names = Engine.shared.cfg.blocks.map { $0.name.lowercased() }
    let b = block.lowercased()
    if let i = names.firstIndex(of: b) ?? names.firstIndex(where: { b.contains($0) || $0.contains(b) }) {
        return blockPalette[i % blockPalette.count]
    }
    return .gray
}
