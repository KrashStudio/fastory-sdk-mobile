package com.fastory.sdk

import android.app.Activity
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import net.openid.appauth.AuthorizationException
import net.openid.appauth.AuthorizationRequest
import net.openid.appauth.AuthorizationResponse
import net.openid.appauth.AuthorizationService
import net.openid.appauth.AuthorizationServiceConfiguration
import net.openid.appauth.ResponseTypeValues

/**
 * What the system-browser leg of `identify(FanId)` needs to start: where to send the fan, which
 * publishable key is asking, and where the browser must hand control back. The token endpoint is
 * carried for the OpenID service configuration even though the SDK performs the code exchange with
 * its own client — the exchange proves the caller with the publishable key and the application
 * identifier, which a generic token request does not carry.
 */
internal data class FanLoginRequest(
    val authorizationEndpoint: String,
    val tokenEndpoint: String,
    val clientId: String,
    val redirectUri: String,
)

/**
 * The browser leg's successful outcome: the single-use authorization code and the PKCE verifier
 * that must accompany it on the exchange. The code alone is worthless by design.
 */
internal data class FanLoginSuccess(val code: String, val codeVerifier: String)

/** A dismissal is a decision, not a failure — [cancelled] tells the two apart (§ 5.4). */
internal class FanLoginException(val cancelled: Boolean) : Exception()

/**
 * Drives the system-browser login through AppAuth, the platform's reference OpenID client: a Custom
 * Tab under the hood, with the state parameter and PKCE generated and validated by the library
 * rather than by hand (§ 2.6). No credential ever transits a WebView.
 */
internal object FanLoginClient {

    /**
     * Builds the login request for a configuration. Pure, so the contract — which endpoint, which
     * client id, which redirect shape — is assertable without a browser.
     */
    fun request(config: FastoryConfig, applicationId: String): FanLoginRequest = FanLoginRequest(
        authorizationEndpoint = "${config.baseUrl.trimEnd('/')}/auth/sdk/authorize",
        tokenEndpoint = config.embedTokenUrl,
        clientId = requireNotNull(config.publishableKey),
        redirectUri = "$applicationId://fastory/callback",
    )

    private val handler = Handler(Looper.getMainLooper())

    /**
     * How long [FanLoginActivity] has to reach `onCreate`. A Custom Tab launches near-instantly when
     * it launches at all; the one reason `onCreate` never runs is a background start refused since
     * Android 10 — logged, and thrown by nothing, so a `catch` cannot see it. Left unguarded, `pending`
     * would hang forever and a non-blocking method would never complete. `openGames` guards the same
     * trap the same way. The window is generous: once the activity is alive it stands the watchdog
     * down, so a fan taking minutes at the login form is never cut off.
     */
    private const val ACTIVITY_START_TIMEOUT_MS = 5_000L

    /** Seam for tests; production launches the login activity below. */
    internal var performLogin: (FanLoginRequest, (Result<FanLoginSuccess>) -> Unit) -> Unit =
        { request, callback -> liveLogin(request, callback) }

    internal fun reset() {
        performLogin = { request, callback -> liveLogin(request, callback) }
        clearWatchdog()
        pending = null
    }

    /**
     * The completion of the login in flight. One at a time, deliberately: a second
     * `identify(FanId)` while the browser is open supersedes the first, which is answered as
     * cancelled rather than left dangling.
     */
    private var pending: ((Result<FanLoginSuccess>) -> Unit)? = null

    /** The armed background-start watchdog, kept so [FanLoginActivity] can stand it down. */
    private var watchdog: Runnable? = null

    private fun liveLogin(request: FanLoginRequest, callback: (Result<FanLoginSuccess>) -> Unit) {
        val context = FastoryAppContext.application
        if (context == null) {
            callback(Result.failure(FanLoginException(cancelled = false)))
            return
        }
        pending?.invoke(Result.failure(FanLoginException(cancelled = true)))
        clearWatchdog()
        pending = callback
        val intent = Intent(context, FanLoginActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(FanLoginActivity.EXTRA_AUTHORIZATION_ENDPOINT, request.authorizationEndpoint)
            .putExtra(FanLoginActivity.EXTRA_TOKEN_ENDPOINT, request.tokenEndpoint)
            .putExtra(FanLoginActivity.EXTRA_CLIENT_ID, request.clientId)
            .putExtra(FanLoginActivity.EXTRA_REDIRECT_URI, request.redirectUri)
        context.startActivity(intent)
        // startActivity from the application context is not a promise (see ACTIVITY_START_TIMEOUT_MS):
        // arm the watchdog now, and let onCreate cancel it once the launch actually took.
        val armed = Runnable {
            watchdog = null
            complete(Result.failure(FanLoginException(cancelled = false)))
        }
        watchdog = armed
        handler.postDelayed(armed, ACTIVITY_START_TIMEOUT_MS)
    }

    /** [FanLoginActivity] reached `onCreate`: the launch was not refused, so stand the watchdog down. */
    internal fun markActivityLaunched() {
        clearWatchdog()
    }

    /** Called by [FanLoginActivity] with the browser leg's outcome. */
    internal fun complete(result: Result<FanLoginSuccess>) {
        clearWatchdog()
        val callback = pending ?: return
        pending = null
        callback(result)
    }

    /**
     * Answers an in-flight login as cancelled. `logout()` calls it so a sign-out wins over a login
     * still in the browser: without it, a login that completes after the logout would re-identify the
     * fan the host just signed out.
     */
    internal fun cancelPending() {
        clearWatchdog()
        val callback = pending ?: return
        pending = null
        callback(Result.failure(FanLoginException(cancelled = true)))
    }

    private fun clearWatchdog() {
        watchdog?.let { handler.removeCallbacks(it) }
        watchdog = null
    }
}

/**
 * The application context, captured at process start by [FastoryInitProvider] and refreshed by the
 * entry points that receive one. `identify`'s signature carries no `Context` on purpose — it is
 * callable from anywhere (§ 2.7) — so the browser leg has to find the application's own.
 */
internal object FastoryAppContext {
    @Volatile
    internal var application: Context? = null
}

/**
 * Captures the application context before any SDK call runs. A `ContentProvider` declared in the
 * manifest is created at process start, which is the one hook a library gets without asking the
 * host to call anything.
 */
internal class FastoryInitProvider : ContentProvider() {
    override fun onCreate(): Boolean {
        FastoryAppContext.application = context?.applicationContext
        return true
    }

    override fun query(
        uri: Uri,
        projection: Array<String>?,
        selection: String?,
        selectionArgs: Array<String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<String>?,
    ): Int = 0
}

/**
 * The invisible activity that hosts the AppAuth round trip: it hands the fan to the Custom Tab and
 * receives the redirect's outcome, then reports to [FanLoginClient] and leaves. Recreated by the
 * system, it does not restart the flow — the in-flight browser session owns it.
 */
internal class FanLoginActivity : Activity() {

    private var service: AuthorizationService? = null
    private var request: AuthorizationRequest? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The launch was not refused by the platform — stand the client's background-start watchdog
        // down before the fan starts typing, or a slow login would trip it.
        FanLoginClient.markActivityLaunched()
        val serialized = savedInstanceState?.getString(STATE_REQUEST)
        if (serialized != null) {
            request = runCatching { AuthorizationRequest.jsonDeserialize(serialized) }.getOrNull()
            return
        }
        val authorizationEndpoint = intent.getStringExtra(EXTRA_AUTHORIZATION_ENDPOINT)
        val tokenEndpoint = intent.getStringExtra(EXTRA_TOKEN_ENDPOINT)
        val clientId = intent.getStringExtra(EXTRA_CLIENT_ID)
        val redirectUri = intent.getStringExtra(EXTRA_REDIRECT_URI)
        if (authorizationEndpoint == null || tokenEndpoint == null ||
            clientId == null || redirectUri == null
        ) {
            FanLoginClient.complete(Result.failure(FanLoginException(cancelled = false)))
            finish()
            return
        }
        val configuration = AuthorizationServiceConfiguration(
            Uri.parse(authorizationEndpoint),
            Uri.parse(tokenEndpoint),
        )
        // The builder generates the state and the S256 PKCE pair — the parts one never writes by
        // hand. AppAuth validates the returned state before handing the response back.
        val authorizationRequest = AuthorizationRequest.Builder(
            configuration,
            clientId,
            ResponseTypeValues.CODE,
            Uri.parse(redirectUri),
        ).build()
        request = authorizationRequest
        val authorizationService = AuthorizationService(this)
        service = authorizationService
        startActivityForResult(
            authorizationService.getAuthorizationRequestIntent(authorizationRequest),
            REQUEST_CODE,
        )
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        request?.let { outState.putString(STATE_REQUEST, it.jsonSerializeString()) }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_CODE) return
        val response = data?.let { AuthorizationResponse.fromIntent(it) }
        val exception = data?.let { AuthorizationException.fromIntent(it) }
        val code = response?.authorizationCode
        val verifier = request?.codeVerifier
        val outcome = when {
            code != null && verifier != null ->
                Result.success(FanLoginSuccess(code, verifier))
            isCancellation(exception, data) ->
                Result.failure(FanLoginException(cancelled = true))
            else ->
                Result.failure(FanLoginException(cancelled = false))
        }
        FanLoginClient.complete(outcome)
        finish()
    }

    override fun onDestroy() {
        service?.dispose()
        service = null
        super.onDestroy()
    }

    /**
     * A closed Custom Tab comes back as a plain cancelled result with no data; an explicit user
     * cancellation carries AppAuth's own code. Both are the fan's decision.
     */
    private fun isCancellation(exception: AuthorizationException?, data: Intent?): Boolean {
        if (data == null) return true
        return exception?.code == AuthorizationException.GeneralErrors.USER_CANCELED_AUTH_FLOW.code
    }

    internal companion object {
        internal const val EXTRA_AUTHORIZATION_ENDPOINT = "com.fastory.sdk.fanlogin.authorization"
        internal const val EXTRA_TOKEN_ENDPOINT = "com.fastory.sdk.fanlogin.token"
        internal const val EXTRA_CLIENT_ID = "com.fastory.sdk.fanlogin.client"
        internal const val EXTRA_REDIRECT_URI = "com.fastory.sdk.fanlogin.redirect"
        internal const val STATE_REQUEST = "com.fastory.sdk.fanlogin.request"
        private const val REQUEST_CODE = 24001
    }
}
