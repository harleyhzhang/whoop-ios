import SwiftUI

struct WhoopBatteryPercentIcon: View {
    let level: Int?
    let isCharging: Bool

    private var clampedLevel: Int {
        min(max(level ?? 0, 0), 100)
    }

    private var fillColor: Color {
        if isCharging { return .green }
        if clampedLevel <= 20 { return .red }
        if clampedLevel <= 35 { return .yellow }
        return .primary
    }

    private var percentageText: String {
        level.map(String.init) ?? "–"
    }

    private var fillFraction: CGFloat {
        level == nil ? 0 : CGFloat(clampedLevel) / 100
    }

    private var trackColor: Color {
        if isCharging { return Color.white.opacity(0.24) }
        return Color.primary.opacity(0.58)
    }

    private static let shellWidth: CGFloat = 29
    private static let shellHeight: CGFloat = 16
    private static let shellRadius: CGFloat = 4.6

    private func percentageLabel(color: Color) -> some View {
        HStack(spacing: -0.5) {
            ForEach(Array(percentageText.enumerated()), id: \.offset) { _, digit in
                Text(String(digit))
            }
        }
        .font(.system(size: 13, weight: .bold, design: .rounded))
        .foregroundStyle(color)
        .frame(width: Self.shellWidth, height: Self.shellHeight)
    }

    private var chargingLabel: some View {
        HStack(spacing: 1) {
            HStack(spacing: -0.5) {
                ForEach(Array(percentageText.enumerated()), id: \.offset) { _, digit in
                    Text(String(digit))
                }
            }
            .font(.system(size: 12, weight: .bold, design: .rounded))

            Image(systemName: "bolt.fill")
                .font(.system(size: 7, weight: .bold))
        }
        .foregroundStyle(.white)
        .frame(width: Self.shellWidth, height: Self.shellHeight)
    }

    var body: some View {
        HStack(spacing: 1.6) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Self.shellRadius, style: .continuous)
                    .fill(trackColor)

                Rectangle()
                    .fill(fillColor)
                    .frame(width: Self.shellWidth * fillFraction)

                if isCharging {
                    chargingLabel
                } else {
                    percentageLabel(color: .black)
                }
            }
            .frame(width: Self.shellWidth, height: Self.shellHeight)
            .clipShape(RoundedRectangle(cornerRadius: Self.shellRadius, style: .continuous))

            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 3.3,
                topTrailingRadius: 3.3,
                style: .continuous
            )
            .fill(trackColor)
            .frame(width: 2.4, height: 6.6)
        }
        .accessibilityHidden(true)
    }
}

struct AnimatedMetricValue: View {
    private static let duration = 0.24
    private static let stagger = 0.014
    private static let maximumStagger = 0.042

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let value: String
    let fontSize: CGFloat
    let animateChanges: Bool

    @State private var previousValue: String
    @State private var displayedValue: String
    @State private var animationProgress: CGFloat = 1
    @State private var animationGeneration = 0

    init(value: String, fontSize: CGFloat = 30, animateChanges: Bool = true) {
        self.value = value
        self.fontSize = fontSize
        self.animateChanges = animateChanges
        _previousValue = State(initialValue: value)
        _displayedValue = State(initialValue: value)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Text(previousValue)
                .modifier(PreviousMetricValueFade(progress: animationProgress))

            HStack(spacing: 0) {
                ForEach(Array(displayedValue.enumerated()), id: \.offset) { index, character in
                    Text(String(character))
                        .modifier(
                            MetricDigitPop(
                                progress: animationProgress,
                                delay: min(Double(index) * Self.stagger, Self.maximumStagger),
                                duration: Self.duration,
                                totalDuration: Self.duration + Self.maximumStagger
                            )
                        )
                }
            }
        }
        .font(.system(size: fontSize, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.primary)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(displayedValue)
        .onChange(of: value) { _, newValue in
            guard newValue != displayedValue else { return }

            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                previousValue = reduceMotion || !animateChanges ? newValue : displayedValue
                displayedValue = newValue
                animationProgress = reduceMotion || !animateChanges ? 1 : 0
                animationGeneration &+= 1
            }
        }
        .task(id: animationGeneration) {
            guard !reduceMotion, animationProgress == 0 else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: Self.duration + Self.maximumStagger)) {
                animationProgress = 1
            }
            try? await Task.sleep(for: .seconds(Self.duration + Self.maximumStagger))
            guard !Task.isCancelled else { return }
            previousValue = displayedValue
        }
    }
}

private struct MetricDigitPop: AnimatableModifier {
    var progress: CGFloat
    let delay: Double
    let duration: Double
    let totalDuration: Double

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let elapsed = progress * CGFloat(totalDuration)
        let localProgress = min(
            max((elapsed - CGFloat(delay)) / CGFloat(duration), 0),
            1
        )
        let easedProgress = easeOutBack(localProgress)

        content
            .opacity(localProgress)
            .blur(radius: (1 - localProgress) * 1.2)
            .scaleEffect(0.97 + (0.03 * easedProgress))
            .offset(y: (1 - easedProgress) * 5)
    }

    private func easeOutBack(_ progress: CGFloat) -> CGFloat {
        let overshoot: CGFloat = 0.72
        let shifted = progress - 1
        return 1 + ((overshoot + 1) * shifted * shifted * shifted)
            + (overshoot * shifted * shifted)
    }
}

private struct PreviousMetricValueFade: AnimatableModifier {
    var progress: CGFloat

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let remaining = CGFloat(1) - min(progress, CGFloat(1))
        content.opacity(Double(remaining))
    }
}
