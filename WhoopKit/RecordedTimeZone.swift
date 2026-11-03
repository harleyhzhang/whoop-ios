import Foundation

/// Recorded identifiers describe locations; their numeric offsets describe only
/// the observation instant. Resolve calendar rules again at the sample instant.
struct RecordedTimeZone {
    struct Observation {
        let timestamp: Double
        let identifier: String
    }
    private struct Run {
        let identifier: String
        var first: Double
        var last: Double
    }
    private var runs: [Run] = []

    init(observations: [Observation]) {
        for observation in observations.sorted(by: { $0.timestamp < $1.timestamp }) {
            if runs.last?.identifier == observation.identifier {
                runs[runs.count - 1].last = observation.timestamp
            } else {
                runs.append(
                    Run(identifier: observation.identifier, first: observation.timestamp, last: observation.timestamp))
            }
        }
    }

    var isEmpty: Bool { runs.isEmpty }

    /// Same-zone observations do not invalidate projections. A changed travel
    /// boundary or identifier does, even if no sensor row changed.
    var signature: String {
        runs.enumerated().map { index, run in
            "\(run.identifier)|\(index == 0 ? "" : String(run.first))|\(index == runs.count - 1 ? "" : String(run.last))"
        }.joined(separator: ";")
    }

    func regions(overlapping start: Double, end: Double) -> [(zone: TimeZone, start: Double, end: Double)] {
        var regions: [(zone: TimeZone, start: Double, end: Double)] = []
        for (index, run) in runs.enumerated() {
            let lower = index == 0 ? -.infinity : runs[index - 1].last
            let upper = index == runs.count - 1 ? .infinity : runs[index + 1].first
            if lower < end, upper > start, let zone = TimeZone(identifier: run.identifier) {
                regions.append((zone: zone, start: max(start, lower), end: min(end, upper)))
            }
        }
        return regions
    }

    /// Between observations in different locations the actual travel instant
    /// is unknown. A whole civil day must fit one known location to be scored.
    func supports(_ zone: TimeZone, start: Double, end: Double) -> Bool {
        runs.enumerated().contains { index, run in
            run.identifier == zone.identifier
                && (index == 0 || start >= run.first)
                && (index == runs.count - 1 || end <= run.last)
        }
    }

    static func offset(identifier: String, recordedOffset: Int, at date: Date) -> Int {
        TimeZone(identifier: identifier)?.secondsFromGMT(for: date) ?? recordedOffset
    }

    static func bounds(day: String, zone: TimeZone) -> (start: Double, end: Double)? {
        guard let date = DayKey.date(from: day, timeZone: zone) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return (start.timeIntervalSince1970, end.timeIntervalSince1970)
    }

    /// Stale seasonal offsets are explainable by the recorded location. A
    /// conflicting offset from elsewhere cannot be repaired by assuming it is DST.
    static func recognizes(offsets: String, zone: TimeZone, start: Double, end: Double) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let year = calendar.component(.year, from: Date(timeIntervalSince1970: start))
        var known = Set([
            zone.secondsFromGMT(for: Date(timeIntervalSince1970: start)),
            zone.secondsFromGMT(for: Date(timeIntervalSince1970: end - 1)),
        ])
        for month in 1...12 {
            if let date = calendar.date(from: DateComponents(year: year, month: month, day: 15, hour: 12)) {
                known.insert(zone.secondsFromGMT(for: date))
            }
        }
        return offsets.split(separator: ",").allSatisfy { Int($0).map(known.contains) ?? false }
    }
}
