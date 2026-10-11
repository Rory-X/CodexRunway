import CodexRunwayCore
import Foundation
import WidgetKit

enum RunwayWidgetLoadState: Equatable {
    case ready(RunwayWidgetSnapshot)
    case missing
    case corrupt
    case unsupportedVersion
}

struct RunwayWidgetEntry: TimelineEntry {
    var date: Date
    var state: RunwayWidgetLoadState
    var metric: RunwayWidgetMetricKind
    var isPlaceholder = false
}

private enum RunwayWidgetLoader {
    static func load(now: Date = Date()) -> RunwayWidgetLoadState {
        let mode = RunwayWidgetStorageMode.mode(
            fromInfoValue: Bundle.main.object(forInfoDictionaryKey: RunwayWidgetStorageMode.infoKey) as? String)
        let appGroupID = Bundle.main.object(
            forInfoDictionaryKey: RunwayWidgetStorageMode.appGroupInfoKey) as? String
        do {
            return .ready(try RunwayWidgetSnapshotStore.make(
                mode: mode,
                appGroupID: appGroupID).load())
        } catch RunwayWidgetSnapshotStoreError.missing {
            return .missing
        } catch RunwayWidgetSnapshotStoreError.unsupportedSchemaVersion {
            return .unsupportedVersion
        } catch {
            return .corrupt
        }
    }

    static func timeline(metric: RunwayWidgetMetricKind) -> Timeline<RunwayWidgetEntry> {
        let now = Date()
        let entry = RunwayWidgetEntry(
            date: now,
            state: load(now: now),
            metric: metric)
        return Timeline(
            entries: [entry],
            policy: .after(now.addingTimeInterval(RunwayWidgetLayoutPolicy.refreshInterval)))
    }
}

@available(macOS 14.0, *)
struct RunwayOverviewTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> RunwayWidgetEntry {
        RunwayWidgetEntry(
            date: Date(),
            state: RunwayWidgetLoader.load(),
            metric: .remainingQuota,
            isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (RunwayWidgetEntry) -> Void) {
        completion(RunwayWidgetEntry(
            date: Date(),
            state: RunwayWidgetLoader.load(),
            metric: .remainingQuota))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RunwayWidgetEntry>) -> Void) {
        completion(RunwayWidgetLoader.timeline(metric: .remainingQuota))
    }
}

@available(macOS 14.0, *)
struct RunwayMetricTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> RunwayWidgetEntry {
        RunwayWidgetEntry(
            date: Date(),
            state: RunwayWidgetLoader.load(),
            metric: .remainingQuota,
            isPlaceholder: true)
    }

    func snapshot(for configuration: RunwayMetricSelectionIntent, in context: Context) async -> RunwayWidgetEntry {
        RunwayWidgetEntry(
            date: Date(),
            state: RunwayWidgetLoader.load(),
            metric: configuration.metric.kind)
    }

    func timeline(for configuration: RunwayMetricSelectionIntent, in context: Context) async -> Timeline<RunwayWidgetEntry> {
        RunwayWidgetLoader.timeline(metric: configuration.metric.kind)
    }
}

@available(macOS 14.0, *)
struct RunwayResetTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> RunwayWidgetEntry {
        RunwayWidgetEntry(
            date: Date(),
            state: RunwayWidgetLoader.load(),
            metric: .remainingQuota,
            isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (RunwayWidgetEntry) -> Void) {
        completion(RunwayWidgetEntry(
            date: Date(),
            state: RunwayWidgetLoader.load(),
            metric: .remainingQuota))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RunwayWidgetEntry>) -> Void) {
        completion(RunwayWidgetLoader.timeline(metric: .remainingQuota))
    }
}

@available(macOS 14.0, *)
private extension RunwayMetricChoice {
    var kind: RunwayWidgetMetricKind {
        switch self {
        case .remainingQuota: .remainingQuota
        case .apiEquivalentCost: .apiEquivalentCost
        case .tokenCount: .tokenCount
        case .balance: .balance
        }
    }
}
