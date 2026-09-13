import SwiftUI
import UIKit

struct DashboardHeader: View {
    let referenceDate: Date
    let errorMessage: String?
    let batteryLevel: Int?
    let isCharging: Bool
    let isConnected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(referenceDate, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            HStack(spacing: 7) {
                ZStack(alignment: .bottomTrailing) {
                    Image("WhoopBand")
                        .resizable()
                        .scaledToFit()
                        .brightness(0.07)
                        .contrast(1.03)
                        .frame(width: 24, height: 24)

                    Circle()
                        .fill(isConnected ? Color.green : Color.secondary)
                        .frame(width: 5, height: 5)
                        .overlay {
                            Circle()
                                .stroke(
                                    Color(uiColor: .systemGroupedBackground),
                                    lineWidth: 1
                                )
                        }
                }

                WhoopBatteryPercentIcon(level: batteryLevel, isCharging: isCharging)
                    .opacity(isConnected ? 1 : 0.45)
            }
            .frame(minHeight: 36)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "WHOOP \(isConnected ? "connected" : "disconnected"), battery \(batteryLevel.map { "\($0) percent" } ?? "unavailable")\(isCharging ? ", charging" : "")"
            )
            .accessibilityIdentifier("whoop.connection.status")
        }
    }
}
