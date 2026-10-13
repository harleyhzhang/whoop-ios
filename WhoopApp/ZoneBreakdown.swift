import SwiftUI

/// Time in each heart-rate zone, highest zone first.
struct ZoneBreakdown: View {
    let shares: [Double]
    let duration: TimeInterval

    private struct Row: Identifiable {
        let id: Int
        let share: Double
    }

    private var rows: [Row] {
        shares.indices.reversed().map { Row(id: $0, share: min(max(shares[$0], 0), 1)) }
    }

    var body: some View {
        CardList(items: rows) { row in
            HStack(spacing: Theme.Layout.spacing) {
                Text("Zone \(row.id + 1)")
                    .font(Theme.Typography.row)
                    .foregroundStyle(Theme.Palette.muted)
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Palette.zones[row.id].opacity(0.25))
                    Capsule().fill(Theme.Palette.zones[row.id])
                        .scaleEffect(x: row.share, anchor: .leading)
                }
                .frame(height: Theme.Layout.zoneBarHeight)
                Text("\(Int((row.share * 100).rounded()))%")
                    .font(Theme.Typography.unit)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Palette.text)
                Text(EntryRow.duration(row.share * duration))
                    .font(Theme.Typography.row)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Palette.muted)
            }
            .padding(.horizontal, Theme.Layout.cardPadding)
            .frame(minHeight: Theme.Layout.rowHeight)
        }
        .accessibilityIdentifier("entry.zones")
    }
}
