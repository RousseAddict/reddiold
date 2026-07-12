import Foundation

/// Disk cache for raw network responses (feed/comment Atom XML and thumbnail image data),
/// keyed by request URL. Persists across app launches so re-visiting an already-fetched
/// subreddit/sort/comment-thread/image doesn't hit Reddit again within `maxAge` — avoids
/// re-triggering the rate limiter and speeds up repeat visits. Same
/// NSSearchPathForDirectoriesInDomains + CharacterSet.alphanumerics.inverted key-sanitizing
/// pattern as oldpipe's AsyncImageView disk cache (confirmed safe on real iOS 6).
/// Wiped entirely from Settings > Clear Cache (SettingsVC).
final class FeedCache {
    private static let directory: String = {
        let dirs = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)
        let base = dirs.first ?? NSTemporaryDirectory()
        let dir = (base as NSString).appendingPathComponent("com.reddiold.feedcache")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        return dir
    }()

    private static let nonAlphanumerics = CharacterSet.alphanumerics.inverted

    private static func path(forKey key: String) -> String {
        let safe = key.components(separatedBy: nonAlphanumerics).joined(separator: "_")
        let trimmed = safe.count > 150 ? String(safe.suffix(150)) : safe
        return (directory as NSString).appendingPathComponent(trimmed)
    }

    /// Returns cached data for `key` if present and not older than `maxAge` seconds.
    static func data(forKey key: String, maxAge: TimeInterval) -> Data? {
        let filePath = path(forKey: key)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
              let modDate = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modDate) <= maxAge else {
            return nil
        }
        return try? Data(contentsOf: URL(fileURLWithPath: filePath))
    }

    /// Returns cached data for `key` regardless of age — used for the "show stale content
    /// instantly, then decide whether to refresh in the background" pattern in PostListVC.
    static func data(forKey key: String) -> Data? {
        return try? Data(contentsOf: URL(fileURLWithPath: path(forKey: key)))
    }

    /// Last-modified date of the cached entry for `key`, or nil if never cached — used to
    /// show "Updated Xm ago" and to decide whether cached content is old enough (per the
    /// user's configured AppSettings.autoRefreshTTL) to warrant a silent background refresh.
    static func modificationDate(forKey key: String) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path(forKey: key)),
              let modDate = attrs[.modificationDate] as? Date else {
            return nil
        }
        return modDate
    }

    static func store(_ data: Data, forKey key: String) {
        try? data.write(to: URL(fileURLWithPath: path(forKey: key)), options: .atomic)
    }

    /// Wipes the entire disk cache.
    static func clearAll() {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for name in contents {
            try? FileManager.default.removeItem(atPath: (directory as NSString).appendingPathComponent(name))
        }
    }

    /// Total bytes currently on disk across all cached feed/comment/thumbnail entries —
    /// shown on the Settings screen next to "Clear Cache".
    static func totalSizeBytes() -> Int64 {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return 0 }
        var total: Int64 = 0
        for name in contents {
            let filePath = (directory as NSString).appendingPathComponent(name)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return total
    }
}
