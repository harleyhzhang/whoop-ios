import ActivityKit
import Foundation

/// Shared between the app and the widget extension that draws the lock screen
/// and Dynamic Island while an activity is live.
struct WorkoutActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var heartRate: Int?
        var averageHeartRate: Int?
        var maxHeartRate: Int?
        var zone: Int?
    }

    let entryID: UUID
    let title: String
    let symbol: String
    let start: Date
}
