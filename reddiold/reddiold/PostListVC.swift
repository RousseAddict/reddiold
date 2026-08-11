import UIKit

/// Shared base for a Reddit post listing (front page or a specific subreddit): table of
/// posts w/ date + thumbnail, pull-to-refresh, stale-while-revalidate caching, pushes
/// PostVC on row tap. Subclasses (HomeVC, SubredditVC) just set `subreddit` and `title` in
/// their own viewDidLoad (after calling super). The sort is a single app-wide preference
/// (Settings > Sort posts by), not a per-screen control.
class PostListVC: UIViewController, UITableViewDataSource, UITableViewDelegate {
    var subreddit: String?

    /// When set, this screen shows post *search* results for the term instead of a listing
    /// (scoped to `subreddit` if that's also set, site-wide otherwise). See SearchResultsVC.
    var searchQuery: String?

    /// Pins this screen to one sort, ignoring the app-wide Settings preference. Only search
    /// results use it (relevance — the listing sorts aren't meaningful for a query).
    var sortOverride: RedditAPI.Sort?

    private var tableView: UITableView?
    private var freshnessLabel: UILabel?
    private var spinner: UIActivityIndicatorView?
    private var errorLabel: UILabel?
    private var retryButton: UIButton?
    private var posts: [Post] = []
    private var postsCache: [RedditAPI.Sort: [Post]] = [:]
    /// Which sort the rows on screen belong to — so viewWillAppear can notice the user
    /// changed the Settings preference while this screen stayed alive underneath.
    private var displayedSort: RedditAPI.Sort?
    private let cellId = "PostCell"

    private static let titleFont = UIFont.boldSystemFont(ofSize: 17)
    private static let detailFont = UIFont.systemFont(ofSize: 13)
    private static let thumbnailSize: CGFloat = 50
    private static let thumbnailCacheMaxAge: TimeInterval = 7 * 24 * 3600  // 1 week — images rarely change
    private static var thumbnailCache = NSCache<NSString, UIImage>()

    private var refreshControl: UIRefreshControl?

    /// Broadcast by SettingsVC's "Clear Cache" so every live PostListVC (Home/Subreddit)
    /// drops its in-memory per-sort cache and, if currently visible, refetches.
    static let cacheDidClearNotification = Notification.Name("PostListVC.cacheDidClear")

    /// Wipes the shared in-memory thumbnail cache. Called from Settings > Clear Cache
    /// alongside FeedCache.clearAll() (the disk-backed feed/comment/thumbnail cache).
    static func clearMemoryCaches() {
        thumbnailCache.removeAllObjects()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.pageBackground
        NotificationCenter.default.addObserver(self, selector: #selector(handleCacheCleared), name: PostListVC.cacheDidClearNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleCacheCleared() {
        postsCache.removeAll()
        if isViewLoaded && view.window != nil {
            loadFeed(forceReload: true)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard tableView == nil else { return }

        // On real iOS 6 (classic UINavigationController layout), a pushed VC's own `view`
        // is already resized/positioned to start right below the nav bar — view.bounds
        // already excludes the bar, unlike UIScreen.main.bounds (the full physical screen).
        let bounds = view.bounds

        let freshnessHeight: CGFloat = 16
        let freshness = UILabel(frame: CGRect(x: Layout.margin, y: 4,
                                              width: bounds.width - (Layout.margin * 2), height: freshnessHeight))
        freshness.font = UIFont.systemFont(ofSize: 11)
        freshness.textColor = Theme.secondaryText
        freshness.textAlignment = .center
        freshness.backgroundColor = UIColor.clear
        view.addSubview(freshness)
        freshnessLabel = freshness

        let availableHeight = bounds.height
        let tableTop = 4 + freshnessHeight + 2
        let table = UITableView(frame: CGRect(x: 0, y: tableTop, width: bounds.width, height: availableHeight - tableTop))
        table.dataSource = self
        table.delegate = self
        table.tableFooterView = UIView(frame: .zero)
        Theme.apply(to: table)
        view.addSubview(table)
        tableView = table

        // Pull-to-refresh: UIRefreshControl works fine added as a plain subview of a
        // manually-created UITableView (not just via UITableViewController.refreshControl,
        // which is iOS10+ anyway) — it observes the scroll view's pan/content offset itself.
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        table.addSubview(refresh)
        refreshControl = refresh

        let indicator = UIActivityIndicatorView(style: Theme.spinnerStyle)
        indicator.center = CGPoint(x: bounds.width / 2, y: tableTop + 60)
        view.addSubview(indicator)
        spinner = indicator

        let label = UILabel(frame: CGRect(x: Layout.margin, y: tableTop + 40,
                                          width: bounds.width - (Layout.margin * 2), height: 40))
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = UIFont.systemFont(ofSize: 14)
        label.textColor = Theme.secondaryText
        label.backgroundColor = UIColor.clear
        label.isHidden = true
        view.addSubview(label)
        errorLabel = label

        // A real button rather than a tap recognizer on the message label — a gray centered
        // sentence reads as a status line, not a control, so the retry was easy to miss.
        let retry = Theme.actionButton(title: "Retry",
                                       frame: CGRect(x: Layout.margin, y: tableTop + 88,
                                                     width: bounds.width - (Layout.margin * 2),
                                                     height: Layout.buttonHeight),
                                       target: self, action: #selector(retryTapped))
        retry.isHidden = true
        view.addSubview(retry)
        retryButton = retry

        loadFeed()
    }

    /// The sort preference can change in Settings while this screen sits alive further down
    /// the nav stack — viewDidAppear's one-time build guard would otherwise leave the old
    /// sort's rows on screen until the app relaunched.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard tableView != nil, let shown = displayedSort else { return }
        // "Updated 2m ago" is relative to now, and now moved on while this screen sat under
        // PostVC — without this it still reads "just now" ten minutes later.
        updateFreshnessLabel(for: shown)
        guard shown != currentSort() else { return }
        loadFeed()
    }

    @objc private func retryTapped() { loadFeed(forceReload: true) }
    @objc private func pullToRefresh() { loadFeed(forceReload: true) }

    private func showError(_ text: String) {
        errorLabel?.text = text
        errorLabel?.isHidden = false
        retryButton?.isHidden = false
    }

    private func hideError() {
        errorLabel?.isHidden = true
        retryButton?.isHidden = true
    }

    /// Tears down all built subviews and cached state so the next viewDidAppear performs a
    /// full rebuild — for subclasses (FavoritesVC) whose effective `subreddit` can change
    /// between appearances (e.g. after the user edits their favorites list on a separate
    /// screen and navigates back).
    func resetForReload() {
        tableView?.removeFromSuperview()
        freshnessLabel?.removeFromSuperview()
        spinner?.removeFromSuperview()
        errorLabel?.removeFromSuperview()
        retryButton?.removeFromSuperview()
        tableView = nil
        freshnessLabel = nil
        spinner = nil
        errorLabel = nil
        retryButton = nil
        refreshControl = nil
        posts = []
        postsCache.removeAll()
        displayedSort = nil
    }

    private func currentSort() -> RedditAPI.Sort {
        return sortOverride ?? AppSettings.listingSort
    }

    /// forceReload (pull-to-refresh / retry tap) always hits the network. Otherwise: show
    /// whatever's cached (in-memory, then on-disk) instantly regardless of age — no spinner,
    /// no network — then silently fetch fresh content in the background only if there was
    /// nothing cached at all, or the cached content is older than the user's configured
    /// AppSettings.autoRefreshTTL (Settings screen; "Never" disables this entirely, making
    /// pull-to-refresh the only way to get new content).
    private func loadFeed(forceReload: Bool = false) {
        let sort = currentSort()
        hideError()

        if !forceReload, let cached = postsCache[sort] {
            posts = cached
            displayedSort = sort
            tableView?.reloadData()
            updateFreshnessLabel(for: sort)
            return
        }

        if forceReload {
            fetchFresh(sort: sort, showSpinner: true)
            return
        }

        RedditAPI.cachedListing(subreddit: subreddit, query: searchQuery, sort: sort) { [weak self] cachedPosts in
            guard let self = self, self.currentSort() == sort else { return }
            if !cachedPosts.isEmpty {
                self.postsCache[sort] = cachedPosts
                self.posts = cachedPosts
                self.displayedSort = sort
                self.tableView?.reloadData()
                self.updateFreshnessLabel(for: sort)
            }
            let ttl = AppSettings.autoRefreshTTL
            let age = RedditAPI.listingCacheDate(subreddit: self.subreddit, query: self.searchQuery, sort: sort)
                .map { Date().timeIntervalSince($0) }
            let needsRefresh = cachedPosts.isEmpty || (ttl != nil && (age ?? .greatestFiniteMagnitude) > ttl!)
            if needsRefresh {
                self.fetchFresh(sort: sort, showSpinner: cachedPosts.isEmpty)
            }
        }
    }

    private func fetchFresh(sort: RedditAPI.Sort, showSpinner: Bool) {
        if showSpinner && refreshControl?.isRefreshing != true {
            spinner?.startAnimating()
        }
        RedditAPI.fetchListing(subreddit: subreddit, query: searchQuery, sort: sort) { [weak self] posts, error in
            guard let self = self else { return }
            // Guard against a stale/out-of-order completion: if the user has since switched
            // to a different sort tab (very possible when a request is slow or hits Reddit's
            // rate limiter), applying this response would overwrite the currently-displayed
            // tab with content from the tab the user switched away from. Still cache the
            // result under its own sort so switching back to it later is instant.
            let isCurrent = self.currentSort() == sort
            if isCurrent {
                self.spinner?.stopAnimating()
                self.refreshControl?.endRefreshing()
            }
            if let error = error, posts.isEmpty {
                // Only show the full-screen error if we have nothing else to show — a failed
                // background refresh (e.g. rate-limited) shouldn't wipe already-displayed,
                // still-useful stale content.
                if isCurrent && self.posts.isEmpty {
                    self.showError(self.errorMessage(for: error))
                }
                return
            }
            self.postsCache[sort] = posts
            if isCurrent {
                self.posts = posts
                self.displayedSort = sort
                self.tableView?.reloadData()
                self.updateFreshnessLabel(for: sort)
                // A successful request that simply matched nothing — common for search, and
                // an empty white table looks like a failure without saying so.
                if posts.isEmpty {
                    self.showError(self.emptyMessage())
                }
            }
        }
    }

    private func emptyMessage() -> String {
        if let query = searchQuery, !query.isEmpty {
            return "No results for \"\(query)\""
        }
        return "Nothing to show here"
    }

    private func updateFreshnessLabel(for sort: RedditAPI.Sort) {
        guard let date = RedditAPI.listingCacheDate(subreddit: subreddit, query: searchQuery, sort: sort) else {
            freshnessLabel?.text = nil
            return
        }
        freshnessLabel?.text = "Updated \(RelativeTime.string(from: date))"
    }

    // Distinguish a genuinely missing/private subreddit from a transient network/rate-limit
    // failure, using the HTTP status CurlFetcher surfaces as the NSError code.
    private func errorMessage(for error: Error) -> String {
        let code = (error as NSError).code
        // Handled before the per-screen branches because it isn't about this subreddit or
        // this query: Reddit answered with something that isn't a feed, so every screen is
        // equally affected and neither retrying nor picking another subreddit will help.
        if code == RedditAPI.notAFeedErrorCode {
            return "Reddit isn't returning feeds - it may now require a login."
        }
        if let query = searchQuery, !query.isEmpty {
            switch code {
            case 429: return "Rate limited by Reddit, try again shortly."
            default: return "Couldn't search for \"\(query)\"."
            }
        }
        if let subreddit = subreddit, !subreddit.isEmpty {
            switch code {
            case 404: return "r/\(subreddit) not found."
            case 403: return "r/\(subreddit) is private or restricted."
            case 429: return "Rate limited by Reddit, try again shortly."
            default: return "Couldn't load r/\(subreddit)."
            }
        }
        switch code {
        case 429: return "Rate limited by Reddit, try again shortly."
        default: return "Couldn't load."
        }
    }

    private func rowHeight(for post: Post, width: CGFloat) -> CGFloat {
        let available = width - Layout.cellTextInset
        let textWidth = post.displayableThumbnailURL != nil ? available - (PostListVC.thumbnailSize + 12) : available
        let titleHeight = TextMeasure.height(text: post.title, font: PostListVC.titleFont, width: textWidth, numberOfLines: 2)
        let minHeight = post.displayableThumbnailURL != nil ? PostListVC.thumbnailSize + 20 : 0
        return max(titleHeight + PostListVC.detailFont.lineHeight + 24, minHeight)
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return rowHeight(for: posts[indexPath.row], width: tableView.bounds.width)
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { return posts.count }

    private func resizedThumbnail(_ image: UIImage, to size: CGFloat) -> UIImage {
        let target = CGSize(width: size, height: size)
        UIGraphicsBeginImageContextWithOptions(target, false, 0)
        image.draw(in: CGRect(origin: .zero, size: target))
        let result = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return result
    }

    private func loadThumbnailIfNeeded(for post: Post, at indexPath: IndexPath) {
        guard let urlString = post.displayableThumbnailURL else { return }
        let key = urlString as NSString
        if PostListVC.thumbnailCache.object(forKey: key) != nil {
            reloadRowIfStillCurrent(post: post, at: indexPath)
            return
        }
        // Disk cache (FeedCache) survives app relaunch, unlike the in-memory NSCache above —
        // avoids re-downloading every thumbnail on every cold launch.
        if let diskData = FeedCache.data(forKey: urlString, maxAge: PostListVC.thumbnailCacheMaxAge),
           let diskImage = UIImage(data: diskData) {
            let resized = resizedThumbnail(diskImage, to: PostListVC.thumbnailSize)
            PostListVC.thumbnailCache.setObject(resized, forKey: key)
            reloadRowIfStillCurrent(post: post, at: indexPath)
            return
        }
        guard let url = URL(string: urlString) else { return }
        CurlFetcher.fetch(url: url, userAgent: RedditAPI.userAgent) { [weak self] data, error in
            guard let self = self, let data = data, let image = UIImage(data: data) else { return }
            FeedCache.store(data, forKey: urlString)
            let resized = self.resizedThumbnail(image, to: PostListVC.thumbnailSize)
            PostListVC.thumbnailCache.setObject(resized, forKey: key)
            self.reloadRowIfStillCurrent(post: post, at: indexPath)
        }
    }

    // Always defers to the next run-loop turn via DispatchQueue.main.async — this method
    // is the ONLY place that's allowed to call tableView.reloadRows for a thumbnail. Fast
    // scrolling triggers many back-to-back cellForRowAt calls, each of which can hit the
    // disk cache synchronously; calling reloadRows(at:) directly from inside cellForRowAt's
    // own call stack re-enters the table view mid-layout and reliably crashes under that
    // load — confirmed root cause of the fast-scroll crash. Re-validates the row still holds
    // this post since content can change between the read and the (deferred) reload.
    private func reloadRowIfStillCurrent(post: Post, at indexPath: IndexPath) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, indexPath.row < self.posts.count, self.posts[indexPath.row].id == post.id else { return }
            self.tableView?.reloadRows(at: [indexPath], with: .none)
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: cellId) ?? UITableViewCell(style: .subtitle, reuseIdentifier: cellId)
        let post = posts[indexPath.row]
        cell.backgroundColor = Theme.cellBackground
        cell.textLabel?.text = post.title
        cell.textLabel?.font = PostListVC.titleFont
        cell.textLabel?.textColor = Theme.primaryText
        cell.textLabel?.numberOfLines = 2

        var detail = "r/\(post.subreddit) - \(post.author)"
        if let createdAt = post.createdAt {
            detail += " - \(RelativeTime.string(from: createdAt))"
        }
        cell.detailTextLabel?.text = detail
        cell.detailTextLabel?.font = PostListVC.detailFont
        cell.detailTextLabel?.textColor = Theme.accent

        if post.displayableThumbnailURL != nil {
            let key = post.displayableThumbnailURL! as NSString
            if let cached = PostListVC.thumbnailCache.object(forKey: key) {
                cell.imageView?.image = cached
            } else {
                cell.imageView?.image = nil
                loadThumbnailIfNeeded(for: post, at: indexPath)
            }
        } else {
            cell.imageView?.image = nil
        }

        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(PostVC(post: posts[indexPath.row]), animated: true)
    }
}
