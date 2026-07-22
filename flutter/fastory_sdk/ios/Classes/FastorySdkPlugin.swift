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
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func configure(_ call: FlutterMethodCall, result: FlutterResult) {
        guard let arguments = call.arguments as? [String: Any],
              let fanzoneSlug = arguments["fanzoneSlug"] as? String,
              !fanzoneSlug.isEmpty else {
            result(FlutterError(code: "invalid_config", message: "fanzoneSlug is required", details: nil))
            return
        }
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
        let config = FastoryConfig(
            environment: environment,
            fanzoneSlug: fanzoneSlug,
            hubTabSlug: arguments["hubTabSlug"] as? String ?? "games-app",
            locale: arguments["locale"] as? String
        )
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
    public func fastoryHubOpened() {
        emit(["type": "hubOpened"])
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

    private func emit(_ event: [String: Any]) {
        eventSink?(event)
    }
}
