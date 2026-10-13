# Shipped with the library and applied to every host app that consumes it, through the
# consumerProguardFiles declaration in this module's build file — so an integrator needs no rule of
# their own, which is what the integration guide's FAQ promises. That declaration is the whole
# mechanism: without it this file still ships and R8 never reads it.
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

# Keeping the method is half of it: addJavascriptInterface exposes a method only while the
# @JavascriptInterface annotation on it is still visible at runtime, and a host configuration that
# keeps no annotation attributes strips the annotation with the method intact — the same silence,
# one layer down. AGP's default file keeps this attribute too; a hand-written one may not.
-keepattributes RuntimeVisibleAnnotations
