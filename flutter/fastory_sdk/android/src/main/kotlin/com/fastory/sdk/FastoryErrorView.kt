package com.fastory.sdk

import android.content.Context
import android.graphics.Color
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.view.isVisible
import com.fastory.sdk.flutter.R

/**
 * The native error view both surfaces show when a load fails (SPEC § 9).
 *
 * One builder rather than two identical ones: the hub and the game sheet must look the same to a
 * fan, and two copies are two places for that to stop being true.
 */
internal object FastoryErrorView {
    /** Hidden until something fails. The caller adds it to its own container and sizes it there. */
    internal fun build(context: Context, onRetry: () -> Unit): LinearLayout =
        LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.WHITE)
            isVisible = false
            addView(
                TextView(context).apply {
                    text = context.getString(R.string.fastory_sdk_error_message)
                    gravity = Gravity.CENTER
                },
            )
            addView(
                Button(context).apply {
                    text = context.getString(R.string.fastory_sdk_retry)
                    setOnClickListener { onRetry() }
                },
            )
        }
}
