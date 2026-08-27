package com.fastory.sdk

import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.webkit.JavascriptInterface
import android.webkit.WebView
import androidx.webkit.JavaScriptReplyProxy
import androidx.webkit.WebMessageCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import java.util.concurrent.ConcurrentHashMap
import org.json.JSONArray
import org.json.JSONObject

/** Internal like its iOS counterpart: SPEC §2.3 declares no such type on the public surface. */
internal data class FastoryBridgeMessage(val type: String, val payload: Map<String, Any?>)

/**
 * One decoded bridge request: what the page asks about, the id its reply must echo, and the payload
 * it sent along (empty when absent).
 */
internal data class FastoryBridgeRequest(
    val type: String,
    val requestId: String,
    val payload: Map<String, Any?>,
)

/**
 * Who asked, as each platform is able to report it. `origin` is null when the platform names none —
 * which is refused, never trusted: an unnamed caller is exactly the case SPEC §13.8.4 exists for.
 */
internal data class FastoryBridgeCaller(val origin: String?, val isMainFrame: Boolean)

/**
 * What the web content may ask the native side to answer (SPEC §13.8.3).
 *
 * An enum rather than a free string: the request registry is the security boundary, so a host cannot
 * name a type outside it — the compiler refuses before anything reaches the page.
 */
enum class FastoryBridgeRequestType(internal val value: String) {
    /**
     * The stories-origin fan token a game asks its host page for. In an SDK WebView the game *is*
     * the top-level document, so there is no host page and the native side answers in its place
     * (`docs/SPIKE_SESSION_TRANSFER.md`, leg B).
     */
    USER_TOKEN("fastory:user-token"),
}

/**
 * Parser for the versioned bridge envelope `{v, type, payload}` (SPEC §13).
 *
 * Fails closed and never throws: the web side ships independently of the app the SDK is embedded in,
 * so anything else would make every web release a client-app risk.
 */
internal object BridgeEnvelope {

    /** Bumped only with a coordinated web + SDK release; a mismatch is ignored, never coerced. */
    const val VERSION = 1

    /**
     * The allow-list, so the web side can ship a new type against an older SDK. Mirrored on the two
     * other platforms and pinned by the fixture's `registry` — adding a type here alone fails a test
     * instead of dropping it silently for the platforms that were missed.
     */
    val KNOWN_TYPES: Set<String> = setOf("fastory:ready")

    /**
     * The types the native side can be *asked* to answer (SPEC §13.8.3), pinned by the fixture's
     * `requestRegistry`. Disjoint from [KNOWN_TYPES] on purpose: a request is never delivered to the
     * host as an event, and an event type is never answerable — so neither channel can be used to
     * reach the other's surface.
     */
    val REQUEST_TYPES: Set<String> = FastoryBridgeRequestType.entries.map { it.value }.toSet()

    /**
     * The reply echoes the id, and the diagnostics log it, so an unbounded one would let the page
     * choose the size of both. Bounded well above any id a caller has a reason to mint.
     */
    const val MAX_REQUEST_ID_CHARS = 64

    /**
     * SPEC §13.1. `addJavascriptInterface` is reachable from every frame, third-party iframes in a
     * game included, so an unbounded parse would be an unbounded cost granted to any of them.
     */
    const val MAX_MESSAGE_CHARS = 65_536

    private const val LOG_TAG = "FastorySDK"

    /** Keeps a forged newline in a web-supplied message from forging a whole log line. */
    private const val TRACE_EXCERPT_LENGTH = 256

    /** Traced, not surfaced: a web surface can be at any version, so a drop is a normal outcome. */
    private enum class Rejection(val reason: String) {
        TOO_LARGE("over the maximum message size"),
        NOT_JSON("not json, or not a json object"),
        VERSION_MISMATCH("envelope version mismatch"),
        UNKNOWN_TYPE("type outside the registry"),
        INVALID_PAYLOAD("payload is not an object"),
    }

    fun parse(raw: String?, knownTypes: Set<String> = KNOWN_TYPES): FastoryBridgeMessage? {
        if (raw == null) {
            trace(Rejection.NOT_JSON, raw)
            return null
        }
        if (raw.length > MAX_MESSAGE_CHARS) {
            trace(Rejection.TOO_LARGE, null)
            return null
        }
        // A top-level array, a truncated document or plain garbage all land here as a JSONException.
        val envelope = runCatching { JSONObject(raw) }.getOrNull()
        if (envelope == null) {
            trace(Rejection.NOT_JSON, raw)
            return null
        }

        // opt(), never optInt(): optInt coerces "1" to 1. Int or Long only — org.json returns
        // whichever fits, and neither a Boolean nor a Double may pass for 1 (iOS agrees, §13.1).
        val version = envelope.opt("v")
        val isCurrentVersion = (version is Int || version is Long) &&
            (version as Number).toLong() == VERSION.toLong()
        if (!isCurrentVersion) {
            trace(Rejection.VERSION_MISMATCH, raw)
            return null
        }

        val type = envelope.opt("type")
        if (type !is String || type !in knownTypes) {
            trace(Rejection.UNKNOWN_TYPE, raw)
            return null
        }

        val payload: Map<String, Any?> = when (val rawPayload = envelope.opt("payload")) {
            null, JSONObject.NULL -> emptyMap()
            is JSONObject -> rawPayload.toPlainMap()
            else -> {
                trace(Rejection.INVALID_PAYLOAD, raw)
                return null
            }
        }
        return FastoryBridgeMessage(type = type, payload = payload)
    }

    /** Off unless enabled: `adb shell setprop log.tag.FastorySDK DEBUG`. See SPEC §13.6. */
    private fun trace(rejection: Rejection, raw: String?) {
        if (!Log.isLoggable(LOG_TAG, Log.DEBUG)) return
        Log.d(LOG_TAG, "ignored bridge message: ${rejection.reason} — ${excerpt(raw)}")
    }

    /**
     * A request answered with a failure. Debug level like every other drop: a web surface can be at
     * any deploy version, so "I cannot answer that" is a normal outcome, not the host's problem.
     */
    internal fun traceRequestFailed(error: ReplyError, raw: String?) {
        if (!Log.isLoggable(LOG_TAG, Log.DEBUG)) return
        Log.d(LOG_TAG, "bridge request refused: ${error.code} — ${excerpt(raw)}")
    }

    /**
     * A request that got **no** envelope at all, which happens only for a caller the SDK does not
     * recognise — the one case where silence is the contract (SPEC §13.8.4).
     */
    internal fun traceUnrecognisedCaller(reason: String, origin: String?) {
        if (!Log.isLoggable(LOG_TAG, Log.DEBUG)) return
        Log.d(LOG_TAG, "bridge request from an unrecognised caller: $reason — ${excerpt(origin)}")
    }

    /** Reasons the reply channel could not be offered on a WebView, or a standing reply not kept. */
    internal fun traceReplyChannel(reason: String) {
        if (!Log.isLoggable(LOG_TAG, Log.DEBUG)) return
        Log.d(LOG_TAG, "bridge reply channel: $reason")
    }

    /** A web-supplied newline would otherwise forge a whole logcat entry under this tag. */
    private fun excerpt(raw: String?): String {
        if (raw == null) return "null"
        val flattened = raw.replace(Regex("[\\r\\n]"), "\\\\n")
        return if (flattened.length <= TRACE_EXCERPT_LENGTH) {
            flattened
        } else {
            flattened.take(TRACE_EXCERPT_LENGTH) + "… (${raw.length} chars)"
        }
    }

    // region The reply channel (SPEC §13.8)

    /**
     * Why a request could not be answered. The [code] values travel to the page as `error.code`, so
     * they are part of the contract — a web caller branches on them, never on a message.
     */
    enum class ReplyError(val code: String) {
        /**
         * The envelope broke §13.1: not a string, over the size bound, not JSON, wrong version, no
         * usable `requestId`, or a payload that is not an object.
         */
        MALFORMED("malformed"),

        /**
         * Well-formed, but the type is outside the request registry — typically a web surface asking
         * an SDK older than the type it wants.
         */
        UNSUPPORTED("unsupported"),

        /** A registry type the native side has no standing answer for: nobody is identified yet. */
        UNAVAILABLE("unavailable"),
    }

    /**
     * A decoded request, or the reason it cannot be answered — plus the id to correlate that failure
     * with when the page sent a usable one. That distinction is the difference between "your request
     * failed" and a reply the page cannot attribute.
     */
    internal sealed interface RequestDecoding {
        data class Decoded(val request: FastoryBridgeRequest) : RequestDecoding

        data class Refused(val error: ReplyError, val requestId: String?) : RequestDecoding
    }

    internal fun decodeRequest(
        raw: String?,
        requestTypes: Set<String> = REQUEST_TYPES,
    ): RequestDecoding {
        if (raw == null || raw.length > MAX_MESSAGE_CHARS) {
            return RequestDecoding.Refused(ReplyError.MALFORMED, null)
        }
        // A top-level array, a truncated document or plain garbage all land here as a JSONException.
        val envelope = runCatching { JSONObject(raw) }.getOrNull()
            ?: return RequestDecoding.Refused(ReplyError.MALFORMED, null)

        // Read the correlation id before anything can fail, so a rejected request still comes back
        // attributable whenever the page gave us something to attribute it to.
        val requestId = usableRequestId(envelope.opt("requestId"))

        // opt(), never optInt(): the same strict integer match as the receive-only channel (§13.1).
        val version = envelope.opt("v")
        val isCurrentVersion = (version is Int || version is Long) &&
            (version as Number).toLong() == VERSION.toLong()
        if (!isCurrentVersion || requestId == null) {
            return RequestDecoding.Refused(ReplyError.MALFORMED, requestId)
        }

        val type = envelope.opt("type")
        if (type !is String || type !in requestTypes) {
            return RequestDecoding.Refused(ReplyError.UNSUPPORTED, requestId)
        }

        val payload: Map<String, Any?> = when (val rawPayload = envelope.opt("payload")) {
            null, JSONObject.NULL -> emptyMap()
            is JSONObject -> rawPayload.toPlainMap()
            else -> return RequestDecoding.Refused(ReplyError.MALFORMED, requestId)
        }
        return RequestDecoding.Decoded(
            FastoryBridgeRequest(type = type, requestId = requestId, payload = payload),
        )
    }

    private fun usableRequestId(raw: Any?): String? {
        if (raw !is String || raw.length > MAX_REQUEST_ID_CHARS || raw.isBlank()) return null
        return raw
    }

    internal fun reply(payload: JSONObject, type: String, requestId: String): String = encodeReply(
        JSONObject()
            .put("v", VERSION)
            .put("type", type)
            .put("requestId", requestId)
            .put("ok", true)
            .put("payload", payload),
    )

    /**
     * [type] is echoed only when it is a registry type — never the arbitrary string the page sent,
     * which would reflect untrusted text back into the document.
     */
    internal fun reply(error: ReplyError, type: String? = null, requestId: String? = null): String {
        val body = JSONObject()
            .put("v", VERSION)
            .put("ok", false)
            .put("error", JSONObject().put("code", error.code))
        if (type != null) body.put("type", type)
        if (requestId != null) body.put("requestId", requestId)
        return encodeReply(body)
    }

    /**
     * Cannot fail in practice — a payload that does not convert is refused when it is set, not when
     * it is asked for — and must not fail at all: a request that produced no reply would leave the
     * page waiting instead of answering it.
     */
    private fun encodeReply(body: JSONObject): String =
        runCatching { body.toString() }
            .getOrDefault("""{"v":1,"ok":false,"error":{"code":"malformed"}}""")

    /** Null means "no JSON encoding" — unambiguous, because a JSON null encodes as [JSONObject.NULL]. */
    private fun toJsonValue(value: Any?): Any? = when (value) {
        null -> JSONObject.NULL
        is String, is Boolean, is Int, is Long, is Short, is Byte -> value
        // NaN and the infinities have no JSON literal, and org.json throws on them.
        is Double -> value.takeIf { it.isFinite() }
        is Float -> value.takeIf { it.isFinite() }
        is Map<*, *> -> toJsonObject(value)
        is Iterable<*> -> toJsonArray(value)
        else -> null
    }

    /**
     * Converts a host-supplied standing reply into the org.json tree the answer path serialises.
     * Returns null when a value has no JSON encoding, so it is refused while there is still a host to
     * tell about it rather than at request time, when the page is already waiting.
     */
    internal fun toJsonObject(map: Map<*, *>): JSONObject? {
        val json = JSONObject()
        for ((key, value) in map) {
            if (key !is String) return null
            json.put(key, toJsonValue(value) ?: return null)
        }
        return json
    }

    private fun toJsonArray(values: Iterable<*>): JSONArray? {
        val array = JSONArray()
        for (element in values) {
            array.put(toJsonValue(element) ?: return null)
        }
        return array
    }

    // endregion

    /** org.json's containers have no encoding in the Flutter codec, so unwrap them all the way. */
    private fun JSONObject.toPlainMap(): Map<String, Any?> =
        keys().asSequence().associateWith { unwrap(opt(it)) }

    private fun JSONArray.toPlainList(): List<Any?> = (0 until length()).map { unwrap(opt(it)) }

    private fun unwrap(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> value.toPlainMap()
        is JSONArray -> value.toPlainList()
        else -> value
    }
}

/**
 * Receiving end of the bridge, shared by every SDK WebView. A singleton on purpose: a WebView holds
 * its interfaces for life and the hub WebView outlives its Activity, so anything holding one leaks.
 */
object FastoryBridge {

    /** The page reaches it at `window.fastory` (SPEC §13.2). */
    const val NAME = "fastory"

    /**
     * No script is injected — binding alone exposes the object, so SPEC §12 still holds. Re-binding
     * the same name replaces it, which is what makes this safe on a WebView reused across sessions.
     *
     * Attaches both channels: the receive-only one below, and the reply one of §13.8. They carry
     * different names, so the 0.4.0 channel keeps its exact shape, binding included.
     */
    internal fun attach(webView: WebView) {
        webView.addJavascriptInterface(this, NAME)
        FastoryBridgeResponder.attach(webView, Fastory.config)
    }

    /**
     * Public where iOS is internal, and it has to be: the WebView finds this by reflection, and
     * Kotlin mangles an `internal` member's JVM name (`postMessage$module`). A host calling it gains
     * nothing it could not already do by invoking its own listener.
     */
    @JavascriptInterface
    fun postMessage(raw: String?) {
        val message = BridgeEnvelope.parse(raw) ?: return
        onMainThread { Fastory.notifyBridgeMessage(message.type, message.payload) }
    }

    // Once, not per message: the JavaBridge thread can deliver in a tight loop. Lazy because plain
    // JUnit has no main looper to bind to.
    private val mainHandler: Handler? by lazy {
        Looper.getMainLooper()?.let { Handler(it) }
    }

    /**
     * `@JavascriptInterface` runs on the JavaBridge thread; the host listener and the Flutter
     * EventChannel both require the main one. No looper (plain JUnit) means a direct call.
     */
    private inline fun onMainThread(crossinline block: () -> Unit) {
        val handler = mainHandler
        if (handler == null || Looper.myLooper() == handler.looper) {
            block()
        } else {
            handler.post { block() }
        }
    }
}

/**
 * Answering end of the bridge (SPEC §13.8): the web asks, the native side answers.
 *
 * Nothing here sends at the SDK's own initiative — the platform enforces it, since a
 * [JavaScriptReplyProxy] only exists once a page has posted. That is what keeps SPEC §12.1 intact with
 * no amendment: pushing a message the page did not ask for would need script evaluation, which that
 * rule forbids until it is amended.
 *
 * A singleton for the same reason as [FastoryBridge]: a WebView holds its listeners for life and the
 * hub WebView outlives its Activity, so anything holding one leaks.
 */
internal object FastoryBridgeResponder : WebViewCompat.WebMessageListener {

    /**
     * The page reaches it at `window.fastoryRequest` — `postMessage(json)` to ask, `onmessage` to
     * receive (SPEC §13.8.1). Deliberately not `fastory`: one name per direction is what makes the
     * receive-only channel provably untouched.
     */
    const val NAME = "fastoryRequest"

    /** Guarded because the setter is host code on any thread while the reads happen on the UI one. */
    private val standingReplies = ConcurrentHashMap<String, JSONObject>()

    /**
     * `addWebMessageListener` is the only Android entry point that reports **which frame** posted and
     * from **which origin**, and it injects the object into matching frames only — so the allow-list
     * is enforced by WebView itself, not merely checked by us afterwards. `addJavascriptInterface`,
     * which the receive-only channel uses, reports neither (§13.7's known asymmetry), and a reply
     * carries a fan credential: handing one to an arbitrary iframe inside a game is not a bounded
     * risk the way receiving a message from it is.
     *
     * No script is injected here either: the object is installed by the WebView provider, exactly as
     * `addJavascriptInterface` does, so SPEC §12 holds for this direction too.
     *
     * A WebView too old for the feature simply has no reply channel, and the page's feature detection
     * (§13.8.1) leaves the fan anonymous rather than broken.
     */
    internal fun attach(webView: WebView, config: FastoryConfig?) {
        val origins = allowedOrigins(config)
        if (origins.isEmpty()) {
            BridgeEnvelope.traceReplyChannel("not attached: no configured Fastory origin")
            return
        }
        val supported = runCatching {
            WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)
        }.getOrDefault(false)
        if (!supported) {
            BridgeEnvelope.traceReplyChannel("not attached: WebView too old for WEB_MESSAGE_LISTENER")
            return
        }
        // Adding the same name twice is not documented as safe, and the hub WebView is reused across
        // sessions — so removing first is what makes attach() repeatable.
        runCatching { WebViewCompat.removeWebMessageListener(webView, NAME) }
        runCatching {
            WebViewCompat.addWebMessageListener(webView, NAME, origins.toSet(), this)
        }.onFailure { error ->
            BridgeEnvelope.traceReplyChannel("not attached: ${error.javaClass.simpleName}")
        }
    }

    // region The standing answer

    /**
     * What the native side will answer the next time the page asks for [type]. Null clears it, and a
     * cleared type answers `unavailable` — explicitly, never with silence.
     *
     * Returns whether the answer was kept, so the platform channel can report a refusal to the host
     * that caused it (SPEC §5.4). A refusal leaves the current answer untouched — replacing it with
     * nothing would sign the fan out on the way to reporting an error.
     */
    internal fun setReply(type: FastoryBridgeRequestType, payload: Map<*, *>?): Boolean {
        if (payload == null) {
            standingReplies.remove(type.value)
            return true
        }
        // Converted and refused here rather than at request time: an un-encodable payload has to be
        // caught while there is still a host to tell about it, not while the page is waiting.
        val encoded = BridgeEnvelope.toJsonObject(payload)
        if (encoded == null) {
            BridgeEnvelope.traceReplyChannel("standing reply refused: payload is not JSON-encodable")
            return false
        }
        standingReplies[type.value] = encoded
        return true
    }

    internal fun standingReply(type: FastoryBridgeRequestType): JSONObject? =
        standingReplies[type.value]

    /**
     * Drops every standing answer. The invalidation points are normative (SPEC § 13.8.2): the value
     * is a fan credential, so it dies with the identity that justified it — `logout()`, an
     * `identify` that resolves a different fan, and a `configure` that replaces the configuration it
     * was set under. Without them `logout()` keeps answering with the previous fan's token.
     *
     * Also the suites' seam, for the same reason it needs to exist at all: a standing answer is
     * process-wide.
     */
    internal fun revokeAll() {
        standingReplies.clear()
    }

    // endregion

    // region Answering

    /**
     * Null means *refuse without answering* — the only silent outcome on this channel, and only for a
     * caller the SDK cannot recognise (SPEC §13.8.4). Every other outcome is an envelope, success or
     * failure, so the page never waits on a reply that is not coming.
     *
     * Split out from [onPostMessage] because a [WebMessageCompat] and a [JavaScriptReplyProxy] cannot
     * be constructed in a test, and this is where the whole contract lives.
     */
    internal fun answer(
        raw: String?,
        caller: FastoryBridgeCaller,
        allowedOrigins: List<String>,
        requestTypes: Set<String> = BridgeEnvelope.REQUEST_TYPES,
        standing: Map<String, JSONObject> = standingReplies,
    ): String? {
        // Both gates before anything is parsed: a caller we will not answer costs us no decode.
        if (!caller.isMainFrame) {
            BridgeEnvelope.traceUnrecognisedCaller("posted from a sub-frame", caller.origin)
            return null
        }
        val origin = caller.origin
        if (origin == null || origin !in allowedOrigins) {
            BridgeEnvelope.traceUnrecognisedCaller("origin is not a Fastory surface", caller.origin)
            return null
        }
        return when (val decoding = BridgeEnvelope.decodeRequest(raw, requestTypes)) {
            is BridgeEnvelope.RequestDecoding.Refused -> {
                BridgeEnvelope.traceRequestFailed(decoding.error, raw)
                BridgeEnvelope.reply(error = decoding.error, requestId = decoding.requestId)
            }
            is BridgeEnvelope.RequestDecoding.Decoded -> {
                val request = decoding.request
                val payload = standing[request.type]
                if (payload == null) {
                    BridgeEnvelope.traceRequestFailed(BridgeEnvelope.ReplyError.UNAVAILABLE, raw)
                    BridgeEnvelope.reply(
                        error = BridgeEnvelope.ReplyError.UNAVAILABLE,
                        type = request.type,
                        requestId = request.requestId,
                    )
                } else {
                    BridgeEnvelope.reply(
                        payload = payload,
                        type = request.type,
                        requestId = request.requestId,
                    )
                }
            }
        }
    }

    // endregion

    // region Recognised callers

    /**
     * The origins the SDK answers: the fanzone the hub renders on, and the stories origin its games
     * come from. Exactly the two surfaces rule 3 of §4 keeps in a WebView — every other origin has
     * already left for the system browser, so a request from one is not a Fastory surface asking.
     *
     * Unconfigured means no recognised origin at all, so no request is answered. Fail closed.
     */
    internal fun allowedOrigins(config: FastoryConfig?): List<String> {
        if (config == null) return emptyList()
        return listOfNotNull(config.baseUrl, config.environment.storiesOrigin).mapNotNull(::originOf)
    }

    /**
     * `java.net.URI` rather than `android.net.Uri`: this runs in plain JUnit too, where the android.jar
     * stubs would hand back a default instead of parsing.
     */
    internal fun originOf(url: String?): String? {
        if (url.isNullOrBlank()) return null
        val uri = runCatching { java.net.URI(url.trim()) }.getOrNull() ?: return null
        val scheme = uri.scheme?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
        val host = uri.host?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
        // -1 is "absent", which is also how a base URL with no explicit port reads — so both sides
        // normalise to the same string.
        val port = uri.port
        return if (port == -1 || port == defaultPort(scheme)) {
            "$scheme://$host"
        } else {
            "$scheme://$host:$port"
        }
    }

    private fun defaultPort(scheme: String): Int? = when (scheme) {
        "http" -> 80
        "https" -> 443
        else -> null
    }

    // endregion

    override fun onPostMessage(
        view: WebView,
        message: WebMessageCompat,
        sourceOrigin: Uri,
        isMainFrame: Boolean,
        replyProxy: JavaScriptReplyProxy,
    ) {
        // getData() throws when the page posted an ArrayBuffer; null then reads as malformed, which
        // is answered rather than dropped.
        val raw = if (message.type == WebMessageCompat.TYPE_STRING) {
            runCatching { message.data }.getOrNull()
        } else {
            null
        }
        val caller = FastoryBridgeCaller(originOf(sourceOrigin.toString()), isMainFrame)
        val reply = answer(raw, caller, allowedOrigins(Fastory.config)) ?: return
        // Already on the UI thread: onPostMessage is @UiThread, and so is postMessage. Traced on
        // failure because §13.6 forbids a silent drop, and a reply lost on the way out is exactly the
        // case a device pass must be able to tell apart from a caller we refused to answer.
        runCatching { replyProxy.postMessage(reply) }.onFailure { error ->
            BridgeEnvelope.traceReplyChannel("reply not delivered: ${error.javaClass.simpleName}")
        }
    }
}
