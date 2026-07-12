import UIKit

/// Plain list of favorited subreddit names (FavoritesStore), swipe-to-delete to remove.
/// Reached via the "Edit" button on FavoritesVC (which itself now shows the combined feed,
/// not this list) — this screen is purely for managing the favorites list.
class EditFavoritesVC: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private var tableView: UITableView?
    private var emptyLabel: UILabel?
    private var favorites: [String] = []
    private let cellId = "FavCell"

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Edit Favorites"
        view.backgroundColor = UIColor.white
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        favorites = FavoritesStore.all()

        if tableView == nil {
            // view.bounds already excludes the nav bar on real iOS 6 — don't use UIScreen.main.bounds.
            let bounds = view.bounds

            let table = UITableView(frame: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
            table.dataSource = self
            table.delegate = self
            table.tableFooterView = UIView(frame: .zero)
            view.addSubview(table)
            tableView = table

            let label = UILabel(frame: CGRect(x: 20, y: 40, width: bounds.width - 40, height: 60))
            label.textAlignment = .center
            label.numberOfLines = 0
            label.font = UIFont.systemFont(ofSize: 14)
            label.textColor = UIColor.gray
            label.text = "No favorites yet - visit a subreddit and tap Favorite."
            view.addSubview(label)
            emptyLabel = label
        }

        emptyLabel?.isHidden = !favorites.isEmpty
        tableView?.isHidden = favorites.isEmpty
        tableView?.reloadData()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return favorites.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: cellId) ?? UITableViewCell(style: .default, reuseIdentifier: cellId)
        cell.textLabel?.text = "r/\(favorites[indexPath.row])"
        cell.textLabel?.textColor = UIColor.black
        cell.textLabel?.numberOfLines = 1
        cell.selectionStyle = .default
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < favorites.count else { return }
        navigationController?.pushViewController(SubredditVC(subreddit: favorites[indexPath.row]), animated: true)
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, indexPath.row < favorites.count else { return }
        FavoritesStore.remove(favorites[indexPath.row])
        favorites.remove(at: indexPath.row)
        tableView.deleteRows(at: [indexPath], with: .automatic)
        if favorites.isEmpty {
            emptyLabel?.isHidden = false
            tableView.isHidden = true
        }
    }
}
