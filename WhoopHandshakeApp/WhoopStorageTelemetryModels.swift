import Foundation

enum WhoopIngestionTelemetryOutcome: String, Codable, Sendable {
    case failed
    case retry
    case unique
}

struct WhoopFrameIngestionWindow: Codable, Equatable, Sendable {
    var uniqueDeliveries: Int64 = 0
    var suppressedRetries: Int64 = 0
    var failedDeliveries: Int64 = 0
    var retryDetectionDisabled: Int64 = 0
    var payloadBytes: Int64 = 0

    mutating func record(
        outcome: WhoopIngestionTelemetryOutcome,
        payloadBytes: Int,
        retryDetectionEnabled: Bool
    ) {
        switch outcome {
        case .failed: failedDeliveries += 1
        case .retry: suppressedRetries += 1
        case .unique: uniqueDeliveries += 1
        }
        if !retryDetectionEnabled { retryDetectionDisabled += 1 }
        self.payloadBytes += Int64(payloadBytes)
    }

    mutating func merge(_ other: Self) {
        uniqueDeliveries += other.uniqueDeliveries
        suppressedRetries += other.suppressedRetries
        failedDeliveries += other.failedDeliveries
        retryDetectionDisabled += other.retryDetectionDisabled
        payloadBytes += other.payloadBytes
    }
}

struct WhoopIngestionLatencyWindow: Codable, Equatable, Sendable {
    static let latencyBucketLabels = [
        "le_0_5_ms", "le_1_ms", "le_2_ms", "le_5_ms", "le_10_ms",
        "le_25_ms", "le_50_ms", "le_100_ms", "gt_100_ms",
    ]

    var deliveryCount: Int64 = 0
    var uniqueCount: Int64 = 0
    var retryCount: Int64 = 0
    var failedCount: Int64 = 0
    var totalNanoseconds: UInt64 = 0
    var maximumNanoseconds: UInt64 = 0
    var transactionLatencyBucketCounts = Array(repeating: Int64(0), count: 9)
    var queueWaitTotalNanoseconds: UInt64 = 0
    var queueWaitMaximumNanoseconds: UInt64 = 0
    var queueWaitBucketCounts = Array(repeating: Int64(0), count: 9)
    // Slots 0...255 are frame types. Slot 256 is unknown. A fixed array avoids
    // dictionary and String allocation on the packet-ingestion hot path.
    var frameOutcomes = Array(repeating: WhoopFrameIngestionWindow(), count: 257)

    mutating func record(
        outcome: WhoopIngestionTelemetryOutcome,
        transactionNanoseconds: UInt64,
        queueWaitNanoseconds: UInt64,
        frameType: UInt8?,
        payloadBytes: Int,
        retryDetectionEnabled: Bool
    ) {
        deliveryCount += 1
        switch outcome {
        case .failed: failedCount += 1
        case .retry: retryCount += 1
        case .unique: uniqueCount += 1
        }
        totalNanoseconds &+= transactionNanoseconds
        maximumNanoseconds = max(maximumNanoseconds, transactionNanoseconds)
        transactionLatencyBucketCounts[Self.bucketIndex(transactionNanoseconds)] += 1
        queueWaitTotalNanoseconds &+= queueWaitNanoseconds
        queueWaitMaximumNanoseconds = max(queueWaitMaximumNanoseconds, queueWaitNanoseconds)
        queueWaitBucketCounts[Self.bucketIndex(queueWaitNanoseconds)] += 1
        let frameIndex = frameType.map(Int.init) ?? 256
        frameOutcomes[frameIndex].record(
            outcome: outcome,
            payloadBytes: payloadBytes,
            retryDetectionEnabled: retryDetectionEnabled
        )
    }

    mutating func merge(_ other: Self) {
        deliveryCount += other.deliveryCount
        uniqueCount += other.uniqueCount
        retryCount += other.retryCount
        failedCount += other.failedCount
        totalNanoseconds &+= other.totalNanoseconds
        maximumNanoseconds = max(maximumNanoseconds, other.maximumNanoseconds)
        queueWaitTotalNanoseconds &+= other.queueWaitTotalNanoseconds
        queueWaitMaximumNanoseconds = max(queueWaitMaximumNanoseconds, other.queueWaitMaximumNanoseconds)
        for index in transactionLatencyBucketCounts.indices {
            transactionLatencyBucketCounts[index] += other.transactionLatencyBucketCounts[index]
            queueWaitBucketCounts[index] += other.queueWaitBucketCounts[index]
        }
        for index in frameOutcomes.indices { frameOutcomes[index].merge(other.frameOutcomes[index]) }
    }

    private static func bucketIndex(_ nanoseconds: UInt64) -> Int {
        switch nanoseconds {
        case ...500_000: 0
        case ...1_000_000: 1
        case ...2_000_000: 2
        case ...5_000_000: 3
        case ...10_000_000: 4
        case ...25_000_000: 5
        case ...50_000_000: 6
        case ...100_000_000: 7
        default: 8
        }
    }
}

struct WhoopFrameRetryTelemetry: Codable, Equatable, Sendable {
    let frameType: String
    let allHistoricalUniquePackets: Int64
    let retryEligibleUniquePackets: Int64
    let retries: Int64
}

struct WhoopStorageTelemetrySnapshot: Codable, Equatable, Sendable {
    let capturedAt: TimeInterval
    let schemaVersion: Int64
    let sourceCommit: String
    let databaseBytes: Int64
    let walBytes: Int64
    let sharedMemoryBytes: Int64
    let pageSize: Int64
    let pageCount: Int64
    let freelistPages: Int64
    let usedDatabaseBytes: Int64
    let uniquePackets: Int64
    let rawPayloadBytes: Int64
    let sourcePairCount: Int64
    let frameRetries: [WhoopFrameRetryTelemetry]
    let derivedTableRows: [String: Int64]
    let walCheckpointSequenceBefore: UInt32?
    let walCheckpointSequenceAfter: UInt32?
    let passiveCheckpointResult: Int32
    let walLogFrames: Int32
    let walCheckpointedFrames: Int32
    let passiveCheckpointNanoseconds: UInt64
    let snapshotCollectionNanoseconds: UInt64
    let persistenceFailureCount: Int64
    let censusFailureCount: Int64
    let ingestion: WhoopIngestionLatencyWindow

    var totalOnDiskBytes: Int64 { databaseBytes + walBytes + sharedMemoryBytes }
}

struct WhoopStorageFileSample: Codable, Equatable, Sendable {
    let capturedAt: TimeInterval
    let databaseBytes: Int64
    let walBytes: Int64
    let sharedMemoryBytes: Int64
    let walCheckpointSequence: UInt32?
}

struct WhoopStorageTelemetryDocument: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    var formatVersion: Int = currentFormatVersion
    var updatedAt: TimeInterval
    var snapshots: [WhoopStorageTelemetrySnapshot]
    var fileSamples: [WhoopStorageFileSample]
    var pendingIngestion: WhoopIngestionLatencyWindow
    // A crash-safe handoff while the daily census runs on another connection.
    var inFlightIngestion: WhoopIngestionLatencyWindow?
    /// Cumulative counters are sampled into every daily snapshot. Reports use
    /// endpoint deltas so a recovered old failure does not poison later windows.
    var writeFailureCount: Int64
    var censusFailureCount: Int64
}
