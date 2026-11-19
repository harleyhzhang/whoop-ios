import Foundation
import UserNotifications

/// A system-scheduled deadline still fires when the collector is suspended.
/// Only recent, durably persisted sensor samples may move that deadline.
@MainActor
final class WhoopCollectionMonitor {
    static let identifier = "whoop.collection.stale"
    static let anchorKey = "WhoopCollectionMonitor.lastFreshSample"
    static let timeout: TimeInterval = 60 * 60
    private static let rearmInterval: TimeInterval = 5 * 60

    private let scheduler: WhoopNotificationScheduling
    private let defaults: UserDefaults
    private let now: () -> Date
    private var started = false
    private var inFlightAnchor: Date?
    private var attemptedAnchor: Date?
    private var scheduledAnchor: Date?
    private var pendingAnchor: Date?
    private var worker: Task<Void, Never>?

    init(
        scheduler: WhoopNotificationScheduling,
        defaults: UserDefaults,
        now: @escaping () -> Date
    ) {
        self.scheduler = scheduler
        self.defaults = defaults
        self.now = now
    }

    func start() {
        guard !started else { return }
        started = true
        let current = now()
        let saved = defaults.object(forKey: Self.anchorKey) as? Date
        let anchor = saved.flatMap { $0 <= current ? $0 : nil } ?? current
        defaults.set(anchor, forKey: Self.anchorKey)
        enqueue(anchor)
    }

    func observePersistedSample(at sampleAt: Date) {
        let current = now()
        // Replayed history, duplicate packets and future device clocks are
        // not evidence that the current collection gap has recovered.
        guard sampleAt <= current, current.timeIntervalSince(sampleAt) <= Self.rearmInterval else { return }
        start()
        let previous = defaults.object(forKey: Self.anchorKey) as? Date
        guard previous.map({ sampleAt > $0 }) ?? true else { return }
        let mostRecentSchedule = pendingAnchor ?? inFlightAnchor ?? scheduledAnchor ?? attemptedAnchor
        guard mostRecentSchedule.map({ sampleAt.timeIntervalSince($0) >= Self.rearmInterval }) ?? true else {
            return
        }
        defaults.set(sampleAt, forKey: Self.anchorKey)
        enqueue(sampleAt)
    }

    private func enqueue(_ anchor: Date) {
        pendingAnchor = anchor
        guard worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            // Serialize replacements: an older async add must never overwrite
            // a newer deadline after the newer request has finished.
            while let anchor = self.pendingAnchor {
                self.pendingAnchor = nil
                self.inFlightAnchor = anchor
                self.attemptedAnchor = anchor
                let content = UNMutableNotificationContent()
                content.title = "WHOOP data has stopped updating"
                content.body =
                    "No fresh sensor samples have been saved for an hour. Open WHOOP and check the band’s battery and Bluetooth connection."
                content.sound = .default
                content.threadIdentifier = "whoop.local"
                let delay = max(1, anchor.addingTimeInterval(Self.timeout).timeIntervalSince(self.now()))
                let request = UNNotificationRequest(
                    identifier: Self.identifier,
                    content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
                )
                do {
                    try await self.scheduler.add(request)
                    self.scheduledAnchor = anchor
                    if self.now().timeIntervalSince(anchor) < Self.timeout {
                        self.scheduler.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
                    }
                } catch {
                    // Leave the persisted deadline intact. The next fresh
                    // sample after the rearm interval, or an app launch, retries
                    // without resetting its age or hammering a denied scheduler.
                }
            }
            self.inFlightAnchor = nil
            self.worker = nil
        }
    }
}
