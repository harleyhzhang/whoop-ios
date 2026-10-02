import SwiftUI
import UIKit

enum PowerPackLEDPresentation {
    enum Tone: Equatable {
        case neutral
        case green
        case yellow
        case red
    }

    static func tone(level: Int?) -> Tone {
        guard let level else { return .neutral }
        if level >= 90 { return .green }
        if level >= 25 { return .yellow }
        return .red
    }
}

struct DashboardHeader: View {
    let referenceDate: Date
    let errorMessage: String?
    let batteryLevel: Int?
    let isCharging: Bool
    let isConnected: Bool
    let powerPackBatteryLevel: Int?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(referenceDate, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.text)

                if let errorMessage {
                    Text(errorMessage)
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Palette.negative)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    ZStack(alignment: .bottomTrailing) {
                        Image("WhoopBand")
                            .resizable()
                            .scaledToFit()
                            .brightness(0.07)
                            .contrast(1.03)
                            .frame(width: 24, height: 24)

                        Circle()
                            .fill(isConnected ? Theme.Palette.positive : Theme.Palette.muted)
                            .frame(width: 5, height: 5)
                            .overlay {
                                Circle()
                                    .stroke(Theme.Palette.canvas, lineWidth: 1)
                            }
                    }
                    .offset(x: -1)

                    WhoopBatteryPercentIcon(level: batteryLevel, isCharging: isCharging)
                        .opacity(isConnected ? 1 : 0.45)
                }

                HStack(spacing: 3) {
                    PowerPackStatusImage(batteryLevel: powerPackBatteryLevel)
                        .offset(x: 2)

                    WhoopBatteryPercentIcon(level: powerPackBatteryLevel, isCharging: false)
                }
            }
            .frame(minHeight: 36)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "WHOOP \(isConnected ? "connected" : "disconnected"), battery \(batteryLevel.map { "\($0) percent" } ?? "unavailable")\(isCharging ? ", charging" : ""); PowerPack battery \(powerPackBatteryLevel.map { "\($0) percent" } ?? "unavailable")"
            )
            .accessibilityIdentifier("whoop.batteries")
        }
    }
}

private struct PowerPackStatusImage: View {
    let batteryLevel: Int?

    private var indicatorColor: Color {
        switch PowerPackLEDPresentation.tone(level: batteryLevel) {
        case .neutral: Theme.Palette.muted
        case .green: Theme.Palette.positive
        case .yellow: Theme.Palette.caution
        case .red: Theme.Palette.negative
        }
    }

    var body: some View {
        ZStack {
            Image("WhoopPowerPack")
                .resizable()
                .scaledToFit()

            Capsule()
                .fill(indicatorColor)
                .frame(width: 3.5, height: 1.3)
                .shadow(
                    color: indicatorColor.opacity(batteryLevel == nil ? 0 : 0.9),
                    radius: 1.2
                )
                .offset(x: 0.5, y: -7.4)
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}
