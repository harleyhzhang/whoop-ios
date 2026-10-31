import Foundation

/// Personal cardiovascular calibration. Fitted coefficients stay in private build output.
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
}

/// A heart-rate exposure estimate, never an inferred workout or muscular-load score.
struct StrainEstimate: Codable, Sendable {
    let day: String
    let score: Double?
    let cardiovascularScore: Double
    let coverage: Double
    let observedSeconds: Double
    let version: String
    let source: String
}

/// Streaming bounded-memory integration. No guessed lifting, missing-HR
/// extrapolation or additional load derived from motion/sleep labels.
struct StrainAccumulator {
    static let version = "local_strain_v3_cardio_zero_fill"
    static let maximumObservationSeconds = 6.0
    let calibration: StrainCalibration
    let start: Double
    let end: Double
    let maximumHeartRate: Double
    private var previous: StrainSample?
    private var recentHeartRates: [Double] = []
    private var cardiovascularLoad = 0.0
    private var observedSeconds = 0.0
    private var lastTimestamp: Double?
    private var isFinished = false

    init(calibration: StrainCalibration, start: Double, end: Double, maximumHeartRate: Double) {
        self.calibration = calibration
        self.start = start
        self.end = end
        self.maximumHeartRate = maximumHeartRate
    }

    private var isUsable: Bool {
        calibration.isValid && start.isFinite && end.isFinite
            && end > start && end - start <= 90_000
            && maximumHeartRate.isFinite && (90...230).contains(maximumHeartRate)
    }

    mutating func append(_ sample: StrainSample) {
        guard !isFinished, isUsable,
            sample.timestamp.isFinite, sample.timestamp >= start, sample.timestamp < end,
            lastTimestamp.map({ sample.timestamp > $0 }) ?? true
        else { return }
        lastTimestamp = sample.timestamp
        if let previous {
            let gap = sample.timestamp - previous.timestamp
            integrate(previous, duration: min(gap, Self.maximumObservationSeconds))
            if gap > Self.maximumObservationSeconds { recentHeartRates.removeAll(keepingCapacity: true) }
        }
        guard sample.heartRate.isFinite, (30...240).contains(sample.heartRate) else {
            previous = nil
            recentHeartRates.removeAll(keepingCapacity: true)
            return
        }
        recentHeartRates.append(sample.heartRate)
        if recentHeartRates.count > 5 { recentHeartRates.removeFirst() }
        let ordered = recentHeartRates.sorted()
        previous = StrainSample(timestamp: sample.timestamp, heartRate: ordered[ordered.count / 2])
    }

    private mutating func integrate(_ sample: StrainSample, duration: Double) {
        let seconds = max(0, min(duration, end - sample.timestamp))
        cardiovascularLoad +=
            seconds / 60
            * calibration.loadPerMinute(
                heartRate: sample.heartRate, maximumHeartRate: maximumHeartRate)
        observedSeconds += seconds
    }

    /// Repeated finishes are idempotent; further samples cannot alter this window.
    mutating func finish(day: String) -> StrainEstimate {
        isFinished = true
        if let previous {
            integrate(previous, duration: Self.maximumObservationSeconds)
            self.previous = nil
        }
        let score = calibration.score(load: cardiovascularLoad)
        return StrainEstimate(
            day: day, score: isUsable ? score : nil, cardiovascularScore: score,
            coverage: isUsable ? min(max(observedSeconds / (end - start), 0), 1) : 0,
            observedSeconds: observedSeconds,
            version: "\(Self.version)/\(calibration.version)", source: "direct_hr_cardiovascular")
    }
}
