import Foundation

/// Personal cardio calibration. Fitted coefficients live only in private build output.
struct StrainCalibration: Codable, Sendable {
    let version: String
    let exponent: Double
    let loadScale: Double
    let scoreScale: Double

    var isValid: Bool {
        exponent.isFinite && (0.1...10).contains(exponent)
            && loadScale.isFinite && loadScale > 0
            && scoreScale.isFinite && (2...15).contains(scoreScale)
    }

    func loadPerMinute(heartRate: Double, maximumHeartRate: Double) -> Double {
        let relative = min(max(heartRate / maximumHeartRate, 0), 1)
        return pow(max((relative - 0.5) / 0.5, 0), exponent)
    }

    func score(load: Double) -> Double {
        guard isValid, load.isFinite else { return 0 }
        return min(20.9, max(0, scoreScale * log1p(max(0, load) / loadScale)))
    }
}

struct StrainSample: Sendable {
    let timestamp: Double
    let heartRate: Double
    let stepCounter: Int?
    let sleepState: Int?
}

struct StrainEstimate: Codable, Sendable {
    let day: String
    let score: Double?
    let cardiovascularScore: Double
    let muscularScore: Double
    let coverage: Double
    let observedSeconds: Double
    let probableStrengthMinutes: Double
    let probableStrengthSessions: Int
    let version: String
    let source: String
}

/// Streaming, bounded-memory estimator for direct strap samples.
/// The muscular classifier is a conservative heuristic, not a validated activity label.
struct StrainAccumulator {
    static let version = "local_strain_v1_experimental"
    private struct Minute {
        var seconds = 0.0
        var heartRateSeconds = 0.0
        var steps = 0.0
        var stepObservedSeconds = 0.0
        var awakeSeconds = 0.0
        var heartRate: Double { seconds > 0 ? heartRateSeconds / seconds : 0 }
    }

    let calibration: StrainCalibration
    let start: Double
    let end: Double
    let maximumHeartRate: Double
    let restingHeartRate: Double
    private var previous: StrainSample?
    private var recentHeartRates: [Double] = []
    private var minutes: [Int: Minute] = [:]
    private var cardiovascularLoad = 0.0
    private var observedSeconds = 0.0
    private var lastTimestamp: Double?
    private var isFinished = false

    init(
        calibration: StrainCalibration, start: Double, end: Double,
        maximumHeartRate: Double, restingHeartRate: Double
    ) {
        self.calibration = calibration
        self.start = start
        self.end = end
        self.maximumHeartRate = maximumHeartRate
        self.restingHeartRate = restingHeartRate
    }

    mutating func append(_ sample: StrainSample) {
        guard !isFinished, calibration.isValid, start.isFinite, end.isFinite,
            end > start, end - start <= 90_000,
            maximumHeartRate.isFinite, (90...230).contains(maximumHeartRate),
            restingHeartRate.isFinite, restingHeartRate >= 30, restingHeartRate < maximumHeartRate,
            sample.timestamp.isFinite, sample.timestamp >= start, sample.timestamp < end,
            lastTimestamp.map({ sample.timestamp > $0 }) ?? true
        else { return }
        lastTimestamp = sample.timestamp
        if let previous {
            let gap = sample.timestamp - previous.timestamp
            // A long outage contributes only a nominal six-second sample, never the entire gap.
            let duration = gap <= 120 ? gap : min(gap, 6)
            var stepDelta: Double?
            if gap <= 120, let old = previous.stepCounter, let new = sample.stepCounter,
                (0...65_535).contains(old), (0...65_535).contains(new)
            {
                let delta = (new - old + 65_536) % 65_536
                if Double(delta) <= gap * 8 { stepDelta = Double(delta) }
            }
            integrate(sample: previous, duration: duration, steps: stepDelta)
        }
        guard sample.heartRate.isFinite, (30...240).contains(sample.heartRate) else {
            previous = nil
            recentHeartRates.removeAll(keepingCapacity: true)
            return
        }
        if let previous, sample.timestamp - previous.timestamp > 120 {
            recentHeartRates.removeAll(keepingCapacity: true)
        }
        recentHeartRates.append(sample.heartRate)
        if recentHeartRates.count > 5 { recentHeartRates.removeFirst() }
        let ordered = recentHeartRates.sorted()
        previous = StrainSample(
            timestamp: sample.timestamp, heartRate: ordered[ordered.count / 2],
            stepCounter: sample.stepCounter, sleepState: sample.sleepState)
    }

    private mutating func integrate(sample: StrainSample, duration: Double, steps: Double?) {
        let stop = min(sample.timestamp + duration, end)
        var cursor = sample.timestamp
        while cursor < stop {
            let index = Int((cursor - start) / 60)
            let sliceEnd = min(start + Double(index + 1) * 60, stop)
            let seconds = sliceEnd - cursor
            var minute = minutes[index, default: Minute()]
            minute.seconds += seconds
            minute.heartRateSeconds += seconds * sample.heartRate
            if let steps {
                minute.steps += steps * seconds / max(duration, 1)
                minute.stepObservedSeconds += seconds
            }
            // Unknown sleep state cannot establish an awake lifting interval.
            if let state = sample.sleepState, [0, 1, 3].contains(state) {
                minute.awakeSeconds += seconds
            }
            minutes[index] = minute
            cardiovascularLoad +=
                seconds / 60
                * calibration.loadPerMinute(
                    heartRate: sample.heartRate, maximumHeartRate: maximumHeartRate)
            observedSeconds += seconds
            cursor = sliceEnd
        }
    }

    /// Finalizes a completed day. Further samples are ignored; repeated finishes are idempotent.
    mutating func finish(day: String) -> StrainEstimate {
        isFinished = true
        if let previous {
            integrate(sample: previous, duration: min(6, end - previous.timestamp), steps: nil)
            self.previous = nil
        }
        let validWindow = start.isFinite && end.isFinite && end > start && end - start <= 90_000
        let coverage = validWindow ? min(max(observedSeconds / (end - start), 0), 1) : 0
        let strength = probableStrength()
        // Explicit engineering prior: a fully known 60-minute lift would contribute
        // 10 points in isolation. Heuristic detections receive only 35% of that load.
        // This is intentionally not presented as a fitted modern WHOOP muscular model.
        let referenceLoad = calibration.loadScale * expm1(10 / calibration.scoreScale)
        let muscularLoad = referenceLoad * strength.minutes / 60 * 0.35
        let usable = coverage >= 0.9 && observedSeconds >= 60 * 60
        return StrainEstimate(
            day: day, score: usable ? calibration.score(load: cardiovascularLoad + muscularLoad) : nil,
            cardiovascularScore: calibration.score(load: cardiovascularLoad),
            muscularScore: calibration.score(load: muscularLoad), coverage: coverage,
            observedSeconds: observedSeconds, probableStrengthMinutes: strength.minutes,
            probableStrengthSessions: strength.sessions,
            version: "\(Self.version)/\(calibration.version)",
            source: "direct_hr_with_probable_strength")
    }

    private func probableStrength() -> (minutes: Double, sessions: Int) {
        // Strength-like set/rest pattern: repeatedly elevated HR with little stepping.
        // Requires known awake state, complete minute coverage, and counter observations.
        // Cycling, chores, or stress can still resemble this; all detections stay provisional.
        guard start.isFinite, end.isFinite, end > start, end - start <= 90_000 else {
            return (0, 0)
        }
        let count = Int(ceil((end - start) / 60))
        guard count >= 20 else { return (0, 0) }
        var activeIndices: [Int] = []
        for index in 0..<count {
            guard let minute = minutes[index], minute.seconds >= 50,
                minute.stepObservedSeconds >= 50,
                minute.awakeSeconds >= minute.seconds * 0.9,
                minute.steps < 25,
                minute.heartRate >= restingHeartRate + 30,
                minute.heartRate < maximumHeartRate * 0.8
            else { continue }
            activeIndices.append(index)
        }
        var groups: [[Int]] = []
        for index in activeIndices {
            if let last = groups.last?.last, index - last <= 8 {
                groups[groups.count - 1].append(index)
            } else {
                groups.append([index])
            }
        }
        var totalMinutes = 0.0
        var sessions = 0
        for group in groups {
            guard let first = group.first, let last = group.last else { continue }
            let span = last - first + 1
            guard (25...120).contains(span), group.count >= 10 else { continue }
            let window = (first...last).compactMap { minutes[$0] }
            guard window.count == span, window.allSatisfy({ $0.seconds >= 50 }),
                window.reduce(0, { $0 + $1.steps }) / Double(span) < 20
            else { continue }
            var peaks = 0
            var lastPeak = -3
            for index in (first + 1)..<last {
                guard let a = minutes[index - 1], let b = minutes[index], let c = minutes[index + 1]
                else { continue }
                if index - lastPeak >= 3, b.heartRate >= restingHeartRate + 35,
                    b.heartRate - a.heartRate >= 10, b.heartRate - c.heartRate >= 10
                {
                    peaks += 1
                    lastPeak = index
                }
            }
            guard peaks >= 3 else { continue }
            totalMinutes += Double(group.count)
            sessions += 1
        }
        return (totalMinutes, sessions)
    }
}
