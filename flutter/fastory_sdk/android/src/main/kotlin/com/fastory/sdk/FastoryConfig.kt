package com.fastory.sdk

enum class FastoryEnvironment(internal val defaultBaseUrl: String?) {
    PRODUCTION("https://fanzone.me"),

    STAGING("https://staging.fanzone.me"),

    DEVELOPMENT(null),
}

data class FastoryConfig(
    val fanzoneSlug: String,
    val environment: FastoryEnvironment = FastoryEnvironment.PRODUCTION,
    val hubTabSlug: String = "games",
    val locale: String? = null,
    val developmentBaseUrl: String? = null,
) {

    init {
        require(fanzoneSlug.isNotBlank()) { "fanzoneSlug must not be blank" }
        require(hubTabSlug.isNotBlank()) { "hubTabSlug must not be blank" }
        if (environment == FastoryEnvironment.DEVELOPMENT) {
            require(!developmentBaseUrl.isNullOrBlank()) {
                "developmentBaseUrl is required when environment is DEVELOPMENT"
            }
        }
    }

    val baseUrl: String
        get() = environment.defaultBaseUrl ?: developmentBaseUrl!!.trimEnd('/')

    val hubUrl: String
        get() = buildString {
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
        }
}
