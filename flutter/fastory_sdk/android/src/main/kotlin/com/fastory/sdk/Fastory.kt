package com.fastory.sdk

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import java.lang.ref.WeakReference

interface FastoryEventsListener {
    fun onHubOpened() {}
    fun onHubClosed() {}
    fun onGameOpened(slug: String) {}
    fun onGameClosed() {}
    fun onExternalLink(url: String) {}
}

object Fastory {

    @Volatile
    internal var config: FastoryConfig? = null
        private set

    @Volatile
    private var listener: FastoryEventsListener? = null

    private var hubRef: WeakReference<Activity>? = null

    fun configure(config: FastoryConfig, listener: FastoryEventsListener? = null) {
        this.config = config
        this.listener = listener
    }

    fun openGames(context: Context) {
        checkNotNull(config) { "Fastory.configure() must be called before openGames()" }
        val intent = Intent(context, FastoryHubActivity::class.java)
        if (context !is Activity) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
    }

    fun close() {
        hubRef?.get()?.finish()
    }

    internal fun notifyHubOpened(activity: Activity) {
        hubRef = WeakReference(activity)
        listener?.onHubOpened()
    }

    internal fun notifyHubClosed(activity: Activity) {
        if (hubRef?.get() === activity) {
            hubRef = null
        }
        listener?.onHubClosed()
    }

    internal fun notifyGameOpened(slug: String) {
        listener?.onGameOpened(slug)
    }

    internal fun notifyGameClosed() {
        listener?.onGameClosed()
    }

    internal fun openExternalBrowser(context: Context, url: String) {
        try {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
            listener?.onExternalLink(url)
        } catch (_: ActivityNotFoundException) {
        }
    }
}
