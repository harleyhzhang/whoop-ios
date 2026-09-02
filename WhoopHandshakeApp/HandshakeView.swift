import SwiftUI

struct HandshakeView: View {
    @ObservedObject var probe: WhoopHandshakeProbe

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    row("Bluetooth", probe.bluetoothState)
                    row("Status", probe.status)
                    row("Device", probe.deviceName)
                    row("Handshake", probe.handshakeState)
                }

                Section("Live measurements") {
                    row("Heart Rate", probe.heartRate)
                    row("R–R intervals", probe.rrSummary)
                    row("Realtime HR", probe.realtimeState)
                    row("WHOOP packets", String(probe.proprietaryPacketCount))
                    row("Saved locally", String(probe.persistedPacketCount))
                    row("Latest packet", probe.latestPacket)
                    row("Notifications", probe.notificationState)
                }

                Section {
                    Button("Attempt encrypted handshake") {
                        AppHaptics.firmImpact()
                        probe.attemptHandshake()
                    }
                    .disabled(!probe.canAttemptHandshake)

                    Button("Scan again") {
                        AppHaptics.softImpact()
                        probe.startScan()
                    }
                    .disabled(!probe.bluetoothReady)
                } footer: {
                    Text("This sends only WHOOP 5's static CLIENT_HELLO. It performs no configuration or deep-data writes. A successful handshake can transfer the strap's Bluetooth bond away from the official WHOOP app.")
                }

                Section("Diagnostic log") {
                    if probe.diagnosticEvents.isEmpty {
                        Text("No events yet")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(probe.diagnosticEvents.suffix(40).joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxHeight: 220, alignment: .topLeading)
                    }

                    ShareLink(item: probe.diagnosticReport) {
                        Label("Share diagnostic report", systemImage: "square.and.arrow.up")
                    }
                }

            }
            .navigationTitle("WHOOP Handshake")
            .onChange(of: probe.isConnected) { wasConnected, isConnected in
                if isConnected && !wasConnected {
                    AppHaptics.success()
                }
            }
            .onChange(of: probe.handshakeState) { _, state in
                if state.hasPrefix("Refused") || state.hasPrefix("Link dropped") {
                    AppHaptics.warning()
                }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value)
    }
}
