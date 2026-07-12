import Foundation

/// Persists full Post snapshots (not just ids) for offline viewing — RSS offers no
/// "fetch single post by id" lookup, so the whole Post needs to be stored at save time.
/// Same UserDefaults-backed static-accessor style as FavoritesStore, using plain
/// [String: Any] dictionaries (Post.asDictionary/init(dictionary:)) rather than
/// JSONEncoder/Codable, which is iOS 11+ only and unsafe on this project's iOS 6/7/8 targets.
final class SavedPostsStore {
    private static let key = "reddiold.savedPosts"

    // Per-post cached comment list, keyed by post id — [postId: [Comment.asDictionary]].
    // Populated whenever a saved post's comments are loaded in PostVC, so they're still
    // readable from SavedPostsVC with no network (unlike FeedCache's comment entries, which
    // are wiped by Settings > Clear Cache and only kept for a short freshness window).
    private static let commentsKey = "reddiold.savedPostComments"

    static func all() -> [Post] {
        guard let raw = UserDefaults.standard.array(forKey: key) as? [[String: Any]] else { return [] }
        return raw.compactMap { Post(dictionary: $0) }
    }

    static func contains(_ postId: String) -> Bool {
        return all().contains { $0.id == postId }
    }

    static func add(_ post: Post) {
        guard !contains(post.id) else { return }
        var raw = (UserDefaults.standard.array(forKey: key) as? [[String: Any]]) ?? []
        raw.insert(post.asDictionary, at: 0)
        UserDefaults.standard.set(raw, forKey: key)
    }

    static func remove(_ postId: String) {
        guard let raw = UserDefaults.standard.array(forKey: key) as? [[String: Any]] else { return }
        let filtered = raw.filter { ($0["id"] as? String) != postId }
        UserDefaults.standard.set(filtered, forKey: key)
        removeComments(forPostId: postId)
    }

    static func comments(forPostId postId: String) -> [Comment]? {
        guard let all = UserDefaults.standard.dictionary(forKey: commentsKey) as? [String: [[String: Any]]],
              let raw = all[postId] else { return nil }
        return raw.compactMap { Comment(dictionary: $0) }
    }

    static func saveComments(_ comments: [Comment], forPostId postId: String) {
        var all = (UserDefaults.standard.dictionary(forKey: commentsKey) as? [String: [[String: Any]]]) ?? [:]
        all[postId] = comments.map { $0.asDictionary }
        UserDefaults.standard.set(all, forKey: commentsKey)
    }

    static func removeComments(forPostId postId: String) {
        guard var all = UserDefaults.standard.dictionary(forKey: commentsKey) as? [String: [[String: Any]]] else { return }
        all.removeValue(forKey: postId)
        UserDefaults.standard.set(all, forKey: commentsKey)
    }
}
