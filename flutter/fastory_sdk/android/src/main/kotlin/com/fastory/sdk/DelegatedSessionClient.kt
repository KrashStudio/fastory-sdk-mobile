package com.fastory.sdk

import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

/**
 * The fan session the SDK gets back when it exchanges a host attestation ([FastoryIdentity.HostToken]).
 *
 * [token] is the embed JWT the games read over the bridge and the hub reads through the handoff;
 * [fanId] is the account's `oauthUserId`, stringified — the only identifier the exchange returns that
 * is present on the first sight of a delegated fan and stable across replays of the same subject
 * (SPEC § 2.6.2).
 *
 * [refreshToken] is what renews a `FanId` fan's session from one launch to the next (SPEC § 2.6.3):
 * returned by the login code's exchange and by every renewal. It is null for a `HostToken` session,
 * and for an API that issues none, in which case the session works exactly as before.
 */
internal data class FastoryDelegatedSession(
    val token: String,
    val fanId: String,
    val refreshToken: String? = null,
)

/**
 * The answer to a refresh-token grant: a renewed session carrying its rotated token, or the
 * classified reason it was not renewed.
 */
internal sealed class FastoryRefreshGrantResult {
    data class Renewed(val session: FastoryDelegatedSession) : FastoryRefreshGrantResult()

    data class Failed(val outcome: FastoryRefreshGrantOutcome) : FastoryRefreshGrantResult()
}

/**
 * Maps an identity-exchange outcome to the `identify` error a host branches on (SPEC § 5.4).
 *
 * Pure and table-driven: iOS and Android map the same outcomes the same way, so a `token_malformed`
 * cannot come back `identify_rejected` on one platform and `identify_network_error` on the other.
 * Kept out of the network client so it is assertable without a request.
 */
internal object FastoryIdentityExchangeClassifier {
    data class Outcome(val identifyCode: String, val detailsCode: String?)

    /** A non-2xx answer is a refusal; the API's own `code` reaches the host on `details`, or none. */
    fun classify(httpStatus: Int, apiCode: String?): Outcome =
        Outcome(FastoryIdentifyException.REJECTED, apiCode)

    /**
     * A failure class the request itself hit. `network`/`timeout` reached no verdict — nothing was
     * refused, so it is a network error with no code. `malformed` did arrive but could not be read: a
     * refusal the SDK cannot name.
     */
    fun classifyNetwork(failureClass: String): Outcome = when (failureClass) {
        "network", "timeout" -> Outcome(FastoryIdentifyException.NETWORK_ERROR, null)
        else -> Outcome(FastoryIdentifyException.REJECTED, null)
    }

    fun error(outcome: Outcome): FastoryIdentifyException =
        if (outcome.identifyCode == FastoryIdentifyException.NETWORK_ERROR) {
            FastoryIdentifyException(FastoryIdentifyException.NETWORK_ERROR)
        } else {
            FastoryIdentifyException(FastoryIdentifyException.REJECTED, detailsCode = outcome.detailsCode)
        }

    /**
     * A bootstrap failure met while resolving the workspace the exchange needs. Not a new class of
     * error to the host: an unreachable API is the same network error the exchange reports, and a
     * refused key is a refusal carried on `details.code`.
     */
    fun error(bootstrapCode: String): FastoryIdentifyException = when (bootstrapCode) {
        FastoryLoadFailureClassifier.UNREACHABLE_CODE ->
            FastoryIdentifyException(FastoryIdentifyException.NETWORK_ERROR)
        FastoryLoadFailureClassifier.MALFORMED_RESPONSE_CODE ->
            FastoryIdentifyException(FastoryIdentifyException.REJECTED, detailsCode = null)
        else ->
            FastoryIdentifyException(FastoryIdentifyException.REJECTED, detailsCode = bootstrapCode)
    }
}

/** What the answer to a refresh-token grant means for the fan on the device (SPEC § 2.6.3). */
internal sealed class FastoryRefreshGrantOutcome {
    /**
     * No verdict was reached: the stored token and the identity stay, and the next launch tries
     * again.
     */
    object Transient : FastoryRefreshGrantOutcome()

    data class Refused(
        val reason: FastoryRevocationReason,
        val code: String?,
    ) : FastoryRefreshGrantOutcome()
}

/**
 * Classifies a refresh-token grant that did not succeed. Pure and table-driven, like the exchange
 * classifier above, so a 503 cannot sign a fan out on one platform and keep them on the other. Unlike
 * that classifier, a refusal here is not an `identify` error: it ends a session the host already
 * holds, so it becomes an `identityRevoked` reason.
 */
internal object FastoryRefreshGrantClassifier {
    const val EXPIRED_CODE = "refresh_token_expired"

    /**
     * [httpStatus] is null when no answer arrived. A refusal's reason is read from the API code, not
     * the status, so an expired token is told apart from a rejected one whatever 4xx carries it.
     */
    fun classify(httpStatus: Int?, apiCode: String?): FastoryRefreshGrantOutcome {
        if (httpStatus == null || httpStatus == 429 || httpStatus >= 500) {
            return FastoryRefreshGrantOutcome.Transient
        }
        if (apiCode == EXPIRED_CODE) {
            return FastoryRefreshGrantOutcome.Refused(FastoryRevocationReason.EXPIRED, null)
        }
        return FastoryRefreshGrantOutcome.Refused(FastoryRevocationReason.REJECTED, apiCode)
    }
}

/**
 * Exchanges a host attestation for a fan session, and mints the single-use token the hub needs to
 * adopt it. No browser and no form: the partner already authenticated the fan, so the JWT is
 * forwarded for server-side verification (SPEC § 2.6, § 12) and the SDK never validates it.
 *
 * Modelled on [WorkspaceResolver]: [HttpURLConnection] rather than a new dependency, the same 15 s
 * budget, work on a background executor and every callback posted to the main thread.
 */
internal object DelegatedSessionClient {

    private val handler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()

    /**
     * Revocations only. Best effort and answered by nothing the fan waits on, so a revocation that
     * hangs never delays the grant or the exchange queued behind it.
     */
    private val revokeExecutor = Executors.newSingleThreadExecutor()

    internal data class Request(
        val url: String,
        val headers: Map<String, String>,
        val body: String,
    )

    /** Seam for tests; production performs the real request. Returns (status, body); status < 0 threw. */
    internal var performRequest: (Request) -> Pair<Int, String?> = { httpPost(it) }

    internal fun reset() {
        performRequest = { httpPost(it) }
    }

    /**
     * Exchanges the attestation against [origin] — the origin the returned session is bound to. It is
     * the games' stories origin, because the games are the surface that reads this token over the
     * bridge and the embed session provider re-mints anything whose `aud` is not its own. The hub
     * takes the same session through a server-side handoff instead.
     */
    fun exchange(
        jwt: String,
        workspaceId: String,
        origin: String,
        config: FastoryConfig,
        callback: (Result<FastoryDelegatedSession>) -> Unit,
    ) {
        val body = JSONObject(
            mapOf("workspaceId" to workspaceId, "token" to jwt, "origin" to origin),
        ).toString()
        val request = Request(
            url = config.embedTokenUrl,
            headers = mapOf("Content-Type" to "application/json"),
            body = body,
        )
        executor.execute {
            val (status, responseBody) = safeRequest(request)
            handler.post { callback(session(status, responseBody, keepsRefreshToken = false)) }
        }
    }

    /**
     * Exchanges the system-browser login's single-use code for a fan session (`identify(FanId)`).
     * The caller is proven by the publishable key and the application identifier — the pair the code
     * was minted for — and the PKCE verifier ties the exchange to the app that started the login.
     * The session comes back bound to the games' stories origin, exactly like the attestation
     * exchange above; a code replayed, expired or presented by another caller is refused. It carries
     * the refresh token the API issued beside it, or none.
     */
    fun exchangeLoginCode(
        code: String,
        codeVerifier: String,
        publishableKey: String,
        applicationId: String,
        config: FastoryConfig,
        callback: (Result<FastoryDelegatedSession>) -> Unit,
    ) {
        val body = JSONObject(
            mapOf(
                "grant_type" to "authorization_code",
                "code" to code,
                "code_verifier" to codeVerifier,
                "publishableKey" to publishableKey,
                "applicationId" to applicationId,
            ),
        ).toString()
        val request = Request(
            url = config.embedTokenUrl,
            headers = mapOf("Content-Type" to "application/json"),
            body = body,
        )
        executor.execute {
            val (status, responseBody) = safeRequest(request)
            handler.post { callback(session(status, responseBody, keepsRefreshToken = true)) }
        }
    }

    /**
     * Presents a `FanId` fan's stored refresh token for a new session, with no browser
     * (SPEC § 2.6.3). The token presented is spent: a renewal comes back with its successor, which
     * replaces it.
     *
     * Anything but a renewal is classified by [FastoryRefreshGrantClassifier]. A success whose body
     * cannot be read is classified as no answer at all — something other than the API answered, or
     * the answer was lost — so it never signs the fan out.
     */
    fun refreshGrant(
        refreshToken: String,
        publishableKey: String,
        applicationId: String,
        config: FastoryConfig,
        callback: (FastoryRefreshGrantResult) -> Unit,
    ) {
        val body = JSONObject(
            mapOf(
                "grant_type" to "refresh_token",
                "refresh_token" to refreshToken,
                "publishableKey" to publishableKey,
                "applicationId" to applicationId,
            ),
        ).toString()
        val request = Request(
            url = config.embedTokenUrl,
            headers = mapOf("Content-Type" to "application/json"),
            body = body,
        )
        executor.execute {
            val (status, responseBody) = safeRequest(request)
            handler.post { callback(grantResult(status, responseBody)) }
        }
    }

    /**
     * Asks the API to end the family of a refresh token the SDK is letting go of. Best effort: the
     * answer, whatever it is, changes nothing on the device, so [callback] reports only that the
     * attempt is over.
     */
    fun revoke(
        refreshToken: String,
        config: FastoryConfig,
        callback: () -> Unit = {},
    ) {
        revoke(refreshToken, config.apiBaseUrl, callback)
    }

    fun revoke(
        refreshToken: String,
        apiBaseUrl: String,
        callback: () -> Unit = {},
    ) {
        val request = Request(
            url = FastoryConfig.revokeUrlAt(apiBaseUrl),
            headers = mapOf("Content-Type" to "application/json"),
            body = JSONObject(mapOf("refresh_token" to refreshToken)).toString(),
        )
        revokeExecutor.execute {
            safeRequest(request)
            handler.post { callback() }
        }
    }

    /**
     * Renews the embed session before it expires, without involving the host: the session token is
     * its own credential, and [origin] must be the one it is bound to (the API refuses a mismatch). A
     * new token with a fresh TTL comes back. A non-2xx is a refusal — the caller then falls back to
     * re-exchanging a fresh host assertion through the provider.
     */
    fun refresh(
        sessionToken: String,
        origin: String,
        config: FastoryConfig,
        callback: (Result<String>) -> Unit,
    ) {
        val request = Request(
            url = config.embedRefreshUrl,
            headers = mapOf(
                "Content-Type" to "application/json",
                "Authorization" to "Bearer $sessionToken",
            ),
            body = JSONObject(mapOf("origin" to origin)).toString(),
        )
        executor.execute {
            val (status, responseBody) = safeRequest(request)
            handler.post { callback(refreshed(status, responseBody)) }
        }
    }

    /**
     * The `exp` claim of an embed session token, read locally with no signature check. This is the
     * SDK's *own* token, not the host's assertion: § 12 forbids inspecting the assertion, not reading
     * when our session lapses. Null when the token is not a readable JWT — the caller then treats the
     * session as already due for renewal rather than trusting an unknown lifetime. Epoch milliseconds.
     */
    fun expiryEpochMillis(token: String): Long? {
        val segments = token.split(".")
        if (segments.size < 2) return null
        val payload = try {
            val decoded = android.util.Base64.decode(
                segments[1],
                android.util.Base64.URL_SAFE or android.util.Base64.NO_PADDING or android.util.Base64.NO_WRAP,
            )
            JSONObject(String(decoded))
        } catch (_: Exception) {
            return null
        }
        if (!payload.has("exp")) return null
        val exp = payload.optDouble("exp", Double.NaN)
        if (exp.isNaN()) return null
        return (exp * 1000).toLong()
    }

    private fun refreshed(status: Int, body: String?): Result<String> {
        if (status < 0 || body == null) {
            return Result.failure(
                FastoryIdentityExchangeClassifier.error(
                    FastoryIdentityExchangeClassifier.classifyNetwork("network"),
                ),
            )
        }
        val json = try {
            JSONObject(body)
        } catch (_: Exception) {
            null
        }
        if (status !in 200..299) {
            val apiCode = json?.optString("code")?.ifBlank { null }
            return Result.failure(
                FastoryIdentityExchangeClassifier.error(
                    FastoryIdentityExchangeClassifier.classify(status, apiCode),
                ),
            )
        }
        val token = json?.optString("token")?.ifBlank { null }
            ?: return Result.failure(
                FastoryIdentityExchangeClassifier.error(
                    FastoryIdentityExchangeClassifier.classifyNetwork("malformed"),
                ),
            )
        return Result.success(token)
    }

    /**
     * Mints the single-use handoff token the hub loads with. Authenticated by the embed session
     * itself, so a host that is not identified has nothing to hand off. Failure is not fatal to the
     * caller: the hub falls back to loading anonymously, which is why this answers a nullable token.
     */
    fun mintHandoff(
        sessionToken: String,
        config: FastoryConfig,
        callback: (String?) -> Unit,
    ) {
        val request = Request(
            url = config.embedHandoffUrl,
            headers = mapOf(
                "Content-Type" to "application/json",
                "Authorization" to "Bearer $sessionToken",
            ),
            body = JSONObject(mapOf("surface" to "hub")).toString(),
        )
        executor.execute {
            val (status, responseBody) = safeRequest(request)
            handler.post { callback(handoffToken(status, responseBody)) }
        }
    }

    private fun safeRequest(request: Request): Pair<Int, String?> =
        try {
            performRequest(request)
        } catch (_: Exception) {
            -1 to null
        }

    private fun session(
        status: Int,
        body: String?,
        keepsRefreshToken: Boolean,
    ): Result<FastoryDelegatedSession> {
        if (status < 0 || body == null) {
            return Result.failure(
                FastoryIdentityExchangeClassifier.error(
                    FastoryIdentityExchangeClassifier.classifyNetwork("network"),
                ),
            )
        }
        val json = try {
            JSONObject(body)
        } catch (_: Exception) {
            null
        }
        if (status !in 200..299) {
            val apiCode = json?.optString("code")?.ifBlank { null }
            return Result.failure(
                FastoryIdentityExchangeClassifier.error(
                    FastoryIdentityExchangeClassifier.classify(status, apiCode),
                ),
            )
        }
        val token = json?.optString("token")?.ifBlank { null }
        val fanId = json?.let(::fanId)
        if (token == null || fanId == null) {
            // A 2xx the SDK cannot read is a refusal it cannot name — never a session built on a guess.
            return Result.failure(
                FastoryIdentityExchangeClassifier.error(
                    FastoryIdentityExchangeClassifier.classifyNetwork("malformed"),
                ),
            )
        }
        return Result.success(
            FastoryDelegatedSession(
                token = token,
                fanId = fanId,
                refreshToken = if (keepsRefreshToken) json?.let(::refreshToken) else null,
            ),
        )
    }

    private fun grantResult(status: Int, body: String?): FastoryRefreshGrantResult {
        val noAnswer = FastoryRefreshGrantResult.Failed(
            FastoryRefreshGrantClassifier.classify(httpStatus = null, apiCode = null),
        )
        if (status < 0) return noAnswer
        val json = body?.let {
            try {
                JSONObject(it)
            } catch (_: Exception) {
                null
            }
        }
        if (status !in 200..299) {
            return FastoryRefreshGrantResult.Failed(
                FastoryRefreshGrantClassifier.classify(
                    httpStatus = status,
                    apiCode = json?.optString("code")?.ifBlank { null },
                ),
            )
        }
        val token = json?.optString("token")?.ifBlank { null }
        val fanId = json?.let(::fanId)
        val refreshToken = json?.let(::refreshToken)
        if (token == null || fanId == null || refreshToken == null) return noAnswer
        return FastoryRefreshGrantResult.Renewed(
            FastoryDelegatedSession(token = token, fanId = fanId, refreshToken = refreshToken),
        )
    }

    private fun refreshToken(json: JSONObject): String? {
        if (!json.has("refreshToken") || json.isNull("refreshToken")) return null
        return json.optString("refreshToken").ifBlank { null }
    }

    /** `oauthUserId` is a number in the response and a string on the identity surface. */
    private fun fanId(json: JSONObject): String? {
        if (!json.has("oauthUserId") || json.isNull("oauthUserId")) return null
        return json.optString("oauthUserId").ifBlank { null }
    }

    private fun handoffToken(status: Int, body: String?): String? {
        if (status !in 200..299 || body == null) return null
        val json = try {
            JSONObject(body)
        } catch (_: Exception) {
            return null
        }
        return json.optString("token").ifBlank { null }
    }

    private fun httpPost(request: Request): Pair<Int, String?> {
        val connection = URL(request.url).openConnection() as HttpURLConnection
        return try {
            connection.requestMethod = "POST"
            connection.connectTimeout = WorkspaceResolver.EXCHANGE_TIMEOUT_MS
            connection.readTimeout = WorkspaceResolver.EXCHANGE_TIMEOUT_MS
            for ((name, value) in request.headers) {
                connection.setRequestProperty(name, value)
            }
            connection.doOutput = true
            connection.outputStream.use { it.write(request.body.toByteArray()) }
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            status to stream?.bufferedReader()?.use { it.readText() }
        } finally {
            connection.disconnect()
        }
    }
}
