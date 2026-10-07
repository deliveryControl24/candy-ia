import SwiftUI

struct OrbView: View {
    var size: CGFloat = 260
    var phase: VoiceManager.Phase = .idle

    private var speed: Double {
        switch phase {
        case .idle: return 0.9
        case .listening: return 2.4
        case .thinking: return 1.7
        case .speaking: return 4.6
        }
    }

    private var amplitude: Double {
        switch phase {
        case .idle: return 0.02
        case .listening: return 0.05
        case .thinking: return 0.035
        case .speaking: return 0.07
        }
    }

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = sin(t * speed * .pi * 2 * 0.5)
            let scale = 1.0 + pulse * amplitude
            let glow = 0.5 + 0.5 * sin(t * speed * .pi * 2 * 0.5 + 1.0)

            ZStack {
                // halo exterior
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Theme.accent.opacity(0.55), Theme.violet.opacity(0.25), .clear],
                            center: .center,
                            startRadius: size * 0.28,
                            endRadius: size * 0.75
                        )
                    )
                    .frame(width: size * 1.5, height: size * 1.5)
                    .blur(radius: 30)
                    .opacity(0.65 + glow * 0.35)

                // anillo orbital (pensando / hablando)
                if phase == .thinking || phase == .speaking {
                    Circle()
                        .stroke(
                            AngularGradient(
                                colors: [.clear, Theme.accent.opacity(0.9), Theme.violet.opacity(0.7), .clear],
                                center: .center
                            ),
                            lineWidth: 3
                        )
                        .frame(width: size * 1.08, height: size * 1.08)
                        .rotationEffect(.degrees(t * (phase == .thinking ? 55 : 110)))
                        .blur(radius: 1.5)
                        .opacity(0.8)
                }

                // esfera
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(hex: 0xFFFFFF),
                                Color(hex: 0xFFD9E8),
                                Theme.accent,
                                Theme.violet,
                            ],
                            center: UnitPoint(x: 0.35, y: 0.3),
                            startRadius: 2,
                            endRadius: size * 0.62
                        )
                    )
                    .frame(width: size, height: size)
                    .scaleEffect(scale)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.18), lineWidth: 1.5)
                            .scaleEffect(scale)
                    )
                    .overlay(
                        // brillo superior-izquierda
                        Ellipse()
                            .fill(Color.white.opacity(0.55))
                            .frame(width: size * 0.34, height: size * 0.2)
                            .blur(radius: size * 0.045)
                            .offset(x: -size * 0.17, y: -size * 0.24)
                            .scaleEffect(scale)
                    )
                    .shadow(color: Theme.violet.opacity(0.55), radius: 45, y: 12)
                    .shadow(color: Theme.accent.opacity(0.35), radius: 90, y: 20)
            }
            .frame(width: size * 1.5, height: size * 1.5)
        }
        .allowsHitTesting(false)
    }
}

struct OrbStage: View {
    @ObservedObject var voice: VoiceManager
    var size: CGFloat = 260

    var body: some View {
        OrbView(size: size, phase: voice.phase)
    }
}
