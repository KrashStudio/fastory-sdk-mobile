import Flutter
import UIKit

public final class FastorySdkPlugin: NSObject, FlutterPlugin {
    private var eventSink: FlutterEventSink?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = FastorySdkPlugin()
        let methodChannel = FlutterMethodChannel(
            name: "fastory_sdk",
            binaryMessenger: registrar.messenger()
        )
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
        case "close":
            Fastory.close()
            result(nil)
        case "identify":
            identify(call, result: result)
        case "logout":
            Fastory.logout { result(nil) }
        case "setBridgeReply":
            setBridgeReply(call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

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
                result(FlutterError(code: error.code, message: "\(error)", details: nil))
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
            theme: theme
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
