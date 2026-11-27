import Foundation
import Observation

enum ClusterDateField: String, CaseIterable, Identifiable, Sendable {
    case modified, created, opened
    var id: String { rawValue }
    var column: String {
        switch self {
        case .modified: "modified_at"
        case .created: "created_at"
        case .opened: "opened_at"
        }
    }
    var title: String {
        switch self {
        case .modified: "Modified"
        case .created: "Created"
        case .opened: "Last Opened"
        }
    }
}

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    var showSystemFiles: Bool { didSet { defaults.set(showSystemFiles, forKey: "showSystemFiles") } }
    var showHiddenFiles: Bool { didSet { defaults.set(showHiddenFiles, forKey: "showHiddenFiles") } }
    var treatPackagesAsItems: Bool { didSet { defaults.set(treatPackagesAsItems, forKey: "treatPackagesAsItems") } }
    var excludedPaths: [String] { didSet { defaults.set(excludedPaths, forKey: "excludedPaths") } }
    var clusterDateField: ClusterDateField { didSet { defaults.set(clusterDateField.rawValue, forKey: "clusterDateField") } }
    var trashConfirmCount: Int { didSet { defaults.set(trashConfirmCount, forKey: "trashConfirmCount") } }
    var trashConfirmGB: Double { didSet { defaults.set(trashConfirmGB, forKey: "trashConfirmGB") } }
    var showMiniMap: Bool { didSet { defaults.set(showMiniMap, forKey: "showMiniMap") } }
    var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: "onboardingDone") } }
    var limitedMode: Bool { didSet { defaults.set(limitedMode, forKey: "limitedMode") } }
    var showPins: Bool { didSet { defaults.set(showPins, forKey: "showPins") } }
    var showInfo: Bool { didSet { defaults.set(showInfo, forKey: "showInfo") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "showSystemFiles": false, "showHiddenFiles": false, "treatPackagesAsItems": true,
            "clusterDateField": ClusterDateField.modified.rawValue, "trashConfirmCount": 50, "trashConfirmGB": 1.0,
            "showMiniMap": true, "onboardingDone": false, "limitedMode": false, "showPins": true, "showInfo": false,
        ])
        showSystemFiles = defaults.bool(forKey: "showSystemFiles")
        showHiddenFiles = defaults.bool(forKey: "showHiddenFiles")
        treatPackagesAsItems = defaults.bool(forKey: "treatPackagesAsItems")
        excludedPaths = defaults.stringArray(forKey: "excludedPaths") ?? []
        clusterDateField = ClusterDateField(rawValue: defaults.string(forKey: "clusterDateField") ?? "") ?? .modified
        trashConfirmCount = defaults.integer(forKey: "trashConfirmCount")
        trashConfirmGB = defaults.double(forKey: "trashConfirmGB")
        showMiniMap = defaults.bool(forKey: "showMiniMap")
        onboardingDone = defaults.bool(forKey: "onboardingDone")
        limitedMode = defaults.bool(forKey: "limitedMode")
        showPins = defaults.bool(forKey: "showPins")
        showInfo = defaults.bool(forKey: "showInfo")
    }

    var visibility: VisibilityFilter {
        VisibilityFilter(showHidden: showHiddenFiles, showSystem: showSystemFiles)
    }

    var trashConfirmBytes: Int64 { Int64(trashConfirmGB * 1_000_000_000) }

    func scanPolicy(limitedTo allowed: [String]?) -> ScanPolicy {
        ScanPolicy(excludedPaths: excludedPaths, treatPackagesAsItems: treatPackagesAsItems, allowedPaths: allowed)
    }
}
