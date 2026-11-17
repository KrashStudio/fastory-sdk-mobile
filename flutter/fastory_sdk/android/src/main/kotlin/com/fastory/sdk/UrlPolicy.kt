package com.fastory.sdk

import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder

internal enum class NavigationDecision {
    ALLOW,
    OPEN_GAME_SHEET,
    OPEN_EXTERNAL_BROWSER,
}

internal object UrlPolicy {

    const val GAME_PATH_PREFIX = "/s/"

    // Games are served from the Fanzone origin or from the Fastory stories domains; /s/ links on
    // either open the game sheet. Any other stories-domain path stays external.
    private val STORIES_HOSTS = setOf("story.tl", "staging.story.tl")

    fun decide(url: String, baseUrl: String): NavigationDecision {
        val scheme = url.substringBefore(':', "").lowercase()
        if (scheme != "http" && scheme != "https") {
            return NavigationDecision.OPEN_EXTERNAL_BROWSER
        }

        val target = url.toUriOrNull() ?: return NavigationDecision.OPEN_EXTERNAL_BROWSER
        val base = baseUrl.toUriOrNull() ?: return NavigationDecision.OPEN_EXTERNAL_BROWSER

        val isGamePath = target.path.orEmpty().startsWith(GAME_PATH_PREFIX)

        if (target.hasSameOriginAs(base)) {
            return if (isGamePath) NavigationDecision.OPEN_GAME_SHEET else NavigationDecision.ALLOW
        }

        if (target.isStoriesOrigin() && isGamePath) {
            return NavigationDecision.OPEN_GAME_SHEET
        }

        return NavigationDecision.OPEN_EXTERNAL_BROWSER
    }

    private fun URI.isStoriesOrigin(): Boolean =
        scheme.orEmpty().equals("https", ignoreCase = true) &&
            STORIES_HOSTS.contains(host.orEmpty().lowercase())

    fun gameSlug(url: String): String? =
        url.toUriOrNull()
            ?.path
            .orEmpty()
            .takeIf { it.startsWith(GAME_PATH_PREFIX) }
            ?.removePrefix(GAME_PATH_PREFIX)
            ?.substringBefore('/')
            ?.takeIf { it.isNotBlank() }

    /**
     * Augments a game URL for embedded rendering (SPEC §3.3): `embed=1`, `utm_source=sdk`,
     * `consent=0`, then [extra], the host's own parameters (locale, theme, host login), each added
     * only when the link does not carry it already — the fanzone builds its own game links, and a
     * value it put there wins, a name being matched once decoded, as iOS does. `utm_source` is the
     * exception: a game the SDK opens is SDK traffic, so the link's own takes the value `sdk` where
     * it stands and a repeat of it is dropped. The host's values are encoded; the embed ones are constants.
     */
    fun embeddedGameUrl(url: String, extra: List<Pair<String, String>> = emptyList()): String {
        val fragmentSplit = url.split('#', limit = 2)
        val base = fragmentSplit[0]
        val fragment = fragmentSplit.getOrNull(1)
        val queryStart = base.indexOf('?')
        val path = if (queryStart < 0) base else base.substring(0, queryStart)
        var attributed = false
        val query = if (queryStart < 0) null else base.substring(queryStart + 1)
            .split('&')
            .mapNotNull { pair ->
                when {
                    pair.substringBefore('=').decodedOrRaw() != ATTRIBUTION -> pair
                    attributed -> null
                    else -> "$ATTRIBUTION=sdk".also { attributed = true }
                }
            }
        val existingNames = query.orEmpty()
            .filter { it.isNotEmpty() }
            .map { it.substringBefore('=').decodedOrRaw() }
            .toSet()
        val hostParams = extra.map { (name, value) -> name to URLEncoder.encode(value, "UTF-8") }
        val missing = (listOf("embed" to "1", ATTRIBUTION to "sdk", "consent" to "0") + hostParams)
            .filter { it.first !in existingNames }
            .joinToString("&") { "${it.first}=${it.second}" }
        val augmented = when {
            query == null && missing.isEmpty() -> path
            query == null -> "$path?$missing"
            missing.isEmpty() -> "$path?${query.joinToString("&")}"
            else -> "$path?${query.joinToString("&")}&$missing"
        }
        return if (fragment != null) "$augmented#$fragment" else augmented
    }

    private const val ATTRIBUTION = "utm_source"

    private fun String.decodedOrRaw(): String = runCatching { URLDecoder.decode(this, "UTF-8") }.getOrDefault(this)

    private fun String.toUriOrNull(): URI? = runCatching { URI(this) }.getOrNull()

    private fun URI.hasSameOriginAs(other: URI): Boolean =
        scheme.orEmpty().equals(other.scheme.orEmpty(), ignoreCase = true) &&
            host.orEmpty().equals(other.host.orEmpty(), ignoreCase = true) &&
            host != null &&
            effectivePort() == other.effectivePort()

    private fun URI.effectivePort(): Int = when {
        port != -1 -> port
        scheme.equals("https", ignoreCase = true) -> 443
        else -> 80
    }
}
