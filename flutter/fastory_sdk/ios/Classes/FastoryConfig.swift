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
}

public struct FastoryConfig: Equatable, Sendable {
    public let environment: FastoryEnvironment
    public let fanzoneSlug: String
    public let hubTabSlug: String
    public let locale: String?

    public init(
        environment: FastoryEnvironment = .production,
        fanzoneSlug: String,
        hubTabSlug: String,
        locale: String? = nil
    ) {
        self.environment = environment
        self.fanzoneSlug = fanzoneSlug
        self.hubTabSlug = hubTabSlug
        self.locale = locale
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
            URLQueryItem(name: "consent", value: "1")
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
            URLQueryItem(name: "utm_source", value: "sdk")
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
