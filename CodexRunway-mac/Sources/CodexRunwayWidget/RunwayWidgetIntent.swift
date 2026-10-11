import AppIntents
import Foundation

@available(macOS 14.0, *)
enum RunwayMetricChoice: String, AppEnum {
    case remainingQuota
    case apiEquivalentCost
    case tokenCount
    case balance

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Metric")
    static let caseDisplayRepresentations: [RunwayMetricChoice: DisplayRepresentation] = [
        .remainingQuota: DisplayRepresentation(title: "Remaining quota"),
        .apiEquivalentCost: DisplayRepresentation(title: "API equivalent cost"),
        .tokenCount: DisplayRepresentation(title: "Token count"),
        .balance: DisplayRepresentation(title: "Balance"),
    ]
}

@available(macOS 14.0, *)
struct RunwayMetricSelectionIntent: AppIntent, WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Key Metric"
    static let description = IntentDescription("Choose which metric the widget displays.")

    @Parameter(title: "Metric", default: .remainingQuota)
    var metric: RunwayMetricChoice

    init() {
        metric = .remainingQuota
    }
}
