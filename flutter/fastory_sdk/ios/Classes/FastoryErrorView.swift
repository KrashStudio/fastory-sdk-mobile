import UIKit

/// The native error view both surfaces show when a load fails (SPEC § 9).
///
/// One builder rather than two identical ones: the hub and the game sheet must look the same to a
/// fan, and two copies of the same eight constraints are two places for that to stop being true.
///
/// Every string a fan reads here comes from the SDK's own table, in the fan's language — the one
/// screen the SDK renders natively must not be the one screen that ignores it.
enum FastoryErrorView {
    /// The view `install` returns. A subclass rather than a bare `UIView` so the message can be
    /// changed once something has failed, without the caller holding on to the label.
    final class Container: UIView {
        let messageLabel = UILabel()
    }

    /// Pinned to `host`'s safe area and hidden until something fails. `actions` are stacked under the
    /// message in the order given — the sheet adds a close affordance the hub already has elsewhere.
    static func install(in host: UIView, actions: [UIButton]) -> Container {
        let errorView = Container()
        errorView.isHidden = true
        errorView.backgroundColor = .systemBackground
        errorView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(errorView)

        let messageLabel = errorView.messageLabel
        messageLabel.text = message(for: .unknown)
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        let stackView = UIStackView(arrangedSubviews: [messageLabel] + actions)
        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.spacing = 16
        stackView.translatesAutoresizingMaskIntoConstraints = false
        errorView.addSubview(stackView)

        NSLayoutConstraint.activate([
            errorView.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor),
            errorView.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor),
            errorView.leadingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.trailingAnchor),
            stackView.centerXAnchor.constraint(equalTo: errorView.centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: errorView.centerYAnchor),
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: errorView.leadingAnchor, constant: 32),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: errorView.trailingAnchor, constant: -32)
        ])
        return errorView
    }

    /// Reveals the view `install` returned, wording it for `reason`: the no-connection variant when
    /// nothing answered, the generic one otherwise (SPEC § 9). A view that did not come from
    /// `install` is still revealed, so a failure is never silent. The screen reader is pointed at
    /// the message, because the label may already be on screen with another wording.
    static func show(_ errorView: UIView, reason: FastoryLoadFailureReason) {
        let container = errorView as? Container
        container?.messageLabel.text = message(for: reason)
        errorView.isHidden = false
        if let label = container?.messageLabel {
            postAccessibilityNotification(.layoutChanged, label)
        }
    }

    /// Every notification the native chrome sends a screen reader goes through here, so what VoiceOver
    /// is told can be observed in one place. The default hands it to UIKit.
    static var postAccessibilityNotification: (UIAccessibility.Notification, Any?) -> Void = {
        UIAccessibility.post(notification: $0, argument: $1)
    }

    /// The screen reader's account of the wait Retry opens, on the hub and on the game sheet alike
    /// (SPEC § 9).
    ///
    /// Retry hides the error view, and VoiceOver's focus goes with it: for the length of the load a
    /// fan hears nothing, and nothing says when the wait is over. The wait is therefore narrated at
    /// both ends. It begins by pointing VoiceOver at the loading indicator, whose label says what is
    /// happening, and it ends either with the page, announced as loaded, or with the error view, which
    /// announces its own message when it is shown. A page that loads outside a retry says nothing: the
    /// first opening is a presentation VoiceOver announces itself, and a navigation inside the surface
    /// is the web's to narrate.
    final class RetryWait {
        private(set) var isPending = false

        /// `indicator` has to be on screen already: VoiceOver cannot land on a hidden view.
        func begin(indicator: UIView) {
            isPending = true
            FastoryErrorView.postAccessibilityNotification(.layoutChanged, indicator)
        }

        /// The page loaded. Announced once, and only when a retry was waiting on it. A screen change
        /// rather than an announcement, so VoiceOver starts the screen over rather than staying on
        /// the indicator that just left.
        func succeed() {
            guard isPending else { return }
            isPending = false
            FastoryErrorView.postAccessibilityNotification(
                .screenChanged,
                FastoryErrorView.localized("status.loaded")
            )
        }

        /// The wait ended without a page — the error view is back and announces itself, or the load
        /// was cancelled — so it only stops expecting one.
        func fail() {
            isPending = false
        }
    }

    /// What a fan reads for `reason`, from the table `bundle` carries — the fan's language unless
    /// one table is being read on purpose.
    static func message(
        for reason: FastoryLoadFailureReason,
        in bundle: Bundle = table()
    ) -> String {
        switch reason {
        case .network:
            return localized("error.noConnection", in: bundle)
        case .rejected, .unknown:
            return localized("error.generic", in: bundle)
        }
    }

    /// The primary action, filled and capsule-shaped on both surfaces.
    static func retryButton(_ handler: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = localized("action.retry")
        configuration.cornerStyle = .capsule
        return UIButton(configuration: configuration, primaryAction: UIAction { _ in handler() })
    }

    /// The way out the sheet keeps visible under the message (SPEC § 9).
    static func closeButton(_ handler: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = localized("action.close")
        return UIButton(configuration: configuration, primaryAction: UIAction { _ in handler() })
    }

    static let stringsTable = "FastorySDK"

    /// The key itself is the fallback: a table that lost a key shows it, rather than silently showing
    /// English where another language was expected.
    static func localized(_ key: String, in bundle: Bundle = table()) -> String {
        bundle.localizedString(forKey: key, value: nil, table: stringsTable)
    }

    /// The language the fan reads, in three steps (SPEC § 9): the first of the languages the fan's
    /// device prefers that the SDK carries a table for; failing that, the `locale` the host passed at
    /// configuration, when the SDK carries it; failing that, English. Read here rather than left to
    /// the platform, which would resolve the host application's language rather than the fan's, and
    /// knows nothing of the configured locale.
    static func language(
        preferred: [String] = Locale.preferredLanguages,
        configured: String? = Fastory.config?.locale,
        available: [String] = Bundle.fastoryResources.localizations
    ) -> String {
        let carried = Set(available.map(languageCode))
        if let match = preferred.map(languageCode).first(where: carried.contains) {
            return match
        }
        if let configured = configured.map(languageCode), carried.contains(configured) {
            return configured
        }
        return "en"
    }

    /// The table for `language`, opened as a bundle of its own; the whole resource bundle when the
    /// table cannot be opened, so the keys show rather than nothing.
    static func table(for language: String = language()) -> Bundle {
        guard let path = Bundle.fastoryResources.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .fastoryResources
        }
        return bundle
    }

    /// `fr-FR`, `fr_FR` and `fr` are one language to a table.
    private static func languageCode(_ identifier: String) -> String {
        let code = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first
        return (code.map(String.init) ?? identifier).lowercased()
    }
}

extension Bundle {
    /// The bundle carrying the SDK's string tables, on either channel it ships on. A Swift package
    /// gets an accessor synthesised for its resources; compiled into a pod, the same tables travel
    /// as a resource bundle inside the pod's own, and the pod's bundle is the fallback when that
    /// resource bundle cannot be found — the keys then show rather than nothing.
    static let fastoryResources: Bundle = {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        let pod = Bundle(for: FastoryErrorView.Container.self)
        return pod.url(forResource: "FastorySDK", withExtension: "bundle")
            .flatMap(Bundle.init(url:)) ?? pod
        #endif
    }()
}
