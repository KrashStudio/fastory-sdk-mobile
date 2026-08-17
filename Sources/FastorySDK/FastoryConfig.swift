import Foundation

public enum FastoryEnvironment: Equatable, Sendable {
    case production
    case staging
    case development(baseURL: URL)

    public var baseURL: URL {
        switch self {
        case .production:
            return URL(string: "https://fanzone.me")!
        case .staging:
            return URL(string: "https://staging.fanzone.me")!
        case .development(let baseURL):
            return baseURL
        }
    }

    /// Origin the fanzone builds its game links on (the web's `storiesUrl`). Preload URLs
    /// must match the URL a real tap would produce, so cache entries line up. Development
    /// environments have no known stories origin — the discovery script falls back to the
    /// page's own origin.
    var storiesOrigin: URL? {
        switch self {
        case .production:
            return URL(string: "https://story.tl")!
        case .staging:
            return URL(string: "https://staging.story.tl")!
        case .development:
            return nil
        }
    }

    /// Publishable keys are minted per environment: a `live` key belongs to production, a
    /// `test` key to everything else. Checked locally at configure time so a key pasted into
    /// the wrong build fails immediately instead of at the first bootstrap call.
    var expectedKeyPrefix: String {
        switch self {
        case .production:
            return FastoryConfig.livePublishableKeyPrefix
        case .staging, .development:
            return FastoryConfig.testPublishableKeyPrefix
        }
    }
}

/// Appearance the host app asks the web surfaces to render in. Forwarded as a `theme` query
/// parameter; the web side does not read it yet, so setting it is inert until it ships there.
public enum FastoryTheme: String, Equatable, Sendable {
    case light
    case dark
}

/// Mirrors Android's (`require`) / Dart's (`ArgumentError`) config validation. Thrown by
/// `FastoryConfig.validate()` for callers that must surface a bad configuration to the host app
/// instead of trapping — e.g. the Flutter plugin's `configure()` bridge, which maps each case to
/// an `invalid_config` error.
public enum FastoryConfigError: Error, Equatable, Sendable, CustomStringConvertible {
    case blankFanzoneSlug
    case blankHubTabSlug
    case missingIdentifier
    case conflictingIdentifier
    case malformedPublishableKey
    case publishableKeyEnvironmentMismatch
    case blankWorkspaceId

    public var description: String {
        switch self {
        case .blankFanzoneSlug:
            return "fanzoneSlug must not be blank"
        case .blankHubTabSlug:
            return "hubTabSlug must not be blank"
        case .missingIdentifier:
            return "configure with either a publishableKey or a fanzoneSlug"
        case .conflictingIdentifier:
            return "configure with a publishableKey or a fanzoneSlug, not both"
        case .malformedPublishableKey:
            return "publishableKey must start with fpk_live_ or fpk_test_"
        case .publishableKeyEnvironmentMismatch:
            return "publishableKey does not belong to this environment"
        case .blankWorkspaceId:
            return "workspaceId must not be blank when provided"
        }
    }
}

public struct FastoryConfig: Equatable, Sendable {
    public static let livePublishableKeyPrefix = "fpk_live_"
    public static let testPublishableKeyPrefix = "fpk_test_"

    public let environment: FastoryEnvironment
    /// Identifies the workspace the host app belongs to. The fanzone to open is resolved from
    /// it at configure time; prefer this over `fanzoneSlug`.
    public let publishableKey: String?
    /// Optional cross-check: when set, a key resolving to a different workspace is rejected.
    /// Catches a key pasted into the wrong app rather than failing silently on someone else's
    /// fanzone.
    public let workspaceId: String?
    /// Deprecated identifier, kept for the whole 0.x compatibility window. `nil` when
    /// configured by publishable key.
    public let fanzoneSlug: String?
    public let hubTabSlug: String
    public let locale: String?
    public let theme: FastoryTheme?

    /// Not deprecated, so SDK-internal construction (and tests) never trips the deprecation
    /// warning attached to the slug initializer below.
    init(
        environment: FastoryEnvironment,
        publishableKey: String?,
        workspaceId: String?,
        fanzoneSlug: String?,
        hubTabSlug: String,
        locale: String?,
        theme: FastoryTheme?
    ) {
        self.environment = environment
        self.publishableKey = publishableKey
        self.workspaceId = workspaceId
        self.fanzoneSlug = fanzoneSlug
        self.hubTabSlug = hubTabSlug
        self.locale = locale
        self.theme = theme
    }

    public init(
        publishableKey: String,
        workspaceId: String? = nil,
        environment: FastoryEnvironment = .production,
        hubTabSlug: String = "games",
        locale: String? = nil,
        theme: FastoryTheme? = nil
    ) {
        self.init(
            environment: environment,
            publishableKey: publishableKey,
            workspaceId: workspaceId,
            fanzoneSlug: nil,
            hubTabSlug: hubTabSlug,
            locale: locale,
            theme: theme
        )
    }

    @available(
        *,
        deprecated,
        message: """
        Configure with a publishable key instead: FastoryConfig(publishableKey:). \
        Create one in the workspace settings. The fanzone slug keeps working for the whole 0.x \
        window; it will be removed in 1.0.
        """
    )
    public init(
        environment: FastoryEnvironment = .production,
        fanzoneSlug: String,
        hubTabSlug: String = "games",
        locale: String? = nil,
        theme: FastoryTheme? = nil
    ) {
        self.init(
            environment: environment,
            publishableKey: nil,
            workspaceId: nil,
            fanzoneSlug: fanzoneSlug,
            hubTabSlug: hubTabSlug,
            locale: locale,
            theme: theme
        )
    }

    /// Every rule the three platforms enforce identically. iOS keeps both initializers
    /// non-throwing (source-compatible with every existing call site), so callers that must
    /// reject bad input gracefully call this explicitly first.
    ///
    /// `environment == .development` needs no rule: unlike Kotlin/Dart's nullable
    /// `developmentBaseUrl: String?`, Swift's `.development(baseURL: URL)` case cannot be
    /// constructed without a URL — "development without a base URL" is not a representable
    /// state on iOS.
    public func validate() throws {
        guard !hubTabSlug.isBlank else { throw FastoryConfigError.blankHubTabSlug }

        switch (publishableKey, fanzoneSlug) {
        case (nil, nil):
            throw FastoryConfigError.missingIdentifier
        case (.some, .some):
            throw FastoryConfigError.conflictingIdentifier
        case (nil, .some(let slug)):
            guard !slug.isBlank else { throw FastoryConfigError.blankFanzoneSlug }
        case (.some(let key), nil):
            try Self.validatePublishableKey(key, environment: environment)
        }

        if let workspaceId, workspaceId.isBlank {
            throw FastoryConfigError.blankWorkspaceId
        }
    }

    static func validatePublishableKey(
        _ key: String,
        environment: FastoryEnvironment
    ) throws {
        let isLive = key.hasPrefix(livePublishableKeyPrefix)
        let isTest = key.hasPrefix(testPublishableKeyPrefix)
        guard isLive || isTest else {
            throw FastoryConfigError.malformedPublishableKey
        }
        // A prefix alone is not a key: reject `fpk_live_` with nothing after it.
        let prefix = isLive ? livePublishableKeyPrefix : testPublishableKeyPrefix
        guard key.count > prefix.count else {
            throw FastoryConfigError.malformedPublishableKey
        }
        guard prefix == environment.expectedKeyPrefix else {
            throw FastoryConfigError.publishableKeyEnvironmentMismatch
        }
    }

    /// Backwards-compatible entry point: the Flutter plugin calls this before constructing a
    /// slug-based config. New code calls `validate()` on the built config instead.
    public static func validate(fanzoneSlug: String, hubTabSlug: String) throws {
        guard !fanzoneSlug.isBlank else { throw FastoryConfigError.blankFanzoneSlug }
        guard !hubTabSlug.isBlank else { throw FastoryConfigError.blankHubTabSlug }
    }

    /// The hub URL for a resolved fanzone slug. Configured by key, the slug is only known once
    /// `/sdk/auth/bootstrap` answers, so this takes it as a parameter rather than reading it off
    /// the config.
    func hubURL(fanzoneSlug slug: String) -> URL {
        var components = URLComponents(
            url: environment.baseURL,
            resolvingAgainstBaseURL: false
        )!
        components.path = "/\(slug)"
        var queryItems = [
            URLQueryItem(name: "tab", value: hubTabSlug),
            URLQueryItem(name: "chrome", value: "0"),
            URLQueryItem(name: "consent", value: "0")
        ]
        if let locale {
            queryItems.append(URLQueryItem(name: "locale", value: locale))
        }
        if let theme {
            queryItems.append(URLQueryItem(name: "theme", value: theme.rawValue))
        }
        components.queryItems = queryItems
        return components.url!
    }

    /// Non-nil only when configured by slug — the one case where the hub URL is known without
    /// a round trip.
    var staticHubURL: URL? {
        guard let fanzoneSlug else { return nil }
        return hubURL(fanzoneSlug: fanzoneSlug)
    }

    /// Query parameters appended to every game URL. `embed`/`utm_source`/`consent` are added by
    /// `fastoryEmbeddedGameURL`; these are the ones that depend on the host's configuration.
    var gamePresentationQueryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let locale {
            items.append(URLQueryItem(name: "locale", value: locale))
        }
        if let theme {
            items.append(URLQueryItem(name: "theme", value: theme.rawValue))
        }
        return items
    }
}

extension URL {
    var fastoryEmbeddedGameURL: URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        var queryItems = components.queryItems ?? []
        let embedItems = [
            URLQueryItem(name: "embed", value: "1"),
            URLQueryItem(name: "utm_source", value: "sdk"),
            URLQueryItem(name: "consent", value: "0")
        ]
        for item in embedItems where !queryItems.contains(where: { $0.name == item.name }) {
            queryItems.append(item)
        }
        components.queryItems = queryItems
        return components.url ?? self
    }

    /// Adds the host's locale/theme on top of the embed parameters, without overwriting values
    /// the fanzone already put on the link.
    func fastoryEmbeddedGameURL(with items: [URLQueryItem]) -> URL {
        let embedded = fastoryEmbeddedGameURL
        guard !items.isEmpty,
              var components = URLComponents(url: embedded, resolvingAgainstBaseURL: false) else {
            return embedded
        }
        var queryItems = components.queryItems ?? []
        for item in items where !queryItems.contains(where: { $0.name == item.name }) {
            queryItems.append(item)
        }
        components.queryItems = queryItems
        return components.url ?? embedded
    }

    var fastoryGameSlug: String {
        let components = pathComponents.filter { $0 != "/" }
        guard components.count >= 2, components[0] == "s" else {
            return ""
        }
        return components[1]
    }
}

private extension String {
    /// Mirrors Kotlin's `isBlank()`: empty, or made up entirely of whitespace.
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
