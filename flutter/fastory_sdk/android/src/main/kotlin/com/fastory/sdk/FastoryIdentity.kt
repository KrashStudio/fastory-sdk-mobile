package com.fastory.sdk

import android.net.Uri
import android.webkit.CookieManager
import android.webkit.WebStorage

/**
 * The identity a host asks the SDK to resolve. See `docs/sdk/SPEC.md` § 2.6.
 *
 * [FanId] carries no argument on purpose — it is a Fastory *login* through the system browser, not
 * an identifier the host supplies. [HostToken] is the opposite: the partner already authenticated
 * the fan, so nothing is typed and no browser opens.
 *
 * A sealed class rather than a flag bag, so constructing more than one mode is impossible by
 * construction instead of rejected at runtime.
 */
sealed class FastoryIdentity {
    object Anonymous : FastoryIdentity()

    object FanId : FastoryIdentity()

    data class HostToken(val jwt: String) : FastoryIdentity()

    internal val mode: FastoryIdentityMode
        get() = when (this) {
            is Anonymous -> FastoryIdentityMode.ANONYMOUS
            is FanId -> FastoryIdentityMode.FAN_ID
            is HostToken -> FastoryIdentityMode.HOST_TOKEN
        }
}

/** [wireName] is the string that crosses the platform channel (SPEC § 5.2). */
enum class FastoryIdentityMode(internal val wireName: String) {
    ANONYMOUS("anonymous"),
    FAN_ID("fanId"),
    HOST_TOKEN("hostToken"),
    ;

    internal companion object {
        fun fromWireName(value: String?): FastoryIdentityMode? =
            entries.firstOrNull { it.wireName == value }
    }
}

/**
 * @property fanId always null for [FastoryIdentityMode.ANONYMOUS]: the device visitor is minted per
 * origin by the web page, so the native side never sees it (SPEC § 2.6.2).
 */
data class FastoryResolvedIdentity(
    val mode: FastoryIdentityMode,
    val fanId: String? = null,
) {
    internal companion object {
        val ANONYMOUS = FastoryResolvedIdentity(FastoryIdentityMode.ANONYMOUS, null)
    }
}

/** Every identify failure of SPEC § 5.4, carried as its machine-readable [code]. */
class FastoryIdentifyException(
    val code: String,
    message: String? = null,
) : Exception(message ?: code) {

    internal companion object {
        const val MODE_UNAVAILABLE = "identify_mode_unavailable"
        const val INVALID_IDENTITY_MODE = "invalid_identity_mode"
        const val INVALID_HOST_TOKEN = "invalid_host_token"
        const val LOGIN_CANCELLED = "login_cancelled"
        const val REJECTED = "identify_rejected"
        const val NETWORK_ERROR = "identify_network_error"

        /**
         * A pre-flight rejection is decided before anything is attempted, so it leaves the current
         * identity untouched. A resolution failure happened after the previous session was already
         * erased, so it leaves the SDK anonymous (SPEC § 2.6.1). Conflating the two is how asking
         * for a not-yet-released mode would sign a fan out.
         */
        fun isPreflight(code: String): Boolean = code in setOf(
            MODE_UNAVAILABLE,
            INVALID_IDENTITY_MODE,
            INVALID_HOST_TOKEN,
        )
    }
}

/**
 * The identity-bearing web state an identity transition must erase, and where.
 *
 * The names are declared rather than discovered because they cannot all be discovered:
 * `CookieManager.getCookie(url)` returns only the JS-readable cookies, and the fan session cookie
 * is `httpOnly`. Erasing by name is the only way to reach it — which is also why iOS keeps the same
 * declared list, so the two platforms behave identically.
 *
 * Cross-platform source of truth: `packages/sdk/fixtures/identity-storage-keys.json`.
 * `V1IdentifyContractTest` asserts this list matches it, so a fixture edit that is not propagated
 * here fails the build.
 */
internal object FastoryIdentityStorage {
    val cookieNames: List<String> = listOf(
        "fst-visitor",
        "__Secure-next-auth.session-token-v2",
        "next-auth.session-token",
        "__Secure-next-auth.callback-url-v2",
        "next-auth.pkce.code_verifier-v2",
        "__Host-next-auth.csrf-token",
        "fst-session",
    )

    /**
     * Both surfaces: the hub session lives on the fanzone origin and the game visitor on the
     * stories origin, so erasing one leaves half the fan behind. Development has no known stories
     * origin, exactly as in game-URL construction.
     */
    fun origins(config: FastoryConfig): List<String> =
        listOfNotNull(config.baseUrl.trimEnd('/'), config.environment.storiesOrigin)
}

/**
 * Erases the declared state ([FastoryIdentityStorage]) from the SDK's own origins only.
 *
 * Never call an all-origins API here. `CookieManager` and `WebStorage` are process-global and
 * shared with the host app, so `removeAllCookies()` or `deleteAllData()` would sign the partner out
 * of their own services (SPEC § 7.4).
 *
 * Main thread only: `WebStorage` is bound to it.
 */
internal object FastoryWebsiteDataEraser {

    fun erase(origins: List<String>) {
        val cookies = CookieManager.getInstance()
        val storage = WebStorage.getInstance()
        for (origin in origins) {
            for (name in FastoryIdentityStorage.cookieNames) {
                cookies.setCookie(origin, expiryDirective(name, origin, withDomain = false))
                // A cookie set for `.fanzone.me` is not overwritten by a host-only one, so expire
                // both forms. `__Host-` cookies reject a Domain attribute outright, which is
                // precisely the guarantee that they are host-only and need no second pass.
                if (!name.startsWith("__Host-") && registrableDomain(origin) != null) {
                    cookies.setCookie(origin, expiryDirective(name, origin, withDomain = true))
                }
            }
            storage.deleteOrigin(origin)
        }
        cookies.flush()
    }

    private fun expiryDirective(name: String, origin: String, withDomain: Boolean): String =
        buildString {
            append(name).append("=; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/")
            if (withDomain) {
                registrableDomain(origin)?.let { append("; Domain=").append(it) }
            }
            // `__Secure-` and `__Host-` prefixed cookies are only accepted — and therefore only
            // overwritten — on a secure origin with the Secure attribute set.
            if (origin.startsWith("https://")) append("; Secure")
        }

    private fun registrableDomain(origin: String): String? {
        val host = Uri.parse(origin).host ?: return null
        val labels = host.split('.')
        return if (labels.size >= 2) labels.takeLast(2).joinToString(".") else null
    }
}

/**
 * What `identify` / `logout` must do, decided before anything is touched.
 *
 * Pure by design: every rule of SPEC § 2.6.1 is decidable without a WebView, a cookie store or a
 * network, which is what makes them assertable in a plain JVM test.
 *
 * @property resolved null when the call fails.
 */
internal data class FastoryIdentityTransition(
    val resolved: FastoryResolvedIdentity?,
    val errorCode: String?,
    val erasesStorage: Boolean,
    val emitsIdentityResolved: Boolean,
    /**
     * Whether the standing bridge answers die with this transition (SPEC § 13.8.2). Not derived from
     * [erasesStorage]: a host may set a standing answer without ever calling `identify`, so
     * `logout()` has to revoke even when it has no session to erase.
     */
    val revokesBridgeReplies: Boolean,
) {
    /**
     * A transition that erases also has to drop the warm hub and the preloaded games: both were
     * built before the transition and hold the previous fan's rendered page (SPEC § 7.4).
     */
    val discardsWarmSurfaces: Boolean get() = erasesStorage
}

internal object FastoryIdentityRules {

    fun transition(
        requested: FastoryIdentity,
        current: FastoryResolvedIdentity?,
    ): FastoryIdentityTransition = when {
        requested is FastoryIdentity.HostToken && requested.jwt.isBlank() ->
            rejected(FastoryIdentifyException.INVALID_HOST_TOKEN)

        // A pre-flight rejection, so asking for a mode this version does not implement must not sign
        // the current fan out.
        requested !is FastoryIdentity.Anonymous ->
            rejected(FastoryIdentifyException.MODE_UNAVAILABLE)

        else -> {
            val resolved = FastoryResolvedIdentity.ANONYMOUS
            // Erase only on a real change. Erasing on an already-anonymous call is what would break
            // idempotency: it forces the web to mint a new visitor, so each call would hand back a
            // different fan.
            val changed = current != resolved
            FastoryIdentityTransition(
                resolved = resolved,
                errorCode = null,
                erasesStorage = changed && current != null,
                emitsIdentityResolved = changed,
                // The same difference rule: a new fan must not inherit the previous one's answer,
                // while an idempotent call must leave a standing answer the host just set alone.
                revokesBridgeReplies = changed && current != null,
            )
        }
    }

    fun logout(current: FastoryResolvedIdentity?): FastoryIdentityTransition =
        FastoryIdentityTransition(
            resolved = null,
            errorCode = null,
            erasesStorage = current != null,
            emitsIdentityResolved = false,
            // Unconditional, unlike the erasure: nothing populates the standing answer
            // automatically yet, so today it is only ever there because the host put it there —
            // with no identify() call anywhere in that story. Gating this on `current != null` would
            // make logout() silently keep serving the fan it announces it signed out.
            revokesBridgeReplies = true,
        )

    private fun rejected(code: String): FastoryIdentityTransition =
        FastoryIdentityTransition(
            resolved = null,
            errorCode = code,
            erasesStorage = false,
            emitsIdentityResolved = false,
            // A pre-flight rejection touches nothing (SPEC § 2.6.1), the standing answer included.
            revokesBridgeReplies = false,
        )
}
