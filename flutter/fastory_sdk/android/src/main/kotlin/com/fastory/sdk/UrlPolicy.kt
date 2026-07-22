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
    private val STORIES_HOSTS = setOf("story.tl", "test.story.tl")

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
