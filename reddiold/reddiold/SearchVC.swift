import UIKit

/// Search screen with two scopes:
///   - Subreddits: /subreddits/search/.rss — fuzzy discovery, results listed here, tap to open
///   - Posts:      /search/.rss — pushes SearchResultsVC (a PostListVC, so it inherits the
///                 sort control, caching, thumbnails and pull-to-refresh for free)
/// Uses the native UISearchBar (available since very early iOS; its own control fixes the
/// text/cursor vertical centering issues a plain short-height UITextField had) + a styled "Go"
/// button. Avoids UIAlertController (iOS8+) and UISearchBarStyle (iOS7+, left unset).
///
/// Search runs only on an explicit Go — never as-you-type. Reddit's rate limiter returns an
/// empty HTTP 429 after only a few requests in quick succession, so a request per keystroke
/// would break the feature within one word.
class SearchVC: UIViewController, UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate {
    private var searchBar: UISearchBar?
    private var scopeControl: UISegmentedControl?
    private var tableView: UITableView?
    private var spinner: UIActivityIndicatorView?
    private var messageLabel: UILabel?
    private var results: [SubredditResult] = []
    /// The term the currently-displayed results belong to — also what the fallback
    /// "go to r/x anyway" message offers when a subreddit search fails outright.
    private var lastQuery: String?
    private let cellId = "SubredditCell"

    private static let titleFont = UIFont.boldSystemFont(ofSize: 16)
    private static let summaryFont = UIFont.systemFont(ofSize: 12)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Search"
        view.backgroundColor = UIColor.white
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard searchBar == nil else { return }

        // view.bounds already excludes the nav bar on real iOS 6 — don't use UIScreen.main.bounds.
        let bounds = view.bounds

        let bar = UISearchBar(frame: CGRect(x: 0, y: 0, width: bounds.width, height: 44))
        bar.placeholder = "Search Reddit"
        bar.autocapitalizationType = .none
        bar.autocorrectionType = .no
        bar.tintColor = UIColor.orange
        bar.delegate = self
        view.addSubview(bar)
        searchBar = bar
        bar.becomeFirstResponder()

        let scope = UISegmentedControl(items: ["Subreddits", "Posts"])
        scope.frame = CGRect(x: 16, y: 52, width: bounds.width - 32, height: 30)
        scope.selectedSegmentIndex = 0
        scope.tintColor = UIColor.orange
        view.addSubview(scope)
        scopeControl = scope

        let button = UIButton(type: .custom)
        button.frame = CGRect(x: 16, y: 90, width: bounds.width - 32, height: 44)
        button.backgroundColor = UIColor.orange
        button.setTitle("Go", for: .normal)
        button.setTitleColor(UIColor.white, for: .normal)
        button.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        button.layer.cornerRadius = 8
        button.layer.masksToBounds = true
        button.addTarget(self, action: #selector(goTapped), for: .touchUpInside)
        view.addSubview(button)

        let tableTop: CGFloat = 146
        let table = UITableView(frame: CGRect(x: 0, y: tableTop, width: bounds.width, height: bounds.height - tableTop))
        table.dataSource = self
        table.delegate = self
        table.tableFooterView = UIView(frame: .zero)
        view.addSubview(table)
        tableView = table

        let indicator = UIActivityIndicatorView(style: .gray)
        indicator.center = CGPoint(x: bounds.width / 2, y: tableTop + 40)
        view.addSubview(indicator)
        spinner = indicator

        let label = UILabel(frame: CGRect(x: 20, y: tableTop + 20, width: bounds.width - 40, height: 60))
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = UIFont.systemFont(ofSize: 14)
        label.textColor = UIColor.gray
        label.backgroundColor = UIColor.clear
        label.isHidden = true
        label.isUserInteractionEnabled = true
        label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(messageTapped)))
        view.addSubview(label)
        messageLabel = label
    }

    @objc private func goTapped() {
        guard let query = searchBar?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else { return }
        searchBar?.resignFirstResponder()
        if scopeControl?.selectedSegmentIndex == 1 {
            navigationController?.pushViewController(SearchResultsVC(query: query), animated: true)
        } else {
            searchSubreddits(query: query)
        }
    }

    private func searchSubreddits(query: String) {
        lastQuery = query
        results = []
        tableView?.reloadData()
        messageLabel?.isHidden = true
        spinner?.startAnimating()
        RedditAPI.searchSubreddits(query: query) { [weak self] found, error in
            guard let self = self else { return }
            // Ignore a response for a term the user has since replaced (slow request, or one
            // that sat behind the rate limiter while they typed and searched again).
            guard self.lastQuery == query else { return }
            self.spinner?.stopAnimating()
            if let error = error {
                self.showMessage(self.errorMessage(for: error, query: query))
                return
            }
            if found.isEmpty {
                self.showMessage("No subreddits found for \"\(query)\"")
                return
            }
            self.results = found
            self.tableView?.reloadData()
        }
    }

    private func showMessage(_ text: String) {
        messageLabel?.text = text
        messageLabel?.isHidden = false
    }

    // Rate limiting is the failure people will actually hit here, and it makes search
    // temporarily useless — so offer the old exact-name jump as an escape hatch rather than
    // leaving them stuck (tapping the message opens r/<query> directly).
    private func errorMessage(for error: Error, query: String) -> String {
        let code = (error as NSError).code
        switch code {
        case 429: return "Rate limited by Reddit, try again shortly.\nTap here to open r/\(query) directly."
        default: return "Couldn't search.\nTap here to open r/\(query) directly."
        }
    }

    @objc private func messageTapped() {
        guard let query = lastQuery, results.isEmpty else { return }
        navigationController?.pushViewController(SubredditVC(subreddit: query), animated: true)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        goTapped()
    }

    // MARK: - Results table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return results.count
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let result = results[indexPath.row]
        let width = tableView.bounds.width - 30
        var height = TextMeasure.height(text: "r/\(result.name)", font: SearchVC.titleFont, width: width, numberOfLines: 1)
        if let summary = result.summary {
            height += TextMeasure.height(text: summary, font: SearchVC.summaryFont, width: width, numberOfLines: 2)
        }
        return height + 20
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: cellId) ?? UITableViewCell(style: .subtitle, reuseIdentifier: cellId)
        let result = results[indexPath.row]
        cell.textLabel?.text = "r/\(result.name)"
        cell.textLabel?.font = SearchVC.titleFont
        cell.textLabel?.numberOfLines = 1
        cell.detailTextLabel?.text = result.summary
        cell.detailTextLabel?.font = SearchVC.summaryFont
        cell.detailTextLabel?.textColor = UIColor.orange
        cell.detailTextLabel?.numberOfLines = 2
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(SubredditVC(subreddit: results[indexPath.row].name), animated: true)
    }
}

/// Post search results — a plain PostListVC with a query set, so it reuses the whole listing
/// pipeline (stale-while-revalidate caching, thumbnails, pull-to-refresh, PostVC on tap).
/// Pinned to relevance: the listing sorts aren't meaningful for a query, and Reddit's search
/// endpoint doesn't accept hot/rising at all.
class SearchResultsVC: PostListVC {
    private let query: String

    init(query: String) {
        self.query = query
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        searchQuery = query
        sortOverride = .relevance
        title = "\"\(query)\""
    }
}
