import Foundation
import SQLite3

struct WhoopTransportUISnapshot: Sendable {
    let heartRate: Int?
    let heartRateReceivedAt: Date?
    let batteryObservation: BatteryObservation?
}

struct WhoopTransportPressureSnapshot: Equatable, Sendable {
    let isBackpressured: Bool
    let queuedEnvelopeCount: Int
    let capacity: Int
}

struct WhoopTransportMetadataEvent: Sendable {
    let type: MetadataType
    let chunkEndData: [UInt8]?
    let diagnostic: String
}

struct WhoopTransportBatchSummary: Sendable {
    let offloadSessionID: String?
    let firstProprietaryOrdinal: Int?
    let lastProprietaryOrdinal: Int?
    let latestHistoricalSampleAt: Date?
    let latestWristState: Bool?
    let metadataEvents: [WhoopTransportMetadataEvent]

    init(envelopes: [WhoopPacketEnvelope]) {
        offloadSessionID = envelopes.compactMap(\.offloadSessionID).last
        let ordinals = envelopes.compactMap(\.proprietaryOrdinal)
        firstProprietaryOrdinal = ordinals.first
        lastProprietaryOrdinal = ordinals.last
        latestHistoricalSampleAt = envelopes.compactMap(\.historical?.sampleAt).max()
        latestWristState = envelopes.compactMap(\.freshWristState).last
        metadataEvents = envelopes.compactMap { envelope in
            guard let metadata = envelope.metadata else { return nil }
            let preview = envelope.packet.prefix(24)
                .map { String(format: "%02X", $0) }
                .joined(separator: " ")
            let suffix = envelope.packet.count > 24 ? " …" : ""
            return WhoopTransportMetadataEvent(
                type: metadata.type,
                chunkEndData: metadata.chunkEndData,
                diagnostic:
                    "WHOOP metadata packet #\(envelope.proprietaryOrdinal ?? 0) on "
                    + "\(envelope.characteristicUUID), \(envelope.packet.count) bytes: "
                    + preview + suffix
            )
        }
    }
}

/// Deterministic bounded batching policy. Chunk terminators are always the last
/// packet in their transaction, so their successful completion is safe to ACK.
struct WhoopPacketBatcher {
    static let defaultMaximumBatchSize = 128

    private(set) var pending: [WhoopPacketEnvelope] = []
    let maximumBatchSize: Int

    init(maximumBatchSize: Int = defaultMaximumBatchSize) {
        self.maximumBatchSize = max(1, maximumBatchSize)
        pending.reserveCapacity(self.maximumBatchSize)
    }

    mutating func ingest(_ envelope: WhoopPacketEnvelope) -> [WhoopPacketEnvelope]? {
        pending.append(envelope)
        let isControlBoundary = envelope.metadata != nil
        guard pending.count >= maximumBatchSize || isControlBoundary else { return nil }
        return drain()
    }

    mutating func drain() -> [WhoopPacketEnvelope]? {
        guard !pending.isEmpty else { return nil }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        return batch
    }
}

/// Owns all packet decoding, integrity checks, burst coalescing, and persistence
/// submission on one FIFO queue. CoreBluetooth lifecycle remains on the main
/// actor, but its value callback performs no protocol work.
final class WhoopTransportPipeline: @unchecked Sendable {
    static let defaultIdleFlushDelay: TimeInterval = 0.15
    static let defaultUISnapshotInterval: TimeInterval = 0.5

    private let queue = DispatchQueue(
        label: "whoop.whoop-transport",
        qos: .userInitiated
    )
    private let queueSpecificKey = DispatchSpecificKey<Void>()
    static let defaultMaximumQueuedEnvelopeCount = 4_096
    static let defaultPersistenceRetryLimit = 3

    private let store: any WhoopPacketPersisting
    private let idleFlushDelay: TimeInterval
    private let uiSnapshotInterval: TimeInterval
    private let maximumQueuedEnvelopeCount: Int
    private let persistenceRetryLimit: Int
    private let persistenceRetryDelay: @Sendable (Int) -> TimeInterval
    private let didPublishUI: @Sendable (WhoopTransportUISnapshot) -> Void
    private let didPersist:
        @Sendable (
            WhoopPacketBatchPersistenceResult,
            WhoopTransportBatchSummary
        ) -> Void
    private let didChangePressure: @Sendable (WhoopTransportPressureSnapshot) -> Void
    private var batcher: WhoopPacketBatcher
    private var proprietaryPacketCount = 0
    private var lastCompletedOffloadSessionID: String?
    private var idleFlushGeneration: UInt64 = 0
    private var uiPublishGeneration: UInt64 = 0
    private var inFlightBatchCount = 0
    private var pendingPersistenceBatches: [[WhoopPacketEnvelope]] = []
    private var pendingPersistenceHead = 0
    private var queuedEnvelopeCount = 0
    private var persistenceIsActive = false
    private var failedHistorySessionID: String?
    private var lastPressureState = false
    private var drainWaiters: [@Sendable () -> Void] = []
    private var lastUISnapshotAt: Date?
    private var pendingUI = PendingUI()
    private var latestBatteryLevel: Int?
    private var latestBatteryStatus = BatteryStatus.unavailable

    init(
        store: any WhoopPacketPersisting,
        maximumBatchSize: Int = WhoopPacketBatcher.defaultMaximumBatchSize,
        maximumQueuedEnvelopeCount: Int = defaultMaximumQueuedEnvelopeCount,
        persistenceRetryLimit: Int = defaultPersistenceRetryLimit,
        persistenceRetryDelay: @escaping @Sendable (Int) -> TimeInterval = {
            WhoopStorageRetryPolicy.delaySeconds(forAttempt: $0)
        },
        idleFlushDelay: TimeInterval = defaultIdleFlushDelay,
        uiSnapshotInterval: TimeInterval = defaultUISnapshotInterval,
        didPublishUI: @escaping @Sendable (WhoopTransportUISnapshot) -> Void,
        didPersist:
            @escaping @Sendable (
                WhoopPacketBatchPersistenceResult,
                WhoopTransportBatchSummary
            ) -> Void,
        didChangePressure: @escaping @Sendable (WhoopTransportPressureSnapshot) -> Void = { _ in }
    ) {
        self.store = store
        self.batcher = WhoopPacketBatcher(maximumBatchSize: maximumBatchSize)
        self.idleFlushDelay = idleFlushDelay
        self.uiSnapshotInterval = uiSnapshotInterval
        self.maximumQueuedEnvelopeCount = max(maximumBatchSize, maximumQueuedEnvelopeCount)
        self.persistenceRetryLimit = max(0, persistenceRetryLimit)
        self.persistenceRetryDelay = persistenceRetryDelay
        self.didPublishUI = didPublishUI
        self.didPersist = didPersist
        self.didChangePressure = didChangePressure
        queue.setSpecific(key: queueSpecificKey, value: ())
    }

    func submitStandardHeartRate(
        packet: Data,
        peripheralID: UUID,
        characteristicUUID: String,
        deliveredAt: Date
    ) {
        queue.async { [self] in
            guard
                let envelope = WhoopPacketEnvelope.standardHeartRate(
                    packet: packet,
                    peripheralID: peripheralID,
                    characteristicUUID: characteristicUUID,
                    deliveredAt: deliveredAt
                )
            else { return }
            publishHeartRate(envelope.realtime, deliveredAt: deliveredAt)
            enqueue(envelope)
        }
    }

    func submitProprietary(
        packet: Data,
        peripheralID: UUID,
        characteristicUUID: String,
        offloadSessionID: String?,
        deliveredAt: Date
    ) {
        queue.async { [self] in
            proprietaryPacketCount += 1
            let effectiveSessionID =
                offloadSessionID == lastCompletedOffloadSessionID ? nil : offloadSessionID
            let envelope = WhoopPacketEnvelope.proprietary(
                packet: packet,
                peripheralID: peripheralID,
                characteristicUUID: characteristicUUID,
                offloadSessionID: effectiveSessionID,
                deliveredAt: deliveredAt,
                proprietaryOrdinal: proprietaryPacketCount
            )
            if envelope.metadata?.type == .historyComplete {
                lastCompletedOffloadSessionID = effectiveSessionID
            } else if envelope.metadata?.type == .historyStart {
                lastCompletedOffloadSessionID = nil
            }
            publishHeartRate(envelope.realtime, deliveredAt: deliveredAt)
            enqueue(envelope)
        }
    }

    func submitBatteryLevel(_ data: Data, deliveredAt: Date) {
        queue.async { [self] in
            guard let level = data.first else { return }
            latestBatteryLevel = Int(level)
            pendingUI.batteryObservation = BatteryObservation(
                level: latestBatteryLevel,
                status: latestBatteryStatus
            )
            publishUIIfDue(now: deliveredAt)
        }
    }

    func submitBatteryLevelStatus(_ data: Data, deliveredAt: Date) {
        queue.async { [self] in
            guard let status = WhoopBluetoothPolicy.batteryLevelStatus(data) else { return }
            latestBatteryStatus = status
            pendingUI.batteryObservation = BatteryObservation(
                level: latestBatteryLevel,
                status: latestBatteryStatus
            )
            publishUIIfDue(now: deliveredAt)
        }
    }

    func submitLegacyBatteryStatus(_ data: Data, deliveredAt: Date) {
        queue.async { [self] in
            guard let status = WhoopBluetoothPolicy.legacyBatteryStatus(data) else { return }
            latestBatteryStatus = status
            pendingUI.batteryObservation = BatteryObservation(
                level: latestBatteryLevel,
                status: latestBatteryStatus
            )
            publishUIIfDue(now: deliveredAt)
        }
    }

    func flush() {
        queue.async { [self] in flushPending() }
    }

    func flushAndWaitForPersistence(
        _ completion: @escaping @Sendable () -> Void
    ) {
        queue.async { [self] in
            flushPending()
            if inFlightBatchCount == 0 {
                completion()
            } else {
                drainWaiters.append(completion)
            }
        }
    }

    private func enqueue(_ envelope: WhoopPacketEnvelope) {
        requireQueue()
        if let batch = batcher.ingest(envelope) {
            persist(batch)
        } else {
            scheduleIdleFlush()
        }
    }

    private func scheduleIdleFlush() {
        requireQueue()
        idleFlushGeneration &+= 1
        let generation = idleFlushGeneration
        queue.asyncAfter(deadline: .now() + idleFlushDelay) { [self] in
            guard generation == idleFlushGeneration else { return }
            flushPending()
        }
    }

    private func flushPending() {
        requireQueue()
        idleFlushGeneration &+= 1
        guard let batch = batcher.drain() else { return }
        persist(batch)
    }

    private func persist(_ batch: [WhoopPacketEnvelope]) {
        requireQueue()
        guard queuedEnvelopeCount + batch.count <= maximumQueuedEnvelopeCount else {
            let summary = WhoopTransportBatchSummary(envelopes: batch)
            if let sessionID = summary.offloadSessionID {
                failedHistorySessionID = sessionID
            }
            let failure = WhoopStorageFailure(
                operation: .insert,
                kind: .full,
                primaryCode: SQLITE_FULL,
                extendedCode: SQLITE_FULL,
                detail: "transport persistence buffer reached \(maximumQueuedEnvelopeCount) envelopes"
            )
            didPersist(
                WhoopPacketBatchPersistenceResult(
                    success: false,
                    deliverySequences: [],
                    failure: failure
                ),
                summary
            )
            publishPressure(isBackpressured: true)
            return
        }
        pendingPersistenceBatches.append(batch)
        queuedEnvelopeCount += batch.count
        inFlightBatchCount += 1
        publishPressure(isBackpressured: queuedEnvelopeCount >= maximumQueuedEnvelopeCount)
        startNextPersistenceBatchIfNeeded()
    }

    private func startNextPersistenceBatchIfNeeded() {
        requireQueue()
        guard !persistenceIsActive, pendingPersistenceHead < pendingPersistenceBatches.count else {
            return
        }
        persistenceIsActive = true
        let batch = pendingPersistenceBatches[pendingPersistenceHead]
        pendingPersistenceHead += 1
        compactPendingPersistenceStorageIfNeeded()
        let summary = WhoopTransportBatchSummary(envelopes: batch)
        if summary.metadataEvents.contains(where: { $0.type == .historyStart }) {
            failedHistorySessionID = nil
        }
        let endsLogicalHistoryBoundary = summary.metadataEvents.contains {
            $0.type == .chunkEnd || $0.type == .historyComplete
        }
        let boundaryHasPriorFailure =
            failedHistorySessionID.map { $0 == summary.offloadSessionID } ?? false
        // If an earlier bounded transaction in this logical band chunk failed,
        // retain the raw boundary packet but do not let it advance or complete
        // the offload session. The band must replay the chunk before an ACK or
        // HISTORY_COMPLETE transition can be considered durable.
        let persistenceBatch =
            endsLogicalHistoryBoundary && boundaryHasPriorFailure
            ? batch.map { $0.replacingOffloadSessionID(nil) }
            : batch
        submitPersistence(
            persistenceBatch,
            originalEnvelopeCount: batch.count,
            summary: summary,
            endsLogicalHistoryBoundary: endsLogicalHistoryBoundary,
            boundaryHasPriorFailure: boundaryHasPriorFailure,
            retryAttempt: 0
        )
    }

    private func submitPersistence(
        _ persistenceBatch: [WhoopPacketEnvelope],
        originalEnvelopeCount: Int,
        summary: WhoopTransportBatchSummary,
        endsLogicalHistoryBoundary: Bool,
        boundaryHasPriorFailure: Bool,
        retryAttempt: Int
    ) {
        store.appendBatch(persistenceBatch) { [weak self] result in
            guard let self else { return }
            self.queue.async { [self] in
                if let failure = result.failure,
                    failure.isTransient,
                    retryAttempt < persistenceRetryLimit
                {
                    let nextAttempt = retryAttempt + 1
                    let delay = persistenceRetryDelay(retryAttempt)
                    queue.asyncAfter(deadline: .now() + delay) { [self] in
                        submitPersistence(
                            persistenceBatch,
                            originalEnvelopeCount: originalEnvelopeCount,
                            summary: summary,
                            endsLogicalHistoryBoundary: endsLogicalHistoryBoundary,
                            boundaryHasPriorFailure: boundaryHasPriorFailure,
                            retryAttempt: nextAttempt
                        )
                    }
                    return
                }
                if !result.success, let offloadSessionID = summary.offloadSessionID {
                    failedHistorySessionID = offloadSessionID
                }
                let boundaryIsDurable =
                    !endsLogicalHistoryBoundary
                    || (result.success && !boundaryHasPriorFailure)
                let publishedResult =
                    boundaryIsDurable
                    ? result
                    : WhoopPacketBatchPersistenceResult(
                        success: false,
                        deliverySequences: [],
                        failure: result.failure
                    )
                if endsLogicalHistoryBoundary {
                    if !boundaryIsDurable,
                        lastCompletedOffloadSessionID == summary.offloadSessionID
                    {
                        lastCompletedOffloadSessionID = nil
                    }
                    if failedHistorySessionID == summary.offloadSessionID {
                        failedHistorySessionID = nil
                    }
                }
                didPersist(publishedResult, summary)
                inFlightBatchCount -= 1
                queuedEnvelopeCount -= originalEnvelopeCount
                persistenceIsActive = false
                publishPressure(isBackpressured: false)
                startNextPersistenceBatchIfNeeded()
                guard inFlightBatchCount == 0, !drainWaiters.isEmpty else { return }
                let waiters = drainWaiters
                drainWaiters.removeAll(keepingCapacity: true)
                for waiter in waiters { waiter() }
            }
        }
    }

    private func compactPendingPersistenceStorageIfNeeded() {
        guard pendingPersistenceHead > 32,
            pendingPersistenceHead * 2 >= pendingPersistenceBatches.count
        else { return }
        pendingPersistenceBatches.removeFirst(pendingPersistenceHead)
        pendingPersistenceHead = 0
    }

    private func publishPressure(isBackpressured: Bool) {
        guard isBackpressured != lastPressureState else { return }
        lastPressureState = isBackpressured
        didChangePressure(
            WhoopTransportPressureSnapshot(
                isBackpressured: isBackpressured,
                queuedEnvelopeCount: queuedEnvelopeCount,
                capacity: maximumQueuedEnvelopeCount
            )
        )
    }

    private func publishHeartRate(_ realtime: WhoopDecodedRealtime?, deliveredAt: Date) {
        requireQueue()
        guard let realtime else { return }
        pendingUI.heartRate = realtime.heartRate
        pendingUI.heartRateReceivedAt = deliveredAt
        publishUIIfDue(now: deliveredAt)
    }

    private func publishUIIfDue(now: Date) {
        requireQueue()
        let elapsed = lastUISnapshotAt.map { now.timeIntervalSince($0) } ?? .infinity
        guard elapsed >= uiSnapshotInterval else {
            let delay = max(0, uiSnapshotInterval - elapsed)
            uiPublishGeneration &+= 1
            let generation = uiPublishGeneration
            queue.asyncAfter(deadline: .now() + delay) { [self] in
                guard generation == uiPublishGeneration else { return }
                publishUI(now: Date())
            }
            return
        }
        uiPublishGeneration &+= 1
        publishUI(now: now)
    }

    private func publishUI(now: Date) {
        requireQueue()
        guard !pendingUI.isEmpty else { return }
        let snapshot = WhoopTransportUISnapshot(
            heartRate: pendingUI.heartRate,
            heartRateReceivedAt: pendingUI.heartRateReceivedAt,
            batteryObservation: pendingUI.batteryObservation
        )
        pendingUI = PendingUI()
        lastUISnapshotAt = now
        didPublishUI(snapshot)
    }

    private struct PendingUI {
        var heartRate: Int?
        var heartRateReceivedAt: Date?
        var batteryObservation: BatteryObservation?

        var isEmpty: Bool {
            heartRate == nil && batteryObservation == nil
        }
    }

    private func requireQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
    }
}
