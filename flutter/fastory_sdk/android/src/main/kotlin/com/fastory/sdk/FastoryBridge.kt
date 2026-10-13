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
import java.math.BigInteger
import java.text.Normalizer
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
     * the top-level document, so there is no host page and the native side answers in its place.
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
     * The allow-list, so the web side can ship a new type against an older SDK. The three platforms
     * hold the same set: a type added on one alone would be delivered there and dropped silently on
     * the others.
     */
    val KNOWN_TYPES: Set<String> = setOf("fastory:ready")

    /**
     * The types the native side can be *asked* to answer (SPEC §13.8.3), held on the three
     * platforms alike. Disjoint from [KNOWN_TYPES] on purpose: a request is never delivered to the
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
        val envelope = strictJsonObject(raw)
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
        val envelope = strictJsonObject(raw)
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

    /**
     * The platform's `org.json` reads more than JSON — comments, `=` for `:`, unquoted and
     * single-quoted strings, `01`, `0x1` or `+1` as numbers, text after the document — where iOS's
     * parser reads JSON alone, so the same envelope could be delivered on one platform and ignored
     * on the other (§13.1 forbids exactly that). The text is judged by the grammar first, so the
     * platform parser only sees a document iOS would read too, without the repeated members iOS
     * reads past. Null for a top-level array, a truncated document or plain garbage alike.
     */
    private fun strictJsonObject(raw: String): JSONObject? {
        val text = StrictJsonSyntax.firstMembersOnly(raw) ?: return null
        return runCatching { JSONObject(text) }.getOrNull()
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
 * Recognises JSON text as iOS's parser reads it: RFC 8259, plus the limits that parser adds — a
 * surrogate escaped alone, a number outside the range it reads that number's spelling in, a value
 * nested deeper than [MAX_DEPTH] — and the one leading byte order mark it skips. A name repeated
 * within one object is read at its first occurrence there and at its last by `org.json`, so the
 * text handed on keeps every member but the repeats. Names are compared as Swift compares strings,
 * by canonical equivalence, so `"é"` written precomposed and decomposed is one name repeated.
 * Iterative, and the depth limit keeps the platform parser, which recurses, from ever seeing a deep
 * document.
 */
private object StrictJsonSyntax {

    /** A value is read inside at most this many open containers, as on iOS. */
    const val MAX_DEPTH = 512

    /** The exponent's characters after the `e`, sign included, that iOS reads at most. */
    private const val MAX_EXPONENT_CHARS = 4

    /** Up to this many digits, iOS reads a number that is not a 64-bit integer as a double. */
    private const val MAX_DOUBLE_DIGITS = 17

    /** Past them, as a decimal: a mantissa below 2^128 and a power of ten within this range. */
    private val MAX_DECIMAL_MANTISSA: BigInteger = BigInteger.ONE.shiftLeft(128) - BigInteger.ONE
    private val DECIMAL_EXPONENTS = -128..127

    /** The text without its repeated members, or null when iOS would not read it as JSON. */
    fun firstMembersOnly(text: String): String? {
        val reader = Reader(text)
        return if (reader.document()) reader.withoutRepeats() else null
    }

    private class Container(val isObject: Boolean) {
        /** Decoded and composed, so `"\u0076"` repeats `"v"` and `"e\u0301"` repeats `"é"`, as on iOS. */
        val names = HashSet<String>()

        /** Where the member being read began, comma included, when its name repeats; -1 otherwise. */
        var repeatFrom = -1
    }

    private class Reader(private val text: String) {
        private var pos = 0

        /** One entry per container still open, innermost last. */
        private val open = ArrayDeque<Container>()

        /** Each repeated member, from the comma before it to the delimiter after its value. */
        private val repeats = mutableListOf<IntRange>()

        fun document(): Boolean {
            if (peek() == '\uFEFF') pos++
            skipWhitespace()
            if (!value()) return false
            skipWhitespace()
            return pos == text.length
        }

        /** A repeat nested in a repeat is already gone with its parent, so it is skipped. */
        fun withoutRepeats(): String {
            if (repeats.isEmpty()) return text
            val kept = StringBuilder(text.length)
            var from = 0
            for (span in repeats.sortedBy { it.first }) {
                if (span.first < from) continue
                kept.append(text, from, span.first)
                from = span.last + 1
            }
            return kept.append(text, from, text.length).toString()
        }

        private fun peek(): Char? = if (pos < text.length) text[pos] else null

        private fun skipWhitespace() {
            while (pos < text.length && text[pos] in " \t\n\r") pos++
        }

        /**
         * Reads one value, containers included. A container opens by pushing onto [open] and looping
         * back for its first element; a completed element then closes every container that ends
         * there, or steps to the next element of the innermost one.
         */
        private fun value(): Boolean {
            while (true) {
                if (open.size > MAX_DEPTH) return false
                skipWhitespace()
                when (peek()) {
                    '{' -> {
                        pos++
                        skipWhitespace()
                        if (peek() == '}') {
                            pos++
                        } else {
                            val container = Container(isObject = true)
                            open.addLast(container)
                            if (!memberName(container, pos)) return false
                            continue
                        }
                    }
                    '[' -> {
                        pos++
                        skipWhitespace()
                        if (peek() == ']') {
                            pos++
                        } else {
                            open.addLast(Container(isObject = false))
                            continue
                        }
                    }
                    '"' -> if (!string(null)) return false
                    else -> if (!scalar()) return false
                }
                while (true) {
                    if (open.isEmpty()) return true
                    skipWhitespace()
                    val container = open.last()
                    if (container.repeatFrom >= 0) {
                        repeats += container.repeatFrom until pos
                        container.repeatFrom = -1
                    }
                    when (peek()) {
                        ',' -> {
                            val comma = pos++
                            if (container.isObject && !memberName(container, comma)) return false
                            break
                        }
                        '}' -> if (container.isObject) open.removeLast() else return false
                        ']' -> if (!container.isObject) open.removeLast() else return false
                        else -> return false
                    }
                    pos++
                }
            }
        }

        /** `"name" :` — the half of a member that precedes its value, which begins at [start]. */
        private fun memberName(container: Container, start: Int): Boolean {
            skipWhitespace()
            if (peek() != '"') return false
            val name = StringBuilder()
            if (!string(name)) return false
            val composed = Normalizer.normalize(name, Normalizer.Form.NFC)
            if (!container.names.add(composed)) container.repeatFrom = start
            skipWhitespace()
            if (peek() != ':') return false
            pos++
            return true
        }

        /** Entered on the opening quote; appends the decoded string to [into] when one is given. */
        private fun string(into: StringBuilder?): Boolean {
            pos++
            while (pos < text.length) {
                val c = text[pos++]
                when {
                    c == '"' -> return true
                    c < ' ' -> return false
                    c == '\\' -> if (!escape(into)) return false
                    else -> into?.append(c)
                }
            }
            return false
        }

        /** Entered just past the backslash. */
        private fun escape(into: StringBuilder?): Boolean {
            val c = peek() ?: return false
            pos++
            val decoded = when (c) {
                '"', '\\', '/' -> c
                'b' -> '\b'
                'f' -> '\u000C'
                'n' -> '\n'
                'r' -> '\r'
                't' -> '\t'
                'u' -> return unicode(into)
                else -> return false
            }
            into?.append(decoded)
            return true
        }

        /** Entered just past `\u`: one code unit, or a high surrogate escaped with its low half. */
        private fun unicode(into: StringBuilder?): Boolean {
            val unit = unicodeEscape() ?: return false
            if (unit in LOW_SURROGATES) return false
            if (unit in HIGH_SURROGATES) {
                if (!text.startsWith("\\u", pos)) return false
                pos += 2
                val low = unicodeEscape()
                if (low == null || low !in LOW_SURROGATES) return false
                into?.append(unit.toChar())?.append(low.toChar())
                return true
            }
            into?.append(unit.toChar())
            return true
        }

        /** The code unit the four hex digits after `\u` spell, or null when they are not four. */
        private fun unicodeEscape(): Int? {
            if (pos + 4 > text.length) return null
            var code = 0
            for (c in text.substring(pos, pos + 4)) {
                val digit = when (c) {
                    in '0'..'9' -> c - '0'
                    in 'a'..'f' -> c - 'a' + 10
                    in 'A'..'F' -> c - 'A' + 10
                    else -> return null
                }
                code = code * 16 + digit
            }
            pos += 4
            return code
        }

        private fun scalar(): Boolean = when (peek()) {
            't' -> literal("true")
            'f' -> literal("false")
            'n' -> literal("null")
            else -> number()
        }

        private fun literal(word: String): Boolean {
            if (!text.startsWith(word, pos)) return false
            pos += word.length
            return true
        }

        /**
         * `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?` — no leading zero, no `+`, no hex —
         * then read as iOS reads it: an integer as a 64-bit one when it fits, any other number of up
         * to [MAX_DOUBLE_DIGITS] digits as a double, and the rest as a decimal.
         */
        private fun number(): Boolean {
            val start = pos
            if (peek() == '-') pos++
            val integerStart = pos
            val first = peek() ?: return false
            when {
                first == '0' -> pos++
                first in '1'..'9' -> digits()
                else -> return false
            }
            val integer = text.substring(integerStart, pos)
            var fraction = ""
            if (peek() == '.') {
                pos++
                val fractionStart = pos
                if (!digits()) return false
                fraction = text.substring(fractionStart, pos)
            }
            var exponent: String? = null
            if (peek() == 'e' || peek() == 'E') {
                pos++
                val exponentStart = pos
                if (peek() == '+' || peek() == '-') pos++
                if (!digits()) return false
                exponent = text.substring(exponentStart, pos)
            }
            if (exponent != null && exponent.length > MAX_EXPONENT_CHARS) return false
            val literal = text.substring(start, pos)
            if (fraction.isEmpty() && exponent == null &&
                (literal.toLongOrNull() != null || literal.toULongOrNull() != null)
            ) {
                return true
            }
            // A leading `0` is no digit to iOS here, where every digit after the point is one.
            val digitCount = (if (integer == "0") 0 else integer.length) + fraction.length
            if (digitCount <= MAX_DOUBLE_DIGITS) {
                return literal.toDouble() != Double.POSITIVE_INFINITY
            }
            return fitsDecimal(integer, fraction, exponent?.toInt() ?: 0)
        }

        /**
         * The mantissa takes digits while it stays below 2^128 and stops at the first it cannot
         * take: every integer digit past that point raises the power of ten, every fraction digit
         * before it lowers it — so an integer of 167 digits overflows, as does `0.` followed by 129
         * zeros the other way. The power has to fit both before the exponent is applied and after.
         */
        private fun fitsDecimal(integer: String, fraction: String, exponent: Int): Boolean {
            var mantissa = BigInteger.ZERO
            var power = 0
            var full = false
            for (digit in integer) {
                if (!full) {
                    val next = mantissa * BigInteger.TEN + BigInteger.valueOf((digit - '0').toLong())
                    if (next <= MAX_DECIMAL_MANTISSA) {
                        mantissa = next
                        continue
                    }
                    full = true
                }
                power++
            }
            for (digit in fraction) {
                if (full) break
                val next = mantissa * BigInteger.TEN + BigInteger.valueOf((digit - '0').toLong())
                if (next > MAX_DECIMAL_MANTISSA) break
                mantissa = next
                power--
            }
            return power in DECIMAL_EXPONENTS && power + exponent in DECIMAL_EXPONENTS
        }

        /** Consumes one digit or more. */
        private fun digits(): Boolean {
            val start = pos
            while (peek()?.let { it in '0'..'9' } == true) pos++
            return pos > start
        }
    }

    private val HIGH_SURROGATES = 0xD800..0xDBFF
    private val LOW_SURROGATES = 0xDC00..0xDFFF
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

    // Once, not per message: the JavaBridge thread can deliver in a tight loop. Lazy because the
    // handler can only be bound where a main looper exists.
    private val mainHandler: Handler? by lazy {
        Looper.getMainLooper()?.let { Handler(it) }
    }

    /**
     * `@JavascriptInterface` runs on the JavaBridge thread; the host listener and the Flutter
     * EventChannel both require the main one. Without a main looper the call is made directly.
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
     * Split out from [onPostMessage]: the decision depends on the caller's frame and origin, on the
     * allow-lists and on the standing answers, never on the [WebMessageCompat] or the
     * [JavaScriptReplyProxy] that carried the request, and this is where the whole contract lives.
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
