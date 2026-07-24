import UIKit
import WebKit

public protocol FastoryEventsDelegate: AnyObject {
    func fastoryHubOpened(fanzoneSlug: String)
    func fastoryHubClosed()
    func fastoryGameOpened(slug: String)
    func fastoryGameClosed()
    func fastoryExternalLink(url: URL)
}

public enum Fastory {
    public private(set) static var config: FastoryConfig?
    public static weak var eventsDelegate: FastoryEventsDelegate?
    private static weak var hubViewController: FastoryHubViewController?
    private static var warmHubWebView: WKWebView?
    private static var memoryWarningObserver: NSObjectProtocol?

    public static func configure(_ config: FastoryConfig) {
        self.config = config
        warmUpHub()
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

    // MARK: - Hub keep-alive

    // The hub WebView is created and loaded at configure() and retained across sessions, so
    // openGames() presents an already-rendered page instead of reloading every time. Dropped on
    // re-configure (the hub URL may change) and under memory pressure.

    static func takeWarmHubWebView() -> WKWebView? {
        let webView = warmHubWebView
        warmHubWebView = nil
        return webView
    }

    static func stashWarmHubWebView(_ webView: WKWebView) {
        warmHubWebView = webView
    }

    // Warm game webviews live in FastoryGamePreloader: games are preloaded from the hub's
    // own game list, and a played game is rebuilt fresh right after its sheet closes.

    static func watchHubForPreloading(_ webView: WKWebView) {
        guard let config else { return }
        FastoryGamePreloader.shared.watchHub(webView, config: config)
    }

    private static func warmUpHub() {
        guard hubViewController == nil, let config else { return }
        FastoryGamePreloader.shared.flush()
        let webView = FastoryWebKit.makeWebView()
        FastoryGamePreloader.shared.watchHub(webView, config: config)
        webView.load(URLRequest(url: config.hubURL))
        warmHubWebView = webView
        observeMemoryPressureOnce()
    }

    private static func observeMemoryPressureOnce() {
        guard memoryWarningObserver == nil else { return }
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            warmHubWebView = nil
            FastoryGamePreloader.shared.flush()
        }
    }
}
