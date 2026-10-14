// Shared look. Mirage is an instrument panel sitting on top of a map, so the visual
// language is: floating glass over cartography, state carried by one accent colour,
// and every number monospaced so it doesn't jitter as it counts.

import SwiftUI

enum Metrics {
    static let corner: CGFloat = 22
    static let innerCorner: CGFloat = 14
    static let gutter: CGFloat = 16
    static let cardPadding: CGFloat = 16
}

extension SpoofController.Mode {
    var tint: Color {
        switch self {
        case .real: return .secondary
        case .holding: return .blue
        case .moving: return .green
        }
    }

    var icon: String {
        switch self {
        case .real: return "location.slash"
        case .holding: return "mappin.circle.fill"
        case .moving: return "car.fill"
        }
    }

    var title: String {
        switch self {
        case .real: return "Real GPS"
        case .holding: return "Holding"
        case .moving: return "Driving"
        }
    }
}

/// Floating panel over the map. Thin material so the cartography still reads through.
struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Metrics.cardPadding)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
    }
}

/// Big tappable primary action. Fills width so it's reachable one-handed.
struct PrimaryActionStyle: ButtonStyle {
    var tint: Color = .blue
    var enabled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: Metrics.innerCorner, style: .continuous)
                    .fill(enabled ? tint.gradient : Color.gray.opacity(0.4).gradient)
            )
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Secondary, sits beside the primary action.
struct SubtleActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: Metrics.innerCorner, style: .continuous))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension View {
    /// Tabular figures: stops readouts from shifting width as digits change.
    func numeric() -> some View {
        monospacedDigit().contentTransition(.numericText())
    }
}
