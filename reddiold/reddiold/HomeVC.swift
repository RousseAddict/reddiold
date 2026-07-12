import UIKit

/// Root screen: front page listing (subreddit = nil). Nav bar has a "Menu" button (left)
/// with a slide-in side panel (currently just Favorites, room to add sections later — same
/// pattern as oldpipe's HomeVC menu) and a native system search icon (right, same
/// `barButtonSystemItem: .search` used by stoatold's ChatVC — a built-in system glyph, not
/// a custom CoreGraphics drawing, so it's guaranteed to render correctly on real iOS 6) that
/// jumps to SearchVC. Consolidating Favorites into the menu and shrinking Search to an icon
/// frees up nav bar width for the title text on the 320pt-wide screen.
class HomeVC: PostListVC {
    private var menuOverlay: UIView?
    private var menuPanel: UIView?
    private var menuOpen = false
    private let menuWidth: CGFloat = 240

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "reddiold"
        subreddit = nil
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Menu", style: .plain, target: self, action: #selector(toggleMenu))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .search, target: self, action: #selector(searchTapped))
    }

    @objc private func searchTapped() {
        navigationController?.pushViewController(SearchVC(), animated: true)
    }

    // MARK: - Side menu (slide-in panel + dimming overlay, same pattern as oldpipe's HomeVC)

    private func buildMenuIfNeeded() {
        guard menuOverlay == nil else { return }
        let bounds = view.bounds

        let overlay = UIView(frame: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
        overlay.backgroundColor = .clear
        overlay.isHidden = true

        let dim = UIButton(type: .custom)
        dim.frame = overlay.bounds
        dim.backgroundColor = UIColor(white: 0, alpha: 0.5)
        dim.addTarget(self, action: #selector(closeMenu), for: .touchUpInside)
        overlay.addSubview(dim)

        let panel = UIView(frame: CGRect(x: -menuWidth, y: 0, width: menuWidth, height: bounds.height))
        panel.backgroundColor = UIColor(white: 0.12, alpha: 1)
        overlay.addSubview(panel)

        let band = UIView(frame: CGRect(x: 0, y: 0, width: menuWidth, height: 78))
        band.backgroundColor = UIColor.orange
        panel.addSubview(band)

        let header = UILabel(frame: CGRect(x: 18, y: 40, width: menuWidth - 36, height: 30))
        header.backgroundColor = .clear
        header.textColor = UIColor.white
        header.font = UIFont.boldSystemFont(ofSize: 22)
        header.text = "reddiold"
        band.addSubview(header)

        let items: [(String, Selector)] = [
            ("Favorites", #selector(menuFavorites)),
            ("Saved Posts", #selector(menuSavedPosts)),
            ("Settings", #selector(menuSettings))
        ]
        var y: CGFloat = 78
        let rowH: CGFloat = 54
        for (itemTitle, sel) in items {
            let btn = UIButton(type: .custom)
            btn.frame = CGRect(x: 0, y: y, width: menuWidth, height: rowH)
            btn.contentHorizontalAlignment = .left
            btn.contentEdgeInsets = UIEdgeInsets(top: 0, left: 24, bottom: 0, right: 0)
            btn.setTitle(itemTitle, for: .normal)
            btn.setTitleColor(UIColor(white: 0.92, alpha: 1), for: .normal)
            btn.setTitleColor(UIColor.orange, for: .highlighted)
            btn.titleLabel?.font = UIFont.systemFont(ofSize: 16)
            btn.addTarget(self, action: sel, for: .touchUpInside)
            panel.addSubview(btn)

            let tab = UIView(frame: CGRect(x: 0, y: y + 14, width: 4, height: rowH - 28))
            tab.backgroundColor = UIColor.orange
            panel.addSubview(tab)

            let sep = UIView(frame: CGRect(x: 0, y: y + rowH - 0.5, width: menuWidth, height: 0.5))
            sep.backgroundColor = UIColor(white: 1, alpha: 0.08)
            panel.addSubview(sep)

            y += rowH
        }

        view.addSubview(overlay)
        menuOverlay = overlay
        menuPanel = panel
    }

    @objc private func toggleMenu() {
        if menuOpen { closeMenu() } else { openMenu() }
    }

    private func openMenu() {
        buildMenuIfNeeded()
        guard let overlay = menuOverlay, let panel = menuPanel else { return }
        view.bringSubviewToFront(overlay)
        overlay.isHidden = false
        menuOpen = true
        UIView.animate(withDuration: 0.25) {
            panel.frame.origin.x = 0
        }
    }

    @objc private func closeMenu() {
        guard let overlay = menuOverlay, let panel = menuPanel else { return }
        menuOpen = false
        UIView.animate(withDuration: 0.25, animations: {
            panel.frame.origin.x = -self.menuWidth
        }, completion: { _ in
            overlay.isHidden = true
        })
    }

    @objc private func menuFavorites() {
        closeMenu()
        navigationController?.pushViewController(FavoritesVC(), animated: true)
    }

    @objc private func menuSavedPosts() {
        closeMenu()
        navigationController?.pushViewController(SavedPostsVC(), animated: true)
    }

    @objc private func menuSettings() {
        closeMenu()
        navigationController?.pushViewController(SettingsVC(), animated: true)
    }
}
