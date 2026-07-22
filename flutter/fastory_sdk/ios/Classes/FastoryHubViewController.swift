import UIKit
import WebKit

enum FastoryWebKit {
    static let processPool = WKProcessPool()

    static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = processPool
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        return webView
    }
}

final class FastoryHubViewController: UIViewController {
    private let config: FastoryConfig
    private lazy var webView = FastoryWebKit.makeWebView()
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    private let errorView = UIView()
    private var hasNotifiedOpened = false

    init(config: FastoryConfig) {
        self.config = config
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupWebView()
        setupLoadingIndicator()
        setupErrorView()
        setupCloseButton()
        loadHub()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !hasNotifiedOpened {
            hasNotifiedOpened = true
            Fastory.eventsDelegate?.fastoryHubOpened()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed {
            Fastory.eventsDelegate?.fastoryHubClosed()
        }
    }

    private func setupWebView() {
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
    }

    private func setupLoadingIndicator() {
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loadingIndicator)
        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func setupErrorView() {
        errorView.isHidden = true
        errorView.backgroundColor = .systemBackground
        errorView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(errorView)

        let messageLabel = UILabel()
        messageLabel.text = "Unable to load content"
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        var retryConfiguration = UIButton.Configuration.filled()
        retryConfiguration.title = "Retry"
        retryConfiguration.cornerStyle = .capsule
        let retryButton = UIButton(
            configuration: retryConfiguration,
            primaryAction: UIAction { [weak self] _ in
                self?.loadHub()
            }
        )

        let stackView = UIStackView(arrangedSubviews: [messageLabel, retryButton])
        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.spacing = 16
        stackView.translatesAutoresizingMaskIntoConstraints = false
        errorView.addSubview(stackView)

        NSLayoutConstraint.activate([
            errorView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            errorView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            errorView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stackView.centerXAnchor.constraint(equalTo: errorView.centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: errorView.centerYAnchor),
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: errorView.leadingAnchor, constant: 32),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: errorView.trailingAnchor, constant: -32)
        ])
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
        closeButton.accessibilityLabel = "Close"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    private func loadHub() {
        errorView.isHidden = true
        loadingIndicator.startAnimating()
        webView.load(URLRequest(url: config.hubURL))
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

    private func isBenignNavigationError(_ error: Error) -> Bool {
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
            decisionHandler(.cancel)
            loadingIndicator.stopAnimating()
            errorView.isHidden = false
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadingIndicator.stopAnimating()
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
        loadingIndicator.stopAnimating()
        guard !isBenignNavigationError(error) else {
            return
        }
        errorView.isHidden = false
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
