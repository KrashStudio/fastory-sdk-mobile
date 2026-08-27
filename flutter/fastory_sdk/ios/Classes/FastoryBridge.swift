import Foundation
import os
import WebKit

/// One decoded bridge message: the envelope's `type`, and its `payload` (empty when absent).
struct FastoryBridgeMessage {
    let type: String
    let payload: [String: Any]
}

/// One decoded bridge request: what the page asks about, the id its reply must echo, and the
/// payload it sent along (empty when absent).
struct FastoryBridgeRequest {
    let type: String
    let requestId: String
    let payload: [String: Any]
}

/// What the web content may ask the native side to answer (SPEC §13.8.3).
///
/// An enum rather than a free string: the request registry is the security boundary, so a host
/// cannot name a type outside it — the compiler refuses before anything reaches the page.
public enum FastoryBridgeRequestType: String, CaseIterable, Sendable {
    /// The stories-origin fan token a game asks its host page for. In an SDK WebView the game *is*
    /// the top-level document, so there is no host page and the native side answers in its place
    /// (`docs/SPIKE_SESSION_TRANSFER.md`, leg B).
    case userToken = "fastory:user-token"
}

/// Parser for the versioned bridge envelope `{v, type, payload}` (SPEC §13).
///
/// Fails closed and never throws: the web side ships independently of the app the SDK is embedded
/// in, so anything else would make every web release a client-app risk.
enum BridgeEnvelope {
    /// Bumped only with a coordinated web + SDK release; a mismatch is ignored, never coerced.
    static let version = 1

    /// The allow-list, so the web side can ship a new type against an older SDK. Mirrored on the two
    /// other platforms and pinned by the fixture's `registry` — adding a type here alone fails a test
    /// instead of dropping it silently for the platforms that were missed.
    static let knownTypes: Set<String> = ["fastory:ready"]

    /// The types the native side can be *asked* to answer (SPEC §13.8.3), pinned by the fixture's
    /// `requestRegistry`. Disjoint from `knownTypes` on purpose: a request is never delivered to the
    /// host as an event, and an event type is never answerable — so neither channel can be used to
    /// reach the other's surface.
    static let requestTypes: Set<String> = Set(FastoryBridgeRequestType.allCases.map(\.rawValue))

    /// The reply echoes the id, and the diagnostics log it, so an unbounded one would let the page
    /// choose the size of both. Bounded well above any id a caller has a reason to mint.
    static let maxRequestIdChars = 64

    /// SPEC §13.1: without it, one multi-megabyte post is decoded on the main thread and the cost
    /// lands on the host's UI. UTF-16 code units, which is exactly Kotlin's `String.length` — same
    /// bound on both platforms, and O(1) rather than walking the string we are refusing to read.
    static let maxMessageChars = 65_536

    /// Why a message was dropped. Traced rather than surfaced: a web surface can be at any version,
    /// so "ignored" is a normal outcome, not an error the host should have to handle.
    enum Rejection: String, Error {
        case notAString = "body is not a string, the envelope must be posted as JSON text"
        case notFromMainFrame = "posted from a sub-frame"
        case tooLarge = "over the maximum message size"
        case notJSON = "not json"
        case notAnObject = "not a json object"
        case versionMismatch = "envelope version mismatch"
        case unknownType = "type outside the registry"
        case invalidPayload = "payload is not an object"
    }

    static func parse(
        _ raw: String,
        knownTypes: Set<String> = BridgeEnvelope.knownTypes
    ) -> FastoryBridgeMessage? {
        switch decode(raw, knownTypes: knownTypes) {
        case .success(let message):
            return message
        case .failure(let rejection):
            FastoryBridgeLog.ignored(rejection, in: raw)
            return nil
        }
    }

    static func decode(
        _ raw: String,
        knownTypes: Set<String>
    ) -> Result<FastoryBridgeMessage, Rejection> {
        guard raw.utf16.count <= maxMessageChars else {
            return .failure(.tooLarge)
        }
        guard let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            return .failure(.notJSON)
        }
        guard let envelope = root as? [String: Any] else {
            return .failure(.notAnObject)
        }
        guard isCurrentVersion(envelope["v"]) else {
            return .failure(.versionMismatch)
        }
        guard let type = envelope["type"] as? String, knownTypes.contains(type) else {
            return .failure(.unknownType)
        }

        var payload: [String: Any] = [:]
        if let rawPayload = envelope["payload"], !(rawPayload is NSNull) {
            guard let object = rawPayload as? [String: Any] else {
                return .failure(.invalidPayload)
            }
            payload = unwrapNulls(object)
        }
        return .success(FastoryBridgeMessage(type: type, payload: payload))
    }

    // MARK: - The reply channel (SPEC §13.8)

    /// Why a request could not be answered. The raw values travel to the page as `error.code`, so
    /// they are part of the contract — a web caller branches on them, never on a message.
    enum ReplyError: String {
        /// The envelope broke §13.1: not a string, over the size bound, not JSON, wrong version, no
        /// usable `requestId`, or a payload that is not an object.
        case malformed
        /// Well-formed, but the type is outside the request registry — typically a web surface
        /// asking an SDK older than the type it wants.
        case unsupported
        /// A registry type the native side has no standing answer for: nobody is identified yet.
        case unavailable
    }

    /// A request that cannot be answered, plus the id to correlate the failure with when the page
    /// sent a usable one. That distinction is the difference between "your request failed" and a
    /// reply the page cannot attribute.
    struct RequestRejection: Error {
        let error: ReplyError
        let requestId: String?
    }

    static func decodeRequest(
        _ raw: String,
        requestTypes: Set<String> = BridgeEnvelope.requestTypes
    ) -> Result<FastoryBridgeRequest, RequestRejection> {
        guard raw.utf16.count <= maxMessageChars else {
            return .failure(RequestRejection(error: .malformed, requestId: nil))
        }
        guard let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data),
              let envelope = root as? [String: Any] else {
            return .failure(RequestRejection(error: .malformed, requestId: nil))
        }
        // Read the correlation id before anything can fail, so a rejected request still comes back
        // attributable whenever the page gave us something to attribute it to.
        let requestId = usableRequestId(envelope["requestId"])
        guard isCurrentVersion(envelope["v"]), let requestId else {
            return .failure(RequestRejection(error: .malformed, requestId: requestId))
        }
        guard let type = envelope["type"] as? String, requestTypes.contains(type) else {
            return .failure(RequestRejection(error: .unsupported, requestId: requestId))
        }

        var payload: [String: Any] = [:]
        if let rawPayload = envelope["payload"], !(rawPayload is NSNull) {
            guard let object = rawPayload as? [String: Any] else {
                return .failure(RequestRejection(error: .malformed, requestId: requestId))
            }
            payload = unwrapNulls(object)
        }
        return .success(
            FastoryBridgeRequest(type: type, requestId: requestId, payload: payload)
        )
    }

    private static func usableRequestId(_ raw: Any?) -> String? {
        guard let id = raw as? String,
              id.utf16.count <= maxRequestIdChars,
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return id
    }

    static func reply(payload: [String: Any], type: String, requestId: String) -> String {
        encodeReply([
            "v": version,
            "type": type,
            "requestId": requestId,
            "ok": true,
            "payload": payload,
        ])
    }

    /// `type` is echoed only when it is a registry type — never the arbitrary string the page sent,
    /// which would reflect untrusted text back into the document.
    static func reply(error: ReplyError, type: String? = nil, requestId: String?) -> String {
        var body: [String: Any] = ["v": version, "ok": false, "error": ["code": error.rawValue]]
        if let type {
            body["type"] = type
        }
        if let requestId {
            body["requestId"] = requestId
        }
        return encodeReply(body)
    }

    /// Cannot fail in practice — a payload that does not serialise is refused when it is set, not
    /// when it is asked for — and must not fail at all: WebKit's reply handler has to settle, so a
    /// dropped encoding would hang the page's promise instead of answering it.
    private static func encodeReply(_ body: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"v":1,"ok":false,"error":{"code":"malformed"}}"#
        }
        return text
    }

    /// Strict integer match. `JSONSerialization` erases `true` and `1.0` into `NSNumber` too, and
    /// `org.json` types `1.0` as `Double` and rejects it — accepting it here would split the two
    /// platforms on the same envelope.
    private static func isCurrentVersion(_ raw: Any?) -> Bool {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number as CFNumber) else {
            return false
        }
        return number.intValue == version
    }

    /// `NSNull` reads as a present value to a Swift host where Kotlin gives `null`, and SPEC §13.4
    /// promises both surfaces the same payload — so drop the key, which reads as absent on both.
    ///
    /// Inside an array the languages genuinely diverge (Kotlin's `List<Any?>` holds a null element, a
    /// Swift `[Any]` cannot), so an `NSNull` element passes through. No registry type carries an
    /// array yet; the first one that does needs a decision here.
    private static func unwrapNulls(_ object: [String: Any]) -> [String: Any] {
        object.reduce(into: [String: Any]()) { result, entry in
            switch entry.value {
            case is NSNull:
                return
            case let nested as [String: Any]:
                result[entry.key] = unwrapNulls(nested)
            case let list as [Any]:
                result[entry.key] = unwrapNulls(list)
            default:
                result[entry.key] = entry.value
            }
        }
    }

    private static func unwrapNulls(_ list: [Any]) -> [Any] {
        list.map { element in
            switch element {
            case let nested as [String: Any]:
                return unwrapNulls(nested)
            case let inner as [Any]:
                return unwrapNulls(inner)
            default:
                return element
            }
        }
    }
}

/// Debug level, so an SDK inside a third-party app is silent in production. Read it with
/// `log stream --level debug --predicate 'subsystem == "io.fastory.sdk"'`. See SPEC §13.6.
enum FastoryBridgeLog {
    private static let logger = Logger(subsystem: "io.fastory.sdk", category: "bridge")

    private static let excerptLength = 256

    static func ignored(_ rejection: BridgeEnvelope.Rejection, in raw: String = "") {
        // The reason is ours and public; the message came from a web page, so `.private` redacts it
        // in collected logs. Truncated too, so `tooLarge` cannot hand the logger the megabyte it
        // just refused. Newlines need no flattening: unified logging entries are structured.
        logger.debug("ignored bridge message: \(rejection.rawValue, privacy: .public) — \(excerpt(of: raw), privacy: .private)")
    }

    /// A request answered with a failure. Debug level like every other drop: a web surface can be at
    /// any deploy version, so "I cannot answer that" is a normal outcome, not the host's problem.
    static func requestFailed(_ error: BridgeEnvelope.ReplyError, in raw: String = "") {
        logger.debug("bridge request refused: \(error.rawValue, privacy: .public) — \(excerpt(of: raw), privacy: .private)")
    }

    /// A request that got **no** envelope at all, which happens only for a caller the SDK does not
    /// recognise — the one case where silence is the contract (SPEC §13.8.4).
    static func requestUnrecognised(_ reason: String, origin: String?) {
        logger.debug("bridge request from an unrecognised caller: \(reason, privacy: .public) — \(origin ?? "no origin", privacy: .private)")
    }

    /// The host set a standing reply the SDK will not serve. Traced rather than thrown: the reply is
    /// a hint the native side offers the page, and refusing it leaves the page anonymous, not broken.
    static func standingReplyRefused(_ reason: String) {
        logger.debug("bridge reply refused: \(reason, privacy: .public)")
    }

    private static func excerpt(of raw: String) -> String {
        guard raw.utf16.count > excerptLength else { return raw }
        let head = String(decoding: raw.utf16.prefix(excerptLength), as: UTF16.self)
        return "\(head)… (\(raw.utf16.count) chars)"
    }
}

/// Receiving end of the bridge, shared by every SDK WebView. A singleton on purpose:
/// `WKUserContentController` retains its handlers, so a per-WebView one holding the WebView or its
/// view controller would be a retain cycle on a hub kept alive across sessions.
final class FastoryBridge: NSObject, WKScriptMessageHandler {
    static let shared = FastoryBridge()

    /// The page reaches it at `window.webkit.messageHandlers.fastory` (SPEC §13.2).
    static let handlerName = "fastory"

    private override init() {
        super.init()
    }

    /// No script is injected — WebKit exposes the handler by registration alone, so SPEC §12 holds.
    /// Registers both channels: the receive-only one below, and the reply one of §13.8. They carry
    /// different names, so the 0.4.0 channel keeps its exact shape, registration included.
    static func attach(to configuration: WKWebViewConfiguration) {
        // Adding the same name twice raises an ObjC exception, and the hub WebView is re-attached
        // across sessions — so removing first is what makes attach() safe to call again.
        configuration.userContentController.removeScriptMessageHandler(forName: handlerName)
        configuration.userContentController.add(shared, name: handlerName)
        FastoryBridgeResponder.attach(to: configuration)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // Main frame only: a game may embed third-party iframes, and sub-frame navigations are
        // equally out of URLPolicy's reach (SPEC §4.2), so both boundaries sit at the same place.
        // Traced like every other drop — vanishing on iOS while arriving on Android needs a reason.
        guard message.frameInfo.isMainFrame else {
            FastoryBridgeLog.ignored(.notFromMainFrame)
            return
        }
        route(message.body)
    }

    /// Split out because `WKScriptMessage` cannot be constructed in a test.
    func route(_ body: Any?) {
        guard let raw = body as? String else {
            FastoryBridgeLog.ignored(.notAString)
            return
        }
        guard let message = BridgeEnvelope.parse(raw) else { return }
        Fastory.eventsDelegate?.fastoryBridgeMessage(type: message.type, payload: message.payload)
    }
}

/// Who asked, as each platform is able to report it. `origin` is `nil` when the platform names none —
/// which is refused, never trusted: an unnamed caller is exactly the case §13.8.4 exists for.
struct FastoryBridgeCaller {
    let origin: String?
    let isMainFrame: Bool
}

/// Answering end of the bridge (SPEC §13.8): the web asks, the native side answers.
///
/// Nothing here sends at the SDK's own initiative — a reply exists only because a request arrived,
/// and WebKit hands us the channel to answer on. That is what keeps §12.1 intact with no amendment:
/// pushing a message the page did not ask for would need script evaluation, which that rule forbids
/// until it is amended.
///
/// A singleton for the same reason as `FastoryBridge`: `WKUserContentController` retains its
/// handlers, so a per-WebView one would pin the hub WebView it outlives.
final class FastoryBridgeResponder: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = FastoryBridgeResponder()

    /// The page reaches it at `window.webkit.messageHandlers.fastoryRequest` and awaits the promise
    /// `postMessage` returns (SPEC §13.8.1). Deliberately not `fastory`: one name per direction is
    /// what makes the receive-only channel provably untouched.
    static let handlerName = "fastoryRequest"

    /// Guarded because the setter is host code on any thread while the reads happen on WebKit's.
    private static let lock = NSLock()
    private static var standingReplies: [String: [String: Any]] = [:]

    private override init() {
        super.init()
    }

    /// No script is injected: `addScriptMessageHandler` exposes the entry point by registration
    /// alone, exactly like the receive-only channel, so SPEC §12 holds for this direction too.
    static func attach(to configuration: WKWebViewConfiguration) {
        configuration.userContentController.removeScriptMessageHandler(
            forName: handlerName,
            contentWorld: .page
        )
        configuration.userContentController.addScriptMessageHandler(
            shared,
            contentWorld: .page,
            name: handlerName
        )
    }

    // MARK: - The standing answer

    /// What the native side will answer the next time the page asks for `type`. `nil` clears it, and
    /// a cleared type answers `unavailable` — explicitly, never with silence.
    ///
    /// Returns whether the answer was kept, so the platform channel can report a refusal to the host
    /// that caused it (SPEC §5.4). A refusal leaves the current answer untouched — replacing it with
    /// nothing would sign the fan out on the way to reporting an error.
    @discardableResult
    static func setReply(for type: FastoryBridgeRequestType, payload: [String: Any]?) -> Bool {
        guard let payload else {
            lock.lock()
            standingReplies.removeValue(forKey: type.rawValue)
            lock.unlock()
            return true
        }
        // Refused here rather than at request time: WebKit's reply handler must settle, so an
        // un-encodable payload has to be caught while there is still a host to tell about it.
        guard JSONSerialization.isValidJSONObject(payload) else {
            FastoryBridgeLog.standingReplyRefused("payload is not JSON-serialisable")
            return false
        }
        lock.lock()
        standingReplies[type.rawValue] = payload
        lock.unlock()
        return true
    }

    static func standingReply(for type: FastoryBridgeRequestType) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return standingReplies[type.rawValue]
    }

    private static func snapshot() -> [String: [String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return standingReplies
    }

    /// Drops every standing answer. The invalidation points are normative (SPEC § 13.8.2): the
    /// value is a fan credential, so it dies with the identity that justified it — `logout()`, an
    /// `identify` that resolves a different fan, and a `configure` that replaces the configuration
    /// it was set under. Without them `logout()` keeps answering with the previous fan's token.
    ///
    /// Also the suites' seam, for the same reason it needs to exist at all: a standing answer is
    /// process-wide.
    static func revokeAll() {
        lock.lock()
        standingReplies = [:]
        lock.unlock()
    }

    // MARK: - Answering

    /// `nil` means *refuse without answering* — the only silent outcome on this channel, and only
    /// for a caller the SDK cannot recognise (SPEC §13.8.4). Every other outcome is an envelope,
    /// success or failure, so the page never waits on a reply that is not coming.
    ///
    /// Split out from the WebKit entry point for the same reason as `route`: `WKScriptMessage` cannot
    /// be constructed in a test, and this is where the whole contract lives.
    static func answer(
        to raw: Any?,
        from caller: FastoryBridgeCaller,
        allowedOrigins: [String],
        requestTypes: Set<String> = BridgeEnvelope.requestTypes,
        standing: [String: [String: Any]]? = nil
    ) -> String? {
        // Both gates before anything is parsed: a caller we will not answer costs us no decode.
        guard caller.isMainFrame else {
            FastoryBridgeLog.requestUnrecognised("posted from a sub-frame", origin: caller.origin)
            return nil
        }
        guard let origin = caller.origin, allowedOrigins.contains(origin) else {
            FastoryBridgeLog.requestUnrecognised("origin is not a Fastory surface", origin: caller.origin)
            return nil
        }
        guard let text = raw as? String else {
            FastoryBridgeLog.requestFailed(.malformed)
            return BridgeEnvelope.reply(error: .malformed, requestId: nil)
        }
        switch BridgeEnvelope.decodeRequest(text, requestTypes: requestTypes) {
        case .failure(let rejection):
            FastoryBridgeLog.requestFailed(rejection.error, in: text)
            return BridgeEnvelope.reply(error: rejection.error, requestId: rejection.requestId)
        case .success(let request):
            guard let payload = (standing ?? snapshot())[request.type] else {
                FastoryBridgeLog.requestFailed(.unavailable, in: text)
                return BridgeEnvelope.reply(
                    error: .unavailable,
                    type: request.type,
                    requestId: request.requestId
                )
            }
            return BridgeEnvelope.reply(
                payload: payload,
                type: request.type,
                requestId: request.requestId
            )
        }
    }

    // MARK: - Recognised callers

    /// The origins the SDK answers: the fanzone the hub renders on, and the stories origin its games
    /// come from. Exactly the two surfaces rule 3 of § 4 keeps in a WebView — every other origin has
    /// already left for the system browser, so a request from one is not a Fastory surface asking.
    ///
    /// Unconfigured means no recognised origin at all, so no request is answered. Fail closed.
    static func allowedOrigins(for config: FastoryConfig?) -> [String] {
        guard let config else { return [] }
        return [config.environment.baseURL, config.environment.storiesOrigin]
            .compactMap { $0 }
            .compactMap(origin(of:))
    }

    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return nil
        }
        return format(scheme: scheme, host: host, port: url.port)
    }

    /// WebKit reports the frame's own origin, so this is the one gate that distinguishes a game's
    /// third-party iframe from the game itself.
    static func origin(of securityOrigin: WKSecurityOrigin) -> String? {
        let scheme = securityOrigin.`protocol`.lowercased()
        let host = securityOrigin.host.lowercased()
        guard !scheme.isEmpty, !host.isEmpty else { return nil }
        // 0 is WebKit's "the scheme's default", which is also how a base URL with no explicit port
        // reads — so both sides normalise to the same string.
        return format(scheme: scheme, host: host, port: securityOrigin.port == 0 ? nil : securityOrigin.port)
    }

    private static func format(scheme: String, host: String, port: Int?) -> String {
        guard let port, port != defaultPort(for: scheme) else {
            return "\(scheme)://\(host)"
        }
        return "\(scheme)://\(host):\(port)"
    }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }

    // MARK: - WKScriptMessageHandlerWithReply

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        let caller = FastoryBridgeCaller(
            origin: Self.origin(of: message.frameInfo.securityOrigin),
            isMainFrame: message.frameInfo.isMainFrame
        )
        guard let reply = Self.answer(
            to: message.body,
            from: caller,
            allowedOrigins: Self.allowedOrigins(for: Fastory.config)
        ) else {
            // WebKit requires the handler to settle exactly once or the page's promise never
            // resolves — so an unrecognised caller gets a rejection, which carries no envelope and
            // therefore no answer. That is the shape §13.8.4 asks for: refused, not answered.
            replyHandler(nil, "fastory: request refused")
            return
        }
        replyHandler(reply, nil)
    }
}
