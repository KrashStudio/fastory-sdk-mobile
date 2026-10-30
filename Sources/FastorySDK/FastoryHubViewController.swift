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

/// The band the container leaves under the status bar has to contrast with the bar's own text. The
/// hub shows this colour there and, in landscape, on the side edges the system reserves, but not at
/// the bottom, where its page runs to the edge; the panel shows it over the home indicator as well.
/// When the host lets view controllers decide, the hub's default style and the system background
/// agree by construction, in either appearance. A host that switches view-controller-based
/// appearance off keeps its own style over the hub — light text over a dark brand, or whatever its
/// current screen last set — so the band follows that style instead.
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

/// The SDK's full-screen container, for either of the two surfaces it presents: the games hub, and
/// the workspace's membership panel (SPEC § 3.2, § 3.5).
///
/// One container rather than two, because everything around the page is the same — the close
/// control, the loading and error views, the four URL policy rules, the cascading dismissal. What
/// the surface decides is the address that is loaded, the warm slot the page is read from and put
/// back into, and which pair of events is announced.
final class FastoryHubViewController: UIViewController {
    /// The address a surface loads, and the fanzone slug the hub's opening event carries. Nil slug
    /// on the panel, which announces itself with no identifier of its own.
    typealias SurfaceResolution = Result<(url: URL, fanzoneSlug: String?), FastoryBootstrapError>
    typealias SurfaceResolver = (@escaping (SurfaceResolution) -> Void) -> Void

    private let config: FastoryConfig
    private let surface: FastorySurface
    private let resolve: SurfaceResolver
    private let webView: WKWebView
    /// Hides what an earlier presentation left on the page (SPEC § 9): up from the start of an
    /// opening on a page that already carries a document, down once that page is reused as it
    /// stands, a document loaded in its place has painted, or the load fails.
    private let outgoingDocumentCover = UIView()
    /// Bumped each time the cover goes up or down, so a paint wait started for one cover can neither
    /// lift the one that replaced it nor touch a page already handed on.
    private var coverGeneration = 0
    private var paintWaitGeneration: Int?
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    private var errorView = UIView()
    private let retryWait = FastoryErrorView.RetryWait()
    private var resolvedFanzoneSlug: String?

    /// The one gate on `hubOpened` and `hubClosed`, shared with the game sheet (SPEC § 9.1). A page
    /// the warm-up already committed starts committed: no further commit callback is coming for it,
    /// and a gate that waited for one would swallow the event on every presentation that reuses a
    /// warmed page — which, on the slug path, is every presentation that goes well.
    private var load: FastorySurfaceLoad

    /// Whether the page taken from the warm slot is worth presenting as it stands — committed, or
    /// on its way. Half of the reuse decision; the other half is the address it carries, which only
    /// the resolution knows.
    private let prewarmedPageIsUsable: Bool

    /// The address that page was prepared for, or nil when nothing was warm. Compared against the
    /// resolved address before the page is reused: a surface asked for at another address is
    /// another document, so the warm page is adopted and reloaded rather than shown as what it is
    /// not.
    private let prewarmedPageURL: URL?

    /// The address this presentation asked for, known once the resolution answers. It is what goes
    /// back into the warm slot on the way out — never `webView.url`, which is wherever the fan's
    /// own navigation left the page, and which the next opening would never recognise.
    private var requestedURL: URL?

    /// The latest resolution has answered. Not `requestedURL`, which a reload after an identity
    /// change keeps from the previous resolution while the new one is still minting its handoff:
    /// until this one answers, what finishes in the page is the outgoing document.
    private var addressSettled = false

    /// Counts the resolutions this container started, so only the latest one loads its answer. A
    /// reload after an identity change can start while an earlier resolution is still minting a
    /// handoff for the previous fan; landing after it, that answer would put the previous fan back.
    private var resolutionCount = 0

    private var presentationEnded = false

    /// One main-thread turn later, as `close()` waits for the game sheet to be gone. Replaceable so
    /// the turns can be driven explicitly rather than waited for.
    static var scheduleCloseTurn: (@escaping () -> Void) -> Void = { work in
        DispatchQueue.main.asyncAfter(deadline: .now() + closeTurnInterval, execute: work)
    }
    static let closeTurnInterval: TimeInterval = 1.0 / 60.0
    /// How many turns `close()` keeps asking for the sheet before taking the hub down with the sheet
    /// still up — about a second, longer than any transition UIKit could be refusing it for.
    static let closeTurnBudget = 60

    /// `resolve` is injected so the presentation contract — chiefly that the opening event fires on
    /// every presentation, prewarmed or not — stands on its own, without the `Fastory` singleton
    /// having to be configured. The default resolves the hub, so a container standing for another
    /// surface is given that surface's resolver at its call site.
    init(
        config: FastoryConfig,
        surface: FastorySurface = .hub,
        resolve: @escaping SurfaceResolver = Fastory.resolveHub
    ) {
        self.config = config
        self.surface = surface
        self.resolve = resolve
        // Each surface keeps its own page: taking the other's would open the wrong one, and stash it
        // back over the wrong slot on the way out.
        let warm = Fastory.takeWarmPage(for: surface)
        self.webView = warm?.webView ?? FastoryWebKit.makeWebView()
        // Reuse the page only when there is one to reuse: committed, or still on its way. A surface
        // whose load failed is stashed back with neither, and presenting it as-is would leave a blank
        // WebView on screen that no callback will ever fire for.
        self.prewarmedPageIsUsable = (warm?.hasCommitted ?? false) || (warm?.webView.isLoading ?? false)
        self.prewarmedPageURL = warm?.url
        self.load = FastorySurfaceLoad(
            surface: surface,
            // Neither surface can announce itself sight unseen: the hub's event carries the
            // fanzone slug the key exchange returns, and the panel's own resolved address can
            // differ from whatever a warm page already committed. identify() is what learns it,
            // for both, once openSurface() knows.
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
        setupOutgoingDocumentCover()
        setupLoadingIndicator()
        setupErrorView()
        setupCloseButton()
        if surface == .hub {
            // Covers the cold-open path (no warm hub yet) and keeps discovery running on every
            // hub load, including retries; harmless re-watch when the hub was prewarmed. The games
            // are listed by the hub's page and by nothing else, so no other surface watches.
            Fastory.watchHubForPreloading(webView)
        }
        // Resolving runs even when the warm-up already produced the page: on the hub it is what
        // yields the fanzone slug, which `hubOpened` cannot be announced without.
        openSurface(mayReusePrewarmedPage: prewarmedPageIsUsable)
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
    /// the API answers — hence `identify()` — and an opening event announces a surface whose page
    /// loaded, not merely a view controller that reached the screen (SPEC § 9.1).
    private func announce(_ announcement: FastorySurfaceLoad.Announcement) {
        switch announcement {
        case .nothing:
            break
        case .opened:
            guard surface != .membership else {
                Fastory.eventsDelegate?.fastoryMembershipOpened()
                return
            }
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

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            presentationEnded = true
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            // Keep the loaded page warm for the next opening instead of reloading from scratch, and
            // in its own surface's slot: stashed over the other's it would open under the wrong
            // entry point.
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.removeFromSuperview()
            // A cover still up was this presentation's: the page goes back readable, but not as one
            // to present as it stands — it may not have drawn its document yet.
            let stillCovered = !outgoingDocumentCover.isHidden
            setCover(false)
            // `config`, not the SDK's current one: a re-configure may have happened while this
            // surface was on screen, and this page still holds the workspace it was built for.
            Fastory.stashWarmPage(
                webView,
                for: surface,
                url: requestedURL,
                config: config,
                hasCommitted: load.hasCommittedPage && !stillCovered
            )
            // A surface that never announced itself open owes no closing event: the pair brackets a
            // session, and a close with no open in front of it is the report of a session that did
            // not happen (SPEC § 5.3).
            if load.dismiss() {
                if surface == .membership {
                    Fastory.eventsDelegate?.fastoryMembershipClosed()
                } else {
                    Fastory.eventsDelegate?.fastoryHubClosed()
                }
            }
        }
    }

    /// Whether the page runs under the home indicator rather than stopping at the safe area. Only the
    /// hub's page keeps its own content clear of the indicator; the panel's pads nothing for it, so a
    /// tab bar or an input field at its foot would sit under the indicator.
    private var runsToBottomEdge: Bool { surface == .hub }

    /// The top and the sides are kept out of the system bars natively rather than left to the page's
    /// `env(safe-area-inset-*)`: WebKit hands a page its insets only after its first layout when the
    /// load started off screen, which a warmed-up page always did, so the page painted its first
    /// frame under the status bar and stayed there until something made WebKit send them.
    ///
    /// The bottom depends on the surface. The hub's page runs to the bottom edge, with no band under
    /// the home indicator, and keeps its last content clear of the indicator through
    /// `env(safe-area-inset-bottom)`. The panel's page stops at the safe area and reads no bottom
    /// inset. The scroll view adjusts nothing on either: an inset it absorbed would never reach the
    /// page, or would reach it twice.
    private func setupWebView() {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(webView)
        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: safeArea.topAnchor),
            webView.bottomAnchor.constraint(
                equalTo: runsToBottomEdge ? view.bottomAnchor : safeArea.bottomAnchor
            ),
            webView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor)
        ])
    }

    /// A sibling over the page rather than the page hidden: WebKit may hold back drawing a hidden
    /// web view, and the new document would then appear late. `systemBackground`, the container's
    /// own background; it also takes the taps meant for the new page.
    private func setupOutgoingDocumentCover() {
        outgoingDocumentCover.backgroundColor = .systemBackground
        outgoingDocumentCover.isHidden = true
        outgoingDocumentCover.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(outgoingDocumentCover)
        NSLayoutConstraint.activate([
            outgoingDocumentCover.topAnchor.constraint(equalTo: webView.topAnchor),
            outgoingDocumentCover.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
            outgoingDocumentCover.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            outgoingDocumentCover.trailingAnchor.constraint(equalTo: webView.trailingAnchor)
        ])
    }

    private func setCover(_ covered: Bool) {
        coverGeneration += 1
        outgoingDocumentCover.isHidden = !covered
        // Covered, the outgoing screen is still in the page, and VoiceOver would read it.
        webView.accessibilityElementsHidden = covered
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
            coversBottomEdge: runsToBottomEdge,
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

    private func openSurface(mayReusePrewarmedPage: Bool = false) {
        signpost(FastoryPerfSignposts.beginBootstrapWait)
        errorView.isHidden = true
        // Before resolving rather than with the load: an identified hub learns its address over a
        // round trip, and the page would show the previous opening for all of it.
        let pageHoldsADocument = webView.fastoryHoldsCommittedDocument
        if pageHoldsADocument {
            setCover(true)
        }
        // A cover with nothing turning over it reads as a blank screen while the address resolves.
        if !mayReusePrewarmedPage || webView.isLoading || pageHoldsADocument {
            loadingIndicator.startAnimating()
        }
        // Configured by publishable key, the address is resolved from the API — the indicator
        // covers that round trip, and a rejected key lands on the same native error view as a
        // failed page load rather than on a blank webview.
        addressSettled = false
        resolutionCount += 1
        let resolution = resolutionCount
        resolve { [weak self] result in
            self?.signpost(FastoryPerfSignposts.endBootstrapWait)
            guard let self, resolution == self.resolutionCount else { return }
            switch result {
            case .success(let resolved):
                self.resolvedFanzoneSlug = resolved.fanzoneSlug
                self.requestedURL = resolved.url
                self.addressSettled = true
                // The address settles it, never the arguments the call carried: a page warmed on
                // the panel's default screen is not the sequence the fan asked for, and a page
                // already warm on that sequence is as reusable as the default one is to a bare
                // call. Stated this way, the next parameter to reach one of these URLs is covered.
                guard !(mayReusePrewarmedPage && self.prewarmedPageURL == resolved.url) else {
                    // Reused as it stands. One reused while it still loads stays covered: until it
                    // commits, what it draws is the document before it.
                    if self.load.hasCommittedPage {
                        self.setCover(false)
                        if !self.webView.isLoading {
                            self.loadingIndicator.stopAnimating()
                        }
                    }
                    self.announce(self.load.identify())
                    return
                }
                // The page in hand is not the one being asked for, so what it already committed
                // must not announce this presentation open before the new document arrives (§ 9.1)
                // — which is why this runs before identify(): settling on the resolved address
                // must never read the outgoing document's own commit.
                self.load.restart()
                self.loadingIndicator.startAnimating()
                self.signpost(FastoryPerfSignposts.beginHubLoad)
                self.webView.load(URLRequest(url: resolved.url))
                self.announce(self.load.identify())
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
        // inside `openSurface`, which can fail on the spot — a refusal the resolver declined to
        // re-arm answers synchronously — and the error view's own announcement has to come second.
        errorView.isHidden = true
        loadingIndicator.startAnimating()
        retryWait.begin(indicator: loadingIndicator)
        openSurface()
    }

    /// Loads the hub again under the session now in force, after an identity transition changed
    /// the identified fan (SPEC § 7). Not a new presentation: the load state keeps its opening, so
    /// no second opening event is announced, and a reload that fails is reported like any failure
    /// after the surface opened. The panel is never reloaded. A container whose view has not loaded
    /// yet has nothing to reload: its first resolution has not run, and it will read the new session.
    /// Nor does a container on its way out, from the moment its dismissal starts: its page goes back
    /// to the warm slot under the address this presentation asked for, so it must not load another.
    func reloadAfterIdentityChange() {
        guard surface == .hub, isViewLoaded, !presentationEnded else { return }
        openSurface()
    }

    /// Only the hub is measured: the marks name the hub's own bootstrap wait and page load, and a
    /// second surface reporting through them would make two openings indistinguishable in one trace.
    private func signpost(_ mark: () -> Void) {
        guard surface == .hub else { return }
        mark()
    }

    private func reportFailure(
        reason: FastoryLoadFailureReason,
        code: String? = nil,
        statusCode: Int? = nil
    ) {
        loadingIndicator.stopAnimating()
        setCover(false)
        retryWait.fail()
        FastoryErrorView.show(errorView, reason: reason)
        announce(load.fail(reason: reason, code: code, statusCode: statusCode))
    }

    private func presentGameSheet(for url: URL) {
        let gameSheet = FastoryGameSheetViewController(
            config: config,
            gameURL: gameSheetURL(for: url),
            gameSlug: url.fastoryGameSlug
        )
        present(gameSheet, animated: true)
    }

    /// Internal rather than private: the taps that reach it come through WebKit, which the tests
    /// cannot drive.
    func gameSheetURL(for url: URL) -> URL {
        url.fastoryEmbeddedGameURL(with: config.gamePresentationQueryItems)
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
            signpost(FastoryPerfSignposts.endHubLoad)
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
        signpost(FastoryPerfSignposts.endHubLoad)
        announce(load.commit())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Before this presentation knows its address, what finishes is the outgoing document: the
        // cover, and the indicator over it, wait for this presentation's own.
        errorView.isHidden = true
        guard addressSettled, !outgoingDocumentCover.isHidden else {
            if addressSettled {
                loadingIndicator.stopAnimating()
            }
            if outgoingDocumentCover.isHidden {
                retryWait.succeed()
            }
            return
        }
        awaitFirstPaint()
    }

    /// Finished is not drawn: WebKit keeps the previous page's last frame on screen until the new one
    /// paints content, and has no public callback for that moment. Under a cover, the page is asked
    /// every `firstPaintPoll` whether its Paint Timing holds a `first-contentful-paint` entry — a
    /// read-only constant, the bounded exception of SPEC § 12.1 — and the cover goes when it does, or
    /// at a native deadline of `firstPaintWait` whatever the page answers. The wait a Retry started is
    /// announced over only then: announced earlier, VoiceOver would land on a page still hidden.
    private func awaitFirstPaint() {
        // One wait per cover: a second finish under the same cover keeps the probe it started.
        guard paintWaitGeneration != coverGeneration else { return }
        let generation = coverGeneration
        paintWaitGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstPaintWait) { [weak self] in
            self?.liftCoverOnceDrawn(generation)
        }
        probeFirstPaint(generation)
    }

    private func probeFirstPaint(_ generation: Int) {
        webView.evaluateJavaScript(Self.firstPaintProbe) { [weak self] painted, _ in
            guard let self, generation == self.coverGeneration else { return }
            if (painted as? Bool) == true {
                self.liftCoverOnceDrawn(generation)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstPaintPoll) { [weak self] in
                guard let self, generation == self.coverGeneration else { return }
                self.probeFirstPaint(generation)
            }
        }
    }

    private func liftCoverOnceDrawn(_ generation: Int) {
        guard generation == coverGeneration else { return }
        loadingIndicator.stopAnimating()
        setCover(false)
        retryWait.succeed()
    }

    /// True once the page has drawn content: Paint Timing records the entry at its first contentful
    /// paint. The same constant on both platforms.
    static let firstPaintProbe = "performance.getEntriesByName('first-contentful-paint').length > 0"
    /// Internal and settable so a test need not wait the real intervals.
    static var firstPaintPoll: DispatchTimeInterval = .milliseconds(50)
    static var firstPaintWait: DispatchTimeInterval = .seconds(2)

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        signpost(FastoryPerfSignposts.endHubLoad)
        handleLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        signpost(FastoryPerfSignposts.endHubLoad)
        handleLoadFailure(error)
    }

    private func handleLoadFailure(_ error: Error) {
        // Under the cover, the load that ended is the outgoing one, cancelled by this presentation's
        // own: the indicator keeps turning until that one settles.
        if outgoingDocumentCover.isHidden {
            loadingIndicator.stopAnimating()
        }
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

extension WKWebView {
    /// Whether the page shows a document it committed. Not `url`, which is the active address, set
    /// the instant `load()` is called: a page still on its first load shows nothing yet, and an
    /// opening that covered it would hide what it is about to draw. `@objc` so a test double can
    /// stand in for the history it cannot build.
    @objc var fastoryHoldsCommittedDocument: Bool { backForwardList.currentItem != nil }
}
