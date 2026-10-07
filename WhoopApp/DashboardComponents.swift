import SwiftUI

enum WhoopBatteryPresentation {
    enum TrackTone: Equatable {
        case lightBehindBlack
        case darkBehindWhite
    }

    static func isLow(level: Int?) -> Bool {
        guard let level else { return false }
        return level <= 20
    }

    static func trackTone(level: Int?, isCharging: Bool) -> TrackTone {
        isCharging || isLow(level: level) ? .darkBehindWhite : .lightBehindBlack
    }
}

struct WhoopBatteryPercentIcon: View {
    private static let chargingTransitionDuration = 0.24
    private static let boltFadeOutDuration = 0.14

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let level: Int?
    let isCharging: Bool

    @State private var chargingStyleActive: Bool
    @State private var chargingContentExpansion: CGFloat
    @State private var boltOpacity: Double

    init(level: Int?, isCharging: Bool) {
        self.level = level
        self.isCharging = isCharging
        _chargingStyleActive = State(initialValue: isCharging)
        _chargingContentExpansion = State(initialValue: isCharging ? 1 : 0)
        _boltOpacity = State(initialValue: isCharging ? 1 : 0)
    }

    private var clampedLevel: Int {
        min(max(level ?? 0, 0), 100)
    }

    private var lowBattery: Bool {
        WhoopBatteryPresentation.isLow(level: level)
    }

    private var percentageText: String {
        level.map(String.init) ?? "–"
    }

    private var fillFraction: CGFloat {
        level == nil ? 0 : CGFloat(clampedLevel) / 100
    }

    private var trackColor: Color {
        // Keep the neutral well legible under the label: a lighter Apple gray
        // behind black text, and a restrained dark gray behind white text.
        switch WhoopBatteryPresentation.trackTone(
            level: level,
            isCharging: chargingStyleActive
        ) {
        case .lightBehindBlack:
            return Theme.Palette.muted
        case .darkBehindWhite:
            return Theme.Palette.mutedDark
        }
    }

    private var fillColor: Color {
        if chargingStyleActive { return Theme.Palette.positive }
        return lowBattery ? Theme.Palette.negative : Theme.Palette.text
    }

    private var labelColor: Color {
        chargingStyleActive || lowBattery ? Theme.Palette.text : Theme.Palette.inverseText
    }

    private static let shellWidth: CGFloat = 29
    private static let shellHeight: CGFloat = 16
    private static let shellRadius: CGFloat = 4.6

    private var statusLabel: some View {
        HStack(spacing: chargingContentExpansion * 0.25) {
            HStack(spacing: -0.5) {
                ForEach(Array(percentageText.enumerated()), id: \.offset) { _, digit in
                    Text(String(digit))
                }
            }
            .font(Theme.Typography.battery)

            Image(systemName: "bolt.fill")
                .font(Theme.Icon.glyph)
                .frame(width: 7 * chargingContentExpansion)
                .opacity(boltOpacity)
        }
        .foregroundStyle(labelColor)
        .frame(width: Self.shellWidth, height: Self.shellHeight)
    }

    var body: some View {
        HStack(spacing: Theme.Layout.batteryTerminalSpacing) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Self.shellRadius, style: .continuous)
                    .fill(trackColor)

                Rectangle()
                    .fill(fillColor)
                    .frame(width: Self.shellWidth * fillFraction)

                statusLabel
            }
            .frame(width: Self.shellWidth, height: Self.shellHeight)
            .clipShape(RoundedRectangle(cornerRadius: Self.shellRadius, style: .continuous))

            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: Theme.Layout.batteryTerminalRadius,
                topTrailingRadius: Theme.Layout.batteryTerminalRadius,
                style: .continuous
            )
            .fill(trackColor)
            .frame(width: Theme.Layout.batteryTerminalWidth, height: Theme.Layout.batteryTerminalHeight)
        }
        .accessibilityHidden(true)
        .task(id: isCharging) {
            if reduceMotion {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    chargingStyleActive = isCharging
                    chargingContentExpansion = isCharging ? 1 : 0
                    boltOpacity = isCharging ? 1 : 0
                }
                return
            }

            if isCharging {
                // Color, digit position, and bolt opacity enter as one motion.
                withAnimation(.easeInOut(duration: Self.chargingTransitionDuration)) {
                    chargingStyleActive = true
                    chargingContentExpansion = 1
                    boltOpacity = 1
                }
                return
            }

            // On exit, preserve the charging layout until the bolt is fully
            // gone. Then center the digits while the colors return together.
            withAnimation(.easeOut(duration: Self.boltFadeOutDuration)) {
                boltOpacity = 0
            }
            try? await Task.sleep(for: .seconds(Self.boltFadeOutDuration))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: Self.chargingTransitionDuration)) {
                chargingContentExpansion = 0
                chargingStyleActive = false
            }
        }
    }
}
