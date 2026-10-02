import Foundation

struct WhoopStepDayInterval: Sendable, Equatable {
    let dateKey: String
    let lowerBound: TimeInterval
    let upperBound: TimeInterval
}

struct WhoopStepFallbackRepair: Sendable, Equatable {
    let dateKey: String
    let lowerBound: TimeInterval
}

enum WhoopStepDayMigration {
    static let civilFallbackSQL = """
        UPDATE whoop_historical_sample
        SET step_date_key = strftime(
            '%Y-%m-%d', sample_at + COALESCE(step_utc_offset_seconds, 0), 'unixepoch'
        )
        WHERE step_motion_counter IS NOT NULL
        """

    static func intervals(for boundaries: [WhoopWakeBoundary]) -> [WhoopStepDayInterval] {
        boundaries.enumerated().map { index, boundary in
            let upperBound =
                boundaries.indices.contains(index + 1)
                ? boundaries[index + 1].wokeAt
                : boundary.wokeAt.addingTimeInterval(
                    WhoopPhysiologicalDay.maximumOpenDayDuration
                )
            return WhoopStepDayInterval(
                dateKey: boundary.dateKey.rawValue,
                lowerBound: boundary.wokeAt.timeIntervalSince1970,
                upperBound: upperBound.timeIntervalSince1970
            )
        }
    }

    static func fallbackRepair(
        before wokeAt: Date,
        boundaries: [WhoopWakeBoundary]
    ) -> WhoopStepFallbackRepair? {
        guard let precedingBoundary = boundaries.last(where: { $0.wokeAt < wokeAt }) else {
            return nil
        }
        let fallbackAt = precedingBoundary.wokeAt.addingTimeInterval(
            WhoopPhysiologicalDay.maximumOpenDayDuration
        )
        guard fallbackAt < wokeAt else { return nil }
        return WhoopStepFallbackRepair(
            dateKey: precedingBoundary.dateKey.rawValue,
            lowerBound: fallbackAt.timeIntervalSince1970
        )
    }
}
