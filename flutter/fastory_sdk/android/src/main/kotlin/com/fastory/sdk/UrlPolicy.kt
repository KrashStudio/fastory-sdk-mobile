package com.fastory.sdk

import java.net.URI

enum class NavigationDecision {
    ALLOW,
    OPEN_GAME_SHEET,
    OPEN_EXTERNAL_BROWSER,
}

object UrlPolicy {

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
     * Augments a game URL with the embedded-rendering params (SPEC §3.3): `embed=1`,
     * `utm_source=sdk`, `consent=0`. Existing params are preserved and never duplicated.
     */
    fun embeddedGameUrl(url: String): String {
        val fragmentSplit = url.split('#', limit = 2)
        val base = fragmentSplit[0]
        val fragment = fragmentSplit.getOrNull(1)
        val existingNames = base.substringAfter('?', "")
            .split('&')
            .filter { it.isNotEmpty() }
            .map { it.substringBefore('=') }
            .toSet()
        val missing = listOf("embed" to "1", "utm_source" to "sdk", "consent" to "0")
            .filter { it.first !in existingNames }
        if (missing.isEmpty()) return url
        val separator = if (base.contains('?')) "&" else "?"
        val augmented = base + separator + missing.joinToString("&") { "${it.first}=${it.second}" }
        return if (fragment != null) "$augmented#$fragment" else augmented
    }

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
