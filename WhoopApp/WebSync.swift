import Foundation

/// Pushes the last week of dashboard numbers and strap status to the website's
/// Convex copy. Throttled and skipped when nothing changed to keep writes cheap.
@MainActor
final class WebSync {
    static let shared = WebSync()

    struct Status: Encodable, Equatable {
        var heartRate: Int?
        var heartRateAt: Double?
        var battery: Int?
        var powerPackBattery: Int?
        var connected: Bool
    }

    private struct Config: Decodable {
        let siteURL: URL
        let syncToken: String
    }

    private struct Day: Encodable, Equatable {
        let day: String
        let sleep, recovery, strain, steps, duration, hrv, rhr: Double?
    }

    private struct Body: Encodable, Equatable {
        let days: [Day]
        let status: Status
    }

    private static let interval: TimeInterval = 5 * 60
    private let config: Config? = Bundle.main.url(forResource: "whoop-web-config", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
    private var lastSentAt: Date?
    private var lastBody: Body?

    func push(days: [HealthDay], status: Status, now: Date = .now) {
        guard let config else { return }
        if let lastSentAt, now.timeIntervalSince(lastSentAt) < Self.interval { return }
        let body = Body(
            days: days.suffix(7).map {
                Day(
                    day: $0.day, sleep: $0.sleep, recovery: $0.recovery, strain: $0.strain,
                    steps: $0.steps, duration: $0.duration, hrv: $0.hrv, rhr: $0.rhr)
            },
            status: status)
        guard body != lastBody, let data = try? JSONEncoder().encode(body) else { return }
        var request = URLRequest(url: config.siteURL.appending(path: "v1/web/sync"))
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(config.syncToken)", forHTTPHeaderField: "authorization")
        lastSentAt = now
        Task {
            let ok = (try? await URLSession.shared.data(for: request))
                .map { ($0.1 as? HTTPURLResponse)?.statusCode == 200 } ?? false
            if ok { lastBody = body } else { lastSentAt = nil }
        }
    }
}
