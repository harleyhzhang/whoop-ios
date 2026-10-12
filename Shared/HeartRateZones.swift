import SwiftUI

/// WHOOP-style heart-rate zones: zone n (1-5) starts at (40 + 10n)% of max HR.
enum HeartRateZones {
    static let count = 5
    static let fallbackMaximum = 190.0
    /// Longer gaps between strap readings are not credited to any zone.
    static let longestGap: TimeInterval = 5

    /// Zero-based zone index, or nil below zone 1.
    static func zone(for bpm: Int, maximum: Double) -> Int? {
        guard maximum > 0 else { return nil }
        let fraction = Double(bpm) / maximum
        guard fraction >= 0.5 else { return nil }
        return min(Int(((fraction - 0.5) * 10).rounded(.down)), count - 1)
    }
}

/// Five segments with the current zone lit.
struct ZoneSegments: View {
    let current: Int?

    var body: some View {
        HStack(spacing: Theme.Layout.zoneSpacing) {
            ForEach(0..<HeartRateZones.count, id: \.self) { index in
                Capsule()
                    .fill(Theme.Palette.zones[index].opacity(index == current ? 1 : 0.25))
                    .frame(height: Theme.Layout.zoneBarHeight)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(current.map { "Zone \($0 + 1)" } ?? "Below zone 1")
    }
}
