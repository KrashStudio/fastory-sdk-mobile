import Foundation
import Security

/// The four Keychain calls the refresh-token store makes. Production forwards them to `SecItem*`
/// unchanged; a test substitutes its own to read the attributes actually sent and to script the
/// statuses actually returned.
protocol FastorySecItemAPI {
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], with attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: Any?)
}

struct FastorySystemSecItem: FastorySecItemAPI {
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(_ query: [String: Any], with attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: Any?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }
}

/// What reading the stored refresh token found. `locked` and `failed` reached no answer, so they are
/// never a missing token: the caller tries again rather than signing the fan out (SPEC § 7.5).
enum FastoryRefreshTokenReadResult: Equatable {
    case present(String)
    case absent
    /// The device has not been unlocked since it restarted.
    case locked
    case failed(OSStatus)
}

enum FastoryRefreshTokenOperationResult: Equatable {
    case done
    case locked
    case failed(OSStatus)
}

struct FastoryStoredRefreshToken: Equatable {
    let account: String
    let token: String
}

/// Keeps a `fanId` fan's refresh token in the Keychain (SPEC § 7.5): a generic password under the
/// SDK's own service, one account per configuration stamp — which names the app's bundle identifier —
/// readable once the device has been unlocked after a restart, never synchronised to iCloud and never
/// restored onto another device.
///
/// Every query names the service and, except the orphan sweep, the account: the Keychain is shared
/// with the host app, so nothing here ever matches a whole class of items. `SecItem*` calls can block,
/// so they run on a serial queue of the store's own, in submission order, and each completion is
/// delivered on the main thread.
final class FastoryRefreshTokenStore {
    static let service = "com.fastory.sdk.refresh-token"

    private static let queue = DispatchQueue(label: "com.fastory.sdk.refresh-token-store", qos: .userInitiated)

    private let secItem: FastorySecItemAPI

    init(secItem: FastorySecItemAPI = FastorySystemSecItem()) {
        self.secItem = secItem
    }

    func read(account: String, completion: @escaping (FastoryRefreshTokenReadResult) -> Void) {
        run(completion) { secItem in
            Self.read(account: account, from: secItem)
        }
    }

    /// Reads the token of `account` and removes it in one queued operation, handing back what was
    /// read — so a token let go before anyone read it can still be revoked. The token is removed even
    /// when it could not be read.
    func take(account: String, completion: @escaping (String?) -> Void) {
        run(completion) { secItem in
            let found = Self.read(account: account, from: secItem)
            _ = secItem.delete(Self.item(account: account))
            guard case .present(let token) = found else { return nil }
            return token
        }
    }

    /// Stores `token` for `account`, replacing the one already there: a rotated token never sits
    /// beside its predecessor.
    func write(
        _ token: String,
        account: String,
        completion: @escaping (FastoryRefreshTokenOperationResult) -> Void = { _ in }
    ) {
        run(completion) { secItem in
            let data = Data(token.utf8)
            var attributes = Self.item(account: account)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            attributes[kSecAttrSynchronizable as String] = false
            var status = secItem.add(attributes)
            if status == errSecDuplicateItem {
                status = secItem.update(
                    Self.item(account: account),
                    with: [kSecValueData as String: data]
                )
            }
            return Self.operationResult(status)
        }
    }

    /// Removes the token of `account` alone. An already missing token is erased too.
    func erase(
        account: String,
        completion: @escaping (FastoryRefreshTokenOperationResult) -> Void = { _ in }
    ) {
        run(completion) { secItem in
            let status = secItem.delete(Self.item(account: account))
            return Self.operationResult(status == errSecItemNotFound ? errSecSuccess : status)
        }
    }

    /// Every token stored under the SDK's service for another account than `account` — tokens left by
    /// a configuration no longer in force, to erase and revoke. A Keychain that cannot be read answers
    /// none, so nothing is concluded from it.
    func otherAccounts(
        keeping account: String,
        completion: @escaping ([FastoryStoredRefreshToken]) -> Void
    ) {
        run(completion) { secItem in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
                kSecReturnData as String: true,
            ]
            let (status, result) = secItem.copyMatching(query)
            guard status == errSecSuccess, let items = result as? [[String: Any]] else {
                return []
            }
            return items.compactMap { item in
                guard let stored = item[kSecAttrAccount as String] as? String,
                      stored != account,
                      let data = item[kSecValueData as String] as? Data,
                      let token = String(data: data, encoding: .utf8) else {
                    return nil
                }
                return FastoryStoredRefreshToken(account: stored, token: token)
            }
        }
    }

    private func run<Value>(
        _ completion: @escaping (Value) -> Void,
        _ operation: @escaping (FastorySecItemAPI) -> Value
    ) {
        let secItem = self.secItem
        Self.queue.async {
            let result = operation(secItem)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func read(account: String, from secItem: FastorySecItemAPI) -> FastoryRefreshTokenReadResult {
        var query = item(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = secItem.copyMatching(query)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let token = String(data: data, encoding: .utf8),
                  !token.isEmpty else {
                return .absent
            }
            return .present(token)
        case errSecItemNotFound:
            return .absent
        case errSecInteractionNotAllowed:
            return .locked
        default:
            return .failed(status)
        }
    }

    private static func item(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func operationResult(_ status: OSStatus) -> FastoryRefreshTokenOperationResult {
        switch status {
        case errSecSuccess:
            return .done
        case errSecInteractionNotAllowed:
            return .locked
        default:
            return .failed(status)
        }
    }
}
