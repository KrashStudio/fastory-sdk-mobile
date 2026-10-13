import UIKit
import WebKit

enum FastoryWebKit {
    // No shared WKProcessPool: deprecated since iOS 15 and "no longer has any effect", so setting
    // one only produced a deprecation warning. WebKit decides process sharing on its own at the
    // SDK's iOS 15 floor (SPEC § 7.1).
    static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        // Every SDK WebView speaks the bridge — hub, game sheet and preloaded games alike, since
        // all three are built here. Receive-only: it adds a channel, it changes no navigation.
        FastoryBridge.attach(to: configuration)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        return webView
    }
}

/// Pure classification, kept independent of any view controller instance: the decision needs only
/// the error.
enum NavigationErrorClassifier {
    static func isBenign(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return true
        }
        // WebKit reports frame-load-interrupted (102, legacy WebKitErrorDomain) when a
        // navigation is cancelled by our URLPolicy decision — not a real load failure.
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 {
            return true
        }
        return false
    }
}

/// The band the hub leaves under the status bar has to contrast with the bar's own text. When the
/// host lets view controllers decide, the hub's default style and the system background agree by
/// construction, in either appearance. A host that switches view-controller-based appearance off
/// keeps its own style over the hub — light text over a dark brand, or whatever its current screen
/// last set — so the band follows that style instead.
enum FastoryStatusBarBand {
    static func color(forcedStyle: UIStatusBarStyle?) -> UIColor {
        switch forcedStyle {
        case .lightContent:
            return .black
        case .darkContent:
            return .white
        default:
            return .systemBackground
        }
    }

    /// The style the host imposes on the scene `view` is shown in, nil when view controllers decide.
    /// Injectable because the test host has neither a window scene nor the Info.plist switch.
    static var forcedStyle: (UIView) -> UIStatusBarStyle? = hostForcedStyle

    static func hostForcedStyle(in view: UIView) -> UIStatusBarStyle? {
        let key = "UIViewControllerBasedStatusBarAppearance"
        guard (Bundle.main.object(forInfoDictionaryKey: key) as? Bool) == false else { return nil }
        return view.window?.windowScene?.statusBarManager?.statusBarStyle
    }
}

final class FastoryHubViewController: UIViewController {
    typealias HubResolution = Result<(url: URL, fanzoneSlug: String), FastoryBootstrapError>
    typealias HubResolver = (@escaping (HubResolution) -> Void) -> Void

    private let config: FastoryConfig
    private let resolveHub: HubResolver
    private let webView: WKWebView
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    private var errorView = UIView()
    private let retryWait = FastoryErrorView.RetryWait()
    private var resolvedFanzoneSlug: String?

    /// The one gate on `hubOpened` and `hubClosed`, shared with the game sheet (SPEC § 9.1). A page
    /// the warm-up already committed starts committed: no further commit callback is coming for it,
    /// and a gate that waited for one would swallow the event on every presentation that reuses a
    /// warmed page — which, on the slug path, is every presentation that goes well.
    private var load: FastorySurfaceLoad

    /// Whether this presentation has a page worth keeping. Reusing it is the whole point of the
    /// warm-up, so it is never reloaded here.
    private let reusesPrewarmedPage: Bool

    /// One main-thread turn later, as `close()` waits for the game sheet to be gone. Replaceable so
    /// the turns can be driven explicitly rather than waited for.
    static var scheduleCloseTurn: (@escaping () -> Void) -> Void = { work in
        DispatchQueue.main.asyncAfter(deadline: .now() + closeTurnInterval, execute: work)
    }
    static let closeTurnInterval: TimeInterval = 1.0 / 60.0
    /// How many turns `close()` keeps asking for the sheet before taking the hub down with the sheet
    /// still up — about a second, longer than any transition UIKit could be refusing it for.
    static let closeTurnBudget = 60

    /// `resolveHub` is injected so the presentation contract — chiefly that `hubOpened` fires on
    /// every presentation, prewarmed or not — stands on its own, without the `Fastory` singleton
    /// having to be configured.
    init(config: FastoryConfig, resolveHub: @escaping HubResolver = Fastory.resolveHub) {
        self.config = config
        self.resolveHub = resolveHub
        let warm = Fastory.takeWarmHubWebView()
        self.webView = warm?.webView ?? FastoryWebKit.makeWebView()
        // Reuse the page only when there is one to reuse: committed, or still on its way. A hub whose
        // load failed is stashed back with neither, and presenting it as-is would leave a blank
        // WebView on screen that no callback will ever fire for.
        self.reusesPrewarmedPage = (warm?.hasCommitted ?? false) || (warm?.webView.isLoading ?? false)
        self.load = FastorySurfaceLoad(
            surface: .hub,
            isIdentified: false,
            hasCommitted: warm?.hasCommitted ?? false
        )
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupWebView()
        setupLoadingIndicator()
        setupErrorView()
        setupCloseButton()
        // Covers the cold-open path (no warm hub yet) and keeps discovery running on every
        // hub load, including retries; harmless re-watch when the hub was prewarmed.
        Fastory.watchHubForPreloading(webView)
        // Resolving runs even when the warm-up already produced the page: it is what yields the
        // fanzone slug, and `hubOpened` cannot be announced without it.
        openHub(reusingPrewarmedPage: reusesPrewarmedPage)
    }

    /// Not `viewWillAppear`: a presented controller's view joins the window after that callback, so
    /// the scene and its status bar style are only readable from here on.
    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        view.backgroundColor = FastoryStatusBarBand.color(
            forcedStyle: FastoryStatusBarBand.forcedStyle(view)
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        announce(load.present())
    }

    /// Emits what the load state decided, so the two events and the failure leave through one place.
    ///
    /// `hubOpened` carries the fanzone slug, which on the publishable key path is only known once
    /// the API answers — hence `identify()` — and it announces a hub whose page loaded, not merely a
    /// view controller that reached the screen (SPEC § 9.1).
    private func announce(_ announcement: FastorySurfaceLoad.Announcement) {
        switch announcement {
        case .nothing:
            break
        case .opened:
            // The slug is stored immediately before `identify()`, and `identify()` is the only way
            // the state machine can reach `.opened` — so nil here is a caller that broke that
            // pairing, and swallowing it would leave a hub open with a `hubClosed` still owed.
            guard let slug = resolvedFanzoneSlug else {
                assertionFailure("the hub announced itself open with no resolved fanzone slug")
                return
            }
            Fastory.eventsDelegate?.fastoryHubOpened(fanzoneSlug: slug)
        case .failed(let failure):
            Fastory.eventsDelegate?.fastorySurfaceLoadFailed(failure)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            // Keep the loaded hub warm for the next openGames() instead of reloading from scratch.
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.removeFromSuperview()
            // `config`, not the SDK's current one: a re-configure may have happened while this hub
            // was on screen, and this page still holds the fanzone it was built for.
            Fastory.stashWarmHubWebView(webView, config: config, hasCommitted: load.hasCommittedPage)
            // A hub that never announced itself open owes no `hubClosed`: the pair brackets a
            // session, and a close with no open in front of it is the report of a session that did
            // not happen (SPEC § 5.3).
            if load.dismiss() {
                Fastory.eventsDelegate?.fastoryHubClosed()
            }
        }
    }

    /// The page is kept out of the system bars natively rather than left to pad itself with
    /// `env(safe-area-inset-*)`: WebKit hands a page its insets only after its first layout when the
    /// load started off screen, which a warmed-up page always did, so the page painted its first
    /// frame under the status bar and stayed there until something made WebKit send them. Inside the
    /// safe area the page reads zero insets and pads nothing, so the two never add up.
    private func setupWebView() {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor)
        ])
    }

    private func setupLoadingIndicator() {
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.isAccessibilityElement = true
        loadingIndicator.accessibilityLabel = FastoryErrorView.localized("status.loading")
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loadingIndicator)
        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func setupErrorView() {
        errorView = FastoryErrorView.install(
            in: view,
            actions: [FastoryErrorView.retryButton { [weak self] in self?.retryHub() }]
        )
    }

    private func setupCloseButton() {
        var closeConfiguration = UIButton.Configuration.filled()
        closeConfiguration.image = UIImage(
            systemName: "xmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        )
        closeConfiguration.baseBackgroundColor = UIColor.systemBackground.withAlphaComponent(0.85)
        closeConfiguration.baseForegroundColor = .label
        closeConfiguration.cornerStyle = .capsule
        let closeButton = UIButton(
            configuration: closeConfiguration,
            primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            }
        )
        closeButton.accessibilityLabel = FastoryErrorView.localized("action.close")
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    private func openHub(reusingPrewarmedPage: Bool = false) {
        FastoryPerfSignposts.beginBootstrapWait()
        errorView.isHidden = true
        if !reusingPrewarmedPage || webView.isLoading {
            loadingIndicator.startAnimating()
        }
        // Configured by publishable key, the fanzone is resolved from the API — the indicator
        // covers that round trip, and a rejected key lands on the same native error view as a
        // failed page load rather than on a blank webview.
        resolveHub { [weak self] result in
            FastoryPerfSignposts.endBootstrapWait()
            guard let self else { return }
            switch result {
            case .success(let hub):
                self.resolvedFanzoneSlug = hub.fanzoneSlug
                self.announce(self.load.identify())
                guard !reusingPrewarmedPage else { return }
                FastoryPerfSignposts.beginHubLoad()
                self.webView.load(URLRequest(url: hub.url))
            case .failure(let error):
                // The exchange's own `code` is what § 2.5 requires a host to branch on, and it was
                // reaching neither the host nor the screen: a revoked key, an application the
                // workspace never declared and a phone in a tunnel all produced this one view.
                let classified = FastoryLoadFailureClassifier.bootstrap(code: error.code)
                self.reportFailure(reason: classified.reason, code: classified.code)
            }
        }
    }

    /// A retry may open the hub the first load could not, so the failure it follows is cleared —
    /// otherwise the surface stays permanently unable to announce itself.
    ///
    /// Configured by key there is no loaded URL to reload, so what has to run again is the exchange
    /// (§ 9) — and it does not restart on its own: `FastoryWorkspaceResolver.rearmAfterFailure`
    /// carries why, and which refusals it declines to re-arm.
    ///
    /// Internal rather than private: the error view is built in code, and this is the only way to
    /// trigger its Retry without the hub actually presented.
    func retryHub() {
        load.restart()
        Fastory.retryHubResolution()
        // The indicator comes up and VoiceOver is pointed at it before the resolution rather than
        // inside `openHub`, which can fail on the spot — a refusal the resolver declined to re-arm
        // answers synchronously — and the error view's own announcement has to come second.
        errorView.isHidden = true
        loadingIndicator.startAnimating()
        retryWait.begin(indicator: loadingIndicator)
        openHub()
    }

    private func reportFailure(
        reason: FastoryLoadFailureReason,
        code: String? = nil,
        statusCode: Int? = nil
    ) {
        loadingIndicator.stopAnimating()
        retryWait.fail()
        FastoryErrorView.show(errorView, reason: reason)
        announce(load.fail(reason: reason, code: code, statusCode: statusCode))
    }

    private func presentGameSheet(for url: URL) {
        let gameSheet = FastoryGameSheetViewController(
            config: config,
            gameURL: url.fastoryEmbeddedGameURL,
            gameSlug: url.fastoryGameSlug
        )
        present(gameSheet, animated: true)
    }

    private func openExternally(_ url: URL) {
        UIApplication.shared.open(url)
        Fastory.eventsDelegate?.fastoryExternalLink(url: url)
    }
}

extension FastoryHubViewController: WKNavigationDelegate {
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
            // A new main-frame document: it may fail on its own account, and a failure already
            // reported for the previous one must not swallow that. Never a second `hubOpened` —
            // the state machine keeps that to one per presentation. `== true` rather than the
            // guard's own `!= false`: a nil target frame is a `window.open`, not this document
            // being replaced, and restarting on one would re-arm a surface nothing is reloading.
            if navigationAction.targetFrame?.isMainFrame == true {
                load.restart()
            }
            decisionHandler(.allow)
        case .openGameSheet:
            decisionHandler(.cancel)
            presentGameSheet(for: url)
        case .openExternal:
            decisionHandler(.cancel)
            openExternally(url)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        // Surface HTTP failures on the main document as the native error view (§9);
        // transient sub-resource failures are ignored.
        if navigationResponse.isForMainFrame,
           let httpResponse = navigationResponse.response as? HTTPURLResponse,
           httpResponse.statusCode >= 400 {
            FastoryPerfSignposts.endHubLoad()
            decisionHandler(.cancel)
            reportFailure(reason: .rejected, statusCode: httpResponse.statusCode)
            return
        }
        decisionHandler(.allow)
    }

    /// Commit, not `didFinish`: the document has been accepted for display, which is what makes the
    /// hub genuinely open, and it lands within a frame or two of the response rather than after
    /// every sub-resource. A page that 404s or never connects never commits, which is precisely
    /// what keeps `hubOpened` off it (SPEC § 9.1).
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        FastoryPerfSignposts.endHubLoad()
        announce(load.commit())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadingIndicator.stopAnimating()
        errorView.isHidden = true
        retryWait.succeed()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        FastoryPerfSignposts.endHubLoad()
        handleLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        FastoryPerfSignposts.endHubLoad()
        handleLoadFailure(error)
    }

    private func handleLoadFailure(_ error: Error) {
        loadingIndicator.stopAnimating()
        // A cancelled load ends the wait too, or a page finishing minutes later would announce
        // itself as the one Retry asked for.
        retryWait.fail()
        guard let reason = FastoryLoadFailureClassifier.navigation(error) else {
            return
        }
        reportFailure(reason: reason)
    }
}

extension FastoryHubViewController: WKUIDelegate {
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
            presentGameSheet(for: url)
        case .openExternal:
            openExternally(url)
        }
        return nil
    }
}

extension UIViewController {
    /// Dismisses this controller and whatever it presents, the presented controller first.
    ///
    /// `dismiss(animated:)` on a controller that is itself presenting something takes down what it
    /// presents and leaves the controller on screen — so a hub with a game sheet up survived the
    /// host's `close()`, and `hubClosed` never came. The order is fixed here rather than left to
    /// UIKit's own stack dismissal, which promises nothing about the order of the disappearance
    /// callbacks the closing events leave from (SPEC § 5.3: `gameClosed` before `hubClosed`).
    /// Only the last surface animates: the host asked for its screen back, and animating the sheet
    /// too would make it wait through two transitions.
    ///
    /// Nothing here waits on a dismissal's completion. UIKit refuses a dismissal asked for while a
    /// transition is in flight — the sheet still animating in, the fan mid-swipe — and may never run
    /// the completion it was given; a hub whose departure hung on it would stay, which is the defect
    /// again in a narrower window. The sheet is asked to go, then its departure is read a turn later
    /// and asked for again until it is gone, within a budget; past it the hub goes with the sheet
    /// still up, and UIKit takes both, because a host that asked for its screen back must get it.
    func fastoryDismissPresentedThenSelf(animated: Bool) {
        fastoryDismissPresentedThenSelf(
            animated: animated,
            turnsLeft: FastoryHubViewController.closeTurnBudget
        )
    }

    private func fastoryDismissPresentedThenSelf(animated: Bool, turnsLeft: Int) {
        guard presentedViewController != nil, turnsLeft > 0 else {
            fastoryDismissFromPresenter(animated: animated)
            return
        }
        dismiss(animated: false)
        FastoryHubViewController.scheduleCloseTurn { [weak self] in
            self?.fastoryDismissPresentedThenSelf(animated: animated, turnsLeft: turnsLeft - 1)
        }
    }

    /// The controller's own dismissal is asked of its presenter, never of itself: on the controller
    /// the call would again mean whatever it presents at that instant. Asked only while the presenter
    /// still presents this controller — on one that no longer does, the call would climb the chain
    /// and take down a screen of the host's. The screen-change notice lands once the controller is
    /// gone, so VoiceOver settles on what the fan came back to rather than on the departing hub.
    private func fastoryDismissFromPresenter(animated: Bool) {
        guard let presenter = presentingViewController,
              presenter.presentedViewController === self else {
            return
        }
        presenter.dismiss(animated: animated) {
            FastoryErrorView.postAccessibilityNotification(.screenChanged, nil)
        }
    }
}
