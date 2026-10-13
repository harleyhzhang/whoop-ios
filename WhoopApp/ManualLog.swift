import Foundation
import Observation
import SwiftUI

/// Sports offered when adding or starting an activity. Running and
/// weightlifting stay pinned; the rest are listed alphabetically.
enum Sport: String, CaseIterable, Codable, Identifiable {
    case running, weightlifting
    case badminton, basketball, boxing, climbing, cycling, golf, hiit, hiking, hockey
    case mountainBiking, pickleball, rowing, skiing, soccer, swimming, tennis
    case ultimateFrisbee, volleyball, walking, yoga, other

    var id: Self { self }

    static let pinned: [Sport] = [.running, .weightlifting]

    static var others: [Sport] {
        allCases.filter { !pinned.contains($0) && $0 != .other }.sorted { $0.title < $1.title } + [.other]
    }

    static func matching(_ query: String) -> [Sport] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return pinned + others }
        return (pinned + others).filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Maps a WHOOP export activity name; unknown names become `.other`.
    init(exportName: String) {
        let name = exportName.lowercased()
        self = Sport.allCases.first { $0.title.lowercased() == name } ?? .other
    }

    var title: String {
        switch self {
        case .hiit: "HIIT"
        case .mountainBiking: "Mountain Biking"
        case .ultimateFrisbee: "Ultimate Frisbee"
        default: rawValue.capitalized
        }
    }

    var symbol: String {
        switch self {
        case .running: "figure.run"
        case .weightlifting: "figure.strengthtraining.traditional"
        case .badminton: "figure.badminton"
        case .basketball: "figure.basketball"
        case .boxing: "figure.boxing"
        case .climbing: "figure.climbing"
        case .cycling, .mountainBiking: "figure.outdoor.cycle"
        case .golf: "figure.golf"
        case .hiit: "figure.highintensity.intervaltraining"
        case .hiking: "figure.hiking"
        case .hockey: "figure.hockey"
        case .pickleball: "figure.pickleball"
        case .rowing: "figure.rower"
        case .skiing: "figure.skiing.downhill"
        case .soccer: "figure.soccer"
        case .swimming: "figure.pool.swim"
        case .tennis: "figure.tennis"
        case .ultimateFrisbee: "figure.disc.sports"
        case .volleyball: "figure.volleyball"
        case .walking: "figure.walk"
        case .yoga: "figure.yoga"
        case .other: "figure.mixed.cardio"
        }
    }
}

/// What an entry records.
enum LogKind: Codable, Hashable {
    case activity(Sport)
    case sleep
    case nap

    var isSleep: Bool { self == .sleep || self == .nap }

    var title: String {
        switch self {
        case .activity(let sport): sport.title
        case .sleep: "Sleep"
        case .nap: "Nap"
        }
    }

    var symbol: String {
        switch self {
        case .activity(let sport): sport.symbol
        case .sleep: "bed.double.fill"
        case .nap: "powersleep"
        }
    }

    var color: Color { isSleep ? HealthMetric.sleep.color : HealthMetric.strain.color }

    /// Prefilled length when adding a past entry.
    var typicalDuration: TimeInterval {
        switch self {
        case .activity: 3600
        case .sleep: 8 * 3600
        case .nap: 1800
        }
    }
}

/// One activity, sleep, or nap. An entry without an end is live.
struct ManualEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let kind: LogKind
    let start: Date
    var end: Date?
    var label: String?
    var strain: Double?
    var averageHeartRate: Int?
    var maxHeartRate: Int?
    var calories: Int?
    var sleepScore: Double?
    var imported: Bool?
    var heartRateTotal: Double?
    var heartRateSamples: Int?
    /// Seconds spent in zones 1-5 while live.
    var zoneSeconds: [Double]?
    /// WHOOP's own zone 1-5 percentages for imported workouts.
    var zonePercents: [Double]?
    var lastSampleAt: Date?

    var isLive: Bool { end == nil }
    var isImported: Bool { imported == true }
    var title: String { label ?? kind.title }

    func duration(at now: Date) -> TimeInterval { max((end ?? now).timeIntervalSince(start), 0) }

    /// Fraction of the activity spent in each zone, 1 through 5.
    func zoneShares(at now: Date) -> [Double]? {
        if let percents = zonePercents, percents.count == HeartRateZones.count {
            return percents.map { $0 / 100 }
        }
        let elapsed = duration(at: end ?? lastSampleAt ?? now)
        guard let seconds = zoneSeconds, seconds.count == HeartRateZones.count, elapsed > 0 else { return nil }
        return seconds.map { min($0 / elapsed, 1) }
    }

    /// Sleep belongs to the day you wake up; activities to the day they start.
    func dayKey(timeZone: TimeZone) -> String {
        DayKey(date: kind.isSleep ? (end ?? start) : start, timeZone: timeZone).rawValue
    }

    /// Folds one live strap reading into the running average, maximum, and
    /// zone time. The gap since the previous reading counts toward this zone.
    mutating func record(heartRate bpm: Int, at date: Date, maximum: Double) {
        let total = (heartRateTotal ?? 0) + Double(bpm)
        let samples = (heartRateSamples ?? 0) + 1
        heartRateTotal = total
        heartRateSamples = samples
        averageHeartRate = Int((total / Double(samples)).rounded())
        maxHeartRate = max(maxHeartRate ?? bpm, bpm)
        let gap = min(max(date.timeIntervalSince(lastSampleAt ?? date), 0), HeartRateZones.longestGap)
        lastSampleAt = date
        guard let zone = HeartRateZones.zone(for: bpm, maximum: maximum) else { return }
        var seconds = zoneSeconds ?? Array(repeating: 0, count: HeartRateZones.count)
        seconds[zone] += gap
        zoneSeconds = seconds
    }
}

enum ManualLogRules {
    static let longestEntry: TimeInterval = 24 * 3600

    static func isValid(start: Date, end: Date, now: Date) -> Bool {
        end > start && end <= now && end.timeIntervalSince(start) <= longestEntry
    }
}

/// Workouts, sleeps, and naps from a WHOOP account export, shown read-only.
enum ImportedActivities {
    private struct Record: Decodable {
        let id: UUID
        let kind: String
        let name: String
        let start: Date
        let end: Date
        let strain: Double?
        let averageHeartRate: Int?
        let maxHeartRate: Int?
        let calories: Int?
        let sleepScore: Double?
        let zonePercents: [Double]?
    }

    static func decode(_ data: Data) -> [ManualEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let records = try? decoder.decode([Record].self, from: data) else { return [] }
        return records.map { record in
            let kind: LogKind =
                switch record.kind {
                case "sleep": .sleep
                case "nap": .nap
                default: .activity(Sport(exportName: record.name))
                }
            return ManualEntry(
                id: record.id, kind: kind, start: record.start, end: record.end,
                label: kind == .activity(.other) ? record.name : nil, strain: record.strain,
                averageHeartRate: record.averageHeartRate, maxHeartRate: record.maxHeartRate,
                calories: record.calories, sleepScore: record.sleepScore, imported: true,
                zonePercents: record.zonePercents)
        }
    }
}

/// Entries live in their own file so they never overwrite strap or imported
/// WHOOP measurements. Activities are only ever started or added by hand.
@Observable
@MainActor
final class ManualLogStore {
    private(set) var entries: [ManualEntry] = []
    private(set) var imported: [ManualEntry] = []
    /// Latest strap reading, shown while an activity is live.
    private(set) var heartRate: Int?
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private let liveActivity: WorkoutLiveActivity?
    /// Zone reference: the highest heart rate WHOOP recorded in a workout.
    @ObservationIgnored let maximumHeartRate: Double

    init(
        url: URL? = ManualLogStore.defaultURL,
        importedURL: URL? = Bundle.main.url(forResource: "whoop-activities", withExtension: "json"),
        liveActivity: WorkoutLiveActivity? = nil,
        maximumHeartRate: Double? = nil
    ) {
        self.url = url
        self.liveActivity = liveActivity
        var loaded: [ManualEntry] = []
        if let url, let data = try? Data(contentsOf: url),
            let saved = try? JSONDecoder().decode([ManualEntry].self, from: data)
        {
            loaded = saved
        }
        // One-time cleanup: early hand-logged sleeps duplicated strap-detected sleep.
        let purgeKey = "ManualLog.purgedHandLoggedSleep.v1"
        if url != nil, !UserDefaults.standard.bool(forKey: purgeKey) {
            loaded.removeAll { $0.kind.isSleep }
            if let url, let data = try? JSONEncoder().encode(loaded) {
                try? data.write(to: url, options: [.atomic, .completeFileProtection])
            }
            UserDefaults.standard.set(true, forKey: purgeKey)
        }
        var history: [ManualEntry] = []
        if let importedURL, let data = try? Data(contentsOf: importedURL) {
            history = ImportedActivities.decode(data)
        }
        self.maximumHeartRate =
            maximumHeartRate ?? history.compactMap(\.maxHeartRate).max().map(Double.init)
            ?? HeartRateZones.fallbackMaximum
        entries = loaded
        imported = history
        liveActivity?.sync(live, heartRate: nil)
    }

    /// Demo and UI-test launches never touch the real log.
    static func forLaunch() -> ManualLogStore {
        DemoHistory.isEnabled
            ? ManualLogStore(url: nil, importedURL: nil) : ManualLogStore(liveActivity: WorkoutLiveActivity())
    }

    static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("manual-log.json")
    }

    var live: ManualEntry? { entries.first { $0.isLive } }

    var currentZone: Int? {
        heartRate.flatMap { HeartRateZones.zone(for: $0, maximum: maximumHeartRate) }
    }

    @discardableResult
    func start(_ kind: LogKind, at date: Date = .now) -> Bool {
        guard live == nil, !kind.isSleep else { return false }
        entries.append(ManualEntry(id: UUID(), kind: kind, start: date))
        save()
        liveActivity?.sync(live, heartRate: heartRate)
        return true
    }

    func record(heartRate bpm: Int, at date: Date = .now) {
        guard bpm > 0 else { return }
        heartRate = bpm
        guard let index = entries.firstIndex(where: \.isLive) else { return }
        entries[index].record(heartRate: bpm, at: date, maximum: maximumHeartRate)
        if (entries[index].heartRateSamples ?? 0) % 15 == 0 { save() }
        liveActivity?.sync(entries[index], heartRate: bpm, zone: currentZone)
    }

    /// Ends the live entry, saving it or throwing it away.
    func stop(at date: Date = .now, keep: Bool = true) {
        guard let index = entries.firstIndex(where: \.isLive) else { return }
        if keep {
            entries[index].end = max(date, entries[index].start)
        } else {
            entries.remove(at: index)
        }
        save()
        liveActivity?.sync(nil, heartRate: nil)
    }

    @discardableResult
    func add(_ kind: LogKind, start: Date, end: Date, now: Date = .now) -> Bool {
        guard ManualLogRules.isValid(start: start, end: end, now: now) else { return false }
        entries.append(ManualEntry(id: UUID(), kind: kind, start: start, end: end))
        entries.sort { $0.start < $1.start }
        save()
        return true
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func entries(on dayKey: String, timeZone: TimeZone = .current) -> [ManualEntry] {
        (imported + entries)
            .filter { !$0.isLive && $0.dayKey(timeZone: timeZone) == dayKey }
            .sorted { $0.start < $1.start }
    }

    /// Today's strain floor: WHOOP's day total only becomes final once the day
    /// ends, and strain only accumulates, so the day is at least as strained as
    /// its hardest activity.
    func strainFloor(on dayKey: String, timeZone: TimeZone = .current) -> Double? {
        entries(on: dayKey, timeZone: timeZone).compactMap(\.strain).max()
    }

    private func save() {
        guard let url, let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}

/// Debug simulator stand-in for the strap so the live screen can be previewed.
@MainActor
enum MockHeartRate {
    static func run(_ log: ManualLogStore) async {
        guard WhoopLaunchOverrides.mocksHeartRate else { return }
        var second = 0.0
        while !Task.isCancelled, log.live != nil {
            log.record(heartRate: Int(150 + 18 * sin(second / 9) + 6 * sin(second / 2)))
            second += 1
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
