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
    private const val TIMEOUT_MS = 15_000

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

    internal fun reset() {
        outcome = null
        isResolving = false
        stateConfig = null
        waiters.clear()
    }

    /**
     * Drops an outcome that belongs to a configuration no longer being asked about. Keeping the
     * stamped one for an equal configuration is **not** what decides whether a new exchange goes
     * out: [resolve] falls through anything but a success, so a cached failure re-arms on an equal
     * `configure` too, on both platforms — that is § 9's escape hatch, and it does not pass through
     * here. What an equal configuration really keeps is a cached *success* (SPEC § 2.1), and the
     * window [whenResolved] opens by reading [outcome] before [isResolving]: the previous failure
     * stays answerable until the new one lands.
     */
    private fun discardOutcomeFromAnotherConfiguration(config: FastoryConfig) {
        val stamped = stateConfig ?: return
        if (stamped != config) reset()
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
            connection.connectTimeout = TIMEOUT_MS
            connection.readTimeout = TIMEOUT_MS
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
