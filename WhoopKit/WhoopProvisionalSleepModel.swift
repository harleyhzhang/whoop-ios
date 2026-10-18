import Foundation
import Observation

/// The dashboard's view of the night in progress. Only foreground analysis
/// computes it; background analysis leaves it untouched so the next visit
/// starts from the last values instead of dashes.
@MainActor
@Observable
final class WhoopProvisionalSleepModel {
    static let cacheKey = "WhoopCollector.cachedProvisionalDay"
    /// A cold start only reuses a recent night; anything older is replaced
    /// by the first foreground analysis anyway and could name a stale day.
    static let maximumCachedAge: TimeInterval = 6 * 60 * 60

    private struct Cached: Codable {
        let day: WhoopProvisionalDay
        let computedAt: Date
    }

    private(set) var day: WhoopProvisionalDay?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        if let data = defaults.data(forKey: Self.cacheKey),
            let cached = try? JSONDecoder().decode(Cached.self, from: data),
            abs(now().timeIntervalSince(cached.computedAt)) < Self.maximumCachedAge
        {
            day = cached.day
        }
    }

    func apply(_ snapshot: WhoopSleepSnapshot) {
        if snapshot.evaluatedProvisional {
            update(snapshot.provisional)
        } else if snapshot.finalizedRecord != nil {
            // Publication supersedes the night; the next visit recomputes.
            update(nil)
        }
    }

    private func update(_ newDay: WhoopProvisionalDay?) {
        guard newDay != day else { return }
        day = newDay
        if let newDay, let data = try? JSONEncoder().encode(Cached(day: newDay, computedAt: now())) {
            defaults.set(data, forKey: Self.cacheKey)
        } else {
            defaults.removeObject(forKey: Self.cacheKey)
        }
    }
}
