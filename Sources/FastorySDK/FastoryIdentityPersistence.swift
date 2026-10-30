import Foundation

/// The last verified delegated identity, kept across launches so a returning fan is shown at once
/// instead of re-verified before anything renders (SPEC § 2.6.3).
///
/// Only the resolved identity is stored — never the host token, never the embed session. `fanId` is
/// an opaque account id, not a credential; the embed session lives minutes, so persisting either
/// would add risk and buy nothing. The panel shows the fan immediately from this; the games' session
/// is re-established in the background.
///
/// Stamped with the workspace and environment it was resolved under. A `configure` that resolves a
/// different pair ignores this and purges it, so one club's fan can never surface in another's app.
enum FastoryIdentityPersistence {
    private static let storageKey = "com.fastory.sdk.delegated-identity"

    struct Entry: Codable, Equatable {
        let mode: String
        let fanId: String
        let stamp: String
    }

    /// Seam for tests: a suite points this at an isolated suite so cases do not leak state into one
    /// another or into the host's real defaults.
    static var store: UserDefaults = .standard

    /// Identifies the configuration an identity belongs to. The base URL carries the environment
    /// (production, staging, or a development host), the publishable key the workspace.
    static func stamp(for config: FastoryConfig) -> String {
        "\(config.environment.baseURL.absoluteString)|\(config.publishableKey ?? "")"
    }

    static func save(_ identity: FastoryResolvedIdentity, config: FastoryConfig) {
        guard let fanId = identity.fanId else { return }
        let entry = Entry(mode: identity.mode.rawValue, fanId: fanId, stamp: stamp(for: config))
        guard let data = try? JSONEncoder().encode(entry) else { return }
        store.set(data, forKey: storageKey)
    }

    /// The persisted identity **iff** it was stamped under this configuration. A stamp mismatch
    /// purges it: a fan stored for another workspace or environment must never be shown here.
    static func load(config: FastoryConfig) -> FastoryResolvedIdentity? {
        guard let data = store.data(forKey: storageKey),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            return nil
        }
        guard entry.stamp == stamp(for: config),
              let mode = FastoryIdentityMode(rawValue: entry.mode) else {
            purge()
            return nil
        }
        return FastoryResolvedIdentity(mode: mode, fanId: entry.fanId)
    }

    static func purge() {
        store.removeObject(forKey: storageKey)
    }
}
