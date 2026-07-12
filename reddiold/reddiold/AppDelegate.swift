import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        let nav = UINavigationController(rootViewController: HomeVC())
        // Orange as main color — iOS 6's UINavigationBar has no barTintColor (iOS 7+ only,
        // would crash at runtime), so use the legacy .tintColor which colors the whole bar.
        nav.navigationBar.tintColor = UIColor.orange
        nav.navigationBar.titleTextAttributes = [NSAttributedString.Key.foregroundColor: UIColor.white]
        window?.rootViewController = nav
        window?.makeKeyAndVisible()
        return true
    }
}
