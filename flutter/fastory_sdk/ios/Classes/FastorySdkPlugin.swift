import Flutter
import UIKit

public final class FastorySdkPlugin: NSObject, FlutterPlugin {
    private var eventSink: FlutterEventSink?
    /// Kept so the SDK can call *back* into Dart (`requestHostToken`) when a delegated session needs
    /// renewing — the one method that travels native → Dart.
    private var methodChannel: FlutterMethodChannel?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = FastorySdkPlugin()
        let methodChannel = FlutterMethodChannel(
            name: "fastory_sdk",
            binaryMessenger: registrar.messenger()
        )
        instance.methodChannel = methodChannel
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        let eventChannel = FlutterEventChannel(
            name: "fastory_sdk/events",
            binaryMessenger: registrar.messenger()
        )
        eventChannel.setStreamHandler(instance)
        Fastory.eventsDelegate = instance
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "configure":
            configure(call, result: result)
        case "openGames":
            openGames(result: result)
        case "openMembership":
            openMembership(call, result: result)
        case "close":
            Fastory.close()
            result(nil)
        case "identify":
            identify(call, result: result)
        case "logout":
            Fastory.logout { result(nil) }
        case "setBridgeReply":
            setBridgeReply(call, result: result)
        case "setHostTokenProvider":
            setHostTokenProvider(call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Registers a native provider that, when the SDK needs a fresh assertion, calls back into Dart
    /// over `requestHostToken` and hands the answer to the core. `hasProvider: false` clears it, so
    /// the core stops asking and lets an expiring session lapse to anonymous.
    private func setHostTokenProvider(_ call: FlutterMethodCall, result: FlutterResult) {
        let arguments = call.arguments as? [String: Any] ?? [:]
        let hasProvider = arguments["hasProvider"] as? Bool ?? false
        guard hasProvider else {
            Fastory.setHostTokenProvider(nil)
            result(nil)
            return
        }
        Fastory.setHostTokenProvider { [weak self] completion in
            // native → Dart, on the main thread the channel requires. A non-string answer (null, a
            // Flutter error, no handler) is "no token" — the core then revokes with `expired`.
            DispatchQueue.main.async {
                guard let self, let channel = self.methodChannel else {
                    completion(nil)
                    return
                }
                // Answer once, whichever comes first: Dart's reply or the deadline. A host that
                // never completes its provider must not stall the renewal forever (SPEC § 5.2) — the
                // timeout hands back `nil`, and the core then revokes with `expired`.
                var answered = false
                let answer: (String?) -> Void = { token in
                    guard !answered else { return }
                    answered = true
                    completion(token)
                }
                channel.invokeMethod("requestHostToken", arguments: nil) { response in
                    answer(response as? String)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.hostTokenRequestTimeout) {
                    answer(nil)
                }
            }
        }
        result(nil)
    }

    /// How long the SDK waits for a host's `requestHostToken` answer before treating it as "no token".
    private static let hostTokenRequestTimeout: TimeInterval = 15

    private func setBridgeReply(_ call: FlutterMethodCall, result: FlutterResult) {
        let arguments = call.arguments as? [String: Any] ?? [:]
        let wireName = arguments["type"] as? String
        // The registry is re-applied here for the same reason as `configure`: a host can drive the
        // channel directly, and a type outside it must not become a reply the SDK serves.
        guard let type = wireName.flatMap(FastoryBridgeRequestType.init(rawValue:)) else {
            result(FlutterError(
                code: "invalid_bridge_request_type",
                message: "unknown bridge request type: \(wireName ?? "nil")",
                details: nil
            ))
            return
        }
        // Absent or null clears; anything else that is not an object is a host error, never a clear.
        // `as? [String: Any]` alone would map a string or a number to nil and sign the fan out.
        let rawPayload = arguments["payload"]
        var payload: [String: Any]?
        if let rawPayload, !(rawPayload is NSNull) {
            guard let object = rawPayload as? [String: Any] else {
                result(Self.invalidPayload)
                return
            }
            payload = object
        }
        guard FastoryBridgeResponder.setReply(for: type, payload: payload) else {
            result(Self.invalidPayload)
            return
        }
        result(nil)
    }

    private static var invalidPayload: FlutterError {
        FlutterError(
            code: "invalid_bridge_reply_payload",
            message: "the bridge reply payload must be a JSON-serialisable object, or null to clear it",
            details: nil
        )
    }

    private func identify(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as? [String: Any] ?? [:]
        let wireName = arguments["mode"] as? String
        guard let mode = wireName.flatMap(FastoryIdentityMode.init(rawValue:)) else {
            result(FlutterError(
                code: "invalid_identity_mode",
                message: "unknown identify mode: \(wireName ?? "nil")",
                details: nil
            ))
            return
        }
        let requested: FastoryIdentity
        switch mode {
        case .anonymous:
            requested = .anonymous
        case .fanId:
            requested = .fanId
        case .hostToken:
            // A blank jwt is rejected by the core as invalid_host_token, not silently accepted.
            requested = .hostToken(jwt: arguments["jwt"] as? String ?? "")
        }
        Fastory.identify(requested) { outcome in
            switch outcome {
            case .success(let identity):
                let resolved: [String: Any] = [
                    "mode": identity.mode.rawValue,
                    "fanId": identity.fanId ?? NSNull(),
                ]
                result(resolved)
            case .failure(let error):
                // A refused identity carries the API's own code so a host branches on it without
                // parsing a message; every other identity error has no detail to add.
                var details: [String: Any]?
                if case .rejected(let code) = error, let code {
                    details = ["code": code]
                }
                result(FlutterError(code: error.code, message: "\(error)", details: details))
            }
        }
    }

    private func configure(_ call: FlutterMethodCall, result: FlutterResult) {
        guard let arguments = call.arguments as? [String: Any] else {
            result(FlutterError(code: "invalid_config", message: "arguments are required", details: nil))
            return
        }
        // Exactly one identifier, enforced by FastoryConfig.validate() below — Dart already
        // rejects the bad combinations, this covers a host calling the channel directly.
        let publishableKey = arguments["publishableKey"] as? String
        let fanzoneSlug = arguments["fanzoneSlug"] as? String
        let environment: FastoryEnvironment
        switch arguments["environment"] as? String {
        case "staging":
            environment = .staging
        case "development":
            guard let developmentBaseUrl = arguments["developmentBaseUrl"] as? String,
                  let baseURL = URL(string: developmentBaseUrl) else {
                result(FlutterError(
                    code: "invalid_config",
                    message: "developmentBaseUrl is required when environment is development",
                    details: nil
                ))
                return
            }
            environment = .development(baseURL: baseURL)
        default:
            environment = .production
        }
        let hubTabSlug = arguments["hubTabSlug"] as? String ?? "games"
        let theme: FastoryTheme? = (arguments["theme"] as? String).flatMap(FastoryTheme.init(rawValue:))
        let config = FastoryConfig(
            environment: environment,
            publishableKey: publishableKey,
            fanzoneSlug: fanzoneSlug,
            hubTabSlug: hubTabSlug,
            locale: arguments["locale"] as? String,
            theme: theme,
            prewarm: FastoryConfig.prewarm(fromChannel: arguments["prewarm"]),
            handlesLoginRequests: FastoryConfig.handlesLoginRequests(
                fromChannel: arguments["handlesLoginRequests"]
            )
        )
        do {
            try config.validate()
        } catch {
            result(FlutterError(code: "invalid_config", message: "\(error)", details: nil))
            return
        }
        Fastory.configure(config)
        result(nil)
    }

    private func openGames(result: FlutterResult) {
        guard Fastory.config != nil else {
            result(FlutterError(
                code: "not_configured",
                message: "Fastory.configure() must be called before openGames()",
                details: nil
            ))
            return
        }
        guard let presenter = Self.topViewController() else {
            result(FlutterError(
                code: "no_view_controller",
                message: "openGames() requires a visible view controller",
                details: nil
            ))
            return
        }
        Fastory.openGames(from: presenter)
        result(nil)
    }

    private func openMembership(_ call: FlutterMethodCall, result: FlutterResult) {
        guard let config = Fastory.config else {
            result(FlutterError(
                code: "not_configured",
                message: "Fastory.configure() must be called before openMembership()",
                details: nil
            ))
            return
        }
        // The core traps on this one, so the bridge has to answer before it does: a Dart host
        // gets a code it can branch on, not a debug crash it cannot catch.
        guard config.publishableKey != nil else {
            result(FlutterError(
                code: "publishable_key_required",
                message: "openMembership() needs a publishable key: a fanzone slug names a "
                    + "fanzone, never the workspace this surface is addressed by",
                details: nil
            ))
            return
        }
        guard let presenter = Self.topViewController() else {
            result(FlutterError(
                code: "no_view_controller",
                message: "openMembership() requires a visible view controller",
                details: nil
            ))
            return
        }
        let arguments = call.arguments as? [String: Any] ?? [:]
        // `as? String` reads anything else a host driving the channel directly might send (a
        // number, a bool) as no sequence, matching Android's own safe cast for the same argument.
        Fastory.openMembership(from: presenter, sequenceId: arguments["sequenceId"] as? String)
        result(nil)
    }

    private static func topViewController() -> UIViewController? {
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

extension FastorySdkPlugin: FlutterStreamHandler {
    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}

extension FastorySdkPlugin: FastoryEventsDelegate {
    public func fastoryHubOpened(fanzoneSlug: String) {
        emit(["type": "hubOpened", "slug": fanzoneSlug])
    }

    public func fastoryHubClosed() {
        emit(["type": "hubClosed"])
    }

    public func fastoryMembershipOpened() {
        emit(["type": "membershipOpened"])
    }

    public func fastoryMembershipClosed() {
        emit(["type": "membershipClosed"])
    }

    public func fastoryGameOpened(slug: String) {
        emit(["type": "gameOpened", "slug": slug])
    }

    public func fastoryGameClosed() {
        emit(["type": "gameClosed"])
    }

    public func fastoryExternalLink(url: URL) {
        emit(["type": "externalLink", "url": url.absoluteString])
    }

    public func fastoryBridgeMessage(type: String, payload: [String: Any]) {
        // `bridgeType`, not `type`: the channel's own `type` is the event discriminator (SPEC §13.4).
        emit(["type": "bridgeMessage", "bridgeType": type, "payload": payload])
    }

    public func fastoryIdentityResolved(_ identity: FastoryResolvedIdentity) {
        emit([
            "type": "identityResolved",
            "mode": identity.mode.rawValue,
            "fanId": identity.fanId ?? NSNull(),
        ])
    }

    public func fastoryIdentityRevoked(_ revocation: FastoryIdentityRevocation) {
        emit([
            "type": "identityRevoked",
            "reason": revocation.reason.rawValue,
            "code": revocation.code ?? NSNull(),
        ])
    }

    public func fastorySurfaceLoadFailed(_ failure: FastoryLoadFailure) {
        emit([
            "type": "surfaceLoadFailed",
            "surface": failure.surface.rawValue,
            "reason": failure.reason.rawValue,
            "code": failure.code ?? NSNull(),
            "statusCode": failure.statusCode ?? NSNull(),
        ])
    }

    private func emit(_ event: [String: Any]) {
        eventSink?(event)
    }
}
