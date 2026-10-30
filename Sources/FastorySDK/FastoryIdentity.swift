import Foundation
import WebKit

/// The identity a host asks the SDK to resolve. See `SPEC.md` § 2.6.
///
/// `fanId` carries no argument on purpose — it is a Fastory *login* through the system browser, not
/// an identifier the host supplies. `hostToken` is the opposite: the partner already authenticated
/// the fan, so nothing is typed and no browser opens.
public enum FastoryIdentity: Equatable, Sendable {
    case anonymous
    case fanId
    case hostToken(jwt: String)

    public var mode: FastoryIdentityMode {
        switch self {
        case .anonymous: return .anonymous
        case .fanId: return .fanId
        case .hostToken: return .hostToken
        }
    }
}

/// Raw values are the strings that cross the platform channel (SPEC § 5.2).
public enum FastoryIdentityMode: String, Equatable, Sendable {
    case anonymous
    case fanId
    case hostToken
}

public struct FastoryResolvedIdentity: Equatable, Sendable {
    public let mode: FastoryIdentityMode
    /// Always `nil` for `.anonymous`: the device visitor is minted per origin by the web page, so
    /// the native side never sees it (SPEC § 2.6.2).
    public let fanId: String?

    public init(mode: FastoryIdentityMode, fanId: String? = nil) {
        self.mode = mode
        self.fanId = fanId
    }

    static let anonymous = FastoryResolvedIdentity(mode: .anonymous, fanId: nil)
}

/// Why the SDK dropped a delegated identity **on its own** — the payload of the `identityRevoked`
/// event (SPEC § 5.3). A host-driven drop (`logout()`, a replacing `configure()`) is never a
/// revocation: the host already knows, so it gets no event.
public enum FastoryRevocationReason: String, Equatable, Sendable {
    /// A background re-exchange was refused by the API. Carries the API's own code when it named one.
    case rejected
    /// The embed session expired and could not be renewed — no host-token provider was registered,
    /// so there was no fresh assertion to re-exchange. Carries no code: nothing refused it.
    case expired
}

/// The `identityRevoked` event's payload. `code` is the API's machine-readable reason, present only
/// for `reason == .rejected` and only when the refusal named one (SPEC § 5.3, § 5.4).
public struct FastoryIdentityRevocation: Equatable, Sendable {
    public let reason: FastoryRevocationReason
    public let code: String?

    public init(reason: FastoryRevocationReason, code: String? = nil) {
        self.reason = reason
        self.code = code
    }
}

public enum FastoryIdentifyError: Error, Equatable, Sendable {
    case notConfigured
    case modeUnavailable(FastoryIdentityMode)
    case invalidIdentityMode(String)
    case invalidHostToken
    case loginCancelled
    /// The API refused the assertion. `code` carries its machine-readable reason when it named one,
    /// and is `nil` when the refusal had no readable body — never a guessed code (SPEC § 5.4).
    case rejected(code: String?)
    case network

    /// Machine-readable code crossing the platform channel (SPEC § 5.4). Hosts branch on this,
    /// never on a message.
    public var code: String {
        switch self {
        case .notConfigured: return "not_configured"
        case .modeUnavailable: return "identify_mode_unavailable"
        case .invalidIdentityMode: return "invalid_identity_mode"
        case .invalidHostToken: return "invalid_host_token"
        case .loginCancelled: return "login_cancelled"
        case .rejected: return "identify_rejected"
        case .network: return "identify_network_error"
        }
    }

    /// A pre-flight rejection is decided before anything is attempted, so it leaves the current
    /// identity untouched. A resolution failure happened after the previous session was already
    /// erased, so it leaves the SDK anonymous (SPEC § 2.6.1). Conflating the two is how asking for
    /// a not-yet-released mode would sign a fan out.
    var isPreflight: Bool {
        switch self {
        case .notConfigured, .modeUnavailable, .invalidIdentityMode, .invalidHostToken:
            return true
        case .loginCancelled, .rejected, .network:
            return false
        }
    }
}

// MARK: - The declared erasure contract

/// The identity-bearing web state an identity transition must erase, and where.
///
/// The names are declared rather than discovered because the platform cookie APIs cannot report
/// them all: the fan session cookie is `httpOnly`, which Android's `CookieManager.getCookie` never
/// returns. Keeping both platforms on one declared list is what makes the behaviour identical.
///
/// iOS and Android declare the same list — a name one platform expires and the other does not is a
/// fan who survives a logout on one of them.
enum FastoryIdentityStorage {
    static let cookieNames: [String] = [
        "fst-visitor",
        "__Secure-next-auth.session-token-v2",
        "next-auth.session-token",
        "__Secure-next-auth.callback-url-v2",
        "next-auth.pkce.code_verifier-v2",
        "__Host-next-auth.csrf-token",
        "fst-session",
    ]

    static let webStorageTypes: Set<String> = [
        WKWebsiteDataTypeLocalStorage,
        WKWebsiteDataTypeSessionStorage,
        WKWebsiteDataTypeIndexedDBDatabases,
        WKWebsiteDataTypeWebSQLDatabases,
    ]

    /// Both surfaces: the hub session lives on the fanzone origin and the game visitor on the
    /// stories origin, so erasing one leaves half the fan behind. Development has no known stories
    /// origin, exactly as in game-URL construction.
    static func origins(for config: FastoryConfig) -> [URL] {
        var origins = [config.environment.baseURL]
        if let stories = config.environment.storiesOrigin {
            origins.append(stories)
        }
        return origins
    }
}

/// Erases the declared state (`FastoryIdentityStorage`) from the SDK's own origins only.
///
/// Never call an all-origins API here. `WKWebsiteDataStore.default()` is shared with every other
/// `WKWebView` in the host app, so a blanket wipe signs the partner out of their own services
/// (SPEC § 7.4).
enum FastoryWebsiteDataEraser {
    static func erase(
        origins: [URL],
        from store: WKWebsiteDataStore = .default(),
        completion: @escaping () -> Void
    ) {
        let hosts = Set(origins.compactMap { $0.host?.lowercased() })
        guard !hosts.isEmpty else {
            completion()
            return
        }
        eraseCookies(hosts: hosts, from: store) {
            eraseWebStorage(hosts: hosts, from: store, completion: completion)
        }
    }

    private static func eraseCookies(
        hosts: Set<String>,
        from store: WKWebsiteDataStore,
        completion: @escaping () -> Void
    ) {
        let names = Set(FastoryIdentityStorage.cookieNames)
        store.httpCookieStore.getAllCookies { cookies in
            let doomed = cookies.filter { names.contains($0.name) && matches(hosts, $0.domain) }
            guard !doomed.isEmpty else {
                completion()
                return
            }
            var remaining = doomed.count
            for cookie in doomed {
                store.httpCookieStore.delete(cookie) {
                    remaining -= 1
                    if remaining == 0 { completion() }
                }
            }
        }
    }

    private static func eraseWebStorage(
        hosts: Set<String>,
        from store: WKWebsiteDataStore,
        completion: @escaping () -> Void
    ) {
        let types = FastoryIdentityStorage.webStorageTypes
        store.fetchDataRecords(ofTypes: types) { records in
            // A record's displayName is a registrable domain, so `staging.fanzone.me` arrives as
            // `fanzone.me` — match by suffix or the staging origins are silently spared.
            let ours = records.filter { matches(hosts, $0.displayName) }
            guard !ours.isEmpty else {
                completion()
                return
            }
            store.removeData(ofTypes: types, for: ours, completionHandler: completion)
        }
    }

    private static func matches(_ hosts: Set<String>, _ domain: String) -> Bool {
        let candidate = domain.hasPrefix(".")
            ? String(domain.dropFirst()).lowercased()
            : domain.lowercased()
        return hosts.contains { $0 == candidate || $0.hasSuffix(".\(candidate)") }
    }
}

// MARK: - The transition rules

/// What `identify` / `logout` must do, decided before anything is touched.
///
/// Pure by design: every rule of SPEC § 2.6.1 is decidable without a WebView, a data store or a
/// network, so the rules can be reasoned about on their own.
struct FastoryIdentityTransition: Equatable {
    /// `nil` when the call fails.
    let resolved: FastoryResolvedIdentity?
    let error: FastoryIdentifyError?
    let erasesStorage: Bool
    let emitsIdentityResolved: Bool

    /// Whether the standing bridge answers die with this transition (SPEC § 13.8.2). Not derived
    /// from `erasesStorage`: a host may set a standing answer without ever calling `identify`, so
    /// `logout()` has to revoke even when it has no session to erase.
    let revokesBridgeReplies: Bool

    /// A transition that erases also has to drop the warm hub and the preloaded games: both were
    /// built before the transition and hold the previous fan's rendered page (SPEC § 7.4).
    var discardsWarmSurfaces: Bool { erasesStorage }
}

enum FastoryIdentityRules {
    static func transition(
        requesting requested: FastoryIdentity,
        from current: FastoryResolvedIdentity?
    ) -> FastoryIdentityTransition {
        switch requested {
        case .hostToken(let jwt) where jwt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return rejected(.invalidHostToken)
        case .fanId, .hostToken:
            // A pre-flight rejection, so asking for a mode this version does not implement must not
            // sign the current fan out.
            return rejected(.modeUnavailable(requested.mode))
        case .anonymous:
            let resolved = FastoryResolvedIdentity.anonymous
            // Erase only on a real change. Erasing on an already-anonymous call is what would break
            // idempotency: it forces the web to mint a new visitor, so each call would hand back a
            // different fan.
            let changed = current != resolved
            return FastoryIdentityTransition(
                resolved: resolved,
                error: nil,
                erasesStorage: changed && current != nil,
                emitsIdentityResolved: changed,
                // The same difference rule: a new fan must not inherit the previous one's answer,
                // while an idempotent call must leave a standing answer the host just set alone.
                revokesBridgeReplies: changed && current != nil
            )
        }
    }

    /// What to do once an exchange has resolved a fan (`identify(.hostToken)`). The same difference
    /// rule as `.anonymous`: erase and re-announce only when the fan actually changed, so resolving
    /// the same fan twice is idempotent — no erasure, no second `identityResolved`, and the standing
    /// answer refreshed rather than revoked. `current == nil` is the first identify ever, which has
    /// nothing to erase but is still a change worth announcing.
    static func afterResolution(
        _ resolved: FastoryResolvedIdentity,
        from current: FastoryResolvedIdentity?
    ) -> FastoryIdentityTransition {
        let changed = current != resolved
        return FastoryIdentityTransition(
            resolved: resolved,
            error: nil,
            erasesStorage: changed && current != nil,
            emitsIdentityResolved: changed,
            revokesBridgeReplies: changed && current != nil
        )
    }

    /// What to do when an exchange fails (SPEC § 2.6.1): the SDK must not keep the previous identity,
    /// or a host that saw `identify` fail would still be serving the old fan. Erase what was there
    /// and revoke the standing answer, landing on anonymous — the caller reports the error instead of
    /// emitting `identityResolved`. A pre-flight rejection never reaches here; it is decided before
    /// the exchange and leaves everything untouched.
    static func afterResolutionFailure(from current: FastoryResolvedIdentity?) -> FastoryIdentityTransition {
        logout(from: current)
    }

    static func logout(from current: FastoryResolvedIdentity?) -> FastoryIdentityTransition {
        FastoryIdentityTransition(
            resolved: nil,
            error: nil,
            erasesStorage: current != nil,
            emitsIdentityResolved: false,
            // Unconditional, unlike the erasure: nothing populates the standing answer
            // automatically yet, so today it is only ever there because the host put it there —
            // with no identify() call anywhere in that story. Gating this on `current != nil` would
            // make logout() silently keep serving the fan it announces it signed out.
            revokesBridgeReplies: true
        )
    }

    private static func rejected(_ error: FastoryIdentifyError) -> FastoryIdentityTransition {
        FastoryIdentityTransition(
            resolved: nil,
            error: error,
            erasesStorage: false,
            emitsIdentityResolved: false,
            // A pre-flight rejection touches nothing (SPEC § 2.6.1), the standing answer included.
            revokesBridgeReplies: false
        )
    }
}

// MARK: - The host-token lifecycle (SPEC § 2.6, § 5.3)

/// The observable effects of one lifecycle event, decided without any I/O so both platforms map the
/// same trigger to the same outcome — the renewal analogue of `FastoryIdentityExchangeClassifier`.
struct FastoryLifecycleEffects: Equatable {
    enum Identity: String { case preserved, anonymous }
    enum StandingAnswer: String { case preserved, refreshed, revoked }
    enum Persistence: String { case unchanged, written, read, purged }

    let identity: Identity
    let standingAnswer: StandingAnswer
    /// The `identityRevoked` event to emit, or `nil`. Only a background drop carries one — a
    /// host-driven `logout`/`configReplaced` never surprises the host with news it already has.
    let revocation: FastoryIdentityRevocation?
    let persistence: Persistence
}

/// Maps each host-token lifecycle event to its effects. Pure and total, so every case is decidable
/// the same way on both platforms: the shared reference the two renewal coordinators in `Fastory` are
/// written against, and what the cross-platform fixture pins so a case cannot drift between them.
enum FastoryHostTokenLifecycle {
    enum Trigger: Equatable {
        /// The embed session is still valid but nearing expiry: refresh it, involving no one.
        case sessionExpiring
        /// `/embed/auth/refresh` refused, but a host-token provider is registered: a fresh assertion
        /// re-exchanges into a new session for the same fan.
        case refreshRefused
        /// A background re-exchange was itself refused. The identity cannot be kept.
        case exchangeRefused(code: String?)
        /// The session expired and no provider is registered — nothing to re-exchange.
        case sessionExpiredNoProvider
        /// `configure` found a persisted identity for this workspace/environment: show it at once,
        /// confirm it in the background.
        case bootRehydration
        /// The host signed the fan out. Host-driven, so no event.
        case logout
        /// A replacing `configure` discards the previous configuration's identity. Host-driven.
        case configReplaced
    }

    static func effects(for trigger: Trigger) -> FastoryLifecycleEffects {
        switch trigger {
        case .sessionExpiring:
            return FastoryLifecycleEffects(
                identity: .preserved, standingAnswer: .refreshed,
                revocation: nil, persistence: .unchanged
            )
        case .refreshRefused:
            // The provider handed back a fresh assertion and the re-exchange resolved the same fan:
            // the new session's token replaces the standing answer, and persistence is re-stamped.
            return FastoryLifecycleEffects(
                identity: .preserved, standingAnswer: .refreshed,
                revocation: nil, persistence: .written
            )
        case .exchangeRefused(let code):
            return FastoryLifecycleEffects(
                identity: .anonymous, standingAnswer: .revoked,
                revocation: FastoryIdentityRevocation(reason: .rejected, code: code),
                persistence: .purged
            )
        case .sessionExpiredNoProvider:
            return FastoryLifecycleEffects(
                identity: .anonymous, standingAnswer: .revoked,
                revocation: FastoryIdentityRevocation(reason: .expired, code: nil),
                persistence: .purged
            )
        case .bootRehydration:
            return FastoryLifecycleEffects(
                identity: .preserved, standingAnswer: .preserved,
                revocation: nil, persistence: .read
            )
        case .logout, .configReplaced:
            // Host-driven: the fan is dropped and persistence purged, but no event — the host
            // initiated it. The standing answer is revoked so no game keeps the old token.
            return FastoryLifecycleEffects(
                identity: .anonymous, standingAnswer: .revoked,
                revocation: nil, persistence: .purged
            )
        }
    }
}
