import Foundation

/// Persists favorited subreddit names via UserDefaults — survives app relaunch.
final class FavoritesStore {
    private static let key = "reddiold.favoriteSubreddits"

    static func all() -> [String] {
        return (UserDefaults.standard.array(forKey: key) as? [String]) ?? []
    }

    static func contains(_ subreddit: String) -> Bool {
        return all().contains(subreddit)
    }

    static func add(_ subreddit: String) {
        var list = all()
        guard !list.contains(subreddit) else { return }
        list.append(subreddit)
        UserDefaults.standard.set(list, forKey: key)
    }

    static func remove(_ subreddit: String) {
        var list = all()
        list.removeAll { $0 == subreddit }
        UserDefaults.standard.set(list, forKey: key)
    }
}
