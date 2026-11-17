package com.fastory.sdk

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONObject
import java.net.URI
import java.net.URISyntaxException

/**
 * The last verified delegated identity, kept across launches so a returning fan is shown at once
 * instead of re-verified before anything renders (SPEC § 2.6.3).
 *
 * The identity is its `mode` and `fanId`: an opaque account id, not a credential. Neither the host's
 * token nor the embed session is ever stored. A `FanId` fan's refresh token is the one credential the
 * SDK keeps, encrypted in the app's no-backup files rather than here (SPEC § 7.5), under the same
 * stamp: [pairing] decides at launch what the two found side by side mean, and they are erased
 * together. The panel shows the fan immediately from this; the games' session is re-established in
 * the background.
 *
 * Stamped with the workspace and environment it was resolved under. A `configure` that resolves a
 * different pair ignores this and purges it, so one club's fan can never surface in another's app.
 *
 * The store is a [SharedPreferences] handed in as soon as the SDK knows the application's [Context]:
 * at process start, or from the first call that passes one. Until then persistence is a no-op — a
 * fan is simply re-verified, which is the same outcome as a first-ever launch.
 */
internal object FastoryIdentityPersistence {
    private const val PREFS_NAME = "com.fastory.sdk.identity"
    private const val KEY_ENTRY = "delegated-identity"

    /** Set from the first application [Context] the SDK sees. */
    var prefs: SharedPreferences? = null

    fun attach(context: Context) {
        if (prefs == null) {
            prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        }
    }

    /**
     * The base URL carries the environment, the publishable key the workspace. It is also the
     * account the refresh token issued under that configuration is stored for.
     */
    fun stamp(config: FastoryConfig): String =
        "${config.baseUrl.trimEnd('/')}|${config.publishableKey ?: ""}"

    fun apiBaseUrlOfStamp(stamp: String): String? {
        val baseUrl = stamp.substringBefore('|', missingDelimiterValue = "")
        val uri = try {
            URI(baseUrl)
        } catch (_: URISyntaxException) {
            return null
        }
        val scheme = uri.scheme?.lowercase()
        if ((scheme != "https" && scheme != "http") || uri.host.isNullOrEmpty()) return null
        return FastoryEnvironment.entries.firstOrNull { it.defaultBaseUrl == baseUrl }?.defaultApiBaseUrl ?: baseUrl
    }

    fun save(identity: FastoryResolvedIdentity, config: FastoryConfig) {
        val fanId = identity.fanId ?: return
        val store = prefs ?: return
        val entry = JSONObject(
            mapOf(
                "mode" to identity.mode.wireName,
                "fanId" to fanId,
                "stamp" to stamp(config),
            ),
        )
        store.edit().putString(KEY_ENTRY, entry.toString()).apply()
    }

    /**
     * The persisted identity **iff** it was stamped under this configuration. A stamp mismatch purges
     * it: a fan stored for another workspace or environment must never be shown here.
     */
    fun load(config: FastoryConfig): FastoryResolvedIdentity? {
        val store = prefs ?: return null
        val raw = store.getString(KEY_ENTRY, null) ?: return null
        val entry = try {
            JSONObject(raw)
        } catch (_: Exception) {
            purge()
            return null
        }
        val mode = FastoryIdentityMode.fromWireName(entry.optString("mode"))
        val fanId = entry.optString("fanId").ifBlank { null }
        if (entry.optString("stamp") != stamp(config) || mode == null || fanId == null) {
            purge()
            return null
        }
        return FastoryResolvedIdentity(mode, fanId)
    }

    fun purge() {
        prefs?.edit()?.remove(KEY_ENTRY)?.apply()
    }

    /** What the identity in force and the refresh token read beside it call for (SPEC § 2.6.3). */
    sealed class Pairing {
        /** A `FanId` fan with a token: present it for a new session. */
        data class Renew(val token: String) : Pairing()

        /**
         * A `FanId` fan whose token is gone — a reinstall, a restore: the fan is signed out, with no
         * event, since nothing was refused.
         */
        object SignOut : Pairing()

        /** A token with no `FanId` fan beside it: it renews no one, so it is erased. */
        data class EraseToken(val token: String) : Pairing()

        /** The read reached no answer: the fan and the token stay, and the read is tried again. */
        object RetryLater : Pairing()

        /** Nothing to pair. */
        object Unchanged : Pairing()
    }

    fun pairing(identity: FastoryResolvedIdentity?, token: RefreshTokenReadResult): Pairing {
        val isFanIdFan = identity?.mode == FastoryIdentityMode.FAN_ID
        return when (token) {
            is RefreshTokenReadResult.Present ->
                if (isFanIdFan) Pairing.Renew(token.token) else Pairing.EraseToken(token.token)
            RefreshTokenReadResult.Absent -> if (isFanIdFan) Pairing.SignOut else Pairing.Unchanged
            RefreshTokenReadResult.Retry -> if (isFanIdFan) Pairing.RetryLater else Pairing.Unchanged
        }
    }
}
