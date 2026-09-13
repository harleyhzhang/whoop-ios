import UIKit

@MainActor
enum AppHaptics {
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let softImpactGenerator = UIImpactFeedbackGenerator(style: .soft)
    private static let firmImpactGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let notificationGenerator = UINotificationFeedbackGenerator()

    static func selection() {
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    static func softImpact() {
        softImpactGenerator.impactOccurred(intensity: 0.75)
        softImpactGenerator.prepare()
    }

    static func firmImpact() {
        firmImpactGenerator.impactOccurred(intensity: 0.85)
        firmImpactGenerator.prepare()
    }

    static func success() {
        notificationGenerator.notificationOccurred(.success)
        notificationGenerator.prepare()
    }

}
