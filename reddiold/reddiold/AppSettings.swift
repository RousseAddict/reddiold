import Foundation

/// Small UserDefaults-backed settings store, same static-accessor style as FeedCache.
final class AppSettings {
    private static let ttlIndexKey = "reddiold.autoRefreshTTLIndex"
    private static let defaultTTLIndex = 2 // "24h"

    /// Choices shown in Settings for how stale a cached feed listing can get before
    /// PostListVC silently re-fetches it in the background on next appear. `seconds == nil`
    /// ("Never") means pure pull-to-refresh-only — cached content is never auto-refreshed.
    static let autoRefreshOptions: [(title: String, seconds: TimeInterval?)] = [
        ("1h", 3600),
        ("6h", 6 * 3600),
        ("24h", 24 * 3600),
        ("Never", nil)
    ]

    static var autoRefreshTTLIndex: Int {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: ttlIndexKey) != nil else { return defaultTTLIndex }
            let index = defaults.integer(forKey: ttlIndexKey)
            return (0..<autoRefreshOptions.count).contains(index) ? index : defaultTTLIndex
        }
        set { UserDefaults.standard.set(newValue, forKey: ttlIndexKey) }
    }

    static var autoRefreshTTL: TimeInterval? {
        return autoRefreshOptions[autoRefreshTTLIndex].seconds
    }
}
