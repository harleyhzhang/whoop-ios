import Foundation

/// Low-rate R18 motion evidence, not exercise/repetition recognition.
struct WhoopStillnessSample: Sendable {
    let timestamp: TimeInterval
    let receivedAt: TimeInterval
    let acceleration: Double
    let sleepState: Int
}

/// Runs on sensor time; a decision separately requires fresh receipt-time
/// evidence. Gaps and ambiguous wake states never earn inactive time.
struct WhoopStillnessPolicy {
    struct Context {
        let now: TimeInterval
        let localHour: Int
        let connected: Bool
        let worn: Bool
        let sleeping: Bool
    }

    static let quietInterval: TimeInterval = 60 * 60
    static let sleepHold: TimeInterval = 90 * 60
    static let maximumSampleAge: TimeInterval = 5 * 60
    private let startedAt: TimeInterval
    private var latest: WhoopStillnessSample?
    private var lastSleepAt: TimeInterval?
    private var minute: Int?
    private var sampleCount = 0
    private var awakeCount = 0
    private var movingCount = 0
    private var quietSince: TimeInterval?
    private var nudged = false

    init(startedAt: TimeInterval) { self.startedAt = startedAt }

    mutating func observe(_ sample: WhoopStillnessSample) {
        guard sample.timestamp.isFinite, sample.receivedAt.isFinite,
            sample.acceleration.isFinite, (0...32).contains(sample.acceleration),
            sample.timestamp <= sample.receivedAt + 5,
            (0...3).contains(sample.sleepState)
        else {
            resetInterval()
            return
        }
        if sample.sleepState == 2 {
            lastSleepAt = max(lastSleepAt ?? sample.timestamp, sample.timestamp)
        }
        // Replayed pre-connection history can suppress sleep, but cannot earn
        // a nudge immediately after launch or reconnect.
        guard sample.timestamp >= startedAt,
            latest.map({ sample.timestamp > $0.timestamp }) ?? true
        else { return }
        if let latest, sample.timestamp - latest.timestamp > 120 {
            resetInterval()
        }
        let nextMinute = Int(sample.timestamp / 60)
        if let minute, nextMinute != minute {
            finishMinute(minute)
            sampleCount = 0
            awakeCount = 0
            movingCount = 0
            if nextMinute != minute + 1 { resetInterval() }
        }
        minute = nextMinute
        sampleCount += 1
        if sample.sleepState == 0 { awakeCount += 1 }
        if sample.acceleration >= 0.3 { movingCount += 1 }
        latest = sample
    }

    mutating func takeNudge(_ context: Context) -> Bool {
        guard context.now.isFinite, context.connected, context.worn, !context.sleeping,
            (10..<22).contains(context.localHour), !nudged, movingCount < 20,
            let latest, latest.sleepState == 0,
            (0...Self.maximumSampleAge).contains(context.now - latest.timestamp),
            (0...Self.maximumSampleAge).contains(context.now - latest.receivedAt),
            lastSleepAt.map({ context.now - $0 > Self.sleepHold }) ?? true,
            let quietSince, let minute,
            Double(minute * 60) - quietSince >= Self.quietInterval
        else { return false }
        nudged = true
        return true
    }

    private mutating func finishMinute(_ minute: Int) {
        // At least 45 seconds of explicitly awake data. Sustained motion
        // (20 one-second summaries >= 0.3) re-arms the next still stretch.
        // This is a conservative heuristic in raw summary units, not a
        // calibrated exercise/step counter or posture classifier.
        guard sampleCount >= 45, awakeCount >= 45, movingCount < 20 else {
            quietSince = nil
            nudged = false
            return
        }
        if quietSince == nil { quietSince = Double(minute * 60) }
    }

    private mutating func resetInterval() {
        minute = nil
        sampleCount = 0
        awakeCount = 0
        movingCount = 0
        quietSince = nil
        nudged = false
    }
}
