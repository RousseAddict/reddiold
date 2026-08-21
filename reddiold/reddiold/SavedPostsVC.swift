import UIKit

/// Posts explicitly saved for offline viewing (SavedPostsStore). Tap pushes PostVC — its
/// thumbnail/body/comment-fetching already goes through CurlFetcher+FeedCache, so a
/// previously-viewed saved post's content still shows without a network hit as long as it's
/// cached; swipe-to-delete removes a saved post. Same list/empty-state pattern as
/// EditFavoritesVC.
class SavedPostsVC: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private var tableView: UITableView?
    private var emptyLabel: UILabel?
    private var posts: [Post] = []
    private let cellId = "SavedPostCell"

    private static let titleFont = UIFont.boldSystemFont(ofSize: 17)
    private static let detailFont = UIFont.systemFont(ofSize: 13)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Saved Posts"
        view.backgroundColor = Theme.pageBackground
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        posts = SavedPostsStore.all()

        if tableView == nil {
            // Not UIScreen.main.bounds; and the view's origin isn't the top of the content —
            // see Layout.contentTop.
            let bounds = view.bounds
            let top = Layout.contentTop(in: self)

            let table = UITableView(frame: CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top))
            table.dataSource = self
            table.delegate = self
            table.tableFooterView = UIView(frame: .zero)
            Theme.apply(to: table)
            view.addSubview(table)
            tableView = table

            let label = UILabel(frame: CGRect(x: Layout.margin, y: top + 40,
                                              width: bounds.width - (Layout.margin * 2), height: 60))
            label.textAlignment = .center
            label.numberOfLines = 0
            label.font = UIFont.systemFont(ofSize: 14)
            label.textColor = Theme.secondaryText
            // UILabel.backgroundColor defaults to WHITE on iOS 6, not clear — without this the
            // empty state is a white block over the page background.
            label.backgroundColor = UIColor.clear
            label.text = "No saved posts yet - open a post and tap Save to view it here offline."
            view.addSubview(label)
            emptyLabel = label
        }

        emptyLabel?.isHidden = !posts.isEmpty
        tableView?.isHidden = posts.isEmpty
        tableView?.reloadData()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return posts.count
    }

    // Same iOS6-safe measured-row-height pattern as PostListVC/PostVC — the default fixed
    // 44pt row height is too short once textLabel uses numberOfLines > 1, causing label
    // overlap between rows and separators cutting through text.
    private func rowHeight(for post: Post, width: CGFloat) -> CGFloat {
        let textWidth = width - Layout.cellTextInset
        let titleHeight = TextMeasure.height(text: post.title, font: SavedPostsVC.titleFont, width: textWidth, numberOfLines: 2)
        return titleHeight + SavedPostsVC.detailFont.lineHeight + 24
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return rowHeight(for: posts[indexPath.row], width: tableView.bounds.width)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: cellId) ?? UITableViewCell(style: .subtitle, reuseIdentifier: cellId)
        let post = posts[indexPath.row]
        cell.backgroundColor = Theme.cellBackground
        cell.textLabel?.text = post.title
        cell.textLabel?.font = SavedPostsVC.titleFont
        cell.textLabel?.textColor = Theme.primaryText
        cell.textLabel?.numberOfLines = 2

        var detail = "r/\(post.subreddit) - \(post.author)"
        if let createdAt = post.createdAt {
            detail += " - \(RelativeTime.string(from: createdAt))"
        }
        cell.detailTextLabel?.text = detail
        cell.detailTextLabel?.font = SavedPostsVC.detailFont
        cell.detailTextLabel?.textColor = Theme.accent
        cell.selectionStyle = .default
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < posts.count else { return }
        navigationController?.pushViewController(PostVC(post: posts[indexPath.row]), animated: true)
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, indexPath.row < posts.count else { return }
        SavedPostsStore.remove(posts[indexPath.row].id)
        posts.remove(at: indexPath.row)
        tableView.deleteRows(at: [indexPath], with: .automatic)
        if posts.isEmpty {
            emptyLabel?.isHidden = false
            tableView.isHidden = true
        }
    }
}
