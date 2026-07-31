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
}

/// Mirrors Android's (`require`) / Dart's (`ArgumentError`) config validation. Thrown by
/// `FastoryConfig.validate(fanzoneSlug:hubTabSlug:)` for callers that must surface a bad
/// configuration to the host app instead of trapping — e.g. the Flutter plugin's `configure()`
/// bridge, which maps each case to an `invalid_config` error.
public enum FastoryConfigError: Error, Equatable, Sendable, CustomStringConvertible {
    case blankFanzoneSlug
    case blankHubTabSlug

    public var description: String {
        switch self {
        case .blankFanzoneSlug:
            return "fanzoneSlug must not be blank"
        case .blankHubTabSlug:
            return "hubTabSlug must not be blank"
        }
    }
}

public struct FastoryConfig: Equatable, Sendable {
    public let environment: FastoryEnvironment
    public let fanzoneSlug: String
    public let hubTabSlug: String
    public let locale: String?

    public init(
        environment: FastoryEnvironment = .production,
        fanzoneSlug: String,
        hubTabSlug: String = "games",
        locale: String? = nil
    ) {
        self.environment = environment
        self.fanzoneSlug = fanzoneSlug
        self.hubTabSlug = hubTabSlug
        self.locale = locale
    }

    /// Validates the two config rules Android/Dart enforce unconditionally at construction.
    /// iOS keeps `init` non-throwing (source-compatible with every existing call site), so
    /// callers that must reject bad input gracefully call this explicitly first.
    ///
    /// `environment == .development` needs no rule here: unlike Kotlin/Dart's nullable
    /// `developmentBaseUrl: String?`, Swift's `.development(baseURL: URL)` case cannot be
    /// constructed without a URL — "development without a base URL" is not a representable
    /// state on iOS, so there is nothing to validate.
    public static func validate(fanzoneSlug: String, hubTabSlug: String) throws {
        guard !fanzoneSlug.isBlank else { throw FastoryConfigError.blankFanzoneSlug }
        guard !hubTabSlug.isBlank else { throw FastoryConfigError.blankHubTabSlug }
    }

    var hubURL: URL {
        var components = URLComponents(
            url: environment.baseURL,
            resolvingAgainstBaseURL: false
        )!
        components.path = "/\(fanzoneSlug)"
        var queryItems = [
            URLQueryItem(name: "tab", value: hubTabSlug),
            URLQueryItem(name: "chrome", value: "0"),
            URLQueryItem(name: "consent", value: "0")
        ]
        if let locale {
            queryItems.append(URLQueryItem(name: "locale", value: locale))
        }
        components.queryItems = queryItems
        return components.url!
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
