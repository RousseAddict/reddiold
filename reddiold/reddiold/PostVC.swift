import UIKit
import MediaPlayer

/// Post detail: title, subreddit/author/date, optional thumbnail (tap for full-size
/// preview), optional body/selftext, a "Show Comments" button that loads the flat
/// comment list on demand. All of this lives in the comments table's tableHeaderView so
/// long posts scroll naturally together with the comment list below — avoids needing a
/// second nested scroll container (never safe on iOS 6 anyway).
class PostVC: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let post: Post
    /// Every comment the scrape produced, in document order — the source of truth, and what
    /// gets persisted for offline reading. The table renders `visibleComments` instead.
    private var comments: [Comment] = []
    /// `comments` minus the descendants of anything collapsed. Kept as a stored array rather
    /// than recomputed per datasource callback: `heightForRowAt`/`cellForRowAt` are called
    /// constantly while scrolling and rebuilding the list each time would be a linear scan
    /// per row.
    private var visibleComments: [Comment] = []
    /// Ids of comments whose replies are hidden. Survives a "load more" — the ids are stable,
    /// so a thread you collapsed stays collapsed after fetching a larger page.
    private var collapsedIDs = Set<String>()
    private var tableView: UITableView?
    private var thumbnailView: UIImageView?
    private var mediaBadgeLabel: UILabel?
    private var statsLabel: UILabel?
    private var commentsButton: UIButton?
    private var commentsSpinner: UIActivityIndicatorView?
    private var thumbnailSpinner: UIActivityIndicatorView?
    private var mediaSpinner: UIActivityIndicatorView?
    private var loadMoreButton: UIButton?
    private var loadMoreSpinner: UIActivityIndicatorView?
    /// The `?limit=` the currently-displayed comments were fetched with (nil == unlimited).
    /// "Load more" escalates this rather than paginating — Reddit's api/morechildren is behind
    /// the same bot wall as .json, so the only way to get more is to re-request the whole page
    /// at a higher limit.
    private var loadedCommentLimit: Int?
    /// The post's true comment count from the permalink page, used to decide whether the
    /// thread we're showing is actually truncated.
    private var totalCommentCount: Int?
    private var isLoadingComments = false
    private var isLoadingGallery = false
    private var isLoadingVideo = false
    // The local RedditVideoProxy session URL backing the currently-presented player, if any —
    // used to tear down that session's state once playback finishes/is dismissed.
    private var activeVideoProxyURL: URL?
    // Retained so it isn't deallocated mid-playback, and so the finish-notification
    // observer below can be torn down against the right object.
    private var activeMoviePlayerVC: MPMoviePlayerViewController?
    private let cellId = "CommentCell"

    private static let bodyFont = UIFont.systemFont(ofSize: 14)
    private static let authorFont = UIFont.systemFont(ofSize: 12)
    private static let moreStubFont = UIFont.italicSystemFont(ofSize: 13)

    // Cap indentation so a very deep sub-thread doesn't eat the whole row width. The per-depth
    // bar colors themselves live in Theme.threadBars.
    private static let maxIndentDepth = 8
    private static let indentWidth: CGFloat = 10
    private static let threadBarTag = 9001

    init(post: Post) {
        self.post = post
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Post"
        view.backgroundColor = Theme.pageBackground
        updateSaveButton()
    }

    private func updateSaveButton() {
        let isSaved = SavedPostsStore.contains(post.id)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: isSaved ? "Unsave" : "Save",
            style: .plain, target: self, action: #selector(toggleSave))
    }

    @objc private func toggleSave() {
        if SavedPostsStore.contains(post.id) {
            SavedPostsStore.remove(post.id)
        } else {
            SavedPostsStore.add(post)
            // Comments may already be loaded (user tapped Show Comments before Save) —
            // persist them right away rather than waiting for a future re-fetch.
            if !comments.isEmpty {
                SavedPostsStore.saveComments(comments, forPostId: post.id)
            }
        }
        updateSaveButton()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard tableView == nil else { return }
        setupUI()
        loadThumbnail()
        loadCachedStats()
    }

    /// Cache-only — see RedditAPI.cachedPostStats. A post the user has never opened the
    /// comments of simply shows no numbers rather than costing a request.
    private func loadCachedStats() {
        guard let parts = permalinkParts() else { return }
        RedditAPI.cachedPostStats(subreddit: parts.subreddit, postId: parts.postId,
                                   limit: AppSettings.commentLimit) { [weak self] stats in
            self?.apply(stats: stats)
        }
    }

    private func apply(stats: PostStats?) {
        guard let stats = stats, !stats.isEmpty else { return }
        totalCommentCount = stats.commentCount
        var parts: [String] = []
        if let score = stats.score {
            parts.append("\(score) \(score == 1 ? "point" : "points")")
        }
        if let count = stats.commentCount {
            parts.append("\(count) \(count == 1 ? "comment" : "comments")")
        }
        statsLabel?.text = parts.joined(separator: " - ")
    }

    /// "https://www.reddit.com/r/AskReddit/comments/1vhs7gp/some_slug/" -> ("AskReddit", "1vhs7gp")
    /// Matches on path segments, not the host, so it handles either reddit hostname.
    private func permalinkParts() -> (subreddit: String, postId: String)? {
        let parts = post.permalink.split(separator: "/").map(String.init)
        guard let rIdx = parts.firstIndex(of: "r"), rIdx + 1 < parts.count,
              let cIdx = parts.firstIndex(of: "comments"), cIdx + 1 < parts.count else { return nil }
        return (parts[rIdx + 1], parts[cIdx + 1])
    }

    private func setupUI() {
        // Not UIScreen.main.bounds, that's the full physical screen. The view's own origin
        // isn't the top of the content either — see Layout.contentTop.
        let bounds = view.bounds
        let top = Layout.contentTop(in: self)

        let table = UITableView(frame: CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top))
        table.dataSource = self
        table.delegate = self
        table.tableFooterView = UIView(frame: .zero)
        Theme.apply(to: table)
        view.addSubview(table)
        tableView = table

        table.tableHeaderView = buildHeaderView(width: bounds.width)
        table.reloadData()  // force contentSize recompute for the tall header, otherwise the table can under-report its scrollable height on long posts and clip the comments button
    }

    private func buildHeaderView(width: CGFloat) -> UIView {
        let contentWidth = width - (Layout.margin * 2)
        var y: CGFloat = 8

        let titleFont = UIFont.boldSystemFont(ofSize: 16)
        let titleHeight = TextMeasure.height(text: post.title, font: titleFont, width: contentWidth, numberOfLines: 0)
        let titleLabel = UILabel(frame: CGRect(x: Layout.margin, y: y, width: contentWidth, height: titleHeight))
        titleLabel.numberOfLines = 0
        titleLabel.font = titleFont
        titleLabel.textColor = Theme.primaryText
        titleLabel.backgroundColor = UIColor.clear
        titleLabel.text = post.title
        y += titleHeight + 4

        // The subreddit name is its own tappable label rather than part of the detail line,
        // so tapping it opens the subreddit without the author/date also being a hit target.
        let subredditText = "r/\(post.subreddit)"
        let subredditWidth = min(TextMeasure.width(text: subredditText, font: PostVC.authorFont), contentWidth)
        let detailHeight = TextMeasure.height(text: subredditText, font: PostVC.authorFont, width: contentWidth, numberOfLines: 1)
        let subredditLabel = UILabel(frame: CGRect(x: Layout.margin, y: y, width: subredditWidth, height: detailHeight))
        subredditLabel.font = PostVC.authorFont
        subredditLabel.backgroundColor = UIColor.clear
        subredditLabel.isUserInteractionEnabled = true
        let subredditAttributed = NSMutableAttributedString(string: subredditText)
        let subredditRange = NSRange(location: 0, length: subredditText.count)
        subredditAttributed.addAttribute(.foregroundColor, value: Theme.accent, range: subredditRange)
        subredditAttributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: subredditRange)
        subredditLabel.attributedText = subredditAttributed
        subredditLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(subredditTapped)))

        var detail = " - \(post.author)"
        if let createdAt = post.createdAt {
            detail += " - \(RelativeTime.string(from: createdAt))"
        }
        let detailLabel = UILabel(frame: CGRect(x: Layout.margin + subredditWidth, y: y,
                                                 width: contentWidth - subredditWidth, height: detailHeight))
        detailLabel.font = PostVC.authorFont
        detailLabel.textColor = Theme.accent
        detailLabel.backgroundColor = UIColor.clear
        detailLabel.text = detail
        y += detailHeight + 2

        // Reserved even when the numbers aren't known yet: they arrive asynchronously (from
        // the cached permalink page, or after Show Comments), and growing the header later
        // would mean rebuilding tableHeaderView — which throws away the loaded thumbnail and
        // the comments button's state. An empty 14pt line costs far less than that.
        let statsLine = UILabel(frame: CGRect(x: Layout.margin, y: y, width: contentWidth, height: detailHeight))
        statsLine.font = PostVC.authorFont
        statsLine.textColor = Theme.secondaryText
        statsLine.backgroundColor = UIColor.clear
        statsLabel = statsLine
        y += detailHeight + 12

        var linkLabel: UILabel?
        if post.mediaKind == .other, let linkURLString = post.linkURL {
            let linkFont = PostVC.authorFont
            let linkHeight = TextMeasure.height(text: linkURLString, font: linkFont, width: contentWidth, numberOfLines: 2)
            let label = UILabel(frame: CGRect(x: Layout.margin, y: y, width: contentWidth, height: linkHeight))
            label.numberOfLines = 2
            label.font = linkFont
            label.backgroundColor = UIColor.clear
            let attributed = NSMutableAttributedString(string: linkURLString)
            attributed.addAttribute(.foregroundColor, value: Theme.link, range: NSRange(location: 0, length: linkURLString.count))
            attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: linkURLString.count))
            label.attributedText = attributed
            label.isUserInteractionEnabled = true
            label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(linkTapped)))
            linkLabel = label
            y += linkHeight + 12
        }

        var imageView: UIImageView?
        var mediaBadge: UILabel?
        if post.displayableThumbnailURL != nil {
            let iv = UIImageView(frame: CGRect(x: Layout.margin, y: y, width: contentWidth, height: 140))
            iv.contentMode = .scaleAspectFit
            iv.backgroundColor = Theme.imagePlaceholder
            iv.isUserInteractionEnabled = true
            iv.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(thumbnailTapped)))
            imageView = iv
            y += 140 + 12

            // The thumbnail is its own fetch; until it lands the view is a flat grey box that
            // reads as "this post has a broken image" rather than "still downloading".
            let thumbSpinner = UIActivityIndicatorView(style: Theme.spinnerStyle)
            thumbSpinner.center = CGPoint(x: iv.bounds.midX, y: iv.bounds.midY)
            thumbSpinner.hidesWhenStopped = true
            thumbSpinner.startAnimating()
            iv.addSubview(thumbSpinner)
            thumbnailSpinner = thumbSpinner

            switch post.mediaKind {
            case .gallery:
                mediaBadge = makeMediaBadge(text: "Gallery - tap to view", over: iv.frame)
            case .video:
                mediaBadge = makeMediaBadge(text: "Play Video", over: iv.frame)
            case .image:
                mediaBadge = makeMediaBadge(text: "Tap to view full image", over: iv.frame)
            case .other:
                break
            }
        }

        var bodyLabel: UILabel?
        if let body = post.displayableBodyText {
            let bodyHeight = TextMeasure.height(text: body, font: PostVC.bodyFont, width: contentWidth, numberOfLines: 0)
            let label = UILabel(frame: CGRect(x: Layout.margin, y: y, width: contentWidth, height: bodyHeight))
            label.numberOfLines = 0
            label.font = PostVC.bodyFont
            label.textColor = Theme.primaryText
            label.backgroundColor = UIColor.clear
            label.text = body
            bodyLabel = label
            y += bodyHeight + 12
        }

        let button = Theme.actionButton(title: "Show Comments",
                                        frame: CGRect(x: Layout.margin, y: y,
                                                      width: contentWidth, height: Layout.buttonHeight),
                                        target: self, action: #selector(loadCommentsTapped))
        // Loading a thread is the slowest thing in the app (a ~600 KB HTML page, up to a 45s
        // timeout). The button title alone changing to "Loading..." reads as frozen, so pin a
        // spinner to its trailing edge for a visible sign of life.
        commentsSpinner = Theme.buttonSpinner(in: button)
        y += Layout.buttonHeight + 12

        let header = UIView(frame: CGRect(x: 0, y: 0, width: width, height: y))
        header.addSubview(titleLabel)
        header.addSubview(subredditLabel)
        header.addSubview(detailLabel)
        header.addSubview(statsLine)
        if let ll = linkLabel { header.addSubview(ll) }
        if let iv = imageView { header.addSubview(iv) }
        if let badge = mediaBadge { header.addSubview(badge) }
        if let bl = bodyLabel { header.addSubview(bl) }
        header.addSubview(button)

        thumbnailView = imageView
        mediaBadgeLabel = mediaBadge
        commentsButton = button

        return header
    }

    // Semi-transparent overlay bar pinned to the bottom edge of the thumbnail, indicating
    // a gallery/video post's tap action. isUserInteractionEnabled = false so the tap
    // gesture on the imageView underneath still fires.
    private func makeMediaBadge(text: String, over imageFrame: CGRect) -> UILabel {
        let badge = UILabel(frame: CGRect(x: imageFrame.minX, y: imageFrame.maxY - 24,
                                           width: imageFrame.width, height: 24))
        badge.backgroundColor = Theme.overlayBadgeBackground
        badge.textColor = Theme.onOverlay
        badge.font = UIFont.boldSystemFont(ofSize: 13)
        badge.textAlignment = .center
        badge.text = text
        badge.isUserInteractionEnabled = false

        // Gallery/video both need a permalink or playlist fetch before anything happens on
        // screen; without this the badge just sits on "Loading..." looking hung.
        let spinner = UIActivityIndicatorView(style: Theme.contrastSpinnerStyle)
        spinner.center = CGPoint(x: Layout.margin, y: badge.bounds.height / 2)
        spinner.hidesWhenStopped = true
        badge.addSubview(spinner)
        mediaSpinner = spinner
        return badge
    }

    private func loadThumbnail() {
        guard let urlString = post.displayableThumbnailURL, let url = URL(string: urlString) else { return }
        CurlFetcher.fetch(url: url, userAgent: RedditAPI.userAgent) { [weak self] data, error in
            guard let self = self else { return }
            self.thumbnailSpinner?.stopAnimating()
            guard let data = data, let image = UIImage(data: data) else { return }
            self.thumbnailView?.image = image
        }
    }

    @objc private func thumbnailTapped() {
        switch post.mediaKind {
        case .gallery:
            openGallery()
        case .video(let videoId):
            playVideo(videoId: videoId)
        case .image(let url):
            openFullImage(urlString: url)
        case .other:
            showFullImage()
        }
    }

    // Fallback for posts with no direct image URL (self-text posts with a preview, unclassified
    // links): all we have is the ~140px RSS preview thumbnail already on screen, so blow that up.
    private func showFullImage() {
        guard let image = thumbnailView?.image else { return }
        presentViewer(ImageViewerVC(image: image))
    }

    // The post links straight at an image file, so show the real thing rather than the tiny
    // RSS preview thumbnail. Same viewer as a gallery, just one page — it already does the
    // async fetch, caching, black backdrop, Close button and zoom, and hides its page control
    // when there's only one page.
    private func openFullImage(urlString: String) {
        presentViewer(ImageViewerVC(imageURLs: [urlString]))
    }

    private func presentViewer(_ viewer: ImageViewerVC) {
        viewer.modalPresentationStyle = .fullScreen
        present(viewer, animated: true, completion: nil)
    }

    // openURL(_:) (not the iOS10+ open(_:options:completionHandler:)) is the oldest
    // universally-available way to hand a URL to Safari — safe on iOS 6/7/8 alike.
    @objc private func subredditTapped() {
        navigationController?.pushViewController(SubredditVC(subreddit: post.subreddit), animated: true)
    }

    @objc private func linkTapped() {
        guard let urlString = post.linkURL, let url = URL(string: urlString) else { return }
        UIApplication.shared.openURL(url)
    }

    // Gallery images are never in the RSS feed — only fetched (and only once, cached
    // after) when the user actually taps the gallery badge, to avoid extra requests
    // against Reddit's rate limiter on every post shown in the list.
    private func openGallery() {
        guard !isLoadingGallery else { return }
        isLoadingGallery = true
        mediaBadgeLabel?.text = "Loading gallery..."
        mediaSpinner?.startAnimating()
        // The thumbnail is passed so that a gallery whose grid can't be scraped can still fall
        // back to its first image at full resolution (see RedditAPI.fullResURL).
        RedditAPI.fetchGalleryImageURLs(permalink: post.permalink,
                                        thumbnailURL: post.thumbnailURL) { [weak self] urls, error in
            guard let self = self else { return }
            self.isLoadingGallery = false
            self.mediaSpinner?.stopAnimating()
            guard error == nil, !urls.isEmpty else {
                self.mediaBadgeLabel?.text = "Gallery - couldn't load, tap to retry"
                return
            }
            self.mediaBadgeLabel?.text = "Gallery - tap to view"
            self.presentViewer(ImageViewerVC(imageURLs: urls))
        }
    }

    // v.redd.it serves fMP4/CMAF HLS (byte-range #EXT-X-MAP segments) which
    // MPMoviePlayerController (an iOS6-era classic-.ts-segment-only HLS client) can't
    // parse — it opens the player then immediately posts a "finish" notification with a
    // playback-error reason, which looks like "it opens then instantly closes". Instead of
    // handing the remote m3u8 straight to the player, fetch+parse it ourselves and spin up
    // a local RedditVideoProxy session that transmuxes the fMP4 video+audio segments to
    // classic .ts on the fly, then point the player at that local http://127.0.0.1 URL.
    private func playVideo(videoId: String) {
        guard !isLoadingVideo else { return }
        isLoadingVideo = true
        mediaBadgeLabel?.text = "Loading video..."
        mediaSpinner?.startAnimating()
        guard let masterURL = URL(string: "https://v.redd.it/\(videoId)/HLSPlaylist.m3u8") else {
            videoLoadFailed()
            return
        }
        CurlFetcher.fetch(url: masterURL, userAgent: RedditAPI.userAgent) { [weak self] data, error in
            guard let self = self else { return }
            guard error == nil, let data = data, let text = String(data: data, encoding: .utf8) else {
                self.videoLoadFailed()
                return
            }
            let variants = M3U8Parser.masterVariants(text, baseURL: masterURL)
            let audioGroups = M3U8Parser.audioGroupURLs(text, baseURL: masterURL)
            // Smallest bandwidth first — this is a small-screen iOS6/7/8 player, no need
            // for the highest-res variant, and it keeps segment fetch/transmux cheap.
            let sorted = variants.sorted { $0.bandwidth < $1.bandwidth }
            guard let variant = sorted.first(where: { $0.audioGroupID != nil && audioGroups[$0.audioGroupID!] != nil }),
                  let audioGroupID = variant.audioGroupID,
                  let audioPlaylistURL = audioGroups[audioGroupID] else {
                self.videoLoadFailed()
                return
            }
            self.fetchVariantPlaylists(videoPlaylistURL: variant.playlistURL, audioPlaylistURL: audioPlaylistURL)
        }
    }

    // No DispatchGroup (iOS6-safe, but this project's convention elsewhere is plain
    // completion-tracking booleans) — fetch both variant playlists, then proceed once
    // both have arrived (or fail immediately if either request errors).
    private func fetchVariantPlaylists(videoPlaylistURL: URL, audioPlaylistURL: URL) {
        var videoText: String?
        var audioText: String?
        var failed = false
        let lock = NSLock()

        func proceedIfReady() {
            lock.lock()
            let vText = videoText
            let aText = audioText
            let didFail = failed
            lock.unlock()
            guard !didFail else { return }
            guard let vText = vText, let aText = aText else { return }
            guard let videoPlaylist = M3U8Parser.variantPlaylist(vText, baseURL: videoPlaylistURL),
                  let audioPlaylist = M3U8Parser.variantPlaylist(aText, baseURL: audioPlaylistURL) else {
                self.videoLoadFailed()
                return
            }
            self.startProxiedPlayback(videoPlaylist: videoPlaylist, audioPlaylist: audioPlaylist)
        }

        CurlFetcher.fetch(url: videoPlaylistURL, userAgent: RedditAPI.userAgent) { [weak self] data, error in
            guard let self = self else { return }
            guard error == nil, let data = data, let text = String(data: data, encoding: .utf8) else {
                lock.lock(); failed = true; lock.unlock()
                self.videoLoadFailed()
                return
            }
            lock.lock(); videoText = text; lock.unlock()
            proceedIfReady()
        }
        CurlFetcher.fetch(url: audioPlaylistURL, userAgent: RedditAPI.userAgent) { [weak self] data, error in
            guard let self = self else { return }
            guard error == nil, let data = data, let text = String(data: data, encoding: .utf8) else {
                lock.lock(); failed = true; lock.unlock()
                self.videoLoadFailed()
                return
            }
            lock.lock(); audioText = text; lock.unlock()
            proceedIfReady()
        }
    }

    // Video/audio variant playlists are confirmed (via curl) to always have the SAME
    // segment count for a given Reddit video — pair them by plain array index, take the
    // min count defensively in case that ever isn't true.
    private func startProxiedPlayback(videoPlaylist: M3U8Parser.VariantPlaylist, audioPlaylist: M3U8Parser.VariantPlaylist) {
        let count = min(videoPlaylist.segments.count, audioPlaylist.segments.count)
        guard count > 0 else {
            videoLoadFailed()
            return
        }
        var segs: [RedditVideoProxy.Seg] = []
        segs.reserveCapacity(count)
        for i in 0..<count {
            segs.append(RedditVideoProxy.Seg(videoRange: videoPlaylist.segments[i].range,
                                              audioRange: audioPlaylist.segments[i].range,
                                              duration: videoPlaylist.segments[i].duration))
        }
        guard let localURL = RedditVideoProxy.shared.registerSession(
            videoURL: videoPlaylist.mediaURL, audioURL: audioPlaylist.mediaURL,
            videoInitRange: videoPlaylist.initRange, audioInitRange: audioPlaylist.initRange,
            segments: segs) else {
            videoLoadFailed()
            return
        }
        guard let playerVC = MPMoviePlayerViewController(contentURL: localURL) else {
            videoLoadFailed()
            return
        }
        isLoadingVideo = false
        mediaSpinner?.stopAnimating()
        mediaBadgeLabel?.text = "Play Video"
        activeVideoProxyURL = localURL
        activeMoviePlayerVC = playerVC
        playerVC.moviePlayer.movieSourceType = .streaming
        playerVC.moviePlayer.scalingMode = .aspectFit
        NotificationCenter.default.addObserver(
            self, selector: #selector(moviePlaybackDidFinish(_:)),
            name: NSNotification.Name("MPMoviePlayerPlaybackDidFinishNotification"),
            object: playerVC.moviePlayer)
        present(playerVC, animated: true, completion: nil)
    }

    private func videoLoadFailed() {
        isLoadingVideo = false
        mediaSpinner?.stopAnimating()
        mediaBadgeLabel?.text = "Video - couldn't load, tap to retry"
    }

    // MPMoviePlayerViewController dismisses itself automatically the moment its
    // moviePlayer posts this notification — including when the "finish" is actually an
    // immediate load/playback error (blocked request, unsupported stream, etc). That's
    // what makes a broken video look like "it opens then instantly closes" with nothing
    // shown. Surface the real reason instead of failing silently. Reason values: 0 =
    // played to the end, 1 = playback error, 2 = user tapped Done — only alert on 1.
    @objc private func moviePlaybackDidFinish(_ notification: Notification) {
        NotificationCenter.default.removeObserver(
            self, name: NSNotification.Name("MPMoviePlayerPlaybackDidFinishNotification"),
            object: notification.object)
        activeMoviePlayerVC = nil
        RedditVideoProxy.shared.closeSession(url: activeVideoProxyURL)
        activeVideoProxyURL = nil
        let reason = (notification.userInfo?["MPMoviePlayerPlaybackDidFinishReasonUserInfoKey"] as? NSNumber)?.intValue ?? -1
        guard reason == 1 else { return }
        let alert = UIAlertView(title: "Couldn't play video",
                                 message: "Reddit's video stream failed to load (blocked request, network issue, or unsupported format).",
                                 delegate: nil, cancelButtonTitle: "OK")
        alert.show()
    }

    @objc private func loadCommentsTapped() {
        commentsButton?.isEnabled = false
        commentsButton?.setTitle("Loading...", for: .normal)
        commentsSpinner?.startAnimating()
        loadComments(limit: AppSettings.commentLimit)
    }

    private func loadComments(limit: Int?) {
        guard !isLoadingComments else { return }
        guard let parts = permalinkParts() else {
            commentsButton?.setTitle("No comments link", for: .normal)
            return
        }
        isLoadingComments = true

        RedditAPI.fetchComments(subreddit: parts.subreddit, postId: parts.postId,
                                 limit: limit) { [weak self] comments, stats, error in
            guard let self = self else { return }
            self.isLoadingComments = false
            self.commentsSpinner?.stopAnimating()
            self.loadMoreSpinner?.stopAnimating()
            self.apply(stats: stats)
            if let error = error, comments.isEmpty {
                // No network (or fetch failed) — fall back to this saved post's offline
                // comment snapshot if one was persisted from an earlier successful load.
                if let cached = SavedPostsStore.comments(forPostId: self.post.id), !cached.isEmpty {
                    self.setComments(cached)
                    self.commentsButton?.isHidden = true
                    return
                }
                // A failed "load more" must not wipe the comments already on screen.
                if self.comments.isEmpty {
                    self.commentsButton?.isEnabled = true
                    self.commentsButton?.setTitle(self.errorMessage(for: error), for: .normal)
                } else {
                    self.loadMoreButton?.setTitle(self.errorMessage(for: error), for: .normal)
                    self.loadMoreButton?.isEnabled = true
                }
                return
            }
            self.setComments(comments)
            self.loadedCommentLimit = limit
            self.commentsButton?.isHidden = true
            self.updateLoadMoreFooter()
            // Keep this saved post's offline comment snapshot in sync with the latest fetch.
            if SavedPostsStore.contains(self.post.id) {
                SavedPostsStore.saveComments(comments, forPostId: self.post.id)
            }
        }
    }

    /// The limit a "load more" tap would request next, or nil when there's nothing more to
    /// get — either we already asked for everything, or we've hit Reddit's own page ceiling.
    private func nextCommentLimit() -> Int? {
        guard let current = loadedCommentLimit, current < RedditAPI.maxCommentLimit else { return nil }
        return min(current * 2, RedditAPI.maxCommentLimit)
    }

    /// Shows the footer only when the thread is genuinely truncated: the post's own comment
    /// count (scraped from the same page) exceeds what we actually parsed. Comparing against
    /// real comments only — "load more" stubs are placeholders, not content.
    private func updateLoadMoreFooter() {
        let loaded = comments.filter { !$0.isMoreStub }.count
        let hasMore = totalCommentCount.map { $0 > loaded } ?? false
        guard hasMore, nextCommentLimit() != nil, let table = tableView else {
            tableView?.tableFooterView = UIView(frame: .zero)
            loadMoreButton = nil
            loadMoreSpinner = nil
            return
        }

        let footer = UIView(frame: CGRect(x: 0, y: 0, width: table.bounds.width, height: 68))
        let button = Theme.actionButton(title: "Load more comments",
                                        frame: CGRect(x: Layout.margin, y: 12,
                                                      width: table.bounds.width - (Layout.margin * 2),
                                                      height: Layout.buttonHeight),
                                        target: self, action: #selector(loadMoreTapped))
        let spinner = Theme.buttonSpinner(in: button)

        footer.addSubview(button)
        table.tableFooterView = footer
        loadMoreButton = button
        loadMoreSpinner = spinner
    }

    @objc private func loadMoreTapped() {
        guard let next = nextCommentLimit() else { return }
        loadMoreButton?.isEnabled = false
        loadMoreButton?.setTitle("Loading...", for: .normal)
        loadMoreSpinner?.startAnimating()
        loadComments(limit: next)
    }

    // Same status-code messaging as PostListVC's feed error handling — the button itself
    // doubles as the retry control instead of a separate error label.
    private func errorMessage(for error: Error) -> String {
        let code = (error as NSError).code
        switch code {
        case 429: return "Rate limited, try again shortly - tap to retry"
        default: return "Couldn't load comments - tap to retry"
        }
    }

    private func moreStubText(for comment: Comment) -> String {
        guard comment.moreCount > 0 else { return "View more replies on reddit" }
        let noun = comment.moreCount == 1 ? "reply" : "replies"
        return "\(comment.moreCount) more \(noun) - view on reddit"
    }

    // MARK: - Collapsing

    /// Replaces the thread and rebuilds what's on screen. Every assignment to `comments` goes
    /// through here so `visibleComments` can't drift out of sync with it.
    private func setComments(_ newComments: [Comment]) {
        comments = newComments
        rebuildVisibleComments()
        tableView?.reloadData()
    }

    /// Walks the flat, document-ordered list and drops everything nested under a collapsed
    /// comment. Depth is the only structural information the scrape gives us — a comment's
    /// descendants are exactly the run of following comments deeper than it, up to the next
    /// one at its own depth or shallower.
    private func rebuildVisibleComments() {
        var result: [Comment] = []
        var hiddenBelowDepth: Int?
        for comment in comments {
            if let depth = hiddenBelowDepth {
                if comment.depth > depth { continue }
                hiddenBelowDepth = nil
            }
            result.append(comment)
            if collapsedIDs.contains(comment.id) {
                hiddenBelowDepth = comment.depth
            }
        }
        visibleComments = result
    }

    /// How many comments are nested under this one — shown in the header of a collapsed row
    /// so it's clear something is hidden rather than missing.
    private func descendantCount(of comment: Comment) -> Int {
        guard let start = comments.firstIndex(where: { $0.id == comment.id }) else { return 0 }
        var count = 0
        var index = start + 1
        while index < comments.count, comments[index].depth > comment.depth {
            count += 1
            index += 1
        }
        return count
    }

    /// Tapping a comment collapses its replies and truncates its own body to one line. On a
    /// 3.5-inch screen a single long top-level comment can fill several screenfuls, so being
    /// able to fold a branch away is what makes a big thread navigable at all.
    private func toggleCollapse(at indexPath: IndexPath) {
        let comment = visibleComments[indexPath.row]
        if collapsedIDs.contains(comment.id) {
            collapsedIDs.remove(comment.id)
        } else {
            collapsedIDs.insert(comment.id)
        }
        rebuildVisibleComments()
        tableView?.reloadData()
        // Collapsing a branch that started above the fold would otherwise leave the user
        // somewhere arbitrary in the middle of the shortened list.
        if indexPath.row < visibleComments.count {
            tableView?.scrollToRow(at: indexPath, at: .top, animated: true)
        }
    }

    // MARK: - Comment rows

    private func isCollapsed(_ comment: Comment) -> Bool {
        return collapsedIDs.contains(comment.id)
    }

    /// A collapsed comment keeps a one-line preview of its body rather than hiding it: the
    /// row stays recognisable, and measuring with the same numberOfLines the cell renders is
    /// what keeps measured and drawn heights in step (see TextMeasure).
    private func bodyLines(for comment: Comment) -> Int {
        return isCollapsed(comment) ? 1 : 0
    }

    private func detailText(for comment: Comment) -> String {
        var detail = comment.author
        if let score = comment.score {
            detail += " - \(score) pts"
        }
        if let createdAt = comment.createdAt {
            detail += " - \(RelativeTime.string(from: createdAt))"
        }
        if isCollapsed(comment) {
            let hidden = descendantCount(of: comment)
            detail = hidden > 0 ? "[+\(hidden)] " + detail : "[+] " + detail
        }
        return detail
    }

    private func rowHeight(for comment: Comment, width: CGFloat) -> CGFloat {
        let indent = CGFloat(min(comment.depth, PostVC.maxIndentDepth)) * PostVC.indentWidth
        let textWidth = width - Layout.cellTextInset - indent
        if comment.isMoreStub {
            let height = TextMeasure.height(text: moreStubText(for: comment), font: PostVC.moreStubFont,
                                            width: textWidth, numberOfLines: 0)
            return height + 24
        }
        let body = HTMLUtil.blockText(comment.bodyHTML)
        let bodyHeight = TextMeasure.height(text: body, font: PostVC.bodyFont, width: textWidth,
                                            numberOfLines: bodyLines(for: comment))
        return bodyHeight + PostVC.authorFont.lineHeight + 24
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return rowHeight(for: visibleComments[indexPath.row], width: tableView.bounds.width)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return visibleComments.count
    }

    // Left-edge colored bars, one per depth level (cycling Theme.threadBars), overlaid
    // behind the cell's own indentationLevel-shifted content — visually separates nested
    // reply chains, similar to Reddit's official app/mobile-web comment threading.
    private func addThreadBars(to cell: UITableViewCell, depth: Int, height: CGFloat) {
        cell.contentView.viewWithTag(PostVC.threadBarTag)?.removeFromSuperview()
        guard depth > 0 else { return }
        let container = UIView(frame: CGRect(x: 0, y: 0, width: CGFloat(depth) * PostVC.indentWidth, height: height))
        container.tag = PostVC.threadBarTag
        container.isUserInteractionEnabled = false
        container.backgroundColor = .clear
        let colors = Theme.threadBars
        for level in 0..<depth {
            let bar = UIView(frame: CGRect(x: CGFloat(level) * PostVC.indentWidth + 4, y: 0, width: 2, height: height))
            bar.backgroundColor = colors[level % colors.count]
            container.addSubview(bar)
        }
        cell.contentView.addSubview(container)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: cellId) ?? UITableViewCell(style: .subtitle, reuseIdentifier: cellId)
        let comment = visibleComments[indexPath.row]
        let depth = min(comment.depth, PostVC.maxIndentDepth)
        cell.indentationLevel = depth
        cell.indentationWidth = PostVC.indentWidth
        cell.selectionStyle = .default
        cell.backgroundColor = Theme.cellBackground

        if comment.isMoreStub {
            cell.textLabel?.text = moreStubText(for: comment)
            cell.textLabel?.font = PostVC.moreStubFont
            cell.textLabel?.textColor = Theme.secondaryText
            cell.textLabel?.numberOfLines = 0
            cell.detailTextLabel?.text = nil
        } else {
            cell.textLabel?.text = HTMLUtil.blockText(comment.bodyHTML)
            cell.textLabel?.font = PostVC.bodyFont
            cell.textLabel?.textColor = Theme.primaryText
            cell.textLabel?.numberOfLines = bodyLines(for: comment)
            cell.detailTextLabel?.text = detailText(for: comment)
            cell.detailTextLabel?.font = PostVC.authorFont
            cell.detailTextLabel?.textColor = Theme.accent
        }

        addThreadBars(to: cell, depth: depth, height: rowHeight(for: comment, width: tableView.bounds.width))
        return cell
    }

    // Tapping a real comment folds/unfolds its replies. "More replies" stubs aren't
    // expandable (would need Reddit's api/morechildren endpoint, presumed blocked by the same
    // bot wall as .json) — those open the full thread on reddit.com instead, same openURL
    // pattern as linkTapped().
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let comment = visibleComments[indexPath.row]
        guard comment.isMoreStub else {
            toggleCollapse(at: indexPath)
            return
        }
        guard let url = URL(string: post.permalink) else { return }
        UIApplication.shared.openURL(url)
    }
}
