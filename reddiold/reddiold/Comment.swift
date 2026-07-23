import Foundation

/// Comment entry parsed from old.reddit.com's plain (non-JS) permalink HTML page — NOT the
/// Atom `.rss` comments feed, which is flat/document-ordered with no threading or score data.
/// The permalink page still server-renders the full nested reply tree as real `<div class=
/// "child">`-wrapped DOM (see CommentHTMLParser in RedditAPI.swift), which is what makes
/// `depth`/`score` possible here. `isMoreStub`/`moreCount` represent Reddit's own "load more
/// comments" truncation placeholder for a deeply/heavily-replied branch — expanding those
/// requires the `api/morechildren` endpoint, presumed blocked by the same bot-detection wall
/// as `.json`, so they're rendered as a non-expandable "N more replies" row that links out to
/// the full thread on reddit.com instead (see PostVC).
struct Comment {
    let id: String
    let author: String
    let bodyHTML: String
    let createdAt: Date?
    let depth: Int
    let score: Int?
    let isMoreStub: Bool
    let moreCount: Int

    init(id: String, author: String, bodyHTML: String, createdAt: Date?, depth: Int = 0,
         score: Int? = nil, isMoreStub: Bool = false, moreCount: Int = 0) {
        self.id = id
        self.author = author
        self.bodyHTML = bodyHTML
        self.createdAt = createdAt
        self.depth = depth
        self.score = score
        self.isMoreStub = isMoreStub
        self.moreCount = moreCount
    }

    // Plist-safe dictionary representation for UserDefaults storage (SavedPostsStore's
    // per-post comment cache) — same rationale as Post.asDictionary: Codable/JSONEncoder
    // is iOS 11+ only, unsafe on this project's iOS 6/7/8 targets.
    var asDictionary: [String: Any] {
        var dict: [String: Any] = ["id": id, "author": author, "bodyHTML": bodyHTML,
                                    "depth": depth, "isMoreStub": isMoreStub, "moreCount": moreCount]
        if let createdAt = createdAt { dict["createdAt"] = createdAt.timeIntervalSince1970 }
        if let score = score { dict["score"] = score }
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
        // (x as? NSNumber)?.intValue, not (x as? Int) — the latter silently returns nil on
        // this project's iOS 6 / Swift 5.1.5 runtime (see project conventions).
        self.depth = (dict["depth"] as? NSNumber)?.intValue ?? 0
        self.score = (dict["score"] as? NSNumber)?.intValue
        self.isMoreStub = (dict["isMoreStub"] as? Bool) ?? false
        self.moreCount = (dict["moreCount"] as? NSNumber)?.intValue ?? 0
    }
}
