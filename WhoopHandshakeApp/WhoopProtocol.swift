import Foundation

enum WhoopFrameIntegrity {
    static func isValid(_ data: Data) -> Bool {
        isValid([UInt8](data))
    }

    static func isValid(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 12,
            bytes[0] == 0xAA,
            Int(UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)) + 8 == bytes.count
        else {
            return false
        }
        let expectedHeader = UInt16(bytes[6]) | (UInt16(bytes[7]) << 8)
        guard crc16Modbus(bytes[0..<6]) == expectedHeader else { return false }
        let payloadEnd = bytes.count - 4
        let expected =
            UInt32(bytes[payloadEnd])
            | (UInt32(bytes[payloadEnd + 1]) << 8)
            | (UInt32(bytes[payloadEnd + 2]) << 16)
            | (UInt32(bytes[payloadEnd + 3]) << 24)
        return crc32(bytes[8..<payloadEnd]) == expected
    }

    static func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func crc16Modbus<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }
}

struct WhoopDecodedRealtime: Sendable {
    let deviceTimestamp: UInt32?
    let heartRate: Int
    let rrIntervals: [UInt16]
    let source: String

    static func decodeStandardHeartRate(_ data: Data) -> WhoopDecodedRealtime? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        let flags = bytes[0]
        let isUInt16 = flags & 0x01 != 0
        var index: Int
        let heartRate: Int
        if isUInt16 {
            guard bytes.count >= 3 else { return nil }
            heartRate = Int(UInt16(bytes[1]) | (UInt16(bytes[2]) << 8))
            index = 3
        } else {
            heartRate = Int(bytes[1])
            index = 2
        }
        guard (1...300).contains(heartRate) else { return nil }
        if flags & 0x08 != 0 {
            guard index + 1 < bytes.count else { return nil }
            index += 2
        }
        var intervals: [UInt16] = []
        if flags & 0x10 != 0 {
            while index + 1 < bytes.count {
                let ticks = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                let milliseconds = (Double(ticks) / 1024 * 1_000).rounded()
                if milliseconds > 0, milliseconds <= Double(UInt16.max) {
                    intervals.append(UInt16(milliseconds))
                }
                index += 2
            }
        }
        return WhoopDecodedRealtime(
            deviceTimestamp: nil,
            heartRate: heartRate,
            rrIntervals: intervals,
            source: "standard_2a37"
        )
    }

    static func decodeWhoop5Realtime(_ data: Data) -> WhoopDecodedRealtime? {
        let bytes = [UInt8](data)
        return decodeWhoop5Realtime(
            bytes: bytes,
            integrityIsValid: WhoopFrameIntegrity.isValid(bytes)
        )
    }

    static func decodeWhoop5Realtime(
        bytes: [UInt8],
        integrityIsValid: Bool
    ) -> WhoopDecodedRealtime? {
        guard bytes.count >= 22,
            FrameType(rawValue: bytes[8]) == .realtimeHeartRate,
            integrityIsValid
        else { return nil }
        let count = min(Int(bytes[17]), (bytes.count - 22) / 2)
        var intervals: [UInt16] = []
        intervals.reserveCapacity(count)
        for index in 0..<count {
            let offset = 18 + index * 2
            let value = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            if value > 0 { intervals.append(value) }
        }
        let timestamp =
            UInt32(bytes[10])
            | (UInt32(bytes[11]) << 8)
            | (UInt32(bytes[12]) << 16)
            | (UInt32(bytes[13]) << 24)
        let heartRate = Int(bytes[16])
        guard heartRate > 0 else { return nil }
        return WhoopDecodedRealtime(
            deviceTimestamp: timestamp,
            heartRate: heartRate,
            rrIntervals: intervals,
            source: "whoop5_type40"
        )
    }
}

struct WhoopDecodedHistorical: Sendable {
    let sampleAt: Date
    let heartRate: Int
    let rrIntervals: [UInt16]
    let sleepState: SleepState
    /// Candidate WHOOP 5 motion fields retained with their wire-level meaning.
    /// The counter is cumulative and must be differenced with UInt16 wrapping;
    /// neither cadence nor class is assigned an invented physical unit.
    let stepMotionCounter: UInt16
    let stepCadenceRaw: UInt8
    let motionClassRaw: UInt8

    /// WHOOP 5 v18 offsets cross-checked against the independent NOOP and Goose
    /// implementations before enabling the destructive-on-ACK history trim.
    /// https://github.com/ryanbr/noop/blob/main/docs/BLE_REVERSE_ENGINEERING.md
    static func decode(_ data: Data) -> WhoopDecodedHistorical? {
        let bytes = [UInt8](data)
        return decode(
            bytes: bytes,
            integrityIsValid: WhoopFrameIntegrity.isValid(bytes)
        )
    }

    static func decode(
        bytes: [UInt8],
        integrityIsValid: Bool
    ) -> WhoopDecodedHistorical? {
        guard bytes.count == 124,
            FrameType(rawValue: bytes[8]) == .historicalSample,
            bytes[9] == 18,
            integrityIsValid
        else { return nil }
        let timestamp =
            UInt32(bytes[15])
            | (UInt32(bytes[16]) << 8)
            | (UInt32(bytes[17]) << 16)
            | (UInt32(bytes[18]) << 24)
        let count = min(Int(bytes[23]), 4)
        var intervals: [UInt16] = []
        for index in 0..<count {
            let offset = 24 + index * 2
            let value = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            if value > 0 { intervals.append(value) }
        }
        return WhoopDecodedHistorical(
            sampleAt: Date(timeIntervalSince1970: TimeInterval(timestamp)),
            heartRate: Int(bytes[22]),
            rrIntervals: intervals,
            sleepState: SleepState(rawValue: Int((bytes[81] >> 4) & 3)),
            stepMotionCounter: UInt16(bytes[57]) | (UInt16(bytes[58]) << 8),
            stepCadenceRaw: bytes[59],
            motionClassRaw: bytes[63]
        )
    }

    /// Why a stored type-47 packet did not become a historical sample. Used by
    /// the diagnostics to tell sparse strap data apart from frames this app
    /// silently drops after the destructive chunk acknowledgement.
    static func decodeFailureReason(_ data: Data) -> String {
        let bytes = [UInt8](data)
        guard bytes.count >= 10 else { return "shorter than 10 bytes" }
        if bytes.count != 124 { return "length \(bytes.count), expected 124" }
        if FrameType(rawValue: bytes[8]) != .historicalSample {
            return "type \(bytes[8]), expected 47"
        }
        if bytes[9] != 18 { return "version \(bytes[9]), expected 18" }
        if !WhoopFrameIntegrity.isValid(data) { return "CRC mismatch" }
        return "decodes"
    }
}

struct WhoopStepCounterSample: Sendable, Equatable {
    let timestamp: TimeInterval
    let counter: UInt16
}

struct WhoopStepDaySummary: Sendable, Equatable {
    /// Version 2 changes the day boundary from civil midnight to the latest
    /// published wake. Counter math is otherwise unchanged.
    static let algorithmVersion = 2
    /// A deliberately permissive physiological ceiling. Values above it are
    /// treated as counter resets/corruption rather than tens of thousands of
    /// fabricated steps; ordinary walk/run deltas are far below this bound.
    static let maximumStepsPerSecond = 8.0

    let stepCount: Int
    let sampleCount: Int
    let spanSeconds: Int
    let coverageFraction: Double
    let gapSeconds: Int
    let counterWrapCount: Int
    let rejectedDeltaCount: Int
    let firstSampleAt: TimeInterval?
    let lastSampleAt: TimeInterval?

    static func summarize(_ input: [WhoopStepCounterSample]) -> WhoopStepDaySummary {
        let sorted = input.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp { return lhs.counter < rhs.counter }
            return lhs.timestamp < rhs.timestamp
        }
        var samples: [WhoopStepCounterSample] = []
        samples.reserveCapacity(sorted.count)
        for sample in sorted {
            if samples.last?.timestamp == sample.timestamp {
                samples[samples.count - 1] = sample
            } else {
                samples.append(sample)
            }
        }

        guard let first = samples.first, let last = samples.last else {
            return WhoopStepDaySummary(
                stepCount: 0,
                sampleCount: 0,
                spanSeconds: 0,
                coverageFraction: 0,
                gapSeconds: 0,
                counterWrapCount: 0,
                rejectedDeltaCount: 0,
                firstSampleAt: nil,
                lastSampleAt: nil
            )
        }

        var steps = 0
        var gapSeconds = 0
        var wraps = 0
        var rejected = 0
        for (previous, current) in zip(samples, samples.dropFirst()) {
            let elapsed = current.timestamp - previous.timestamp
            guard elapsed > 0 else { continue }
            gapSeconds += max(0, Int(elapsed.rounded(.down)) - 1)
            let delta = Int(current.counter &- previous.counter)
            let maximumPlausible = max(8, Int(ceil(elapsed * maximumStepsPerSecond)))
            guard delta <= maximumPlausible else {
                rejected += 1
                continue
            }
            steps += delta
            if current.counter < previous.counter, delta > 0 { wraps += 1 }
        }

        let span = max(1, Int((last.timestamp - first.timestamp).rounded(.down)) + 1)
        return WhoopStepDaySummary(
            stepCount: steps,
            sampleCount: samples.count,
            spanSeconds: span,
            coverageFraction: min(1, Double(samples.count) / Double(span)),
            gapSeconds: gapSeconds,
            counterWrapCount: wraps,
            rejectedDeltaCount: rejected,
            firstSampleAt: first.timestamp,
            lastSampleAt: last.timestamp
        )
    }
}

struct WhoopWakeBoundary: Sendable, Equatable {
    let dateKey: DayKey
    let wokeAt: Date
}

enum WhoopPhysiologicalDay {
    /// A day starts only when a completed sleep is published. Until then,
    /// including after civil midnight and throughout sleep, movement remains
    /// part of the preceding wake-to-sleep day.
    static func dateKey(
        for sampleAt: Date,
        publishedWakes: [WhoopWakeBoundary],
        civilFallback: DayKey
    ) -> DayKey {
        var lower = 0
        var upper = publishedWakes.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if publishedWakes[middle].wokeAt <= sampleAt {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower > 0 ? publishedWakes[lower - 1].dateKey : civilFallback
    }
}

struct WhoopDecodedPPG: Sendable, Equatable {
    let sampleAt: Date
    let channel: Int
    let samples: [Int16]

    /// WHOOP 5 v26 is one second of 24 Hz AC-coupled optical data. Channel is
    /// retained as the firmware's raw non-zero index; no LED colour or
    /// physiological unit is invented. Harley's current firmware uses values
    /// beyond the 1...26 range seen in the original reference captures.
    static func decode(_ data: Data) -> WhoopDecodedPPG? {
        let bytes = [UInt8](data)
        return decode(
            bytes: bytes,
            integrityIsValid: WhoopFrameIntegrity.isValid(bytes)
        )
    }

    static func decode(
        bytes: [UInt8],
        integrityIsValid: Bool
    ) -> WhoopDecodedPPG? {
        guard bytes.count == 88,
            FrameType(rawValue: bytes[8]) == .historicalSample,
            bytes[9] == 26,
            bytes[21] != 0,
            integrityIsValid
        else { return nil }
        let timestamp =
            UInt32(bytes[15])
            | (UInt32(bytes[16]) << 8)
            | (UInt32(bytes[17]) << 16)
            | (UInt32(bytes[18]) << 24)
        var samples: [Int16] = []
        samples.reserveCapacity(24)
        for offset in stride(from: 27, to: 75, by: 2) {
            let raw = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            samples.append(Int16(bitPattern: raw))
        }
        return WhoopDecodedPPG(
            sampleAt: Date(timeIntervalSince1970: TimeInterval(timestamp)),
            channel: Int(bytes[21]),
            samples: samples
        )
    }
}
