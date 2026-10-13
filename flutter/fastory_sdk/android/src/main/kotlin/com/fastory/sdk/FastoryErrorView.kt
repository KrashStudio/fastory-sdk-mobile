package com.fastory.sdk

import android.content.Context
import android.content.res.Configuration
import android.graphics.Color
import android.view.Gravity
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.annotation.StringRes
import androidx.core.view.isVisible
import java.util.Locale
import com.fastory.sdk.flutter.R

/**
 * The native error view both surfaces show when a load fails (SPEC § 9).
 *
 * One builder rather than two identical ones: the hub and the game sheet must look the same to a
 * fan, and two copies are two places for that to stop being true.
 *
 * Every string a fan reads here is a resource, resolved for the fan's language — the one screen the
 * SDK renders natively must not be the one screen that ignores it. Being resources, a host
 * application may redefine them under the same names, for each language it ships.
 */
internal object FastoryErrorView {
    /** The languages the SDK carries a table for; `values/` is English. */
    internal val SUPPORTED_LANGUAGES = setOf("en", "fr", "es")

    /** Hidden until something fails. The caller adds it to its own container and sizes it there. */
    internal fun build(context: Context, onRetry: () -> Unit): LinearLayout {
        val strings = localizedContext(context)
        return LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.WHITE)
            isVisible = false
            addView(
                TextView(context).apply {
                    id = R.id.fastory_sdk_error_message_text
                    text = strings.getString(messageResource(FastoryLoadFailureReason.UNKNOWN))
                    gravity = Gravity.CENTER
                },
            )
            addView(
                Button(context).apply {
                    text = strings.getString(R.string.fastory_sdk_retry)
                    setOnClickListener { onRetry() }
                },
            )
        }
    }

    /**
     * Reveals the view [build] returned, worded for [reason]: the no-connection variant when nothing
     * answered, the generic one otherwise (SPEC § 9). The message is announced, because the label may
     * already be on screen with another wording.
     */
    internal fun show(errorView: LinearLayout, reason: FastoryLoadFailureReason) {
        val message = localizedContext(errorView.context).getString(messageResource(reason))
        errorView.findViewById<TextView>(R.id.fastory_sdk_error_message_text)?.text = message
        errorView.isVisible = true
        announce(errorView, message)
    }

    /**
     * Every announcement the native chrome makes to a screen reader goes through here, so what
     * TalkBack is told can be observed in one place; [focus] below is the other channel. The default
     * hands it to the platform.
     */
    internal var announce: (View, CharSequence) -> Unit = { view, text ->
        view.announceForAccessibility(text)
    }

    /**
     * Asks the screen reader to land on [view]. True when the request was taken, which TalkBack
     * answers by reading the view out; false with no screen reader, or on a view that is not visible.
     */
    internal var focus: (View) -> Boolean = { view ->
        view.performAccessibilityAction(AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS, null)
    }

    /**
     * The screen reader's account of the wait Retry opens, on the hub and on the game sheet alike
     * (SPEC § 9).
     *
     * Retry hides the error view, and TalkBack's focus goes with it: for the length of the load a
     * fan hears nothing, and nothing says when the wait is over. The wait is therefore narrated at
     * both ends. It begins by moving the focus onto the loading indicator, whose label says what is
     * happening, and it ends either with the page, announced as loaded, or with the error view,
     * which announces its own message when it is shown. A page that loads outside a retry says
     * nothing: the first opening is a window TalkBack announces itself, and a navigation inside the
     * surface is the web's to narrate.
     *
     * [host] is the view the announcements leave from — one that stays on screen for the whole wait.
     */
    internal class RetryWait(
        private val host: View,
        private val loading: CharSequence,
        private val loaded: CharSequence,
    ) {
        internal var isPending = false
            private set

        /**
         * [indicator] has to be visible already, and labelled with the loading text: a focus move
         * TalkBack takes is read out, so the text is announced from [host] only when it is not — a
         * screen reader that takes no focus still hears that a load began.
         */
        internal fun begin(indicator: View) {
            isPending = true
            if (!focus(indicator)) announce(host, loading)
        }

        /** The page loaded. Announced once, and only when a retry was waiting on it. */
        internal fun succeed() {
            if (!isPending) return
            isPending = false
            announce(host, loaded)
        }

        /** The error view is back. It announces itself, so the wait only stops expecting a page. */
        internal fun fail() {
            isPending = false
        }
    }

    /** What a fan reads for [reason]. */
    @StringRes
    internal fun messageResource(reason: FastoryLoadFailureReason): Int = when (reason) {
        FastoryLoadFailureReason.NETWORK -> R.string.fastory_sdk_error_no_connection
        FastoryLoadFailureReason.REJECTED,
        FastoryLoadFailureReason.UNKNOWN,
        -> R.string.fastory_sdk_error_message
    }

    /**
     * [context] itself when one of the languages the fan's device prefers is a language the SDK
     * carries — the platform resolves that on its own. Otherwise a copy configured for the `locale`
     * the host passed at configuration, when the SDK carries it (SPEC § 9); otherwise [context]
     * again, which the platform resolves to English.
     */
    internal fun localizedContext(
        context: Context,
        configured: String? = Fastory.config?.locale,
        supported: Set<String> = SUPPORTED_LANGUAGES,
    ): Context {
        val device = context.resources.configuration.locales
        if ((0 until device.size()).any { device[it].language in supported }) return context
        val fallback = configured?.let(::languageOf)?.takeIf { it in supported } ?: return context
        val configuration = Configuration(context.resources.configuration).apply {
            setLocale(Locale.forLanguageTag(fallback))
        }
        return context.createConfigurationContext(configuration)
    }

    /** `fr-FR`, `fr_FR` and `fr` are one language to a table. */
    private fun languageOf(identifier: String): String =
        identifier.split('-', '_').first().lowercase()
}
