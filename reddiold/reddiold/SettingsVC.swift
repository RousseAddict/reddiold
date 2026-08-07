import UIKit

/// Settings screen — the app-wide listing sort, the cache auto-refresh TTL, and a
/// "Clear Cache" action that wipes the disk feed/
/// comment/thumbnail cache (FeedCache) and the in-memory thumbnail cache, then broadcasts
/// PostListVC.cacheDidClearNotification so any live Home/Subreddit screen drops its
/// per-sort in-memory cache too. No UIAlertController confirmation (iOS8+ only) — just an
/// inline status label, same proven pattern as the error/empty labels elsewhere.
class SettingsVC: UIViewController {
    private var sizeLabel: UILabel?
    private var statusLabel: UILabel?
    private var ttlControl: UISegmentedControl?
    private var sortControl: UISegmentedControl?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        view.backgroundColor = UIColor.white
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard sizeLabel == nil else { return }
        let bounds = view.bounds

        let button = UIButton(type: .custom)
        button.frame = CGRect(x: 16, y: 24, width: bounds.width - 32, height: 44)
        button.backgroundColor = UIColor.orange
        button.setTitle("Clear Cache", for: .normal)
        button.setTitleColor(UIColor.white, for: .normal)
        button.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        button.layer.cornerRadius = 8
        button.layer.masksToBounds = true
        button.addTarget(self, action: #selector(clearCacheTapped), for: .touchUpInside)
        view.addSubview(button)

        let size = UILabel(frame: CGRect(x: 16, y: 80, width: bounds.width - 32, height: 20))
        size.textAlignment = .center
        size.font = UIFont.systemFont(ofSize: 13)
        size.textColor = UIColor.gray
        view.addSubview(size)
        sizeLabel = size
        refreshCacheSizeLabel()

        let label = UILabel(frame: CGRect(x: 16, y: 108, width: bounds.width - 32, height: 30))
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = UIFont.systemFont(ofSize: 13)
        label.textColor = UIColor.gray
        label.isHidden = true
        view.addSubview(label)
        statusLabel = label

        let ttlLabel = UILabel(frame: CGRect(x: 16, y: 156, width: bounds.width - 32, height: 20))
        ttlLabel.textAlignment = .center
        ttlLabel.font = UIFont.systemFont(ofSize: 13)
        ttlLabel.textColor = UIColor.darkGray
        ttlLabel.text = "Auto-refresh cached feeds after:"
        view.addSubview(ttlLabel)

        let items = AppSettings.autoRefreshOptions.map { $0.title }
        let control = UISegmentedControl(items: items)
        control.frame = CGRect(x: 16, y: 180, width: bounds.width - 32, height: 30)
        control.tintColor = UIColor.orange
        control.selectedSegmentIndex = AppSettings.autoRefreshTTLIndex
        control.addTarget(self, action: #selector(ttlChanged), for: .valueChanged)
        view.addSubview(control)
        ttlControl = control

        let ttlHint = UILabel(frame: CGRect(x: 16, y: 214, width: bounds.width - 32, height: 32))
        ttlHint.textAlignment = .center
        ttlHint.numberOfLines = 0
        ttlHint.font = UIFont.systemFont(ofSize: 11)
        ttlHint.textColor = UIColor.gray
        ttlHint.text = "Cached posts are always shown instantly. \"Never\" means only pull-to-refresh fetches new content."
        view.addSubview(ttlHint)

        let sortTitle = UILabel(frame: CGRect(x: 16, y: 258, width: bounds.width - 32, height: 20))
        sortTitle.textAlignment = .center
        sortTitle.font = UIFont.systemFont(ofSize: 13)
        sortTitle.textColor = UIColor.darkGray
        sortTitle.text = "Sort posts by:"
        view.addSubview(sortTitle)

        let sortItems = AppSettings.listingSortOptions.map { $0.displayName }
        let sort = UISegmentedControl(items: sortItems)
        sort.frame = CGRect(x: 16, y: 282, width: bounds.width - 32, height: 30)
        sort.tintColor = UIColor.orange
        sort.selectedSegmentIndex = AppSettings.listingSortIndex
        sort.addTarget(self, action: #selector(sortChanged), for: .valueChanged)
        view.addSubview(sort)
        sortControl = sort

        let sortHint = UILabel(frame: CGRect(x: 16, y: 316, width: bounds.width - 32, height: 32))
        sortHint.textAlignment = .center
        sortHint.numberOfLines = 0
        sortHint.font = UIFont.systemFont(ofSize: 11)
        sortHint.textColor = UIColor.gray
        sortHint.text = "Applies to the front page, subreddits and favorites."
        view.addSubview(sortHint)
    }

    @objc private func sortChanged() {
        guard let index = sortControl?.selectedSegmentIndex else { return }
        AppSettings.listingSortIndex = index
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
