import UIKit

public protocol FastoryEventsDelegate: AnyObject {
    func fastoryHubOpened()
    func fastoryHubClosed()
    func fastoryGameOpened(slug: String)
    func fastoryGameClosed()
    func fastoryExternalLink(url: URL)
}

public enum Fastory {
    public private(set) static var config: FastoryConfig?
    public static weak var eventsDelegate: FastoryEventsDelegate?
    private static weak var hubViewController: FastoryHubViewController?

    public static func configure(_ config: FastoryConfig) {
        self.config = config
    }

    public static func openGames(from presenter: UIViewController) {
        guard let config else {
            assertionFailure("Fastory.configure(_:) must be called before openGames(from:)")
            return
        }
        guard hubViewController == nil else {
            return
        }
        let hub = FastoryHubViewController(config: config)
        hubViewController = hub
        presenter.present(hub, animated: true)
    }

    public static func close() {
        hubViewController?.dismiss(animated: true)
    }
}
