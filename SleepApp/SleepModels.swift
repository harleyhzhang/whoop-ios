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

    var hasCompletePrimarySleepMetrics: Bool {
        sleepScore != nil
            && sleepDurationMinutes != nil
            && hrvRMSSDMilliseconds != nil
            && restingHeartRateBPM != nil
    }

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
    private var reloadGeneration = 0

    init(store: WhoopStore = .shared) {
        self.store = store
        reload()
    }

    var latestRecord: DailyHealthRecord? { records.last }

    var sourceSummary: String {
        guard let latestRecord else { return isLoading ? "Loading real history…" : "No real history imported" }
        return "WHOOP API history · \(records.count) nights · through \(latestRecord.date.formatted(.dateTime.month(.abbreviated).day()))"
    }

    /// Applies one freshly derived night without waiting for the full reload, so
    /// the dashboard can update on the frame after a manual process.
    func merge(_ record: DailyHealthRecord) {
        if let index = records.firstIndex(where: { $0.dateKey == record.dateKey }) {
            records[index] = record
        } else {
            records.append(record)
            records.sort { $0.dateKey < $1.dateKey }
        }
    }

    func reload() {
        reloadGeneration += 1
        let generation = reloadGeneration
        isLoading = true
        store.loadDailyHealthRecords { [weak self] result in
            Task { @MainActor in
                guard let self, generation == self.reloadGeneration else { return }
                switch result {
                case .success(let records):
                    self.records = records
                    self.errorMessage = nil
                case .failure(let error):
                    // Keep the last known-good dashboard visible through a
                    // transient read failure instead of blanking every chart.
                    self.errorMessage = error.localizedDescription
                }
                self.isLoading = false
            }
        }
    }
}
