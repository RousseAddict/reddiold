import UIKit

/// Settings screen — the app-wide listing sort, the comment limit, the cache auto-refresh
/// TTL, and a "Clear Cache" action that wipes the disk feed/comment/thumbnail cache
/// (FeedCache) and the in-memory thumbnail cache, then broadcasts
/// PostListVC.cacheDidClearNotification so any live Home/Subreddit screen drops its
/// per-sort in-memory cache too. No UIAlertController confirmation (iOS8+ only).
///
/// Clear Cache is deliberately **last** and is a **single row**. It used to lead the screen as
/// a button plus a size caption plus a result caption — 114pt of the three stacked elements,
/// with the status caption's height reserved even while hidden — which made a destructive
/// maintenance action the most prominent thing here and pushed the actual preferences below
/// the fold on a 3.5-inch screen. The size now lives in the button's own title and the result
/// is shown by the button itself (see clearCacheTapped), so the whole block is 44pt.
///
/// Laid out inside a UIScrollView with a running `y` cursor rather than hardcoded offsets:
/// the content is now taller than a 3.5-inch screen, and hand-tuned absolute y values were
/// what let the spacing drift out of step in the first place. Only plain controls go in the
/// scroll view — never a table/collection view, which isn't safe to nest on iOS 6.
class SettingsVC: UIViewController {
    private var scrollView: UIScrollView?
    private var cacheButton: UIButton?
    private var cacheSpinner: UIActivityIndicatorView?
    private var ttlControl: UISegmentedControl?
    private var sortControl: UISegmentedControl?
    private var commentLimitControl: UISegmentedControl?

    /// Size measured by the just-finished wipe, applied to the button once the "Cache cleared"
    /// flash ends. Read back from disk rather than assumed to be 0, so a wipe that only
    /// partially succeeded doesn't claim otherwise.
    private var clearedCacheBytes: Int64 = 0

    /// Named, and static so it isn't recreated per call — a queue built inside a frequently
    /// called function burns a thread each time and the 4S caps out at 512.
    private static let cacheQueue = DispatchQueue(label: "com.reddiold.settings.cache")

    /// How long the green "Cache cleared" state holds before fading back.
    private static let confirmDuration: TimeInterval = 1.2

    private static let sectionGap: CGFloat = 24
    private static let labelGap: CGFloat = 6
    private static let hintGap: CGFloat = 4

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        view.backgroundColor = Theme.pageBackground
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard scrollView == nil else {
            // Built once, but the cache will have grown while the user was browsing, and that
            // number is now on the button rather than in a caption nobody reads.
            refreshCacheButton()
            return
        }
        let bounds = view.bounds
        let contentWidth = bounds.width - (Layout.margin * 2)

        // Inset the scroll view itself rather than its content, so the running `y` below stays
        // in content coordinates and the first section can't start underneath the nav bar
        // (which it does since iOS 7 — see Layout.contentTop).
        let top = Layout.contentTop(in: self)
        let scroll = UIScrollView(frame: CGRect(x: 0, y: top, width: bounds.width,
                                                height: bounds.height - top))
        scroll.backgroundColor = Theme.pageBackground
        view.addSubview(scroll)
        scrollView = scroll

        var y = Layout.margin

        y = addSection(to: scroll, y: y, width: contentWidth,
                       title: "Sort posts by:",
                       items: AppSettings.listingSortOptions.map { $0.displayName },
                       selected: AppSettings.listingSortIndex,
                       action: #selector(sortChanged),
                       hint: "Applies to the front page, subreddits and favorites.",
                       store: { self.sortControl = $0 })

        y = addSection(to: scroll, y: y, width: contentWidth,
                       title: "Comments per thread:",
                       items: AppSettings.commentLimitOptions.map { $0.title },
                       selected: AppSettings.commentLimitIndex,
                       action: #selector(commentLimitChanged),
                       hint: "A full thread page can top 1 MB and time out on a slow connection. Extra comments become non-expandable \"load more\" links.",
                       store: { self.commentLimitControl = $0 })

        y = addSection(to: scroll, y: y, width: contentWidth,
                       title: "Auto-refresh cached feeds after:",
                       items: AppSettings.autoRefreshOptions.map { $0.title },
                       selected: AppSettings.autoRefreshTTLIndex,
                       action: #selector(ttlChanged),
                       hint: "Cached posts are always shown instantly. \"Never\" means only pull-to-refresh fetches new content.",
                       store: { self.ttlControl = $0 })

        // addSection already left a section gap below the last hint. Headed like the settings
        // above it, so it reads as a section of this screen rather than a stray button.
        y = addHeading(to: scroll, y: y, width: contentWidth, text: "Cache management:")

        let button = Theme.actionButton(title: "Clear Cache",
                                        frame: CGRect(x: Layout.margin, y: y,
                                                      width: contentWidth, height: Layout.buttonHeight),
                                        target: self, action: #selector(clearCacheTapped))
        scroll.addSubview(button)
        cacheButton = button
        cacheSpinner = Theme.buttonSpinner(in: button)
        refreshCacheButton()
        y += Layout.buttonHeight + Layout.margin

        scroll.contentSize = CGSize(width: bounds.width, height: y)
    }

    /// A section heading, returning the y to continue from. Shared by the settings sections and
    /// the cache block so the cache row can't drift out of step with them.
    private func addHeading(to scroll: UIScrollView, y: CGFloat, width: CGFloat, text: String) -> CGFloat {
        let label = UILabel(frame: CGRect(x: Layout.margin, y: y, width: width, height: 18))
        label.font = UIFont.systemFont(ofSize: 13)
        label.textColor = Theme.headingText
        label.backgroundColor = UIColor.clear
        label.text = text
        scroll.addSubview(label)
        return y + label.frame.height + SettingsVC.labelGap
    }

    /// One "title / segmented control / hint" block, returning the y to continue from.
    /// Every setting is the same shape, so building them from one function is what actually
    /// keeps their spacing identical.
    private func addSection(to scroll: UIScrollView, y: CGFloat, width: CGFloat,
                            title: String, items: [String], selected: Int,
                            action: Selector, hint: String,
                            store: (UISegmentedControl) -> Void) -> CGFloat {
        var y = y

        y = addHeading(to: scroll, y: y, width: width, text: title)

        let control = UISegmentedControl(items: items)
        control.frame = CGRect(x: Layout.margin, y: y, width: width, height: 30)
        control.tintColor = Theme.accent
        control.selectedSegmentIndex = selected
        control.addTarget(self, action: action, for: .valueChanged)
        scroll.addSubview(control)
        store(control)
        y += 30 + SettingsVC.hintGap

        let hintFont = UIFont.systemFont(ofSize: 11)
        let hintHeight = TextMeasure.height(text: hint, font: hintFont, width: width, numberOfLines: 0)
        let hintLabel = UILabel(frame: CGRect(x: Layout.margin, y: y, width: width, height: hintHeight))
        hintLabel.numberOfLines = 0
        hintLabel.font = hintFont
        hintLabel.textColor = Theme.secondaryText
        hintLabel.backgroundColor = UIColor.clear
        hintLabel.text = hint
        scroll.addSubview(hintLabel)
        y += hintHeight + SettingsVC.sectionGap

        return y
    }

    @objc private func sortChanged() {
        guard let index = sortControl?.selectedSegmentIndex else { return }
        AppSettings.listingSortIndex = index
    }

    @objc private func commentLimitChanged() {
        guard let index = commentLimitControl?.selectedSegmentIndex else { return }
        AppSettings.commentLimitIndex = index
    }

    @objc private func ttlChanged() {
        guard let index = ttlControl?.selectedSegmentIndex else { return }
        AppSettings.autoRefreshTTLIndex = index
    }

    /// Measures the cache off-main and puts the result in the button's title.
    private func refreshCacheButton() {
        SettingsVC.cacheQueue.async {
            let bytes = FeedCache.totalSizeBytes()
            DispatchQueue.main.async { [weak self] in
                self?.applyCacheState(bytes: bytes)
            }
        }
    }

    /// An empty cache disables the button rather than leaving a tap that silently does nothing
    /// (and would otherwise flash a success it didn't earn).
    private func applyCacheState(bytes: Int64) {
        guard let button = cacheButton else { return }
        let isEmpty = bytes <= 0
        button.setTitle(isEmpty ? "Cache is empty"
                                : "Clear Cache (\(SettingsVC.formattedSize(bytes)))", for: .normal)
        button.isEnabled = !isEmpty
        button.alpha = isEmpty ? 0.4 : 1
    }

    // No ByteCountFormatter — kept to plain arithmetic + String(format:) for consistency
    // with the rest of this app's iOS6-safe-by-construction style.
    private static func formattedSize(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 {
            return String(format: "%.0f KB", kb)
        }
        return String(format: "%.1f MB", kb / 1024)
    }

    /// The wipe walks and deletes every cached file, so with a full cache it stalls the main
    /// thread long enough that the tap reads as a freeze — hence the background queue and the
    /// button's own progress state. The button also *is* the confirmation: it flashes green,
    /// which is far more noticeable than the 13pt grey caption this replaced.
    @objc private func clearCacheTapped() {
        guard let button = cacheButton, button.isEnabled else { return }
        button.isEnabled = false
        button.setTitle("Clearing...", for: .normal)
        cacheSpinner?.startAnimating()

        SettingsVC.cacheQueue.async {
            FeedCache.clearAll()
            let bytes = FeedCache.totalSizeBytes()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.cacheSpinner?.stopAnimating()
                // Both touch UIKit-side state, so they belong on the main thread.
                PostListVC.clearMemoryCaches()
                NotificationCenter.default.post(name: PostListVC.cacheDidClearNotification, object: nil)
                self.clearedCacheBytes = bytes
                self.cacheButton?.setTitle("Cache cleared", for: .normal)
                self.cacheButton?.backgroundColor = Theme.confirm
                // The button stays disabled through the flash, so a second tap can't land here.
                self.perform(#selector(SettingsVC.restoreCacheButton), with: nil,
                             afterDelay: SettingsVC.confirmDuration)
            }
        }
    }

    @objc private func restoreCacheButton() {
        UIView.animate(withDuration: 0.25) {
            self.cacheButton?.backgroundColor = Theme.accent
        }
        applyCacheState(bytes: clearedCacheBytes)
    }
}
