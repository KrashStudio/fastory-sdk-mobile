import UIKit
import WebKit

final class FastoryGameSheetViewController: UIViewController {
    private let config: FastoryConfig
    private let gameURL: URL
    private var gameSlug: String
    private var lastGameURL: URL
    private let webView: WKWebView
    private let isPreloaded: Bool
    private var hasNotifiedOpened = false

    init(config: FastoryConfig, gameURL: URL, gameSlug: String) {
        self.config = config
        self.gameURL = gameURL
        self.lastGameURL = gameURL
        self.gameSlug = gameSlug
        if let preloaded = FastoryGamePreloader.shared.takeWebView(slug: gameSlug) {
            self.webView = preloaded
            self.isPreloaded = true
        } else {
            self.webView = FastoryWebKit.makeWebView()
            self.isPreloaded = false
        }
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        FastoryGamePreloader.shared.gameSheetWillPresent()
        // A preloaded webview is already rendering the game (or finishing its load) on a
        // fresh state — present it as-is. Only cold opens need a load here.
        if !isPreloaded {
            webView.load(URLRequest(url: gameURL))
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !hasNotifiedOpened {
            hasNotifiedOpened = true
            Fastory.eventsDelegate?.fastoryGameOpened(slug: gameSlug)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            // Closing must actually end the game: silence it right away, then discard the
            // played webview with the sheet — its page (timers, audio, state) dies with it.
            // The preloader immediately rebuilds a fresh copy so reopening stays instant.
            webView.stopLoading()
            webView.pauseAllMediaPlayback()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.removeFromSuperview()
            FastoryGamePreloader.shared.gameSheetDidClose(slug: gameSlug, url: lastGameURL)
            Fastory.eventsDelegate?.fastoryGameClosed()
        }
    }

    private func openExternally(_ url: URL) {
        UIApplication.shared.open(url)
        Fastory.eventsDelegate?.fastoryExternalLink(url: url)
    }

    private func loadGameInPlace(for url: URL) {
        let newSlug = url.fastoryGameSlug
        let slugChanged = newSlug != gameSlug
        if slugChanged {
            // Game-to-game navigation (§4.2): bracket the swap with gameClosed → gameOpened.
            Fastory.eventsDelegate?.fastoryGameClosed()
            gameSlug = newSlug
        }
        lastGameURL = url.fastoryEmbeddedGameURL
        webView.load(URLRequest(url: lastGameURL))
        if slugChanged {
            Fastory.eventsDelegate?.fastoryGameOpened(slug: newSlug)
        }
    }
}

extension FastoryGameSheetViewController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url,
              navigationAction.targetFrame?.isMainFrame != false else {
            decisionHandler(.allow)
            return
        }
        switch URLPolicy.decide(url: url, baseURL: config.environment.baseURL) {
        case .allow:
            decisionHandler(.allow)
        case .openGameSheet:
            if url.fastoryGameSlug == gameSlug {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                loadGameInPlace(for: url)
            }
        case .openExternal:
            decisionHandler(.cancel)
            openExternally(url)
        }
    }
}

extension FastoryGameSheetViewController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else {
            return nil
        }
        switch URLPolicy.decide(url: url, baseURL: config.environment.baseURL) {
        case .allow:
            webView.load(URLRequest(url: url))
        case .openGameSheet:
            loadGameInPlace(for: url)
        case .openExternal:
            openExternally(url)
        }
        return nil
    }
}
