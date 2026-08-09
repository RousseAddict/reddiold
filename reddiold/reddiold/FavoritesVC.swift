import UIKit

/// Shows the combined "New" feed across all favorited subreddits (Reddit's "+"-joined
/// multireddit RSS path — confirmed via curl to work unauthenticated, server-side
/// chronologically interleaved, gracefully skipping any invalid/banned joined name), or an
/// empty-state message if there are no favorites yet. A right-nav "Edit" button pushes
/// EditFavoritesVC to manage (view/remove) the favorited subreddit list; since that list can
/// change on a screen we're not rebuilt from, viewWillAppear recomputes the effective
/// `subreddit` each time and calls PostListVC.resetForReload() whenever it changed, so the
/// next viewDidAppear does a full rebuild against the new list.
class FavoritesVC: PostListVC {
    private var emptyLabel: UILabel?
    private var lastFavoritesKey = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Favorites"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Edit", style: .plain, target: self, action: #selector(editTapped))
    }

    // Recompute the "+"-joined key *before* calling super: resetForReload() tears the table
    // down, which makes super's own viewWillAppear (sort-changed check) correctly bail out
    // instead of firing a fetch for the favorites list we're about to replace.
    override func viewWillAppear(_ animated: Bool) {
        let names = FavoritesStore.all()
        let key = names.joined(separator: "+")
        if key != lastFavoritesKey {
            lastFavoritesKey = key
            subreddit = names.isEmpty ? nil : key
            resetForReload()
            emptyLabel?.removeFromSuperview()
            emptyLabel = nil
        }
        super.viewWillAppear(animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        guard !FavoritesStore.all().isEmpty else {
            if emptyLabel == nil {
                let bounds = view.bounds
                let label = UILabel(frame: CGRect(x: Layout.margin, y: Layout.margin,
                                                  width: bounds.width - (Layout.margin * 2),
                                                  height: bounds.height - (Layout.margin * 2)))
                label.numberOfLines = 0
                label.textAlignment = .center
                label.font = UIFont.systemFont(ofSize: 15)
                label.textColor = UIColor.gray
                label.text = "No favorites yet. Visit a subreddit and tap Favorite, then come back here to see their combined New feed."
                view.addSubview(label)
                emptyLabel = label
            }
            return
        }
        super.viewDidAppear(animated)
    }

    @objc private func editTapped() {
        navigationController?.pushViewController(EditFavoritesVC(), animated: true)
    }
}
