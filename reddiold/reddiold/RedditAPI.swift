import Foundation

/// High-level Reddit access built on the public Atom/RSS feeds (old.reddit.com/*.rss) —
/// no OAuth, no API key. Bare-minimum version: always routes through CurlFetcher since
/// this is an iOS 6-only build (iOS 6 Secure Transport is CBC-only and can't negotiate
/// the GCM cipher suites Reddit's edge requires).
final class RedditAPI {

    static let userAgent = "reddiold/0.1 (iOS; +https://github.com/rousseaddict/reddiold)"

    private static let parseQueue = DispatchQueue(label: "com.reddiold.parse")

    // Comments are fetched on-demand per visit (not auto-refreshed on a timer like listings),
    // so a short fixed freshness window is enough to dodge Reddit's rate limiter on repeat
    // taps within the same sitting without needing a user-facing setting.
    private static let commentsCacheMaxAge: TimeInterval = 120 // 2 min

    enum Sort: String {
        case hot, new, top, rising
    }

    /// subreddit == nil fetches the front page; a "+"-joined name (e.g. "a+b+c") fetches
    /// Reddit's ad-hoc multireddit combined listing (confirmed working unauthenticated,
    /// server-side chronologically interleaved, gracefully skips any joined name that's
    /// invalid/banned/private rather than erroring the whole request) — used by FavoritesFeedVC.
    private static func listingPath(subreddit: String?, sort: Sort) -> String {
        var path = "https://old.reddit.com"
        if let subreddit = subreddit, !subreddit.isEmpty {
            path += "/r/\(subreddit)"
        }
        path += "/\(sort.rawValue)/.rss"
        return path
    }

    /// Last-modified date of the on-disk cached response for this listing, or nil if never
    /// cached — PostListVC uses this both for the "Updated Xm ago" label and to decide
    /// whether cached content is stale enough (per AppSettings.autoRefreshTTL) to silently
    /// refresh in the background.
    static func listingCacheDate(subreddit: String?, sort: Sort) -> Date? {
        return FeedCache.modificationDate(forKey: listingPath(subreddit: subreddit, sort: sort))
    }

    /// Parses whatever is currently on disk for this listing, regardless of age. Calls back
    /// with an empty array (not an error) if nothing has ever been cached — this is only
    /// meant for the "show stale content instantly" step, not a real fetch.
    static func cachedListing(subreddit: String?, sort: Sort, completion: @escaping ([Post]) -> Void) {
        guard let data = FeedCache.data(forKey: listingPath(subreddit: subreddit, sort: sort)) else {
            completion([])
            return
        }
        parseQueue.async {
            let entries = AtomFeedParser.parseEntries(data: data)
            let posts = entries.compactMap { Post(entry: $0) }
            DispatchQueue.main.async { completion(posts) }
        }
    }

    /// Always hits the network and re-stores the fresh response to disk — used for the
    /// initial cold load (nothing cached yet), pull-to-refresh/retry (explicit user intent),
    /// and PostListVC's TTL-based silent background refresh of stale cached content.
    static func fetchListing(subreddit: String?, sort: Sort = .hot,
                              completion: @escaping ([Post], Error?) -> Void) {
        let path = listingPath(subreddit: subreddit, sort: sort)
        guard let url = URL(string: path) else {
            completion([], NSError(domain: "RedditAPI", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return
        }

        CurlFetcher.fetch(url: url, userAgent: userAgent) { data, error in
            guard let data = data, error == nil else {
                DispatchQueue.main.async { completion([], error) }
                return
            }
            FeedCache.store(data, forKey: path)
            parseQueue.async {
                let entries = AtomFeedParser.parseEntries(data: data)
                let posts = entries.compactMap { Post(entry: $0) }
                DispatchQueue.main.async { completion(posts, nil) }
            }
        }
    }

    /// Scrapes the classic (non-JS) old.reddit.com permalink HTML page for a gallery post's
    /// full-resolution image URLs. The .rss feed only ever exposes ONE preview thumbnail for
    /// a gallery post (confirmed via curl) — old.reddit.com still server-renders the gallery
    /// grid as plain HTML (a "gallery-tile" per image, each with its own "media-tile-{postId}-
    /// {mediaId}" id and a same-tile "preview.redd.it/{mediaId}.{ext}" <img>), which resolves
    /// 1:1 to a full-res "i.redd.it/{mediaId}.{ext}" URL (confirmed via curl, HTTP 200).
    /// Only called on-demand (user taps "Gallery" in PostVC) — never from the listing/list
    /// view — to avoid extra requests against Reddit's rate limiter on every post shown.
    /// Cached indefinitely on disk keyed by permalink (gallery contents don't change).
    static func fetchGalleryImageURLs(permalink: String, completion: @escaping ([String], Error?) -> Void) {
        guard let url = URL(string: permalink) else {
            completion([], NSError(domain: "RedditAPI", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return
        }

        if let cached = FeedCache.data(forKey: permalink) {
            parseQueue.async {
                let html = String(data: cached, encoding: .utf8) ?? ""
                let urls = GalleryHTMLParser.imageURLs(fromHTML: html)
                DispatchQueue.main.async { completion(urls, nil) }
            }
            return
        }

        CurlFetcher.fetch(url: url, userAgent: userAgent) { data, error in
            guard let data = data, error == nil else {
                DispatchQueue.main.async { completion([], error) }
                return
            }
            FeedCache.store(data, forKey: permalink)
            parseQueue.async {
                let html = String(data: data, encoding: .utf8) ?? ""
                let urls = GalleryHTMLParser.imageURLs(fromHTML: html)
                DispatchQueue.main.async { completion(urls, nil) }
            }
        }
    }

    static func fetchComments(subreddit: String, postId: String, forceRefresh: Bool = false,
                               completion: @escaping ([Comment], Error?) -> Void) {
        let path = "https://old.reddit.com/r/\(subreddit)/comments/\(postId)/.rss"

        guard let url = URL(string: path) else {
            completion([], NSError(domain: "RedditAPI", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return
        }

        if !forceRefresh, let cached = FeedCache.data(forKey: path, maxAge: commentsCacheMaxAge) {
            parseQueue.async {
                let entries = AtomFeedParser.parseEntries(data: cached)
                let comments = entries.compactMap { Comment(entry: $0) }
                DispatchQueue.main.async { completion(comments, nil) }
            }
            return
        }

        CurlFetcher.fetch(url: url, userAgent: userAgent) { data, error in
            guard let data = data, error == nil else {
                DispatchQueue.main.async { completion([], error) }
                return
            }
            FeedCache.store(data, forKey: path)
            parseQueue.async {
                let entries = AtomFeedParser.parseEntries(data: data)
                let comments = entries.compactMap { Comment(entry: $0) }
                DispatchQueue.main.async { completion(comments, nil) }
            }
        }
    }
}

/// Manual scanner (no NSRegularExpression, matches this project's plain-string-parsing
/// convention — see HTMLUtil) for old.reddit.com's server-rendered gallery grid markup:
///   <div class="gallery-tile ..." id="media-tile-{postId}-{mediaId}" ...>
///     <img class="preview" src="https://preview.redd.it/{mediaId}.{ext}?..." ...>
/// Each tile's own preview <img> always immediately follows its id attribute (confirmed via
/// curl), so a small bounded forward-scan per "media-tile-" marker is enough — no need to
/// locate the matching closing </div>. The permalink page is specific to one post, so every
/// "media-tile-" marker on it belongs to this post's own gallery (no postId filtering needed).
private struct GalleryHTMLParser {
    static func imageURLs(fromHTML html: String) -> [String] {
        var results: [String] = []
        var seen = Set<String>()
        var remainder = Substring(html)

        while let tileRange = remainder.range(of: "id=\"media-tile-") {
            remainder = remainder[tileRange.upperBound...]
            let window = remainder.prefix(400)
            guard let previewRange = window.range(of: "preview.redd.it/") else { continue }
            let afterPrefix = window[previewRange.upperBound...]
            guard let dotRange = afterPrefix.range(of: ".") else { continue }
            let mediaId = String(afterPrefix[..<dotRange.lowerBound])
            let afterDot = afterPrefix[dotRange.upperBound...]
            guard let extEnd = afterDot.firstIndex(where: { $0 == "?" || $0 == "\"" }) else { continue }
            let ext = String(afterDot[..<extEnd])
            guard !mediaId.isEmpty, !ext.isEmpty else { continue }

            let fullURL = "https://i.redd.it/\(mediaId).\(ext)"
            if seen.insert(fullURL).inserted {
                results.append(fullURL)
            }
        }
        return results
    }
}
