import Foundation

/// Classifies what a post's external "[link]" (embedded in the Atom <content>) points to.
/// RSS never gives us more than this classification + a single preview thumbnail — actual
/// gallery images / video playback URLs require an additional on-demand fetch (see
/// RedditAPI.fetchGalleryImageURLs and PostVC's HLS playback), only triggered when the
/// user taps into the post, to avoid extra requests against Reddit's rate limiter.
enum PostMediaKind: Equatable {
    case gallery
    case video(videoId: String)
    case other

    var dictionaryValue: String {
        switch self {
        case .gallery: return "gallery"
        case .video(let videoId): return "video:\(videoId)"
        case .other: return "other"
        }
    }

    init(dictionaryValue: String?) {
        guard let value = dictionaryValue else { self = .other; return }
        if value == "gallery" {
            self = .gallery
        } else if value.hasPrefix("video:") {
            self = .video(videoId: String(value.dropFirst("video:".count)))
        } else {
            self = .other
        }
    }
}

/// Post metadata parsed from a Reddit Atom feed entry (fullname prefix "t3_").
/// Score is not available via RSS — kept as an unused placeholder.
struct Post {
    let id: String
    let title: String
    let author: String
    let subreddit: String
    let permalink: String
    let thumbnailURL: String?
    let contentHTML: String
    let createdAt: Date?
    let score: Int? = nil
    let mediaKind: PostMediaKind
    // The "[link]" href when it points somewhere other than this post's own permalink —
    // i.e. this is a link post (not a self-text post). Gallery/video posts also have a
    // linkURL but PostVC only surfaces it as a plain tappable link for .other kind, since
    // gallery/video already get their own dedicated tap-to-view/play handling.
    let linkURL: String?

    var displayableThumbnailURL: String? {
        guard let url = thumbnailURL, url.hasPrefix("http") else { return nil }
        return url
    }

    // Reddit's Atom <content> always appends a "submitted by <author> to <subreddit> ..."
    // chrome line (plus [link]/[comments] anchors) after the real body — cut everything
    // from that marker onward so self-text posts show just the selftext, and link posts
    // (whose content is only a thumbnail <img> + that chrome) resolve to nil (no body to show).
    var displayableBodyText: String? {
        var raw = contentHTML
        if let range = raw.range(of: "submitted by", options: .caseInsensitive) {
            raw = String(raw[..<range.lowerBound])
        }
        let text = HTMLUtil.stripTags(raw)
        return text.isEmpty ? nil : text
    }

    init?(entry: AtomEntry) {
        guard entry.id.hasPrefix("t3_"), !entry.title.isEmpty else { return nil }
        id = entry.id
        title = entry.title
        author = entry.authorName
        subreddit = entry.subreddit
        permalink = entry.link
        thumbnailURL = entry.thumbnailURL
        contentHTML = entry.contentHTML
        createdAt = AtomDate.parse(entry.updated)
        let linkHref = Post.extractLinkHref(from: entry.contentHTML)
        mediaKind = Post.classifyMedia(linkHref: linkHref, permalink: entry.link)
        linkURL = (linkHref != entry.link) ? linkHref : nil
    }

    // Plain memberwise init for reconstructing a Post from SavedPostsStore's persisted
    // dictionary form (see asDictionary below) — not used for parsing Atom feed entries.
    init(id: String, title: String, author: String, subreddit: String, permalink: String,
         thumbnailURL: String?, contentHTML: String, createdAt: Date?, mediaKind: PostMediaKind = .other,
         linkURL: String? = nil) {
        self.id = id
        self.title = title
        self.author = author
        self.subreddit = subreddit
        self.permalink = permalink
        self.thumbnailURL = thumbnailURL
        self.contentHTML = contentHTML
        self.createdAt = createdAt
        self.mediaKind = mediaKind
        self.linkURL = linkURL
    }

    // Extracts the href of the "[link]" anchor embedded in the Atom entry's <content>
    // (confirmed present for every post kind, including self-text — where it just points
    // back at the permalink itself). This is the only signal RSS gives us about whether a
    // post is a gallery (reddit.com/gallery/{id}) or native video (v.redd.it/{id}).
    // Manual string scanning (no NSRegularExpression) to match this project's existing
    // hand-rolled parsing style (see HTMLUtil).
    static func extractLinkHref(from contentHTML: String) -> String? {
        guard let markerRange = contentHTML.range(of: ">[link]<") else { return nil }
        let before = contentHTML[..<markerRange.lowerBound]
        guard let hrefStart = before.range(of: "href=\"", options: .backwards) else { return nil }
        let afterHref = before[hrefStart.upperBound...]
        guard let hrefEnd = afterHref.range(of: "\"") else { return nil }
        return String(afterHref[..<hrefEnd.lowerBound])
    }

    static func classifyMedia(linkHref: String?, permalink: String) -> PostMediaKind {
        guard let href = linkHref, href != permalink else { return .other }
        if href.contains("reddit.com/gallery/") {
            return .gallery
        }
        if let range = href.range(of: "https://v.redd.it/") {
            let videoId = String(href[range.upperBound...].split(separator: "/").first ?? "")
            if !videoId.isEmpty { return .video(videoId: videoId) }
        }
        return .other
    }

    // Plist-safe dictionary representation for UserDefaults storage (SavedPostsStore).
    // Deliberately not Codable/JSONEncoder — that API is iOS 11+ only, unsafe on this
    // project's iOS 6/7/8 targets. UserDefaults natively supports [String: Any] dictionaries
    // of plist-compatible types (String/Double/etc.) since iOS 2.
    var asDictionary: [String: Any] {
        var dict: [String: Any] = [
            "id": id, "title": title, "author": author, "subreddit": subreddit,
            "permalink": permalink, "contentHTML": contentHTML, "mediaKind": mediaKind.dictionaryValue
        ]
        if let thumbnailURL = thumbnailURL { dict["thumbnailURL"] = thumbnailURL }
        if let createdAt = createdAt { dict["createdAt"] = createdAt.timeIntervalSince1970 }
        if let linkURL = linkURL { dict["linkURL"] = linkURL }
        return dict
    }

    init?(dictionary dict: [String: Any]) {
        guard let id = dict["id"] as? String,
              let title = dict["title"] as? String,
              let author = dict["author"] as? String,
              let subreddit = dict["subreddit"] as? String,
              let permalink = dict["permalink"] as? String,
              let contentHTML = dict["contentHTML"] as? String else { return nil }
        self.id = id
        self.title = title
        self.author = author
        self.subreddit = subreddit
        self.permalink = permalink
        self.thumbnailURL = dict["thumbnailURL"] as? String
        self.contentHTML = contentHTML
        self.mediaKind = PostMediaKind(dictionaryValue: dict["mediaKind"] as? String)
        self.linkURL = dict["linkURL"] as? String
        if let interval = dict["createdAt"] as? Double {
            self.createdAt = Date(timeIntervalSince1970: interval)
        } else {
            self.createdAt = nil
        }
    }
}
