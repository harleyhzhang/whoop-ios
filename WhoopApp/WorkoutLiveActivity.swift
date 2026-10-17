import ActivityKit
import Foundation

/// Mirrors the live manual activity onto the lock screen and Dynamic Island.
/// Activities are looked up by entry ID off the main actor because ActivityKit
/// handles are not sendable.
@MainActor
final class WorkoutLiveActivity {
    private var entryID: UUID?
    private var lastUpdate = Date.distantPast
    private static let updateInterval: TimeInterval = 5

    func sync(_ entry: ManualEntry?, heartRate: Int?, zone: Int? = nil, now: Date = .now) {
        guard let entry else {
            entryID = nil
            Task.detached { await Self.endAll(except: nil) }
            return
        }
        let state = Self.state(for: entry, heartRate: heartRate, zone: zone)
        let id = entry.id
        if entryID == id {
            guard now.timeIntervalSince(lastUpdate) >= Self.updateInterval else { return }
            lastUpdate = now
            Task.detached { await Self.update(id, state: state) }
            return
        }
        entryID = id
        lastUpdate = now
        Task.detached { await Self.endAll(except: id) }
        let running = Activity<WorkoutActivityAttributes>.activities.contains { $0.attributes.entryID == id }
        guard !running, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = WorkoutActivityAttributes(
            entryID: id, title: entry.title, symbol: entry.kind.symbol, start: entry.start)
        _ = try? Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil))
    }

    static func state(
        for entry: ManualEntry, heartRate: Int?, zone: Int?
    ) -> WorkoutActivityAttributes.ContentState {
        WorkoutActivityAttributes.ContentState(
            heartRate: heartRate, averageHeartRate: entry.averageHeartRate, maxHeartRate: entry.maxHeartRate,
            zone: zone)
    }

    private nonisolated static func update(_ id: UUID, state: WorkoutActivityAttributes.ContentState) async {
        for activity in Activity<WorkoutActivityAttributes>.activities where activity.attributes.entryID == id {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    /// Also clears activities left behind by a previous launch.
    private nonisolated static func endAll(except id: UUID?) async {
        for activity in Activity<WorkoutActivityAttributes>.activities where activity.attributes.entryID != id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
