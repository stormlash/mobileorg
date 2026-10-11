import UIKit

@objc(SceneDelegate)
class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        guard let appDelegate = UIApplication.shared.delegate as? MobileOrgAppDelegate else { return }

        let window = UIWindow(windowScene: windowScene)
        appDelegate.window = window
        window.rootViewController = appDelegate.tabBarController
        window.makeKeyAndVisible()
        self.window = window
    }
}
