import SwiftUI

struct HandshakeView: View {
    @Environment(\.dismiss) private var dismiss
    var probe: WhoopHandshakeProbe

    private var isConnected: Bool {
        probe.isConnected || WhoopLaunchOverrides.isConnected
    }

    private var deviceDisplayName: String {
        probe.deviceName == "—" ? "WHOOP 5.0" : probe.deviceName
    }

    private var batteryLevel: Int? {
        WhoopLaunchOverrides.batteryLevel ?? probe.batteryLevel
    }

    private var batterySymbol: String {
        switch batteryLevel ?? 0 {
        case 76...: "battery.100percent"
        case 51...: "battery.75percent"
        case 26...: "battery.50percent"
        case 1...: "battery.25percent"
        default: "battery.0percent"
        }
    }

    @ViewBuilder private var lastConnectedValue: some View {
        if WhoopLaunchOverrides.isConnected {
            Text("Now")
        } else if let date = probe.lastConnectedAt {
            Text(date, style: .relative)
        } else {
            Text("Not yet")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Image("WhoopBand")
                .resizable()
                .scaledToFit()
                .frame(height: 108)
                .accessibilityHidden(true)
                .padding(.top, 2)

            VStack(spacing: 2) {
                Text(deviceDisplayName)
                    .font(.title3.weight(.semibold))

                HStack(spacing: 6) {
                    Circle()
                        .fill(isConnected ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)

                    Text(isConnected ? "Connected" : "Disconnected")
                        .foregroundStyle(isConnected ? Color.green : Color.secondary)
                        .font(.subheadline.weight(.medium))
                }
            }
            .padding(.top, 2)

            primaryMetric(
                title: "Battery",
                value: batteryLevel.map { "\($0)%" } ?? "—",
                symbol: batterySymbol
            )
            .padding(.vertical, 18)

            Divider()

            statusRow(
                title: "Collection",
                symbol: "waveform.path.ecg",
                positive: isConnected
            ) {
                Text(isConnected ? "Active" : "Paused")
            }

            Divider().padding(.leading, 31)

            statusRow(
                title: "Last connected",
                symbol: "clock",
                positive: false
            ) {
                lastConnectedValue
            }

            if !isConnected {
                Button("Reconnect") {
                    AppHaptics.firmImpact()
                    probe.startScan()
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 20)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .presentationDetents([.height(360)])
        .presentationDragIndicator(.visible)
        .onChange(of: probe.isConnected) { wasConnected, connected in
            if connected && !wasConnected {
                AppHaptics.success()
            }
        }
    }

    private var header: some View {
        HStack {
            Spacer()

            Button {
                AppHaptics.softImpact()
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    private func primaryMetric(title: String, value: String, symbol: String) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)

                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private func statusRow<Value: View>(
        title: String,
        symbol: String,
        positive: Bool,
        @ViewBuilder value: () -> Value
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 19)

            Text(title)
                .font(.subheadline)

            Spacer()

            value()
                .font(.subheadline.weight(.medium))
                .foregroundStyle(positive ? Color.green : Color.secondary)
        }
        .frame(minHeight: 46)
    }
}
