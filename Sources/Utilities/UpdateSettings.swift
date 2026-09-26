import Foundation

/// Background checks and downloads remain opt-in. Installation always starts
/// from an explicit user action, independently of this preference.
@MainActor
final class UpdateSettings: ObservableObject {
    static let shared = UpdateSettings()

    /// Minimum time between automatic checks — once a day. `nonisolated` so the
    /// pure `isDue(...)` helper can use it as a default argument off the main actor.
    nonisolated static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults

    private let automaticallyCheckKey = "automaticallyCheckForUpdates"
    private let lastCheckKey = "lastUpdateCheckTimestamp"

    @Published var automaticallyCheckForUpdates: Bool {
        didSet {
            defaults.set(automaticallyCheckForUpdates, forKey: automaticallyCheckKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Absent key → `bool(forKey:)` returns false, which is the intended default.
        self.automaticallyCheckForUpdates = defaults.bool(forKey: automaticallyCheckKey)
    }

    var lastCheckDate: Date? {
        let timestamp = defaults.double(forKey: lastCheckKey)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    func markCheckedNow(date: Date = Date()) {
        defaults.set(date.timeIntervalSince1970, forKey: lastCheckKey)
    }

    /// True when the opt-in is on *and* enough time has elapsed since the last check.
    func isDueForAutomaticCheck(now: Date = Date()) -> Bool {
        guard automaticallyCheckForUpdates else { return false }
        return Self.isDue(lastCheck: lastCheckDate, now: now, interval: Self.automaticCheckInterval)
    }

    /// Pure timing helper (no `UserDefaults`), kept `nonisolated` so it can be
    /// unit-tested synchronously off the main actor.
    nonisolated static func isDue(lastCheck: Date?, now: Date, interval: TimeInterval = automaticCheckInterval) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }
}
