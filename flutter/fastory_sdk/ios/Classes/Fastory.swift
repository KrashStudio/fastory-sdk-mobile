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
        do {
            try config.validate()
        } catch {
            // Kept non-throwing for source compatibility. A rejected configuration is not
            // stored, so openGames() reports "not configured" instead of opening someone
            // else's fanzone or a blank hub.
            assertionFailure("Fastory.configure(_:) rejected the configuration: \(error)")
            return
        }
        self.config = config
        FastoryWorkspaceResolver.shared.reset()
        // Configured by key, the fanzone to open is only known once the API answers. Start the
        // exchange now so openGames() usually finds it already resolved.
        FastoryWorkspaceResolver.shared.resolve(config: config)
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

    /// Resolves the fanzone to open, and its slug — the `hubOpened` event carries it. Immediate on
    /// the deprecated slug path; on the publishable key path it waits for
    /// `/sdk/auth/bootstrap`, which `configure` already started.
    static func resolveHub(
        _ completion: @escaping (Result<(url: URL, fanzoneSlug: String), FastoryBootstrapError>) -> Void
    ) {
        guard let config else {
            completion(.failure(.unreachable))
            return
        }
        if let slug = config.fanzoneSlug {
            completion(.success((url: config.hubURL(fanzoneSlug: slug), fanzoneSlug: slug)))
            return
        }
        FastoryWorkspaceResolver.shared.whenResolved(config: config) { result in
            completion(result.map {
                (url: config.hubURL(fanzoneSlug: $0.slug), fanzoneSlug: $0.slug)
            })
        }
    }

    private static func warmUpHub() {
        guard hubViewController == nil, let config else { return }
        FastoryGamePreloader.shared.flush()
        // Only the slug path can warm up synchronously. On the key path the hub view controller
        // resolves and loads on presentation — warming a webview for an unknown URL is pointless.
        guard let hubURL = config.staticHubURL else { return }
        let webView = FastoryWebKit.makeWebView()
        FastoryGamePreloader.shared.watchHub(webView, config: config)
        webView.load(URLRequest(url: hubURL))
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
