import SwiftUI

enum Theme {
    static let bg = Color(hex: 0x0B0B0E)
    static let surface = Color(hex: 0x16161B)
    static let elevated = Color(hex: 0x1F1F27)
    static let chip = Color(hex: 0x2A2A33)
    static let input = Color(hex: 0x1C1C23)
    static let stroke = Color(hex: 0x2E2E38)
    static let textPrimary = Color(hex: 0xF4F4F7)
    static let textSecondary = Color(hex: 0x9C9CA8)
    static let accent = Color(hex: 0xFF4D8D)
    static let accentSoft = Color(hex: 0xFF7AB0)
    static let violet = Color(hex: 0x8B5CF6)
    static let green = Color(hex: 0x34D399)
    static let amber = Color(hex: 0xFBBF24)
    static let red = Color(hex: 0xF87171)
    static let userBubble = Color(hex: 0x303038)

    static let candyGradient = LinearGradient(
        colors: [accent, violet],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension Color {
    init(hex: UInt) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

struct ChipBackground: ViewModifier {
    var color: Color = Theme.chip
    var radius: CGFloat = 8
    func body(content: Content) -> some View {
        content.background(color, in: RoundedRectangle(cornerRadius: radius))
    }
}

extension View {
    func chipBackground(_ color: Color = Theme.chip, radius: CGFloat = 8) -> some View {
        modifier(ChipBackground(color: color, radius: radius))
    }
}
