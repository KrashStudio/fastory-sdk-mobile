package com.fastory.sdk

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONObject

/**
 * The last verified delegated identity, kept across launches so a returning fan is shown at once
 * instead of re-verified before anything renders (SPEC § 2.6.3).
 *
 * Only the resolved identity is stored — never the host token, never the embed session. `fanId` is
 * an opaque account id, not a credential; the embed session lives minutes, so persisting either
 * would add risk and buy nothing. The panel shows the fan immediately from this; the games' session
 * is re-established in the background.
 *
 * Stamped with the workspace and environment it was resolved under. A `configure` that resolves a
 * different pair ignores this and purges it, so one club's fan can never surface in another's app.
 *
 * The store is a [SharedPreferences] handed in when a [Context] first becomes available (the SDK's
 * `configure` has none of its own). Until then persistence is a no-op — a fan is simply re-verified,
 * which is the same outcome as a first-ever launch.
 */
internal object FastoryIdentityPersistence {
    private const val PREFS_NAME = "com.fastory.sdk.identity"
    private const val KEY_ENTRY = "delegated-identity"

    /** Set from a [Context] the SDK sees (openGames, the hub warm-up, the plugin attach). */
    var prefs: SharedPreferences? = null

    fun attach(context: Context) {
        if (prefs == null) {
            prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        }
    }

    /** The base URL carries the environment, the publishable key the workspace. */
    fun stamp(config: FastoryConfig): String =
        "${config.baseUrl.trimEnd('/')}|${config.publishableKey ?: ""}"

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
}
