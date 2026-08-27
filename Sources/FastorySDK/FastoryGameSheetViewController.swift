import UIKit
import WebKit

final class FastoryGameSheetViewController: UIViewController {
    private let config: FastoryConfig
    private let gameURL: URL
    private var gameSlug: String
    private var lastGameURL: URL
    private let webView: WKWebView
    private let isPreloaded: Bool
    private var errorView = UIView()

    /// The same gate the hub uses (SPEC § 9.1). A pooled page has finished loading, so it starts
    /// committed and a prewarmed game announces itself the instant the sheet appears; a load adopted
    /// mid-flight has not, and waits for its own commit.
    private var load: FastorySurfaceLoad

    init(config: FastoryConfig, gameURL: URL, gameSlug: String) {
        self.config = config
        self.gameURL = gameURL
        self.lastGameURL = gameURL
        self.gameSlug = gameSlug
        let preloaded = FastoryGamePreloader.shared.takeWebView(slug: gameSlug)
        self.webView = preloaded?.webView ?? FastoryWebKit.makeWebView()
        self.isPreloaded = preloaded != nil
        self.load = FastorySurfaceLoad(
            surface: .game,
            hasCommitted: preloaded?.hasCommitted ?? false
        )
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
        setupErrorView()
        FastoryGamePreloader.shared.gameSheetWillPresent()
        // A preloaded webview is already rendering the game (or finishing its load) on a
        // fresh state — present it as-is. Only cold opens need a load here.
        if !isPreloaded {
            webView.load(URLRequest(url: gameURL))
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        announce(load.present())
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
            // A game that never announced itself open owes no `gameClosed` — the pair brackets a
            // session, and a sheet that only ever showed the error view held none (SPEC § 5.3).
            if load.dismiss() {
                Fastory.eventsDelegate?.fastoryGameClosed()
            }
        }
    }

    /// The game sheet's own native error view (SPEC § 9). Without it a failed game is a black sheet,
    /// which the fan cannot tell from a slow one.
    ///
    /// The sheet is swipe-dismissible, but a fan looking at an error view should not have to
    /// discover that: § 9's "the fan keeps a way out" is an affordance, not a gesture.
    private func setupErrorView() {
        errorView = FastoryErrorView.install(
            in: view,
            actions: [
                FastoryErrorView.retryButton { [weak self] in self?.retryGame() },
                FastoryErrorView.plainButton(title: "Close") { [weak self] in
                    self?.dismiss(animated: true)
                }
            ]
        )
    }

    private func announce(_ announcement: FastorySurfaceLoad.Announcement) {
        switch announcement {
        case .nothing:
            break
        case .opened:
            Fastory.eventsDelegate?.fastoryGameOpened(slug: gameSlug)
        case .failed(let failure):
            Fastory.eventsDelegate?.fastorySurfaceLoadFailed(failure)
        }
    }

    /// Internal rather than private so a suite can drive the error view's own button: the view is
    /// built in code, and reaching it through a tap would need the sheet actually presented.
    func retryGame() {
        load.restart()
        errorView.isHidden = true
        webView.load(URLRequest(url: lastGameURL))
    }

    private func reportFailure(
        reason: FastoryLoadFailureReason,
        statusCode: Int? = nil
    ) {
        errorView.isHidden = false
        announce(load.fail(reason: reason, statusCode: statusCode))
    }

    private func openExternally(_ url: URL) {
        UIApplication.shared.open(url)
        Fastory.eventsDelegate?.fastoryExternalLink(url: url)
    }

    private func loadGameInPlace(for url: URL) {
        let newSlug = url.fastoryGameSlug
        let slugChanged = newSlug != gameSlug
        if slugChanged {
            // Game-to-game navigation (§4.2): bracket the swap with gameClosed → gameOpened. The
            // close is owed only if the outgoing game ever opened, and the incoming one announces
            // itself when *its* document commits — not here, where it has not loaded yet.
            if load.dismiss() {
                Fastory.eventsDelegate?.fastoryGameClosed()
            }
            gameSlug = newSlug
        }
        load.restart()
        errorView.isHidden = true
        lastGameURL = url.fastoryEmbeddedGameURL
        webView.load(URLRequest(url: lastGameURL))
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
        // A new main-frame document may fail on its own account, and a failure reported for the
        // previous one must not swallow that. `== true` rather than the guard's own `!= false`: a
        // nil target frame is a `window.open`, not this document being replaced.
        let replacesTheDocument = navigationAction.targetFrame?.isMainFrame == true
        switch URLPolicy.decide(url: url, baseURL: config.environment.baseURL) {
        case .allow:
            if replacesTheDocument { load.restart() }
            decisionHandler(.allow)
        case .openGameSheet:
            if url.fastoryGameSlug == gameSlug {
                if replacesTheDocument { load.restart() }
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

    /// Without this and the two failure callbacks below there is no point in the sheet's code where
    /// a failure can be seen at all, and a game that 404s renders a blank sheet (SPEC § 9.1).
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame,
           let httpResponse = navigationResponse.response as? HTTPURLResponse,
           httpResponse.statusCode >= 400 {
            decisionHandler(.cancel)
            reportFailure(reason: .rejected, statusCode: httpResponse.statusCode)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        announce(load.commit())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        errorView.isHidden = true
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handleLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadFailure(error)
    }

    private func handleLoadFailure(_ error: Error) {
        guard let reason = FastoryLoadFailureClassifier.navigation(error) else {
            return
        }
        reportFailure(reason: reason)
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
