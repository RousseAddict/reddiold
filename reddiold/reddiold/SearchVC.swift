import UIKit

/// Subreddit-jump search screen. Uses the native UISearchBar (available since very early
/// iOS, its own control fixes the text/cursor vertical centering issues a plain
/// short-height UITextField had) + a styled "Go" button below it, pushing SubredditVC.
/// Avoids UIAlertController (iOS8+ only) and UISearchBarStyle (iOS7+ only, left unset).
class SearchVC: UIViewController, UISearchBarDelegate {
    private var searchBar: UISearchBar?

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
        bar.placeholder = "Subreddit name, e.g. swift"
        bar.autocapitalizationType = .none
        bar.autocorrectionType = .no
        bar.tintColor = UIColor.orange
        bar.delegate = self
        view.addSubview(bar)
        searchBar = bar
        bar.becomeFirstResponder()

        let button = UIButton(type: .custom)
        button.frame = CGRect(x: 16, y: 60, width: bounds.width - 32, height: 44)
        button.backgroundColor = UIColor.orange
        button.setTitle("Go", for: .normal)
        button.setTitleColor(UIColor.white, for: .normal)
        button.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        button.layer.cornerRadius = 8
        button.layer.masksToBounds = true
        button.addTarget(self, action: #selector(goTapped), for: .touchUpInside)
        view.addSubview(button)
    }

    @objc private func goTapped() {
        guard let name = searchBar?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
        searchBar?.resignFirstResponder()
        navigationController?.pushViewController(SubredditVC(subreddit: name), animated: true)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        goTapped()
    }
}
