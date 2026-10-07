import SwiftUI
import UIKit

/// The app's only source of color, type, and shape values. Views reference
/// these tokens instead of literal sizes or RGB values.
enum Theme {
    /// Neutral greys from black to white, plus the few status accents.
    enum Palette {
        static let canvas = Color.black
        static let surface = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
        static let surfaceRaised = Color(white: 36 / 255)
        static let guide = Color(white: 0.32)
        static let muted = Color(uiColor: .systemGray)
        static let mutedDark = Color(uiColor: .systemGray3)
        static let text = Color.white
        static let inverseText = Color.black

        static let positive = Color.green
        static let caution = Color.yellow
        static let negative = Color.red

        /// Per-metric chart accents.
        static let steps = Color(red: 0.64, green: 0.56, blue: 0.86)
        static let sleep = Color(red: 0.39, green: 0.69, blue: 1.0)

        /// WHOOP's published recovery band colors.
        static let recoveryLow = Color(red: 1, green: 0, blue: 38 / 255)
        static let recoveryModerate = Color(red: 1, green: 222 / 255, blue: 0)
        static let recoveryHigh = Color(red: 22 / 255, green: 236 / 255, blue: 6 / 255)
    }

    /// One rounded family at a fixed set of sizes.
    enum Typography {
        static let design: Font.Design = .rounded

        /// Chart axis and average labels.
        static let caption = font(9, .medium)
        /// Battery percentages and inline status text.
        static let small = font(11, .bold)
        /// Card and summary metric labels.
        static let body = font(14, .regular)
        /// Header date.
        static let title = font(22, .semibold)
        /// Units beside a metric value.
        static let unit = font(18, .semibold)
        /// Metric values.
        static let value = font(28, .semibold)

        static func font(_ size: CGFloat, _ weight: Font.Weight) -> Font {
            .system(size: size, weight: weight, design: design)
        }
    }

    /// SF Symbol sizes; symbols are not text and stay outside the type scale.
    enum Icon {
        static let glyph = Typography.font(7, .bold)
        static let ring = Typography.font(10, .bold)
        static let label = Typography.font(12, .regular)
    }

    enum Layout {
        static let spacing: CGFloat = 12
        static let cornerRadius: CGFloat = 22
        static let cardPadding: CGFloat = 17
        static let screenInset: CGFloat = 16
        static let summaryLeadingInset: CGFloat = 6
        static let summaryColumnSpacing: CGFloat = 40
    }

    /// Diagonal neutral gradient shared by every card.
    static var cardBackground: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Palette.surface, location: 0),
                .init(color: Palette.surface, location: 0.65),
                .init(color: Palette.surfaceRaised, location: 1),
            ],
            startPoint: .bottomLeading,
            endPoint: .topTrailing
        )
    }
}

extension View {
    /// Applies the shared card gradient and corner radius.
    func cardBackground() -> some View {
        background(
            Theme.cardBackground,
            in: RoundedRectangle(cornerRadius: Theme.Layout.cornerRadius, style: .continuous)
        )
    }
}
