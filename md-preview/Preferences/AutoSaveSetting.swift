//
//  AutoSaveSetting.swift
//  md-preview
//

import Foundation

/// Shared interval used by the editor's periodic save timer and Settings.
enum AutoSaveSetting {
    static let defaultsKey = "MarkdownPreview.autoSaveIntervalMinutes"
    // Negative values represent sub-minute delays while preserving existing
    // minute-based preferences.
    static let instant = -2 // 2-second delay after the last edit
    static let thirtySeconds = -30
    static let disabledMinutes = 0
    static let minimumMinutes = 1
    static let maximumMinutes = 60

    static var currentMinutes: Int {
        currentMinutes(from: .standard)
    }

    static func currentMinutes(from defaults: UserDefaults) -> Int {
        guard let stored = defaults.object(forKey: defaultsKey) as? NSNumber else {
            return disabledMinutes
        }
        return clampedMinutes(stored.intValue)
    }

    static func store(minutes: Int, in defaults: UserDefaults = .standard) {
        defaults.set(clampedMinutes(minutes), forKey: defaultsKey)
    }

    static func clampedMinutes(_ minutes: Int) -> Int {
        if minutes == instant || minutes == thirtySeconds { return minutes }
        guard minutes != disabledMinutes else { return disabledMinutes }
        return min(max(minutes, minimumMinutes), maximumMinutes)
    }

    static var interval: TimeInterval? {
        interval(for: currentMinutes)
    }

    static func interval(for minutes: Int) -> TimeInterval? {
        switch minutes {
        case disabledMinutes:
            return nil
        case instant:
            return 2
        case thirtySeconds:
            return 30
        default:
            return TimeInterval(minutes * 60)
        }
    }
}
