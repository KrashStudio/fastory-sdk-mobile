import Foundation

/// The last verified delegated identity, kept across launches so a returning fan is shown at once
/// instead of re-verified before anything renders (SPEC § 2.6.3).
///
/// The identity is its `mode` and `fanId`: an opaque account id, not a credential. Neither the host's
/// token nor the embed session is ever stored. A `fanId` fan's refresh token is the one credential the
/// SDK keeps, in the Keychain rather than here (SPEC § 7.5), under the same stamp followed by the app's
/// bundle identifier: `pairing` decides at launch what the two found side by side mean, and they are
/// erased together.
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
    /// (production, staging, or a development host), the publishable key the workspace. The app's
    /// own defaults need nothing more, and an identity saved by an earlier version under this same
    /// stamp is still found after an update.
    private static func identityStamp(for config: FastoryConfig) -> String {
        "\(config.environment.baseURL.absoluteString)|\(config.publishableKey ?? "")"
    }

    /// The stamp of the refresh token issued under `config`, which is its Keychain account: the
    /// identity's stamp, then the app's bundle identifier. The default access group can be shared by
    /// several apps of one team, and the bundle identifier keeps each app to its own items.
    static func stamp(for config: FastoryConfig) -> String {
        "\(identityStamp(for: config))|\(applicationId)"
    }

    /// Whether `account` can be one of this app's: an account naming another bundle identifier is
    /// another app's, and is never erased or revoked here. An account naming none predates the
    /// bundle identifier, so it is this app's.
    static func belongsToThisApp(account: String) -> Bool {
        let parts = account.components(separatedBy: "|")
        return parts.count < 3 || parts.last == applicationId
    }

    private static let applicationIdLock = NSLock()
    private static var readApplicationId: String?

    /// The app's bundle identifier, read once: the account a token was stored under stays the one it
    /// is read back from for as long as the process runs.
    private static var applicationId: String {
        applicationIdLock.lock()
        defer { applicationIdLock.unlock() }
        if let readApplicationId {
            return readApplicationId
        }
        let read = FastoryWorkspaceResolver.shared.applicationId() ?? ""
        readApplicationId = read
        return read
    }

    /// Forgets the bundle identifier read so far, so the next stamp reads it again.
    static func forgetApplicationId() {
        applicationIdLock.lock()
        readApplicationId = nil
        applicationIdLock.unlock()
    }

    /// The environment a stamp was made under, or `nil` when it cannot be read as one — a token whose
    /// environment is unknown is never sent anywhere at a guess.
    static func environment(ofStamp stamp: String) -> FastoryEnvironment? {
        guard let separator = stamp.firstIndex(of: "|"),
              let url = URL(string: String(stamp[..<separator])),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else {
            return nil
        }
        let known: [FastoryEnvironment] = [.production, .staging]
        return known.first { $0.baseURL.absoluteString == url.absoluteString } ?? .development(baseURL: url)
    }

    static func save(_ identity: FastoryResolvedIdentity, config: FastoryConfig) {
        guard let fanId = identity.fanId else { return }
        let entry = Entry(mode: identity.mode.rawValue, fanId: fanId, stamp: identityStamp(for: config))
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
        guard entry.stamp == identityStamp(for: config),
              let mode = FastoryIdentityMode(rawValue: entry.mode) else {
            purge()
            return nil
        }
        return FastoryResolvedIdentity(mode: mode, fanId: entry.fanId)
    }

    static func purge() {
        store.removeObject(forKey: storageKey)
    }

    // MARK: - The identity and the refresh token, side by side

    /// What the identity in force and the refresh token read beside it call for (SPEC § 2.6.3).
    enum Pairing: Equatable {
        /// A `fanId` fan with a token: present it for a new session.
        case renew(String)
        /// A `fanId` fan whose token is gone — a reinstall, a restore: the fan is signed out, with no
        /// event, since nothing was refused.
        case signOut
        /// A token with no `fanId` fan beside it: it renews no one, so it is erased.
        case eraseToken(String)
        /// The device has not been unlocked since it restarted, so an empty read means *not yet*:
        /// nothing is concluded until it has.
        case waitForUnlock
        /// The read reached no answer: the fan and the token stay, and the read is tried again.
        case retryLater
        /// Nothing to pair.
        case unchanged
    }

    static func pairing(
        identity: FastoryResolvedIdentity?,
        token: FastoryRefreshTokenReadResult
    ) -> Pairing {
        let isFanIdFan = identity?.mode == .fanId
        switch token {
        case .present(let value):
            return isFanIdFan ? .renew(value) : .eraseToken(value)
        case .absent:
            return isFanIdFan ? .signOut : .unchanged
        case .locked:
            return isFanIdFan ? .waitForUnlock : .unchanged
        case .failed:
            return isFanIdFan ? .retryLater : .unchanged
        }
    }
}
