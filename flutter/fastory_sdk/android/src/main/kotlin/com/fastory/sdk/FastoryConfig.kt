package com.fastory.sdk

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
    /**
     * Optional cross-check: when set, a key resolving to a different workspace is rejected.
     * Catches a key pasted into the wrong app rather than failing silently on someone else's
     * fanzone.
     */
    val workspaceId: String? = null,
    val theme: FastoryTheme? = null,
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
        if (workspaceId != null) {
            require(workspaceId.isNotBlank()) { "workspaceId must not be blank when provided" }
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
     * Query parameters appended to every game URL, on top of the embed parameters. Only the ones
     * that depend on the host's configuration live here.
     */
    internal val gamePresentationQuery: Map<String, String>
        get() = buildMap {
            locale?.let { put("locale", it) }
            theme?.let { put("theme", it.value) }
        }

    companion object {
        const val LIVE_PUBLISHABLE_KEY_PREFIX = "fpk_live_"
        const val TEST_PUBLISHABLE_KEY_PREFIX = "fpk_test_"

        internal fun validatePublishableKey(key: String, environment: FastoryEnvironment) {
            val prefix = when {
                key.startsWith(LIVE_PUBLISHABLE_KEY_PREFIX) -> LIVE_PUBLISHABLE_KEY_PREFIX
                key.startsWith(TEST_PUBLISHABLE_KEY_PREFIX) -> TEST_PUBLISHABLE_KEY_PREFIX
                else -> throw IllegalArgumentException(
                    "publishableKey must start with $LIVE_PUBLISHABLE_KEY_PREFIX or " +
                        TEST_PUBLISHABLE_KEY_PREFIX
                )
            }
            // A prefix alone is not a key: reject `fpk_live_` with nothing after it.
            require(key.length > prefix.length) {
                "publishableKey must start with $LIVE_PUBLISHABLE_KEY_PREFIX or " +
                    TEST_PUBLISHABLE_KEY_PREFIX
            }
            require(prefix == environment.expectedKeyPrefix) {
                "publishableKey does not belong to this environment"
            }
        }
    }
}
