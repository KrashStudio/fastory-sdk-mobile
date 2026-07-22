import Foundation

public enum NavigationDecision: Equatable, Sendable {
    case allow
    case openGameSheet
    case openExternal
}

public enum URLPolicy {
    // Games are served from the Fanzone origin or from the Fastory stories domains; /s/ links on
    // either open the game sheet. Any other stories-domain path stays external.
    private static let storiesHosts: Set<String> = ["story.tl", "test.story.tl"]

    public static func decide(url: URL, baseURL: URL) -> NavigationDecision {
        guard isWebScheme(url) else {
            return .openExternal
        }
        if isSameOrigin(url, baseURL) {
            return url.path.hasPrefix("/s/") ? .openGameSheet : .allow
        }
        if isStoriesOrigin(url), url.path.hasPrefix("/s/") {
            return .openGameSheet
        }
        return .openExternal
    }

    private static func isStoriesOrigin(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && storiesHosts.contains(url.host?.lowercased() ?? "")
    }

    private static func isWebScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    private static func isSameOrigin(_ url: URL, _ baseURL: URL) -> Bool {
        url.scheme?.lowercased() == baseURL.scheme?.lowercased()
            && url.host?.lowercased() == baseURL.host?.lowercased()
            && effectivePort(of: url) == effectivePort(of: baseURL)
    }

    private static func effectivePort(of url: URL) -> Int? {
        if let port = url.port {
            return port
        }
        switch url.scheme?.lowercased() {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }
}
