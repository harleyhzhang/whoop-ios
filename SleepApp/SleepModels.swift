import Combine
import Foundation

extension Notification.Name {
    static let whoopDailyHealthUpdated = Notification.Name("whoopDailyHealthUpdated")
}

struct DailyHealthRecord: Codable, Hashable, Identifiable, Sendable {
    let dateKey: String
    let sleepScore: Double?
    let sleepDurationMinutes: Double?
    let hrvRMSSDMilliseconds: Double?
    let restingHeartRateBPM: Double?
    let sleepID: String?
    let cycleID: Int64?
    let source: String
    let sourceArchive: String?
    let sourceUpdatedAt: String

    var id: String { dateKey }

    var date: Date {
        let pieces = dateKey.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return .distantPast }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = pieces[0]
        components.month = pieces[1]
        components.day = pieces[2]
        components.hour = 12
        return components.date ?? .distantPast
    }
}

@MainActor
final class HealthHistoryModel: ObservableObject {
    @Published private(set) var records: [DailyHealthRecord] = []
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?

    private let store: WhoopStore

    init(store: WhoopStore = .shared) {
        self.store = store
        reload()
    }

    var latestRecord: DailyHealthRecord? { records.last }

    var sourceSummary: String {
        guard let latestRecord else { return isLoading ? "Loading real history…" : "No real history imported" }
        return "WHOOP API history · \(records.count) nights · through \(latestRecord.date.formatted(.dateTime.month(.abbreviated).day()))"
    }

    func reload() {
        isLoading = true
        store.loadDailyHealthRecords { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let records):
                    self.records = records
                    self.errorMessage = nil
                case .failure(let error):
                    self.records = []
                    self.errorMessage = error.localizedDescription
                }
                self.isLoading = false
            }
        }
    }
}
