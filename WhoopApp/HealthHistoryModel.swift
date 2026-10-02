import Foundation
import Observation

@Observable
@MainActor
final class HealthHistoryModel {
    private(set) var snapshot = DashboardHistorySnapshot.empty
    private(set) var errorMessage: String?

    @ObservationIgnored
    private let store: WhoopStore
    @ObservationIgnored
    private var reloadGeneration = 0
    init(store: WhoopStore = .shared) {
        self.store = store
        reload()
    }

    /// Applies one freshly derived night without waiting for the full reload, so
    /// the dashboard can update immediately after automatic publication.
    func merge(_ record: DailyHealthRecord) {
        var healthRecords = snapshot.healthRecords
        if let index = healthRecords.firstIndex(where: { $0.dateKey == record.dateKey }) {
            healthRecords[index] = record
        } else {
            healthRecords.append(record)
            healthRecords.sort { lhs, rhs in
                guard let lhsKey = DayKey(rawValue: lhs.dateKey) else { return false }
                guard let rhsKey = DayKey(rawValue: rhs.dateKey) else { return true }
                return lhsKey < rhsKey
            }
        }
        snapshot = DashboardHistorySnapshot(
            healthRecords: healthRecords,
            stepRecords: snapshot.stepRecords,
            recoveryRecords: snapshot.recoveryRecords,
            strainRecords: snapshot.strainRecords,
            strainDerivations: snapshot.strainDerivations
        )
    }

    func reload() {
        if DemoHistory.isEnabled {
            snapshot = DemoHistory.snapshot()
            return
        }
        reloadGeneration += 1
        let generation = reloadGeneration
        let store = store
        store.loadDashboardHistory { [weak self] result in
            Task { @MainActor in
                guard let self, generation == self.reloadGeneration else { return }
                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot
                    self.errorMessage = nil
                case .failure(let error):
                    // Preserve every last known-good dataset through a
                    // transient read failure instead of blanking its charts.
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
