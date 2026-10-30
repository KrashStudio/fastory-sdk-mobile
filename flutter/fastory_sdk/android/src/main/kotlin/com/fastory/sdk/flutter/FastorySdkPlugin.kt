package com.fastory.sdk.flutter

import android.app.Activity
import android.content.Context
import com.fastory.sdk.Fastory
import com.fastory.sdk.FastoryBridgeRequestType
import com.fastory.sdk.FastoryBridgeResponder
import com.fastory.sdk.FastoryConfig
import com.fastory.sdk.FastoryEnvironment
import com.fastory.sdk.FastoryEventsListener
import com.fastory.sdk.FastoryHostTokenProvider
import com.fastory.sdk.FastoryIdentifyException
import com.fastory.sdk.FastoryIdentity
import com.fastory.sdk.FastoryIdentityMode
import com.fastory.sdk.FastoryIdentityRevocation
import com.fastory.sdk.FastoryLoadFailure
import com.fastory.sdk.FastoryResolvedIdentity
import com.fastory.sdk.FastoryTheme
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class FastorySdkPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var activity: Activity? = null
    private var applicationContext: Context? = null

    private val eventsListener = object : FastoryEventsListener {
        override fun onHubOpened(fanzoneSlug: String) =
            emit(mapOf("type" to "hubOpened", "slug" to fanzoneSlug))
        override fun onHubClosed() = emit(mapOf("type" to "hubClosed"))
        override fun onMembershipOpened() = emit(mapOf("type" to "membershipOpened"))
        override fun onMembershipClosed() = emit(mapOf("type" to "membershipClosed"))
        override fun onGameOpened(slug: String) = emit(mapOf("type" to "gameOpened", "slug" to slug))
        override fun onGameClosed() = emit(mapOf("type" to "gameClosed"))
        override fun onExternalLink(url: String) = emit(mapOf("type" to "externalLink", "url" to url))
        // `bridgeType`, not `type`: the channel's own `type` is the event discriminator (SPEC §13.4).
        override fun onBridgeMessage(type: String, payload: Map<String, Any?>) =
            emit(mapOf("type" to "bridgeMessage", "bridgeType" to type, "payload" to payload))
        override fun onIdentityResolved(identity: FastoryResolvedIdentity) = emit(
            mapOf(
                "type" to "identityResolved",
                "mode" to identity.mode.wireName,
                "fanId" to identity.fanId,
            ),
        )
        override fun onIdentityRevoked(revocation: FastoryIdentityRevocation) = emit(
            mapOf(
                "type" to "identityRevoked",
                "reason" to revocation.reason.wireName,
                "code" to revocation.code,
            ),
        )
        override fun onSurfaceLoadFailed(failure: FastoryLoadFailure) = emit(
            mapOf(
                "type" to "surfaceLoadFailed",
                "surface" to failure.surface.wireName,
                "reason" to failure.reason.wireName,
                "code" to failure.code,
                "statusCode" to failure.statusCode,
            ),
        )
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "fastory_sdk").also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(binding.binaryMessenger, "fastory_sdk/events").also {
            it.setStreamHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        eventSink = null
        applicationContext = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "configure" -> configure(call, result)
            "openGames" -> openGames(result)
            "openMembership" -> openMembership(call, result)
            "close" -> {
                Fastory.close()
                result.success(null)
            }
            "identify" -> identify(call, result)
            "logout" -> Fastory.logout { result.success(null) }
            "setBridgeReply" -> setBridgeReply(call, result)
            "setHostTokenProvider" -> setHostTokenProvider(call, result)
            else -> result.notImplemented()
        }
    }

    /**
     * Registers a native provider that, when the SDK needs a fresh assertion, calls back into Dart
     * over `requestHostToken` and hands the answer to the core. `hasProvider: false` clears it, so the
     * core stops asking and lets an expiring session lapse to anonymous.
     */
    private fun setHostTokenProvider(call: MethodCall, result: MethodChannel.Result) {
        val hasProvider = call.argument<Boolean>("hasProvider") ?: false
        if (!hasProvider) {
            Fastory.setHostTokenProvider(null)
            result.success(null)
            return
        }
        Fastory.setHostTokenProvider(
            FastoryHostTokenProvider { completion ->
                val channel = methodChannel
                if (channel == null) {
                    completion(null)
                    return@FastoryHostTokenProvider
                }
                // Answer once, whichever comes first: Dart's reply or the deadline. A host that never
                // completes its provider must not stall the renewal forever (SPEC § 5.2) — the timeout
                // hands back null, and the core then revokes with `expired`. A non-string answer (null,
                // an error, no handler) is likewise "no token".
                val answered = java.util.concurrent.atomic.AtomicBoolean(false)
                fun answer(token: String?) {
                    if (answered.compareAndSet(false, true)) completion(token)
                }
                channel.invokeMethod(
                    "requestHostToken",
                    null,
                    object : MethodChannel.Result {
                        override fun success(response: Any?) = answer(response as? String)
                        override fun error(code: String, message: String?, details: Any?) = answer(null)
                        override fun notImplemented() = answer(null)
                    },
                )
                android.os.Handler(android.os.Looper.getMainLooper())
                    .postDelayed({ answer(null) }, HOST_TOKEN_REQUEST_TIMEOUT_MS)
            },
        )
        result.success(null)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun configure(call: MethodCall, result: MethodChannel.Result) {
        val environment = when (call.argument<String>("environment")) {
            "staging" -> FastoryEnvironment.STAGING
            "development" -> FastoryEnvironment.DEVELOPMENT
            else -> FastoryEnvironment.PRODUCTION
        }
        val theme = when (call.argument<String>("theme")) {
            "light" -> FastoryTheme.LIGHT
            "dark" -> FastoryTheme.DARK
            else -> null
        }
        val config = try {
            // Exactly one identifier — FastoryConfig's init enforces it. Dart already rejects the
            // bad combinations; this covers a host calling the channel directly.
            FastoryConfig(
                fanzoneSlug = call.argument<String>("fanzoneSlug"),
                environment = environment,
                hubTabSlug = call.argument<String>("hubTabSlug") ?: "games",
                locale = call.argument<String>("locale"),
                developmentBaseUrl = call.argument<String>("developmentBaseUrl"),
                publishableKey = call.argument<String>("publishableKey"),
                theme = theme,
                // Read untyped: a typed `argument<List<String>>` would throw a ClassCastException on
                // anything else a host driving the channel directly might send.
                prewarm = FastoryConfig.prewarmFromChannel(call.argument<Any?>("prewarm")),
                // Untyped for the same reason: a host driving the channel directly may send
                // anything, and only a boolean `true` declares the capability.
                handlesLoginRequests = FastoryConfig.handlesLoginRequestsFromChannel(
                    call.argument<Any?>("handlesLoginRequests"),
                ),
            )
        } catch (error: IllegalArgumentException) {
            result.error("invalid_config", error.message, null)
            return
        }
        val appContext = applicationContext
        if (appContext != null) {
            Fastory.configure(appContext, config, eventsListener)
        } else {
            @Suppress("DEPRECATION")
            Fastory.configure(config, eventsListener)
        }
        result.success(null)
    }

    private fun openMembership(call: MethodCall, result: MethodChannel.Result) {
        // The core traps on both refusals, so the bridge answers before it does: a Dart host gets a
        // code it can branch on, not a debug crash it cannot catch. They stay distinct (SPEC § 5.2),
        // so they are read from the configuration in force rather than from one exception type.
        val config = Fastory.config
        if (config == null) {
            result.error(
                "not_configured",
                "Fastory.configure() must be called before openMembership()",
                null,
            )
            return
        }
        if (config.publishableKey == null) {
            result.error(
                "publishable_key_required",
                "openMembership() needs a publishable key: a fanzone slug names a fanzone, never " +
                    "the workspace this surface is addressed by",
                null,
            )
            return
        }
        val currentActivity = activity
        if (currentActivity == null) {
            result.error("no_activity", "openMembership() requires a foreground activity", null)
            return
        }
        // A typed `argument<String>` would throw a ClassCastException on anything else a host
        // driving the channel directly might send (a number, a bool) — the safe cast reads it as
        // no sequence instead, exactly as iOS's `as? String` already does.
        val sequenceId = call.argument<Any?>("sequenceId") as? String
        Fastory.openMembership(currentActivity, sequenceId)
        result.success(null)
    }

    private fun openGames(result: MethodChannel.Result) {
        val currentActivity = activity
        if (currentActivity == null) {
            result.error("no_activity", "openGames() requires a foreground activity", null)
            return
        }
        try {
            Fastory.openGames(currentActivity)
            result.success(null)
        } catch (error: IllegalStateException) {
            result.error("not_configured", error.message, null)
        }
    }

    private fun setBridgeReply(call: MethodCall, result: MethodChannel.Result) {
        val wireName = call.argument<String>("type")
        // The registry is re-applied here for the same reason as `configure`: a host can drive the
        // channel directly, and a type outside it must not become a reply the SDK serves.
        val type = FastoryBridgeRequestType.entries.firstOrNull { it.value == wireName }
        if (type == null) {
            result.error(
                "invalid_bridge_request_type",
                "unknown bridge request type: $wireName",
                null,
            )
            return
        }
        // Absent or null clears; anything else that is not a map is a host error, never a clear. A
        // typed `argument<Map<…>>` would instead throw a ClassCastException here, where iOS silently
        // cleared — the two channels have to refuse the same input the same way.
        val rawPayload = call.argument<Any>("payload")
        if (rawPayload != null && rawPayload !is Map<*, *>) {
            result.error(INVALID_PAYLOAD, INVALID_PAYLOAD_MESSAGE, null)
            return
        }
        if (!FastoryBridgeResponder.setReply(type, rawPayload as Map<*, *>?)) {
            result.error(INVALID_PAYLOAD, INVALID_PAYLOAD_MESSAGE, null)
            return
        }
        result.success(null)
    }

    private fun identify(call: MethodCall, result: MethodChannel.Result) {
        val wireName = call.argument<String>("mode")
        val mode = FastoryIdentityMode.fromWireName(wireName)
        if (mode == null) {
            result.error(
                FastoryIdentifyException.INVALID_IDENTITY_MODE,
                "unknown identify mode: $wireName",
                null,
            )
            return
        }
        val requested = when (mode) {
            FastoryIdentityMode.ANONYMOUS -> FastoryIdentity.Anonymous
            FastoryIdentityMode.FAN_ID -> FastoryIdentity.FanId
            // A blank jwt is rejected by the core as invalid_host_token, not silently accepted.
            FastoryIdentityMode.HOST_TOKEN ->
                FastoryIdentity.HostToken(call.argument<String>("jwt") ?: "")
        }
        try {
            Fastory.identify(requested) { outcome ->
                outcome.fold(
                    onSuccess = {
                        result.success(mapOf("mode" to it.mode.wireName, "fanId" to it.fanId))
                    },
                    onFailure = { error ->
                        val identifyError = error as? FastoryIdentifyException
                        val code = identifyError?.code ?: FastoryIdentifyException.NETWORK_ERROR
                        // A refused identity carries the API's own code so a host branches on it
                        // without parsing a message; every other identity error has no detail to add.
                        val details = identifyError?.detailsCode?.let { mapOf("code" to it) }
                        result.error(code, error.message, details)
                    },
                )
            }
        } catch (error: IllegalStateException) {
            result.error("not_configured", error.message, null)
        }
    }

    private fun emit(event: Map<String, Any?>) {
        eventSink?.success(event)
    }

    private companion object {
        /** How long the SDK waits for a host's `requestHostToken` answer before treating it as "no token". */
        const val HOST_TOKEN_REQUEST_TIMEOUT_MS = 15_000L
        const val INVALID_PAYLOAD = "invalid_bridge_reply_payload"
        const val INVALID_PAYLOAD_MESSAGE =
            "the bridge reply payload must be a JSON-encodable map, or null to clear it"
    }
}
