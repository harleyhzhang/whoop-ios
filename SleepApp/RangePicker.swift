import SwiftUI

struct RangePicker: View {
    @Binding var selection: HealthRange
    let availableRanges: [HealthRange]

    var body: some View {
        HStack(spacing: 12) {
            Text("Trends")
                .font(.title3.weight(.semibold))

            Spacer(minLength: 8)

            Picker("Trend range", selection: $selection) {
                ForEach(availableRanges) { range in
                    Text(range.rawValue)
                        .tag(range)
                        .accessibilityLabel(range.accessibilityName)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityValue(selection.accessibilityName)
        }
        .padding(.top, 12)
    }
}
