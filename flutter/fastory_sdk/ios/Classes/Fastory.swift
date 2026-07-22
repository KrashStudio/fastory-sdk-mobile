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
    private static var warmGameWebView: WKWebView?
    private static var warmGameSlug: String?
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

    // The game sheet WebView is also retained across opens: reopening the same game shows it
    // instantly with its state; a different game reuses the warm webview and process.

    static func takeWarmGameWebView(loadedSlug: inout String?) -> WKWebView? {
        let webView = warmGameWebView
        loadedSlug = warmGameSlug
        warmGameWebView = nil
        warmGameSlug = nil
        return webView
    }

    static func stashWarmGameWebView(_ webView: WKWebView, slug: String) {
        warmGameWebView = webView
        warmGameSlug = slug
    }

    private static func warmUpHub() {
        guard hubViewController == nil, let config else { return }
        let webView = FastoryWebKit.makeWebView()
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
            warmGameWebView = nil
            warmGameSlug = nil
        }
    }
}
