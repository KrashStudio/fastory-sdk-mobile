package com.fastory.sdk.flutter

import android.app.Activity
import android.content.Context
import com.fastory.sdk.Fastory
import com.fastory.sdk.FastoryConfig
import com.fastory.sdk.FastoryEnvironment
import com.fastory.sdk.FastoryEventsListener
import com.fastory.sdk.FastoryTheme
import com.fastory.sdk.WorkspaceResolver
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
        override fun onGameOpened(slug: String) = emit(mapOf("type" to "gameOpened", "slug" to slug))
        override fun onGameClosed() = emit(mapOf("type" to "gameClosed"))
        override fun onExternalLink(url: String) = emit(mapOf("type" to "externalLink", "url" to url))
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
            "close" -> {
                Fastory.close()
                result.success(null)
            }
            else -> result.notImplemented()
        }
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
                workspaceId = call.argument<String>("workspaceId"),
                theme = theme,
            )
        } catch (error: IllegalArgumentException) {
            result.error("invalid_config", error.message, null)
            return
        }
        // The key only bootstraps for the applications it was created with, so the resolver needs
        // the host's package name before configure() kicks the exchange off.
        WorkspaceResolver.applicationId = applicationContext?.packageName
        Fastory.configure(config, eventsListener)
        applicationContext?.let(Fastory::preloadHub)
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

    private fun emit(event: Map<String, Any?>) {
        eventSink?.success(event)
    }
}
