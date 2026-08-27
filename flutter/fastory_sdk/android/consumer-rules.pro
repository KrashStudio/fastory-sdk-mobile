# Shipped with the library and applied to every host app that consumes it
# (consumerProguardFiles), so an integrator needs no rule of their own — which is what
# packages/sdk/docs/INTEGRATION.md promises in its FAQ.
#
# The bridge's entry point is reached only by reflection, from the WebView. R8 sees no caller and
# strips it, and the failure is silent and release-only: window.fastory.postMessage throws inside
# the page, nothing reaches native, and the debug diagnostics of SPEC §13.6 never fire because the
# method was never entered. AGP's default proguard-android.txt carries the same rule, but a host
# with a hand-written configuration does not necessarily include it, and "it worked in debug" is the
# worst possible way to discover that.
-keepclassmembers class com.fastory.sdk.FastoryBridge {
    @android.webkit.JavascriptInterface <methods>;
}
