import SwiftUI

struct MotionCalibrationModifier: ViewModifier {
    let metric: HealthMetric
    let capture: WhoopMotionCapture
    @State private var presented = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if metric == .strain {
            content.contextMenu {
                Button("Record movement calibration", systemImage: "figure.strengthtraining.traditional") {
                    presented = true
                }
            }
            .sheet(isPresented: $presented) { MotionCalibrationView(capture: capture) }
        } else {
            content
        }
    }
}

struct MotionCalibrationView: View {
    let capture: WhoopMotionCapture
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var label = WhoopMotionCaptureState.Label.rest
    @State private var duration = 60
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Form {
                    Section("Brief movement recording") {
                        Text(
                            "Keep WHOOP on your wrist and this screen open. Start just before the activity and stop when you finish."
                        )
                        Picker("Activity", selection: $label) {
                            ForEach(WhoopMotionCaptureState.Label.allCases, id: \.self) { label in
                                Text(label.rawValue).tag(label)
                            }
                        }
                        Picker("Stop automatically after", selection: $duration) {
                            Text("1 minute").tag(60)
                            Text("3 minutes").tag(180)
                            Text("5 minutes").tag(300)
                            Text("10 minutes").tag(600)
                        }
                        TextField("Exercise, reps and weight", text: $notes, axis: .vertical)
                            .onChange(of: notes) { _, value in notes = String(value.prefix(300)) }
                    }
                    .disabled(capture.blocksHistory)
                    Section {
                        Text(capture.status)
                        if let state = capture.state {
                            Text("\(state.buffers.count) motion buffers saved")
                            if state.phase == .complete { Text(state.reason) }
                            if state.isCollecting {
                                Text(state.deadline, style: .timer).monospacedDigit()
                            }
                        }
                        if capture.blocksHistory {
                            Button("Stop recording", role: .destructive) { capture.stop() }
                        } else {
                            Button("Start recording") {
                                capture.start(label: label, notes: notes, duration: Double(duration))
                            }
                            .disabled(!capture.canStart)
                        }
                    } footer: {
                        Text(
                            "This saves raw movement data for improving lifting detection. It does not change Strain. Leaving the app stops recording. Interrupted sensor cleanup resumes when WHOOP reconnects."
                        )
                    }
                }
            }
            .font(Theme.Typography.body)
            .navigationTitle("Movement calibration")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { capture.prepareForBackground() }
            }
            .onDisappear { capture.stop(reason: "Recording screen closed") }
        }
        .preferredColorScheme(.dark)
    }
}
