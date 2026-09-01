package com.fastory.sdk

import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

/**
 * Exchanges a publishable key for the workspace it belongs to, once per configuration.
 *
 * The fanzone to open is not in the config when the host configures by key — it comes back from
 * `POST /sdk/auth/bootstrap`. [Fastory.configure] starts the exchange and the hub activity waits on
 * it, so the public API stays synchronous and the hub reuses the loading and error views it already
 * has.
 *
 * Uses [HttpURLConnection] rather than adding an HTTP client: the SDK ships inside third-party apps
 * and stays dependency-free on purpose.
 *
 * The short-lived session token the endpoint also returns is deliberately dropped: no authenticated
 * route accepts it yet, and holding a credential nothing consumes only creates a leak surface.
 */
internal object WorkspaceResolver {

    // Spelled exactly as the API declares them in validate_publishable_key.ts.
    private const val KEY_HEADER = "x-fastory-publishable-key"
    private const val APPLICATION_HEADER = "x-fastory-application-id"
    /**
     * How long the exchange waits before it is declared failed. The same number on both native
     * platforms, deliberately: left to each one's own default it was 15 s here and 60 s on iOS, so
     * the same dead network kept the fan waiting four times longer depending on the phone.
     */
    internal const val EXCHANGE_TIMEOUT_MS = 15_000

    internal data class Workspace(val id: String, val slug: String)

    internal sealed interface Outcome {
        data class Success(val workspace: Workspace) : Outcome
        /** [code] is the API's machine-readable failure code, e.g. `sdk_key_revoked`. */
        data class Failure(val code: String) : Outcome
    }

    private val handler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()

    private var outcome: Outcome? = null
    private var isResolving = false

    /**
     * The configuration the current [outcome] or in-flight exchange belongs to. A resolved workspace
     * belongs to the configuration that asked for it: served under another one, its slug builds a hub
     * URL in the wrong environment — the warm hub's defect reached by the resolver's route
     * instead. [Fastory.configure] resets this resolver anyway, but on a later main-looper turn
     * (SPEC § 2.7), and a stamp closes the gap structurally instead of depending on that ordering.
     */
    private var stateConfig: FastoryConfig? = null
    private val waiters = mutableListOf<(Outcome) -> Unit>()

    /** Package name on Android, bundle identifier on iOS: the key only bootstraps for the
     * applications it was created with, so this must match what the workspace declared. */
    internal var applicationId: String? = null

    /** Seam for tests; production performs the real request. */
    internal var performRequest: (String, String, String) -> Pair<Int, String?> =
        { url, key, appId -> httpPost(url, key, appId) }

    /**
     * Drops everything this resolver holds — and **answers** the waiters rather than forgetting
     * them, which is the part that is not housekeeping.
     *
     * A waiter is a surface sitting on its loading state with nothing else to hear back from: a hub
     * whose callback is discarded keeps its progress bar up with its error view hidden, so the fan
     * can neither see what happened nor press Retry again, and the host is told nothing either. The
     * window is real because [Fastory.configure] resets on the caller's schedule, not on the
     * exchange's, and it widened the day Retry started parking a waiter of its own. Reported as
     * unreachable: the exchange never answered, which is what SPEC § 9.1's `network` row describes,
     * and it leaves the surface recoverable.
     *
     * State first, waiters after, so a callback coming back through [whenResolved] finds this
     * resolver already clean rather than half-reset.
     */
    internal fun reset() {
        outcome = null
        isResolving = false
        stateConfig = null
        val abandoned = waiters.toList()
        waiters.clear()
        abandoned.forEach { it(Outcome.Failure(FastoryLoadFailureClassifier.UNREACHABLE_CODE)) }
    }

    /**
     * Drops an outcome that belongs to a configuration no longer being asked about. Keeping the
     * stamped one for an equal configuration is **not** what decides whether a new exchange goes
     * out: [resolve] falls through anything but a success, so a cached failure re-arms on an equal
     * `configure` too, on both platforms. What an equal configuration really keeps is a cached
     * *success* (SPEC § 2.1), and the window [whenResolved] opens by reading [outcome] before
     * [isResolving]: the previous failure stays answerable until the new one lands.
     */
    private fun discardOutcomeFromAnotherConfiguration(config: FastoryConfig) {
        val stamped = stateConfig ?: return
        if (stamped != config) reset()
    }

    /**
     * Re-arms a cached **failure** so the next resolution sends a new request — the fan pressing
     * Retry on the error view, and nothing else (SPEC § 9).
     *
     * The distinction this draws is the whole point. [whenResolved] hands a cached outcome straight
     * back to every ordinary caller, which is what keeps a re-configure that changed nothing from
     * paying for a round trip (SPEC § 2.1); an explicit retry is the one caller asking for the
     * opposite. Only a failure is dropped: a resolved workspace stays resolved, and an exchange
     * already in flight is left to land, so a fan tapping Retry twice still sends one request.
     *
     * **And one refusal is never re-armed**, which is the difference between a button and a loop.
     * `sdk_rate_limited` is the one code § 2.5 forbids presenting as transient, and its sanction
     * escalates on the caller's *address* — shared by everyone behind one CGNAT or one stadium's
     * wifi — until a third one blocks it with no expiry. A refusal answers in milliseconds, so the
     * button is back under the fan's thumb at once: honouring the tap here is precisely how the SDK
     * would become the looping client § 2.5 tells a host not to write. The error view stays and
     * nothing leaves the device.
     */
    internal fun rearmAfterFailure() {
        val failure = outcome as? Outcome.Failure ?: return
        if (failure.code == FastoryLoadFailureClassifier.RATE_LIMITED_CODE) return
        outcome = null
    }

    internal fun resolve(config: FastoryConfig) {
        val key = config.publishableKey ?: return
        discardOutcomeFromAnotherConfiguration(config)
        if (isResolving || outcome is Outcome.Success) return
        // No outcome is recorded when the application id is still unknown: configure() has no
        // Context on the standalone SDK, so the id only arrives with openGames()/preloadHub().
        // Caching a failure here would make every later attempt fail too.
        val appId = applicationId
        if (appId.isNullOrBlank()) return
        isResolving = true
        stateConfig = config
        val url = config.bootstrapUrl
        executor.execute {
            val (status, body) = try {
                performRequest(url, key, appId)
            } catch (_: Exception) {
                -1 to null
            }
            handler.post {
                // The other half of the stamp. Written when the request starts and never read when it
                // lands, the stamp lets a re-configure be overtaken by its own predecessor: this
                // executor is single-threaded, so the exchange for the previous configuration is
                // *ahead* of the current one in the queue, and without this check it records its
                // workspace against the current stamp and hands it to the current configuration's
                // waiters (SPEC § 2.1). A stale exchange is dropped; the live one is right behind it.
                if (stateConfig != config) return@post
                finish(parse(status, body))
            }
        }
    }

    internal fun whenResolved(config: FastoryConfig, callback: (Outcome) -> Unit) {
        discardOutcomeFromAnotherConfiguration(config)
        outcome?.let { callback(it); return }
        waiters += callback
        if (!isResolving) resolve(config)
    }

    private fun parse(status: Int, body: String?): Outcome {
        if (status < 0 || body == null) return Outcome.Failure("sdk_unreachable")
        val json = try {
            JSONObject(body)
        } catch (_: Exception) {
            return Outcome.Failure("sdk_malformed_response")
        }
        if (status !in 200..299) {
            // Every failure carries `code`; fall back to the status so an unexpected shape
            // (a proxy error page, say) still reaches the host as something actionable.
            return Outcome.Failure(json.optString("code").ifBlank { "http_$status" })
        }
        val workspace = json.optJSONObject("workspace")
            ?: return Outcome.Failure("sdk_malformed_response")
        val id = workspace.optString("id")
        val slug = workspace.optString("slug")
        if (id.isBlank() || slug.isBlank()) return Outcome.Failure("sdk_malformed_response")
        return Outcome.Success(Workspace(id = id, slug = slug))
    }

    private fun finish(result: Outcome) {
        outcome = result
        isResolving = false
        val pending = waiters.toList()
        waiters.clear()
        pending.forEach { it(result) }
    }

    private fun httpPost(url: String, key: String, appId: String): Pair<Int, String?> {
        val connection = URL(url).openConnection() as HttpURLConnection
        return try {
            connection.requestMethod = "POST"
            connection.connectTimeout = EXCHANGE_TIMEOUT_MS
            connection.readTimeout = EXCHANGE_TIMEOUT_MS
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty(KEY_HEADER, key)
            connection.setRequestProperty(APPLICATION_HEADER, appId)
            connection.doOutput = true
            connection.outputStream.use { it.write("{}".toByteArray()) }
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            status to stream?.bufferedReader()?.use { it.readText() }
        } finally {
            connection.disconnect()
        }
    }
}
