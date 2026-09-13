import Foundation
import SQLite3

/// Bounded, fail-open storage telemetry. Exact hot-path counters stay on the
/// store queue; expensive daily SQL runs asynchronously on a second connection.
final class WhoopStorageTelemetry: @unchecked Sendable {
    static let minimumSnapshotInterval: TimeInterval = 20 * 60 * 60
    static let maximumSnapshots = 10
    static let fileSampleInterval: TimeInterval = 15 * 60
    static let maximumFileSamples = 8 * 24 * 4
    static let pendingPersistenceStride: Int64 = 4_096
    static let pendingPersistenceInterval: TimeInterval = 30 * 60
    static let failedCensusRetryInterval: TimeInterval = 30 * 60

    let reportURL: URL
    private let databaseURL: URL
    private let ownerQueue: DispatchQueue
    private let censusQueue = DispatchQueue(
        label: "com.clintonst.sleep.storage-telemetry-census", qos: .utility
    )
    private var document: WhoopStorageTelemetryDocument
    private var lastPersistenceAttemptAt: TimeInterval
    private var lastCensusAttemptAt: TimeInterval?
    private var censusRunning = false

    init(databaseURL: URL, ownerQueue: DispatchQueue, now: Date = .now) {
        self.databaseURL = databaseURL
        self.ownerQueue = ownerQueue
        reportURL = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("storage-telemetry-v1.json")
        var loaded = Self.loadDocument(from: reportURL)
        if let interrupted = loaded?.inFlightIngestion {
            loaded?.pendingIngestion.merge(interrupted)
            loaded?.inFlightIngestion = nil
        }
        document =
            loaded
            ?? WhoopStorageTelemetryDocument(
                updatedAt: now.timeIntervalSince1970,
                snapshots: [],
                fileSamples: [],
                pendingIngestion: WhoopIngestionLatencyWindow(),
                inFlightIngestion: nil,
                writeFailureCount: 0,
                censusFailureCount: 0
            )
        lastPersistenceAttemptAt = document.updatedAt
        lastCensusAttemptAt = document.snapshots.last?.capturedAt
    }

    func recordIngestion(
        outcome: WhoopIngestionTelemetryOutcome,
        transactionNanoseconds: UInt64,
        queueWaitNanoseconds: UInt64,
        frameType: UInt8?,
        payloadBytes: Int,
        retryDetectionEnabled: Bool,
        now: Date
    ) {
        document.pendingIngestion.record(
            outcome: outcome,
            transactionNanoseconds: transactionNanoseconds,
            queueWaitNanoseconds: queueWaitNanoseconds,
            frameType: frameType,
            payloadBytes: payloadBytes,
            retryDetectionEnabled: retryDetectionEnabled
        )
        captureIfDue(now: now)
        let shouldPersistCount =
            document.pendingIngestion.deliveryCount
            > 0
            && document.pendingIngestion.deliveryCount.isMultiple(
                of: Self.pendingPersistenceStride
            )
        let shouldPersistTime =
            now.timeIntervalSince1970 - lastPersistenceAttemptAt
            >= Self.pendingPersistenceInterval
        let shouldSampleFiles = fileSampleIsDue(now: now)
        if shouldPersistCount || shouldPersistTime || shouldSampleFiles {
            if shouldSampleFiles { appendFileSample(now: now) }
            persist(now: now)
        }
    }

    func captureIfDue(now: Date = .now) {
        guard !censusRunning else { return }
        guard
            Self.censusIsDue(
                lastAttemptAt: lastCensusAttemptAt,
                lastSnapshotAt: document.snapshots.last?.capturedAt,
                now: now.timeIntervalSince1970
            )
        else { return }

        censusRunning = true
        lastCensusAttemptAt = now.timeIntervalSince1970
        let ingestion = document.pendingIngestion
        document.pendingIngestion = WhoopIngestionLatencyWindow()
        document.inFlightIngestion = ingestion
        guard persist(now: now) else {
            document.pendingIngestion = ingestion
            document.inFlightIngestion = nil
            censusRunning = false
            return
        }
        let databaseURL = databaseURL
        let persistenceFailureCount = document.writeFailureCount
        let censusFailureCount = document.censusFailureCount
        censusQueue.async { [weak self] in
            let snapshot = WhoopStorageTelemetryCensus.capture(
                databaseURL: databaseURL,
                ingestion: ingestion,
                persistenceFailureCount: persistenceFailureCount,
                censusFailureCount: censusFailureCount,
                now: now
            )
            self?.ownerQueue.async { [weak self] in self?.completeCensus(snapshot, now: now) }
        }
    }

    func flush(now: Date = .now) {
        if fileSampleIsDue(now: now) { appendFileSample(now: now) }
        persist(now: now)
    }

    #if DEBUG
        @discardableResult
        func captureSynchronouslyForTesting(database: OpaquePointer, now: Date) -> Bool {
            guard
                let snapshot = WhoopStorageTelemetryCensus.capture(
                    database: database,
                    databaseURL: databaseURL,
                    ingestion: document.pendingIngestion,
                    persistenceFailureCount: document.writeFailureCount,
                    censusFailureCount: document.censusFailureCount,
                    now: now
                )
            else { return false }
            document.pendingIngestion = WhoopIngestionLatencyWindow()
            append(snapshot, now: now)
            return true
        }
    #endif

    private func completeCensus(_ snapshot: WhoopStorageTelemetrySnapshot?, now: Date) {
        censusRunning = false
        guard let snapshot else {
            if let inFlight = document.inFlightIngestion { document.pendingIngestion.merge(inFlight) }
            document.inFlightIngestion = nil
            document.censusFailureCount += 1
            persist(now: now)
            return
        }
        document.inFlightIngestion = nil
        append(snapshot, now: now)
    }

    private func append(_ snapshot: WhoopStorageTelemetrySnapshot, now: Date) {
        document.snapshots.append(snapshot)
        if document.snapshots.count > Self.maximumSnapshots {
            document.snapshots.removeFirst(document.snapshots.count - Self.maximumSnapshots)
        }
        appendFileSample(now: now)
        persist(now: now)
    }

    private func fileSampleIsDue(now: Date) -> Bool {
        document.fileSamples.last.map {
            now.timeIntervalSince1970 - $0.capturedAt >= Self.fileSampleInterval
        } ?? true
    }

    private func appendFileSample(now: Date) {
        guard fileSampleIsDue(now: now) else { return }
        document.fileSamples.append(
            WhoopStorageTelemetryCensus.makeFileSample(databaseURL: databaseURL, now: now)
        )
        if document.fileSamples.count > Self.maximumFileSamples {
            document.fileSamples.removeFirst(document.fileSamples.count - Self.maximumFileSamples)
        }
    }

    @discardableResult
    private func persist(now: Date) -> Bool {
        document.updatedAt = now.timeIntervalSince1970
        lastPersistenceAttemptAt = document.updatedAt
        guard let data = try? JSONEncoder().encode(document) else {
            document.writeFailureCount += 1
            return false
        }
        do {
            try data.write(to: reportURL, options: .atomic)
            try FileManager.default.setAttributes(
                [
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                    .posixPermissions: 0o600,
                ],
                ofItemAtPath: reportURL.path
            )
            return true
        } catch {
            document.writeFailureCount += 1
            return false
        }
    }

    private static func loadDocument(from url: URL) -> WhoopStorageTelemetryDocument? {
        guard let data = try? Data(contentsOf: url),
            let document = try? JSONDecoder().decode(WhoopStorageTelemetryDocument.self, from: data),
            document.formatVersion == WhoopStorageTelemetryDocument.currentFormatVersion,
            valid(window: document.pendingIngestion),
            document.inFlightIngestion.map({ valid(window: $0) }) ?? true,
            document.snapshots.allSatisfy({ valid(window: $0.ingestion) })
        else { return nil }
        return document
    }

    private static func valid(window: WhoopIngestionLatencyWindow) -> Bool {
        window.transactionLatencyBucketCounts.count == 9
            && window.queueWaitBucketCounts.count == 9
            && window.frameOutcomes.count == 257
    }

    static func censusIsDue(
        lastAttemptAt: TimeInterval?,
        lastSnapshotAt: TimeInterval?,
        now: TimeInterval
    ) -> Bool {
        if let lastAttemptAt, now - lastAttemptAt < failedCensusRetryInterval { return false }
        if let lastSnapshotAt, now - lastSnapshotAt < minimumSnapshotInterval { return false }
        return true
    }
}
