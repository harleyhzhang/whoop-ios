import UIKit

@MainActor
enum AppHaptics {
    private static let selectionGenerator = UISelectionFeedbackGenerator()

    static func selection() {
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }
}
