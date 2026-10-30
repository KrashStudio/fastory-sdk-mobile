package com.fastory.sdk

import java.net.URLEncoder

enum class FastoryEnvironment(
    internal val defaultBaseUrl: String?,
    // Origin the fanzone builds its game links on (the web's storiesUrl). Preload URLs
    // must match the URL a real tap would produce, so cache entries line up. Development
    // environments have no known stories origin — discovery falls back to the page origin.
    internal val storiesOrigin: String?,
    internal val defaultApiBaseUrl: String?,
) {
    PRODUCTION("https://fanzone.me", "https://story.tl", "https://api.fastory.io"),

    STAGING("https://staging.fanzone.me", "https://staging.story.tl", "https://api.staging.fastory.io"),

    DEVELOPMENT(null, null, null),
    ;

    /**
     * Publishable keys are minted per environment: a `live` key belongs to production, a `test`
     * key to everything else. Checked locally at configure time so a key pasted into the wrong
     * build fails immediately instead of at the first bootstrap call.
     */
    internal val expectedKeyPrefix: String
        get() = if (this == PRODUCTION) {
            FastoryConfig.LIVE_PUBLISHABLE_KEY_PREFIX
        } else {
            FastoryConfig.TEST_PUBLISHABLE_KEY_PREFIX
        }
}

/**
 * Appearance the host app asks the web surfaces to render in. Forwarded as a `theme` query
 * parameter; the web side does not read it yet, so setting it is inert until it ships there.
 */
enum class FastoryTheme(internal val value: String) {
    LIGHT("light"),
    DARK("dark"),
}

data class FastoryConfig(
    /**
     * Deprecated identifier, kept for the whole 0.x compatibility window. Null when configured
     * by publishable key, in which case the fanzone is resolved from the API.
     */
    @property:Deprecated(
        "Configure with a publishableKey instead. Create one in the workspace settings. " +
            "The fanzone slug keeps working for the whole 0.x window; it will be removed in 1.0."
    )
    val fanzoneSlug: String? = null,
    val environment: FastoryEnvironment = FastoryEnvironment.PRODUCTION,
    val hubTabSlug: String = "games",
    val locale: String? = null,
    val developmentBaseUrl: String? = null,
    /**
     * Identifies the workspace the host app belongs to. The fanzone to open is resolved from it
     * at configure time; prefer this over [fanzoneSlug].
     */
    val publishableKey: String? = null,
    val theme: FastoryTheme? = null,
    /**
     * The surfaces the SDK prepares before their first opening (SPEC § 2.1) — the hub alone unless
     * you ask for more.
     *
     * A prepared surface opens already rendered, and it keeps a WebView — and its renderer process —
     * resident from the moment it is prepared. Add [FastorySurface.MEMBERSHIP] when your app opens
     * the membership panel; left out, the panel's first opening loads when it is asked for, and its
     * page is kept after it closes like any other. An empty set prepares nothing ahead of time.
     * [FastorySurface.GAME] has no effect of its own: games are preloaded from the hub's page, so
     * they follow [FastorySurface.HUB]. The deprecated slug path resolves no workspace, so it has no
     * panel to prepare and ignores [FastorySurface.MEMBERSHIP]. Nothing is prepared ahead of time
     * through the context-less [Fastory.configure], whatever this holds.
     */
    val prewarm: Set<FastorySurface> = setOf(FastorySurface.HUB),
    /**
     * Whether your app signs the fan in when a Fastory page asks it to (SPEC § 2.6).
     *
     * No page the SDK presents ever shows a login form of its own. Declared, the hub, the membership
     * panel and the games keep their sign-in entries, and a fan's tap on one reaches
     * [FastoryEventsListener.onBridgeMessage] as `fastory:login-requested`: sign the fan in your own
     * way, then call [Fastory.identify]. Left `false`, the pages show no sign-in entry at all.
     * Declare it only if you handle that message — otherwise every sign-in entry becomes a control
     * that does nothing.
     *
     * The last parameter, so a call that passes the others by position compiles unchanged.
     */
    val handlesLoginRequests: Boolean = false,
) {

    init {
        require(hubTabSlug.isNotBlank()) { "hubTabSlug must not be blank" }
        @Suppress("DEPRECATION")
        val slug = fanzoneSlug
        require(!(slug == null && publishableKey == null)) {
            "configure with either a publishableKey or a fanzoneSlug"
        }
        require(!(slug != null && publishableKey != null)) {
            "configure with a publishableKey or a fanzoneSlug, not both"
        }
        if (slug != null) {
            require(slug.isNotBlank()) { "fanzoneSlug must not be blank" }
        }
        if (publishableKey != null) {
            validatePublishableKey(publishableKey, environment)
        }
        if (environment == FastoryEnvironment.DEVELOPMENT) {
            require(!developmentBaseUrl.isNullOrBlank()) {
                "developmentBaseUrl is required when environment is DEVELOPMENT"
            }
        }
    }

    val baseUrl: String
        get() = environment.defaultBaseUrl ?: developmentBaseUrl!!.trimEnd('/')

    internal val apiBaseUrl: String
        get() = environment.defaultApiBaseUrl ?: developmentBaseUrl!!.trimEnd('/')

    internal val bootstrapUrl: String
        get() = "${apiBaseUrl.trimEnd('/')}/sdk/auth/bootstrap"

    /** Exchanges a host attestation for a fan session (SPEC § 2.6 delegated identity). */
    internal val embedTokenUrl: String
        get() = "${apiBaseUrl.trimEnd('/')}/embed/auth/token"

    /** Mints a single-use session-handoff token for a surface to adopt the session with. */
    internal val embedHandoffUrl: String
        get() = "${apiBaseUrl.trimEnd('/')}/embed/auth/handoff"

    /** Renews an embed session before it expires, returning a token with a fresh TTL. */
    internal val embedRefreshUrl: String
        get() = "${apiBaseUrl.trimEnd('/')}/embed/auth/refresh"

    /**
     * The hub URL for a resolved fanzone slug. Configured by key, the slug is only known once
     * `/sdk/auth/bootstrap` answers, so this takes it as a parameter.
     */
    fun hubUrl(fanzoneSlug: String): String = buildString {
        append(baseUrl.trimEnd('/'))
        append('/')
        append(fanzoneSlug)
        append("?tab=")
        append(hubTabSlug)
        append("&chrome=0&consent=0")
        locale?.let {
            append("&locale=")
            append(it)
        }
        theme?.let {
            append("&theme=")
            append(it.value)
        }
        appendHostLogin()
    }

    /**
     * The bot page of a resolved workspace (SPEC § 3.5, "Bot URL").
     *
     * Addressed by workspace identifier, which the publishable-key exchange returns and the
     * deprecated slug path never learns: a fanzone slug names a fanzone, not the workspace that owns
     * it. `consent=0` says the host application owns the fan's analytics consent, so the page raises
     * no banner of its own. The appearance hint the hub and the game carry is not one of this page's
     * parameters, and forwarding it here would be reading the hub's rules into it.
     *
     * The host names a [sequenceId] and the page reads a `sequence` parameter. Blank is no sequence
     * at all: a host reading an empty field out of its own interface names none, and an empty
     * parameter would ask the page for a sequence with no identifier rather than for the panel's
     * default screen. The identifier is host-supplied text and this address is concatenated rather
     * than composed, so it is escaped here — pasted in as it came, its own `&` would mint a
     * parameter nobody sent and leave the page with a truncated identifier.
     */
    fun membershipUrl(workspaceId: String, sequenceId: String? = null): String = buildString {
        append(baseUrl.trimEnd('/'))
        append("/embed/bot/")
        append(workspaceId)
        append("?consent=0")
        locale?.let {
            append("&locale=")
            append(it)
        }
        sequenceId?.takeIf { it.isNotBlank() }?.let {
            append("&sequence=")
            append(URLEncoder.encode(it, "UTF-8"))
        }
        appendHostLogin()
    }

    /**
     * `hostLogin=1` when the host declared [handlesLoginRequests], nothing otherwise (SPEC § 3.2,
     * § 3.3, § 3.5). Never `hostLogin=0`: an absent parameter is what tells the page to show no
     * sign-in entry, so a configuration that declares nothing leaves the addresses exactly as before.
     */
    internal val hostLoginQuery: List<Pair<String, String>>
        get() = if (handlesLoginRequests) listOf("hostLogin" to "1") else emptyList()

    private fun StringBuilder.appendHostLogin() {
        hostLoginQuery.forEach { (name, value) -> append('&').append(name).append('=').append(value) }
    }

    /**
     * Non-null only when configured by slug — the one case where the hub URL is known without a
     * round trip, and therefore the only one that can warm a webview at configure time.
     */
    val staticHubUrl: String?
        get() {
            @Suppress("DEPRECATION")
            val slug = fanzoneSlug ?: return null
            return hubUrl(slug)
        }

    /**
     * What the warm-up actually prepares: the surfaces [prewarm] asks for, among those this
     * configuration can address before any opening. A game has no address of its own until the hub's
     * page names it, and a fanzone slug names no workspace, so no panel.
     */
    internal val surfacesToPrewarm: Set<FastorySurface>
        get() = prewarm.intersect(
            if (publishableKey != null) {
                setOf(FastorySurface.HUB, FastorySurface.MEMBERSHIP)
            } else {
                setOf(FastorySurface.HUB)
            },
        )

    /**
     * Query parameters appended to every game URL, on top of the embed parameters. Only the ones
     * that depend on the host's configuration live here.
     */
    internal val gamePresentationQuery: Map<String, String>
        get() = buildMap {
            locale?.let { put("locale", it) }
            theme?.let { put("theme", it.value) }
            putAll(hostLoginQuery)
        }

    companion object {
        const val LIVE_PUBLISHABLE_KEY_PREFIX = "fpk_live_"
        const val TEST_PUBLISHABLE_KEY_PREFIX = "fpk_test_"
        private const val MALFORMED_PUBLISHABLE_KEY = "publishableKey must start with " +
            "$LIVE_PUBLISHABLE_KEY_PREFIX or $TEST_PUBLISHABLE_KEY_PREFIX, followed by the key itself"

        /**
         * Reads `prewarm` off the platform channel's `configure` payload (SPEC § 5.2).
         *
         * Absent, `null` or not a list, it is the default — a caller that sends no such key asks for
         * what every earlier version did. A name no surface carries is ignored rather than refused,
         * exactly as an unrecognised `theme` is read as none.
         */
        internal fun prewarmFromChannel(value: Any?): Set<FastorySurface> {
            val names = value as? List<*> ?: return setOf(FastorySurface.HUB)
            return names.mapNotNull { name ->
                FastorySurface.entries.firstOrNull { it.wireName == name }
            }.toSet()
        }

        /**
         * Reads `handlesLoginRequests` off the platform channel's `configure` payload (SPEC § 5.2).
         *
         * Only a boolean `true` declares it. Absent, `null` or anything else reads as `false`, never
         * as a refusal: a declaration nobody can read is not one, and reading it as `true` would hand
         * the fan sign-in entries no host listens for.
         */
        internal fun handlesLoginRequestsFromChannel(value: Any?): Boolean = value == true

        internal fun validatePublishableKey(key: String, environment: FastoryEnvironment) {
            val prefix = when {
                key.startsWith(LIVE_PUBLISHABLE_KEY_PREFIX) -> LIVE_PUBLISHABLE_KEY_PREFIX
                key.startsWith(TEST_PUBLISHABLE_KEY_PREFIX) -> TEST_PUBLISHABLE_KEY_PREFIX
                else -> throw IllegalArgumentException(MALFORMED_PUBLISHABLE_KEY)
            }
            // A prefix alone is not a key: reject `fpk_live_` with nothing after it.
            require(key.length > prefix.length) { MALFORMED_PUBLISHABLE_KEY }
            require(prefix == environment.expectedKeyPrefix) {
                "publishableKey does not belong to this environment"
            }
        }
    }
}
