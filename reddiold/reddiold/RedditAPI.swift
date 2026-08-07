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

    /// hot/rising apply only to plain listings; relevance/comments only to search results.
    /// new/top are valid for both.
    enum Sort: String {
        case hot, new, top, rising, relevance, comments

        /// Segmented-control label. "Relevant" rather than "Relevance" purely to fit four
        /// segments across a 320pt-wide screen.
        var displayName: String {
            switch self {
            case .hot: return "Hot"
            case .new: return "New"
            case .top: return "Top"
            case .rising: return "Rising"
            case .relevance: return "Relevant"
            case .comments: return "Comments"
            }
        }
    }

    /// Percent-encodes a search term for use in a query string. Hand-rolled because
    /// `addingPercentEncoding(withAllowedCharacters:)` / `CharacterSet.urlQueryAllowed` are
    /// iOS 7+ and crash on iOS 6. Escapes every byte outside RFC 3986's unreserved set.
    static func percentEncodeQuery(_ raw: String) -> String {
        var out = ""
        for byte in Array(raw.utf8) {
            let isUnreserved = (byte >= 0x41 && byte <= 0x5A)   // A-Z
                || (byte >= 0x61 && byte <= 0x7A)               // a-z
                || (byte >= 0x30 && byte <= 0x39)               // 0-9
                || byte == 0x2D || byte == 0x2E                 // - .
                || byte == 0x5F || byte == 0x7E                 // _ ~
            if isUnreserved {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// With `query == nil` this is a plain listing: subreddit == nil fetches the front page;
    /// a "+"-joined name (e.g. "a+b+c") fetches Reddit's ad-hoc multireddit combined listing
    /// (confirmed working unauthenticated, server-side chronologically interleaved, gracefully
    /// skips any joined name that's invalid/banned/private rather than erroring the whole
    /// request) — used by FavoritesVC.
    ///
    /// With a `query` it's a post search instead (confirmed HTTP 200 unauthenticated): either
    /// site-wide, or restricted to one subreddit when `subreddit` is also set. Search results
    /// come back as ordinary `t3_` Atom entries — same shape as a listing, so `Post(entry:)`
    /// parses them unchanged. The returned path doubles as the FeedCache key, so two different
    /// queries (or sorts) never share cached content.
    private static func listingPath(subreddit: String?, query: String?, sort: Sort) -> String {
        var path = "https://old.reddit.com"
        if let subreddit = subreddit, !subreddit.isEmpty {
            path += "/r/\(subreddit)"
        }
        guard let query = query, !query.isEmpty else {
            path += "/\(sort.rawValue)/.rss"
            return path
        }
        path += "/search/.rss?q=\(percentEncodeQuery(query))&sort=\(sort.rawValue)"
        if let subreddit = subreddit, !subreddit.isEmpty {
            path += "&restrict_sr=on"
        }
        return path
    }

    /// Last-modified date of the on-disk cached response for this listing, or nil if never
    /// cached — PostListVC uses this both for the "Updated Xm ago" label and to decide
    /// whether cached content is stale enough (per AppSettings.autoRefreshTTL) to silently
    /// refresh in the background.
    static func listingCacheDate(subreddit: String?, query: String? = nil, sort: Sort) -> Date? {
        return FeedCache.modificationDate(forKey: listingPath(subreddit: subreddit, query: query, sort: sort))
    }

    /// Parses whatever is currently on disk for this listing, regardless of age. Calls back
    /// with an empty array (not an error) if nothing has ever been cached — this is only
    /// meant for the "show stale content instantly" step, not a real fetch.
    static func cachedListing(subreddit: String?, query: String? = nil, sort: Sort,
                               completion: @escaping ([Post]) -> Void) {
        guard let data = FeedCache.data(forKey: listingPath(subreddit: subreddit, query: query, sort: sort)) else {
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
    static func fetchListing(subreddit: String?, query: String? = nil, sort: Sort = .hot,
                              completion: @escaping ([Post], Error?) -> Void) {
        let path = listingPath(subreddit: subreddit, query: query, sort: sort)
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

    /// Scrapes the same plain (non-JS) permalink HTML page used by fetchGalleryImageURLs —
    /// unlike the `.rss` comments feed (flat, document-ordered, no score/threading data at
    /// all), this page server-renders the full nested reply tree as real `<div class="child">`
    /// DOM nesting, which is what makes comment depth/score possible (see CommentHTMLParser
    /// below). No trailing slug segment needed — CurlFetcher follows Reddit's redirect to the
    /// canonical slugged URL (curl_bridge_set_follow_redirects, already set in CurlFetcher).
    static func fetchComments(subreddit: String, postId: String, forceRefresh: Bool = false,
                               completion: @escaping ([Comment], Error?) -> Void) {
        let path = "https://old.reddit.com/r/\(subreddit)/comments/\(postId)/"

        guard let url = URL(string: path) else {
            completion([], NSError(domain: "RedditAPI", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return
        }

        if !forceRefresh, let cached = FeedCache.data(forKey: path, maxAge: commentsCacheMaxAge) {
            parseQueue.async {
                let html = String(data: cached, encoding: .utf8) ?? ""
                let comments = CommentHTMLParser.parseComments(fromHTML: html)
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
                let html = String(data: data, encoding: .utf8) ?? ""
                let comments = CommentHTMLParser.parseComments(fromHTML: html)
                DispatchQueue.main.async { completion(comments, nil) }
            }
        }
    }

    /// Subreddit discovery: /subreddits/search/.rss?q= (confirmed HTTP 200 unauthenticated).
    /// Unlike post search these entries are `t5_` and have their own shape, so they parse into
    /// SubredditResult rather than Post. Cached on disk keyed by the full URL; subreddit
    /// descriptions change rarely and the point of the cache is to survive a user re-running
    /// the same search, which is exactly what trips Reddit's rate limiter.
    static func searchSubreddits(query: String, forceRefresh: Bool = false,
                                  completion: @escaping ([SubredditResult], Error?) -> Void) {
        let path = "https://old.reddit.com/subreddits/search/.rss?q=\(percentEncodeQuery(query))"
        guard let url = URL(string: path) else {
            completion([], NSError(domain: "RedditAPI", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return
        }

        if !forceRefresh, let cached = FeedCache.data(forKey: path) {
            parseQueue.async {
                let results = AtomFeedParser.parseEntries(data: cached).compactMap { SubredditResult(entry: $0) }
                DispatchQueue.main.async { completion(results, nil) }
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
                let results = AtomFeedParser.parseEntries(data: data).compactMap { SubredditResult(entry: $0) }
                DispatchQueue.main.async { completion(results, nil) }
            }
        }
    }
}

/// One hit from /subreddits/search/.rss (Atom fullname prefix "t5_").
/// Note the entry's <title> is the subreddit's *display* title ("Retro Reddit"), NOT its r/
/// name — the only place the actual name appears is the <link href> ("…/r/Retro/"), so that's
/// what navigation has to use. Subscriber counts aren't exposed by RSS at all.
struct SubredditResult {
    let name: String
    let displayTitle: String
    let summary: String?

    init?(entry: AtomEntry) {
        guard entry.id.hasPrefix("t5_"),
              let name = SubredditResult.extractName(fromLink: entry.link), !name.isEmpty else { return nil }
        self.name = name
        self.displayTitle = entry.title
        let text = HTMLUtil.stripTags(entry.contentHTML)
        self.summary = text.isEmpty ? nil : text
    }

    /// "https://old.reddit.com/r/Retro/" -> "Retro"
    static func extractName(fromLink link: String) -> String? {
        guard let range = link.range(of: "/r/") else { return nil }
        let rest = link[range.upperBound...]
        return String(rest.split(separator: "/").first ?? "")
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

/// Manual scanner (no NSRegularExpression, same convention as GalleryHTMLParser/HTMLUtil) for
/// old.reddit.com's server-rendered nested comment tree on the plain permalink page:
///   <div class=" thing id-t1_XXX ... comment " data-type="comment" data-fullname="t1_XXX"
///        data-author="..." ...>
///     <div class="entry unvoted">
///       <p class="tagline">
///         <span class="score unvoted" title="5297">5297 points</span>
///         <time datetime="2026-07-23T12:27:03+00:00" ...>
///       <div class="md">...comment body...</div>
///     </div>
///     <div class="child">  <!-- present only when there are replies -->
///       <div class=" thing id-t1_YYY ... comment " ...>  <!-- one level deeper -->
///     </div>
///   </div>
/// A truncated branch renders a "load more comments" stub instead of continuing to expand:
///   <div class=" thing id-t1_XXX ... morechildren " data-type="morechildren" ...>
///     <span class="morecomments"><a ...>load more comments<span class="gray">
///       &nbsp;(1 reply)</span></a></span>
/// Expanding those needs Reddit's `api/morechildren` endpoint (presumed blocked by the same
/// bot wall as `.json`), so they're surfaced as a non-expandable Comment(isMoreStub: true).
///
/// Depth of a comment == the number of `<div class="child">` wrapper divs currently enclosing
/// it — tracked via a stack-based linear scan of every `<div>`/`</div>` tag in document order.
/// This is safe because Reddit's markdown-to-HTML renderer for comment bodies (the "md" div's
/// content) never emits raw `<div>` tags (confirmed by inspecting a real 1100+-comment thread),
/// so div nesting stays balanced around comment content.
// Byte-array/integer-offset based scanner — NOT Substring/String.Index based. A prior
// Substring-based implementation of this parser was profiled against a real ~800KB permalink
// page and found to be O(n²)-like: Substring.range(of:) bridges to NSString (a copy) on every
// single call, so its cost scales with the REMAINING substring length, not the actual gap to
// the next match. That made real (200+ comment) threads take minutes to parse — the direct
// cause of a "stuck on Loading..." bug. This version scans a plain [UInt8] with a hand-written
// find() that's a true early-exit forward byte scan (cost proportional to the actual gap).
// Small extracted spans (ids, authors, scores, timestamps, body HTML) are decoded to String
// only once, at the point of final extraction — never during scanning.
private struct CommentHTMLParser {
    private enum DivToken {
        case open(tagStart: Int)
        case close(tagStart: Int)
    }

    static func parseComments(fromHTML html: String) -> [Comment] {
        let bytes = Array(html.utf8)
        var results: [Comment] = []
        // One entry per currently-open <div>: true if that div's own class is exactly
        // "child" (a reply-nesting wrapper) — used to pop currentDepth back down correctly
        // when it closes, without needing to re-scan the whole stack every time.
        var stack: [Bool] = []
        var currentDepth = 0
        var cursor = 0

        while let token = nextDivToken(in: bytes, from: cursor) {
            switch token {
            case .close(let tagStart):
                guard let tagEnd = scanToTagEnd(bytes, from: tagStart) else { return results }
                if let wasChildWrapper = stack.popLast(), wasChildWrapper {
                    currentDepth -= 1
                }
                cursor = tagEnd

            case .open(let tagStart):
                guard let tagEnd = scanToTagEnd(bytes, from: tagStart) else { return results }
                let tagText = String(decoding: bytes[tagStart..<tagEnd], as: UTF8.self)
                let depth = currentDepth

                let classValue = attributeValue(in: tagText, name: "class") ?? ""
                let isChildWrapper = classValue.trimmingCharacters(in: .whitespaces) == "child"
                stack.append(isChildWrapper)
                if isChildWrapper { currentDepth += 1 }

                switch attributeValue(in: tagText, name: "data-type") {
                case "comment":
                    if let comment = parseCommentEntry(tagText: tagText, bytes: bytes, from: tagEnd, depth: depth) {
                        results.append(comment)
                    }
                case "morechildren":
                    if let stub = parseMoreStub(tagText: tagText, bytes: bytes, from: tagEnd, depth: depth) {
                        results.append(stub)
                    }
                default:
                    break
                }
                cursor = tagEnd
            }
        }
        return results
    }

    private static func find(_ pattern: [UInt8], in bytes: [UInt8], from: Int) -> Int? {
        let n = bytes.count
        let m = pattern.count
        guard m > 0, from >= 0, from + m <= n else { return nil }
        let first = pattern[0]
        var i = from
        let last = n - m
        while i <= last {
            if bytes[i] == first {
                var j = 1
                while j < m, bytes[i + j] == pattern[j] { j += 1 }
                if j == m { return i }
            }
            i += 1
        }
        return nil
    }

    private static func find(_ pattern: String, in bytes: [UInt8], from: Int) -> Int? {
        find(Array(pattern.utf8), in: bytes, from: from)
    }

    private static func nextDivToken(in bytes: [UInt8], from: Int) -> DivToken? {
        let openIdx = find("<div", in: bytes, from: from)
        let closeIdx = find("</div", in: bytes, from: from)
        switch (openIdx, closeIdx) {
        case (nil, nil): return nil
        case (let o?, nil): return .open(tagStart: o)
        case (nil, let c?): return .close(tagStart: c)
        case (let o?, let c?): return o <= c ? .open(tagStart: o) : .close(tagStart: c)
        }
    }

    // Scans forward from a "<div"/"</div" marker to the end of that tag (its own, unquoted
    // ">"), tracking quote state so a ">" inside an attribute value (e.g. an onclick handler
    // string) doesn't end the tag early.
    private static func scanToTagEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        let dquote: UInt8 = 0x22, squote: UInt8 = 0x27, gt: UInt8 = 0x3E
        var inQuote: UInt8?
        var i = start
        let n = bytes.count
        while i < n {
            let b = bytes[i]
            if let q = inQuote {
                if b == q { inQuote = nil }
            } else if b == dquote || b == squote {
                inQuote = b
            } else if b == gt {
                return i + 1
            }
            i += 1
        }
        return nil
    }

    private static func attributeValue(in tag: String, name: String) -> String? {
        guard let range = tag.range(of: "\(name)=\"") else { return nil }
        let after = tag[range.upperBound...]
        guard let end = after.firstIndex(of: "\"") else { return nil }
        return String(after[..<end])
    }

    // Bounds the search for this comment's own tagline/score/time/body to just its own entry
    // section — stopping at whichever comes first: a nested reply's "child" wrapper, or the
    // next sibling/nested "thing" div's own class attribute (every comment/stub thing div's
    // class contains "id-t1_..."). Either marker is guaranteed to appear AFTER this comment's
    // own tagline/md (which are always emitted first), so this never grabs a wrong comment's
    // data even for a comment with no replies (no "child" div follows it at all).
    private static func ownContentWindowEnd(bytes: [UInt8], from: Int) -> Int {
        let n = bytes.count
        var cutoff = n
        if let c = find("<div class=\"child\"", in: bytes, from: from) { cutoff = min(cutoff, c) }
        if let t = find("id-t1_", in: bytes, from: from) { cutoff = min(cutoff, t) }
        return cutoff
    }

    private static func decode(_ bytes: [UInt8], _ range: Range<Int>) -> String {
        String(decoding: bytes[range], as: UTF8.self)
    }

    private static func parseCommentEntry(tagText: String, bytes: [UInt8], from: Int, depth: Int) -> Comment? {
        guard let fullname = attributeValue(in: tagText, name: "data-fullname") else { return nil }
        let author = attributeValue(in: tagText, name: "data-author") ?? "[deleted]"
        let windowEnd = ownContentWindowEnd(bytes: bytes, from: from)

        var score: Int?
        if let scoreIdx = find("class=\"score unvoted\"", in: bytes, from: from), scoreIdx < windowEnd,
           let titleIdx = find("title=\"", in: bytes, from: scoreIdx), titleIdx < windowEnd {
            let digitsStart = titleIdx + "title=\"".utf8.count
            if let quoteEnd = find("\"", in: bytes, from: digitsStart), quoteEnd <= windowEnd {
                score = Int(decode(bytes, digitsStart..<quoteEnd))
            }
        }

        var createdAt: Date?
        if let timeIdx = find("datetime=\"", in: bytes, from: from), timeIdx < windowEnd {
            let valueStart = timeIdx + "datetime=\"".utf8.count
            if let quoteEnd = find("\"", in: bytes, from: valueStart), quoteEnd <= windowEnd {
                createdAt = AtomDate.parse(decode(bytes, valueStart..<quoteEnd))
            }
        }

        var bodyHTML = ""
        if let mdIdx = find("<div class=\"md\">", in: bytes, from: from), mdIdx < windowEnd {
            let bodyStart = mdIdx + "<div class=\"md\">".utf8.count
            if let closeIdx = find("</div>", in: bytes, from: bodyStart) {
                bodyHTML = decode(bytes, bodyStart..<closeIdx)
            }
        }

        return Comment(id: fullname, author: author, bodyHTML: bodyHTML, createdAt: createdAt,
                        depth: depth, score: score)
    }

    private static func parseMoreStub(tagText: String, bytes: [UInt8], from: Int, depth: Int) -> Comment? {
        guard let fullname = attributeValue(in: tagText, name: "data-fullname") else { return nil }
        let windowEnd = ownContentWindowEnd(bytes: bytes, from: from)

        var moreCount = 0
        if let grayIdx = find("class=\"gray\"", in: bytes, from: from), grayIdx < windowEnd {
            let afterGray = grayIdx + "class=\"gray\"".utf8.count
            if let openParen = find("(", in: bytes, from: afterGray), openParen < windowEnd,
               let closeParen = find(")", in: bytes, from: openParen) {
                let digitsText = decode(bytes, (openParen + 1)..<closeParen)
                let digits = digitsText.prefix(while: { $0.isNumber })
                moreCount = Int(digits) ?? 0
            }
        }

        // Prefix "more_" — this stub's own data-fullname is the SAME id as the comment whose
        // further replies were truncated (it's a "load more replies to this comment"
        // placeholder, not a new distinct comment), so keep it visually distinct from that
        // comment's own row id even though nothing in this app currently keys off Comment.id.
        return Comment(id: "more_\(fullname)", author: "", bodyHTML: "", createdAt: nil,
                        depth: depth, score: nil, isMoreStub: true, moreCount: moreCount)
    }
}
