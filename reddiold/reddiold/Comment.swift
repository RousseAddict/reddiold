import Foundation

/// Flat comment entry parsed from a Reddit Atom comments feed (fullname prefix "t1_").
/// No parent_id/depth field in RSS — comments render as a flat, document-ordered list.
struct Comment {
    let id: String
    let author: String
    let bodyHTML: String
    let createdAt: Date?

    init?(entry: AtomEntry) {
        guard entry.id.hasPrefix("t1_") else { return nil }
        id = entry.id
        author = entry.authorName
        bodyHTML = entry.contentHTML
        createdAt = AtomDate.parse(entry.updated)
    }

    // Plist-safe dictionary representation for UserDefaults storage (SavedPostsStore's
    // per-post comment cache) — same rationale as Post.asDictionary: Codable/JSONEncoder
    // is iOS 11+ only, unsafe on this project's iOS 6/7/8 targets.
    var asDictionary: [String: Any] {
        var dict: [String: Any] = ["id": id, "author": author, "bodyHTML": bodyHTML]
        if let createdAt = createdAt { dict["createdAt"] = createdAt.timeIntervalSince1970 }
        return dict
    }

    init?(dictionary dict: [String: Any]) {
        guard let id = dict["id"] as? String,
              let author = dict["author"] as? String,
              let bodyHTML = dict["bodyHTML"] as? String else { return nil }
        self.id = id
        self.author = author
        self.bodyHTML = bodyHTML
        if let interval = dict["createdAt"] as? Double {
            self.createdAt = Date(timeIntervalSince1970: interval)
        } else {
            self.createdAt = nil
        }
    }
}
