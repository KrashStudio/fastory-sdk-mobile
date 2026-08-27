import UIKit

/// The native error view both surfaces show when a load fails (SPEC § 9).
///
/// One builder rather than two identical ones: the hub and the game sheet must look the same to a
/// fan, and two copies of the same eight constraints are two places for that to stop being true.
enum FastoryErrorView {
    /// Pinned to `host`'s safe area and hidden until something fails. `actions` are stacked under the
    /// message in the order given — the sheet adds a close affordance the hub already has elsewhere.
    static func install(in host: UIView, actions: [UIButton]) -> UIView {
        let errorView = UIView()
        errorView.isHidden = true
        errorView.backgroundColor = .systemBackground
        errorView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(errorView)

        let messageLabel = UILabel()
        messageLabel.text = "Unable to load content"
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

    /// The primary action, filled and capsule-shaped on both surfaces.
    static func retryButton(_ handler: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = "Retry"
        configuration.cornerStyle = .capsule
        return UIButton(configuration: configuration, primaryAction: UIAction { _ in handler() })
    }

    static func plainButton(title: String, handler: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        return UIButton(configuration: configuration, primaryAction: UIAction { _ in handler() })
    }
}
