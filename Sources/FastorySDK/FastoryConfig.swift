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
///
/// `LocalizedError` as well as `CustomStringConvertible`, so the rule reads the same through
/// `error.localizedDescription` — the idiomatic thing to log in a `catch` — as through
/// interpolation. Without it Foundation answers "The operation couldn't be completed" there.
public enum FastoryConfigError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    case blankFanzoneSlug
    case blankHubTabSlug
    case missingIdentifier
    case conflictingIdentifier
    case malformedPublishableKey
    case publishableKeyEnvironmentMismatch

    public var errorDescription: String? { description }

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
            return "publishableKey must start with fpk_live_ or fpk_test_, followed by the key itself"
        case .publishableKeyEnvironmentMismatch:
            return "publishableKey does not belong to this environment"
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
    /// Deprecated identifier, kept for the whole 0.x compatibility window. `nil` when
    /// configured by publishable key.
    public let fanzoneSlug: String?
    public let hubTabSlug: String
    public let locale: String?
    public let theme: FastoryTheme?
    /// The surfaces the SDK prepares before their first opening (SPEC § 2.1) — the hub alone unless
    /// you ask for more.
    ///
    /// A prepared surface opens already rendered, and it keeps a WebView resident from the moment it
    /// is prepared. Add `.membership` when your app opens the membership panel; left out, the panel's
    /// first opening loads when it is asked for, and its page is kept after it closes like any other.
    /// An empty set prepares nothing ahead of time. `.game` has no effect of its own: games are
    /// preloaded from the hub's page, so they follow `.hub`. The deprecated slug path resolves no
    /// workspace, so it has no panel to prepare and ignores `.membership`.
    public let prewarm: Set<FastorySurface>
    /// Whether your app signs the fan in when a Fastory page asks it to (SPEC § 2.6).
    ///
    /// No page the SDK presents ever shows a login form of its own. Declared, the hub, the
    /// membership panel and the games keep their sign-in entries, and a fan's tap on one reaches
    /// `FastoryEventsDelegate.fastoryBridgeMessage(type:payload:)` as `fastory:login-requested`:
    /// sign the fan in your own way, then call `Fastory.identify`. Left `false`, the pages show no
    /// sign-in entry at all. Declare it only if you handle that message — otherwise every sign-in
    /// entry becomes a control that does nothing.
    public let handlesLoginRequests: Bool

    /// Not deprecated, so SDK-internal construction never trips the deprecation warning attached to
    /// the slug initializer below.
    init(
        environment: FastoryEnvironment,
        publishableKey: String?,
        fanzoneSlug: String?,
        hubTabSlug: String,
        locale: String?,
        theme: FastoryTheme?,
        prewarm: Set<FastorySurface> = [.hub],
        handlesLoginRequests: Bool = false
    ) {
        self.environment = environment
        self.publishableKey = publishableKey
        self.fanzoneSlug = fanzoneSlug
        self.hubTabSlug = hubTabSlug
        self.locale = locale
        self.theme = theme
        self.prewarm = prewarm
        self.handlesLoginRequests = handlesLoginRequests
    }

    public init(
        publishableKey: String,
        environment: FastoryEnvironment = .production,
        hubTabSlug: String = "games",
        locale: String? = nil,
        theme: FastoryTheme? = nil,
        prewarm: Set<FastorySurface> = [.hub],
        handlesLoginRequests: Bool = false
    ) {
        self.init(
            environment: environment,
            publishableKey: publishableKey,
            fanzoneSlug: nil,
            hubTabSlug: hubTabSlug,
            locale: locale,
            theme: theme,
            prewarm: prewarm,
            handlesLoginRequests: handlesLoginRequests
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
        theme: FastoryTheme? = nil,
        prewarm: Set<FastorySurface> = [.hub],
        handlesLoginRequests: Bool = false
    ) {
        self.init(
            environment: environment,
            publishableKey: nil,
            fanzoneSlug: fanzoneSlug,
            hubTabSlug: hubTabSlug,
            locale: locale,
            theme: theme,
            prewarm: prewarm,
            handlesLoginRequests: handlesLoginRequests
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
        queryItems += hostLoginQueryItems
        components.queryItems = queryItems
        return components.url!
    }

    /// The bot page of a resolved workspace (SPEC § 3.5, "Bot URL").
    ///
    /// Addressed by workspace identifier, which the publishable-key exchange returns and the
    /// deprecated slug path never learns: a fanzone slug names a fanzone, not the workspace that
    /// owns it. `consent=0` says the host application owns the fan's analytics consent, so the page
    /// raises no banner of its own. The appearance hint the hub and the game carry is not one of
    /// this page's parameters, and forwarding it here would be reading the hub's rules into it.
    ///
    /// The host names a `sequenceId` and the page reads a `sequence` parameter. Blank is no
    /// sequence at all: a host reading an empty field out of its own interface names none, and an
    /// empty parameter would ask the page for a sequence with no identifier rather than for the
    /// panel's default screen. The identifier is host-supplied text, so it travels as a query
    /// *value* — pasted into the query string, its own `&` would mint a parameter nobody sent.
    func membershipURL(workspaceId: String, sequenceId: String? = nil) -> URL {
        var components = URLComponents(
            url: environment.baseURL,
            resolvingAgainstBaseURL: false
        )!
        components.path = "/embed/bot/\(workspaceId)"
        var queryItems = [URLQueryItem(name: "consent", value: "0")]
        if let locale {
            queryItems.append(URLQueryItem(name: "locale", value: locale))
        }
        if let sequenceId, !sequenceId.isBlank {
            queryItems.append(URLQueryItem(name: "sequence", value: sequenceId))
        }
        queryItems += hostLoginQueryItems
        components.queryItems = queryItems
        // Composing a query item escapes every character the page could read as structure except
        // `+`: Foundation counts it legal inside a query value, while the page's own reader takes a
        // bare `+` for a space — an identifier carrying one would arrive as a different string.
        // Nothing else here can produce one, the parameter names being literals, so every `+` left
        // in the composed query came from a value the host named.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// Non-nil only when configured by slug — the one case where the hub URL is known without
    /// a round trip.
    var staticHubURL: URL? {
        guard let fanzoneSlug else { return nil }
        return hubURL(fanzoneSlug: fanzoneSlug)
    }

    /// What the warm-up actually prepares: the surfaces `prewarm` asks for, among those this
    /// configuration can address before any opening. A game has no address of its own until the
    /// hub's page names it, and a fanzone slug names no workspace, so no panel.
    var surfacesToPrewarm: Set<FastorySurface> {
        prewarm.intersection(publishableKey != nil ? [.hub, .membership] : [.hub])
    }

    /// Reads `prewarm` off the platform channel's `configure` payload (SPEC § 5.2).
    ///
    /// Absent, `null` or not a list, it is the default — a caller that sends no such key asks for
    /// what every earlier version did. A name no surface carries is ignored rather than refused,
    /// exactly as an unrecognised `theme` is read as none.
    static func prewarm(fromChannel value: Any?) -> Set<FastorySurface> {
        guard let names = value as? [Any] else { return [.hub] }
        return Set(names.compactMap { ($0 as? String).flatMap(FastorySurface.init(rawValue:)) })
    }

    /// Reads `handlesLoginRequests` off the platform channel's `configure` payload (SPEC § 5.2).
    ///
    /// Only a boolean `true` declares it. Absent, `null` or anything else reads as `false`, never as
    /// an `invalid_config`: a declaration nobody can read is not one, and reading it as `true` would
    /// hand the fan sign-in entries no host listens for. A number is not a boolean here, although
    /// Foundation would bridge a `1` to `true`.
    static func handlesLoginRequests(fromChannel value: Any?) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    /// `hostLogin=1` when the host declared `handlesLoginRequests`, nothing otherwise (SPEC § 3.2,
    /// § 3.3, § 3.5). Never `hostLogin=0`: an absent parameter is what tells the page to show no
    /// sign-in entry, so a configuration that declares nothing leaves the addresses exactly as before.
    var hostLoginQueryItems: [URLQueryItem] {
        handlesLoginRequests ? [URLQueryItem(name: "hostLogin", value: "1")] : []
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
        return items + hostLoginQueryItems
    }
}

extension URL {
    /// The URL a game is loaded with (SPEC § 3.3): `embed`, `utm_source`, `consent`, then the host's
    /// own parameters (`FastoryConfig.gamePresentationQueryItems`), each added only when the link
    /// does not carry it already — the fanzone builds its own game links, and a value it put there
    /// wins. The host's parameters are required rather than defaulted: a call that forgot them would
    /// still compile, and quietly drop the locale and theme the host configured.
    func fastoryEmbeddedGameURL(with hostItems: [URLQueryItem]) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        var queryItems = components.queryItems ?? []
        let embedItems = [
            URLQueryItem(name: "embed", value: "1"),
            URLQueryItem(name: "utm_source", value: "sdk"),
            URLQueryItem(name: "consent", value: "0")
        ]
        for item in embedItems + hostItems where !queryItems.contains(where: { $0.name == item.name }) {
            queryItems.append(item)
        }
        components.queryItems = queryItems
        return components.url ?? self
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
