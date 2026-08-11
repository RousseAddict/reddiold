import UIKit

/// Settings screen — the app-wide listing sort, the comment limit, the cache auto-refresh
/// TTL, and a "Clear Cache" action that wipes the disk feed/comment/thumbnail cache
/// (FeedCache) and the in-memory thumbnail cache, then broadcasts
/// PostListVC.cacheDidClearNotification so any live Home/Subreddit screen drops its
/// per-sort in-memory cache too. No UIAlertController confirmation (iOS8+ only) — just an
/// inline status label, same proven pattern as the error/empty labels elsewhere.
///
/// Laid out inside a UIScrollView with a running `y` cursor rather than hardcoded offsets:
/// the content is now taller than a 3.5-inch screen, and hand-tuned absolute y values were
/// what let the spacing drift out of step in the first place. Only plain controls go in the
/// scroll view — never a table/collection view, which isn't safe to nest on iOS 6.
class SettingsVC: UIViewController {
    private var scrollView: UIScrollView?
    private var sizeLabel: UILabel?
    private var statusLabel: UILabel?
    private var ttlControl: UISegmentedControl?
    private var sortControl: UISegmentedControl?
    private var commentLimitControl: UISegmentedControl?

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
        guard scrollView == nil else { return }
        let bounds = view.bounds
        let contentWidth = bounds.width - (Layout.margin * 2)

        let scroll = UIScrollView(frame: bounds)
        scroll.backgroundColor = Theme.pageBackground
        view.addSubview(scroll)
        scrollView = scroll

        var y = Layout.margin

        let button = Theme.actionButton(title: "Clear Cache",
                                        frame: CGRect(x: Layout.margin, y: y,
                                                      width: contentWidth, height: Layout.buttonHeight),
                                        target: self, action: #selector(clearCacheTapped))
        scroll.addSubview(button)
        y += Layout.buttonHeight + SettingsVC.labelGap

        let size = makeCaption(width: contentWidth, y: y, color: Theme.secondaryText)
        scroll.addSubview(size)
        sizeLabel = size
        refreshCacheSizeLabel()
        y += size.frame.height + SettingsVC.hintGap

        let status = makeCaption(width: contentWidth, y: y, color: Theme.secondaryText)
        status.isHidden = true
        scroll.addSubview(status)
        statusLabel = status
        y += status.frame.height + SettingsVC.sectionGap

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

        scroll.contentSize = CGSize(width: bounds.width, height: y)
    }

    /// One "title / segmented control / hint" block, returning the y to continue from.
    /// Every setting is the same shape, so building them from one function is what actually
    /// keeps their spacing identical.
    private func addSection(to scroll: UIScrollView, y: CGFloat, width: CGFloat,
                            title: String, items: [String], selected: Int,
                            action: Selector, hint: String,
                            store: (UISegmentedControl) -> Void) -> CGFloat {
        var y = y

        let titleLabel = makeCaption(width: width, y: y, color: Theme.headingText)
        titleLabel.text = title
        titleLabel.textAlignment = .left
        scroll.addSubview(titleLabel)
        y += titleLabel.frame.height + SettingsVC.labelGap

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

    private func makeCaption(width: CGFloat, y: CGFloat, color: UIColor) -> UILabel {
        let label = UILabel(frame: CGRect(x: Layout.margin, y: y, width: width, height: 18))
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 13)
        label.textColor = color
        label.backgroundColor = UIColor.clear
        return label
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

    private func refreshCacheSizeLabel() {
        sizeLabel?.text = "Cache size: \(SettingsVC.formattedSize(FeedCache.totalSizeBytes()))"
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

    @objc private func clearCacheTapped() {
        FeedCache.clearAll()
        PostListVC.clearMemoryCaches()
        NotificationCenter.default.post(name: PostListVC.cacheDidClearNotification, object: nil)
        refreshCacheSizeLabel()
        statusLabel?.text = "Cache cleared."
        statusLabel?.isHidden = false
    }
}
