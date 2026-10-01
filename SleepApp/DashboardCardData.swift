import Foundation
import SwiftUI

struct HealthDay: Decodable, Identifiable {
    let day: String
    let sleep: Double?
    let recovery: Double?
    let strain: Double?
    let steps: Double?
    let duration: Double?
    let hrv: Double?
    let rhr: Double?
    let localStrain: StrainEstimate?
    var id: String { day }
    var date: Date { DayKey.date(from: day, timeZone: .current) ?? .distantPast }

    func value(for metric: HealthMetric) -> Double? {
        switch metric {
        case .steps: steps
        case .duration: duration
        case .hrv: hrv
        case .rhr: rhr
        case .sleep: sleep
        case .recovery: recovery
        case .strain: strain
        }
    }
}

enum HealthMetric: String, CaseIterable, Identifiable {
    case steps, duration, hrv, rhr, sleep, recovery, strain
    var id: Self { self }
    var title: String {
        switch self {
        case .steps: "Steps"
        case .duration: "Sleep duration"
        case .hrv: "HRV"
        case .rhr: "RHR"
        case .sleep: "Sleep"
        case .recovery: "Recovery"
        case .strain: "Strain"
        }
    }
    var symbol: String {
        switch self {
        case .steps: "figure.walk"
        case .duration: "bed.double.fill"
        case .hrv: "waveform.path.ecg"
        case .rhr, .recovery: "heart.fill"
        case .sleep: "moon.fill"
        case .strain: "figure.run"
        }
    }
    var color: Color {
        switch self {
        case .steps: Color(red: 0.64, green: 0.56, blue: 0.86)
        case .duration: .cyan
        case .hrv: .pink
        case .rhr: .red
        case .sleep: Color(red: 0.39, green: 0.69, blue: 1.0)
        case .recovery: Color(uiColor: .systemGray)
        case .strain: .blue
        }
    }
    func color(for value: Double?) -> Color {
        guard self == .recovery else { return color }
        return RecoveryBand(score: value)?.color ?? color
    }
    var unit: String {
        switch self {
        case .hrv: "ms"
        case .rhr: "bpm"
        default: ""
        }
    }
    func formatted(_ value: Double?) -> String {
        guard let value else { return "—" }
        switch self {
        case .sleep, .recovery: return "\(Int(value.rounded()))%"
        case .strain: return String(format: "%.1f", value)
        case .steps: return Int(value.rounded()).formatted()
        case .duration:
            let minutes = Int(value.rounded())
            return "\(minutes / 60)h \(minutes % 60)m"
        case .hrv, .rhr: return "\(Int(value.rounded()))"
        }
    }
}

/// WHOOP's displayed whole-percent bands and published recovery palette.
enum RecoveryBand {
    case low, moderate, high

    init?(score: Double?) {
        guard let score, score.isFinite, (0...100).contains(score) else { return nil }
        switch score.rounded() {
        case ..<34: self = .low
        case ..<67: self = .moderate
        default: self = .high
        }
    }

    var color: Color {
        switch self {
        case .low: Color(red: 1, green: 0, blue: 38 / 255)
        case .moderate: Color(red: 1, green: 222 / 255, blue: 0)
        case .high: Color(red: 22 / 255, green: 236 / 255, blue: 6 / 255)
        }
    }
}
