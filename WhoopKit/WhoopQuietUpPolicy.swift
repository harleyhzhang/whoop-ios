import Foundation

/// The strap's onboard state 3 (`up`) also fires during still sleep. Across
/// 58 local nights, all 33 stretches of `up` bounded by sleep on both sides
/// kept the night's asleep heart rate (−4 to +3 bpm) and step noise (at most
/// 70 steps in any five minutes, against 53 inside explicit sleep), while real
/// morning wakes rose 12–19 bpm and reached 94–512 steps within the hour.
/// Excluding them cut up to 108 minutes from a night the wearer slept through.
///
/// Such a stretch counts as sleep only when it still looks like sleep. Any
/// explicit awake sample, missing step evidence, raised heart rate, or a
/// walking burst keeps it excluded. The evidence gates stay on explicit sleep,
/// so bridged time never makes an otherwise unscorable night publishable.
enum WhoopQuietUpPolicy {
    static let maximumHeartRateRise = 5.0
    static let stepBurstWindow: TimeInterval = 5 * 60
    static let maximumStepsPerBurst = 80

    /// Sleep added by quiet bounded `up` stretches, measured exactly like
    /// explicit sleep so outages inside a stretch are never counted.
    static func bridgedSleepSeconds(
        session: [WhoopStore.HistoricalRow],
        cadence: Double
    ) -> Double {
        let asleep = session.filter { $0.sleepState == .asleep }
        guard let baseline = medianHeartRate(asleep) else { return 0 }
        var counted: [WhoopStore.HistoricalRow] = []
        var index = session.startIndex
        while index < session.endIndex {
            guard session[index].sleepState != .asleep else {
                counted.append(session[index])
                index += 1
                continue
            }
            let start = index
            while index < session.endIndex, session[index].sleepState != .asleep { index += 1 }
            guard start > session.startIndex, index < session.endIndex else { continue }
            let stretch = Array(session[start..<index])
            if isQuietSleep(
                stretch, before: session[start - 1], after: session[index], baseline: baseline)
            {
                counted += stretch
            }
        }
        return max(
            0,
            WhoopStore.elapsedSeconds(across: counted, cadence: cadence)
                - WhoopStore.elapsedSeconds(across: asleep, cadence: cadence)
        )
    }

    static func isQuietSleep(
        _ stretch: [WhoopStore.HistoricalRow],
        before: WhoopStore.HistoricalRow,
        after: WhoopStore.HistoricalRow,
        baseline: Double
    ) -> Bool {
        guard stretch.allSatisfy({ $0.sleepState == .up }),
            let heartRate = medianHeartRate(stretch), heartRate <= baseline + maximumHeartRateRise
        else { return false }
        let bounded = [before] + stretch + [after]
        guard bounded.allSatisfy({ $0.stepCounter != nil }) else { return false }
        return largestStepBurst(bounded) < maximumStepsPerBurst
    }

    /// Step deltas follow `WhoopStepDaySummary`: a 16-bit wrap is accepted only
    /// across an observed gap, and implausible jumps are counter resets.
    static func largestStepBurst(_ rows: [WhoopStore.HistoricalRow]) -> Int {
        var deltas: [(timestamp: TimeInterval, steps: Int)] = []
        for (previous, current) in zip(rows, rows.dropFirst()) {
            guard let old = previous.stepCounter, let new = current.stepCounter else { continue }
            let elapsed = current.timestamp - previous.timestamp
            guard elapsed > 0 else { continue }
            guard new >= old || elapsed <= WhoopStepDaySummary.maximumWrapObservationGap else {
                continue
            }
            let steps = Int(new &- old)
            let plausible = max(8, Int(ceil(elapsed * WhoopStepDaySummary.maximumStepsPerSecond)))
            if steps <= plausible { deltas.append((current.timestamp, steps)) }
        }
        var largest = 0
        var running = 0
        var first = deltas.startIndex
        for delta in deltas {
            running += delta.steps
            while deltas[first].timestamp <= delta.timestamp - stepBurstWindow {
                running -= deltas[first].steps
                first += 1
            }
            largest = max(largest, running)
        }
        return largest
    }

    static func medianHeartRate(_ rows: [WhoopStore.HistoricalRow]) -> Double? {
        let values = rows.map(\.heartRate).filter { $0 > 0 }.sorted()
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        return values.count.isMultiple(of: 2)
            ? Double(values[middle - 1] + values[middle]) / 2
            : Double(values[middle])
    }
}
