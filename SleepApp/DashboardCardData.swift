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
    var color: Color {
        switch self {
        case .steps: Color(red: 0.64, green: 0.56, blue: 0.86)
        case .duration: .cyan
        case .hrv: .pink
        case .rhr: .red
        case .sleep: Color(red: 0.39, green: 0.69, blue: 1.0)
        case .recovery: .mint
        case .strain: .blue
        }
    }
    var ringColor: Color {
        switch self {
        case .sleep: Color(red: 0.49, green: 0.69, blue: 0.80)
        case .recovery: .green
        default: color
        }
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
