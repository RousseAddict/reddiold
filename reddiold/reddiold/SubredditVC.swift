import UIKit

/// Post listing pinned to one subreddit. Nav bar has a Favorite/Unfavorite button that
/// adds/removes it from favorites (persisted via FavoritesStore). Plain ASCII button
/// titles used instead of star glyphs — safer bet on iOS 6's system font rendering.
class SubredditVC: PostListVC {
    private let subredditName: String

    init(subreddit: String) {
        self.subredditName = subreddit
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        subreddit = subredditName
        title = "r/\(subredditName)"
        updateFavoriteButton()
    }

    private func updateFavoriteButton() {
        let isFav = FavoritesStore.contains(subredditName)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: isFav ? "Unfavorite" : "Favorite",
            style: .plain, target: self, action: #selector(toggleFavorite))
    }

    @objc private func toggleFavorite() {
        if FavoritesStore.contains(subredditName) {
            FavoritesStore.remove(subredditName)
        } else {
            FavoritesStore.add(subredditName)
        }
        updateFavoriteButton()
    }
}
