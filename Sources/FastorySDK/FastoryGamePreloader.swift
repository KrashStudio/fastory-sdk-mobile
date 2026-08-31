import UIKit
import WebKit

/// Preloads the hub's games into warm `WKWebView`s so tapping a tile presents an
/// already-rendered game, and rebuilds a fresh copy of a game right after it is played
/// so reopening is both instant and back on the start screen.
///
/// How it works:
/// - When the hub finishes loading, the preloader reads the game list from the page's
///   embedded SSR data (`__NEXT_DATA__`) with a read-only script — game URLs never appear
///   in the DOM (tiles call `window.open` from JS), so this is the only reliable source.
/// - Games are loaded **sequentially** (one detached WebView at a time), never while a
///   game sheet is presented, so preloading never competes with the hub or a live game.
/// - The first `livePoolCapacity` games stay alive in the pool; the rest are loaded once
///   and released, which still warms WebKit's disk cache and makes their cold open fast.
/// - The game the player closed last always outranks hub order: it is re-preloaded first
///   and never evicted before untouched games.
final class FastoryGamePreloader: NSObject {
    static let shared = FastoryGamePreloader()

    // 3 live game webviews keeps hub + host app headroom on low-end devices; 12 preloads
    // bounds background data usage on large hubs. Both flushed under memory pressure.
    private let livePoolCapacity = 3
    private let maxPreloadCount = 12
    /// Seam for unit tests: real loads never stall for 30s in a test run. `internal` (not
    /// `private`) and mutable so `@testable` tests can shrink it before triggering a load.
    var loadTimeoutSeconds: TimeInterval = 30

    /// Live prewarmed webviews keyed by game slug, never presented yet (fresh state).
    private var pool: [String: WKWebView] = [:]
    /// Games waiting for a background load, most urgent first.
    private var queue: [(slug: String, url: URL)] = []
    /// Hub display order of the discovered games; drives pool eviction priority.
    private var hubOrder: [String] = []
    /// Load URL per discovered slug, so the pool can be rebuilt after a game is played
    /// without waiting for the hub to run discovery again.
    private var discoveredURLs: [String: URL] = [:]
    /// The game the player closed last — always the top preload priority.
    private var lastClosedSlug: String?
    private var currentLoad: (slug: String, webView: WKWebView)?
    private var loadTimeout: DispatchWorkItem?
    private var hubObservation: NSKeyValueObservation?
    private var isGameSheetPresented = false
    private var config: FastoryConfig?
    /// Seam for unit tests (network loads are not deterministic there); production always
    /// performs the real load. Named rather than inlined so a suite that stubs it can put it back —
    /// this is a singleton, so a stub left behind is the next suite's silent no-op.
    static let performLoad: (WKWebView, URLRequest) -> Void = { webView, request in
        webView.load(request)
    }

    var startLoad: (WKWebView, URLRequest) -> Void = FastoryGamePreloader.performLoad

    /// How the stalled-load timeout is armed. A seam for the same reason as `startLoad`, and the
    /// reason is the runner rather than convenience: it starves the main thread, so a case that
    /// waits a wall-clock delay for this work item measures the machine's load and not the
    /// preloader's behaviour. Named rather than inlined so a suite that stubs it can put it back.
    static let performScheduleTimeout: (TimeInterval, DispatchWorkItem) -> Void = { seconds, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    var scheduleTimeout: (TimeInterval, DispatchWorkItem) -> Void =
        FastoryGamePreloader.performScheduleTimeout

    // MARK: - Hub hook

    /// Starts (or restarts) game discovery every time the given hub webview finishes a load.
    func watchHub(_ webView: WKWebView, config: FastoryConfig) {
        self.config = config
        hubObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, change in
            guard change.newValue == false else { return }
            DispatchQueue.main.async { self?.discoverGames(in: webView) }
        }
    }

    // MARK: - Game sheet hooks

    /// Pool hit: hands the prewarmed webview (loaded, or still loading — the sheet adopts
    /// the in-flight navigation) to the game sheet. Miss: returns nil.
    ///
    /// `hasCommitted` comes with it because the sheet cannot work it out: `WKWebView.url` is the
    /// active URL, set the instant `load()` is called, so an adopted in-flight page already has one.
    /// Only a load that reached `didFinish` is pooled, so a pool hit has committed by construction.
    func takeWebView(slug: String) -> (webView: WKWebView, hasCommitted: Bool)? {
        if let webView = pool.removeValue(forKey: slug) {
            return (webView, true)
        }
        if let load = currentLoad, load.slug == slug {
            cancelLoadTimeout()
            currentLoad = nil
            load.webView.navigationDelegate = nil
            return (load.webView, false)
        }
        return nil
    }

    /// Seam for tests: hands the next `takeWebView(slug:)` a page a suite controls, so a game sheet
    /// can be presented without loading anything. A unit-test host never completes a real
    /// navigation, so the alternative is a sheet that either waits for a load that cannot land or
    /// asserts around one racing it.
    ///
    /// `hasCommitted` picks which of the two handover paths it models: the pool, whose pages have
    /// finished loading, or the load in flight, which the sheet adopts mid-navigation.
    func stashForTesting(_ webView: WKWebView, slug: String, hasCommitted: Bool) {
        if hasCommitted {
            pool[slug] = webView
        } else {
            currentLoad = (slug: slug, webView: webView)
        }
    }

    /// Gives the game about to be played the whole budget: background loads stop, the load in
    /// flight is abandoned, and every other warm game is released.
    ///
    /// Releasing the pool is what matters for heavy games. A pooled WebView sits outside the
    /// view hierarchy, so WebKit throttles its timers — but it keeps its page, its textures and
    /// its WebGL context resident, and WebKit shares one content process (and therefore one memory
    /// limit) across same-site WebViews on its own. Three warm 3D games starve the one
    /// on screen. The sheet already took its own WebView out of the pool before this runs, so
    /// opening stays instant; `gameSheetDidClose` rebuilds the pool afterwards.
    func gameSheetWillPresent() {
        isGameSheetPresented = true
        cancelLoadTimeout()
        if let load = currentLoad {
            load.webView.stopLoading()
            load.webView.navigationDelegate = nil
            currentLoad = nil
        }
        pool.removeAll()
    }

    /// The played webview is discarded by the sheet. Rebuild the pool that `gameSheetWillPresent`
    /// released, with a fresh copy of the game just closed first so reopening it is instant and
    /// starts from a clean state.
    func gameSheetDidClose(slug: String, url: URL) {
        isGameSheetPresented = false
        if !slug.isEmpty {
            lastClosedSlug = slug
            discoveredURLs[slug] = url
        }
        refillQueue(firstSlug: slug.isEmpty ? nil : slug)
        startNextLoadIfIdle()
    }

    /// Rebuilds the pending queue from the games discovered on the hub, skipping whatever is
    /// already warm or in flight. Playing a game empties the pool, so this is what puts the
    /// other games back in line once the sheet is gone.
    private func refillQueue(firstSlug: String?) {
        var pending: [(slug: String, url: URL)] = []
        var ordered = hubOrder
        if let firstSlug {
            ordered.removeAll { $0 == firstSlug }
            ordered.insert(firstSlug, at: 0)
        }
        for slug in ordered {
            guard pool[slug] == nil,
                  slug != currentLoad?.slug,
                  let url = discoveredURLs[slug] else { continue }
            pending.append((slug: slug, url: url))
        }
        queue = pending
    }

    /// Drops every warm game and pending load (memory pressure, re-configure).
    func flush() {
        cancelLoadTimeout()
        if let load = currentLoad {
            load.webView.stopLoading()
            load.webView.navigationDelegate = nil
        }
        currentLoad = nil
        pool.removeAll()
        queue.removeAll()
        hubOrder = []
        discoveredURLs = [:]
        lastClosedSlug = nil
    }

    // MARK: - Discovery

    private func discoverGames(in webView: WKWebView) {
        guard let config else { return }
        let script = Self.discoveryScript(storiesOrigin: config.environment.storiesOrigin)
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self, let json = result as? String else { return }
            let games = Self.parseDiscoveredGames(
                json: json,
                baseURL: config.environment.baseURL,
                limit: self.maxPreloadCount
            )
            self.schedule(games)
        }
    }

    /// Read-only query of the fanzone's SSR payload, in two passes: visible Experience tiles
    /// and Crusher blocks of the active tab first (mirroring the web's own URL construction,
    /// `{storiesOrigin}/s/{slug}?utm_source=fanzone`), then any direct game URL — an absolute
    /// http(s) string with an `/s/` path — found anywhere in the payload, verbatim: hubs whose
    /// tiles are plain links reference games that way, with no Experience component at all.
    /// The URL scan may over-collect on origin; `parseDiscoveredGames` filters through
    /// URLPolicy and dedups. Must stay read-only — the SDK never alters page behavior.
    static func discoveryScript(storiesOrigin: URL?) -> String {
        let origin = storiesOrigin?.absoluteString ?? ""
        return """
        (function () {
          try {
            var data = window.__NEXT_DATA__;
            if (!data) return "[]";
            var urls = [];
            var seen = {};
            var fanzone = data.props && data.props.pageProps && data.props.pageProps.fanzoneData;
            if (fanzone) {
              var tabSlug = new URLSearchParams(window.location.search).get("tab");
              var tabs = fanzone.tabs || [];
              var activeTabId = null;
              if (tabSlug && tabSlug !== "default") {
                for (var i = 0; i < tabs.length; i++) {
                  if (tabs[i] && tabs[i].slug === tabSlug) { activeTabId = tabs[i].id; break; }
                }
              }
              var origin = "\(origin)" || window.location.origin;
              var push = function (slug) {
                var parts = String(slug).split("/").filter(Boolean);
                var normalized = parts.length ? parts[parts.length - 1] : null;
                if (!normalized || seen[normalized]) return;
                seen[normalized] = true;
                urls.push(origin + "/s/" + normalized + "?utm_source=fanzone");
              };
              var components = fanzone.components || [];
              for (var j = 0; j < components.length; j++) {
                var component = components[j];
                if (!component || component.isHidden) continue;
                var hiddenByTab = component.tabId == null
                  ? activeTabId != null
                  : component.tabId !== activeTabId;
                if (hiddenByTab) continue;
                if (component.type === "Experience") {
                  var experiences = (component.settings && component.settings.experiences) || [];
                  for (var k = 0; k < experiences.length; k++) {
                    var experience = experiences[k];
                    if (experience && experience.visible && experience.slug) push(experience.slug);
                  }
                } else if (component.type === "Crusher" && component.settings && component.settings.slug) {
                  push(component.settings.slug);
                }
              }
            }
            var gameUrlPattern = new RegExp("^https?://[^/?#]+/s/");
            var collect = function (node) {
              if (typeof node === "string") {
                if (gameUrlPattern.test(node) && !seen[node]) {
                  seen[node] = true;
                  urls.push(node);
                }
                return;
              }
              if (node && typeof node === "object") {
                for (var key in node) collect(node[key]);
              }
            };
            collect(data);
            return JSON.stringify(urls);
          } catch (error) {
            return "[]";
          }
        })()
        """
    }

    /// Parses the discovery result and keeps only URLs URLPolicy would open in the game
    /// sheet, mapped to their load URL (embed/consent params added, like a real tap). The
    /// script's URL scan over-collects (any origin with an `/s/` path), so this filter is
    /// what enforces the game-sheet policy.
    static func parseDiscoveredGames(
        json: String,
        baseURL: URL,
        limit: Int
    ) -> [(slug: String, url: URL)] {
        guard let data = json.data(using: .utf8),
              let strings = (try? JSONSerialization.jsonObject(with: data)) as? [String] else {
            return []
        }
        var games: [(slug: String, url: URL)] = []
        var seen = Set<String>()
        for string in strings {
            guard games.count < limit,
                  let url = URL(string: string),
                  URLPolicy.decide(url: url, baseURL: baseURL) == .openGameSheet else {
                continue
            }
            let slug = url.fastoryGameSlug
            guard !slug.isEmpty, !seen.contains(slug) else { continue }
            seen.insert(slug)
            games.append((slug: slug, url: url.fastoryEmbeddedGameURL))
        }
        return games
    }

    // MARK: - Sequential loading

    /// `internal` (not `private`) so tests can drive pool/eviction/rank scenarios directly,
    /// without a real WKWebView JS-evaluation round trip (see FastoryGamePreloaderTests).
    func schedule(_ games: [(slug: String, url: URL)]) {
        guard !games.isEmpty else { return }
        hubOrder = games.map(\.slug)
        for game in games {
            discoveredURLs[game.slug] = game.url
        }
        let alreadyWarm = Set(pool.keys)
        queue = games.filter { !alreadyWarm.contains($0.slug) && $0.slug != currentLoad?.slug }
        if let last = lastClosedSlug, let index = queue.firstIndex(where: { $0.slug == last }) {
            queue.insert(queue.remove(at: index), at: 0)
        }
        startNextLoadIfIdle()
    }

    private func startNextLoadIfIdle() {
        guard currentLoad == nil, !isGameSheetPresented, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        guard pool[next.slug] == nil else {
            startNextLoadIfIdle()
            return
        }
        let webView = FastoryWebKit.makeWebView()
        // Detached webviews otherwise measure 0×0, which canvas-based games mis-initialize on.
        webView.frame = UIScreen.main.bounds
        webView.navigationDelegate = self
        currentLoad = (slug: next.slug, webView: webView)
        startLoad(webView, URLRequest(url: next.url))
        scheduleLoadTimeout()
    }

    private func finishCurrentLoad(success: Bool) {
        cancelLoadTimeout()
        guard let load = currentLoad else { return }
        currentLoad = nil
        load.webView.navigationDelegate = nil
        if success {
            insertIntoPool(slug: load.slug, webView: load.webView)
        } else {
            load.webView.stopLoading()
        }
        startNextLoadIfIdle()
    }

    /// Keeps the webview live when the pool has room or the new game outranks a pooled one;
    /// otherwise releases it — the load still warmed WebKit's disk cache.
    private func insertIntoPool(slug: String, webView: WKWebView) {
        if pool.count < livePoolCapacity {
            pool[slug] = webView
            return
        }
        guard let evictable = pool.keys.max(by: { rank($0) < rank($1) }),
              rank(evictable) > rank(slug) else {
            return
        }
        pool.removeValue(forKey: evictable)
        pool[slug] = webView
    }

    /// Lower is more valuable: last-closed game first, then hub display order.
    private func rank(_ slug: String) -> Int {
        if slug == lastClosedSlug { return -1 }
        return hubOrder.firstIndex(of: slug) ?? Int.max
    }

    private func scheduleLoadTimeout() {
        let timeout = DispatchWorkItem { [weak self] in
            self?.finishCurrentLoad(success: false)
        }
        loadTimeout = timeout
        scheduleTimeout(loadTimeoutSeconds, timeout)
    }

    private func cancelLoadTimeout() {
        loadTimeout?.cancel()
        loadTimeout = nil
    }
}

extension FastoryGamePreloader: WKNavigationDelegate {
    /// A game that answered an error status must not reach the pool. Its error **body** loads like
    /// any other document, so `didFinish` fires and the page looks warm — and the sheet that later
    /// takes it announces `gameOpened` on a page the fan sees as broken (SPEC § 9.1).
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        guard webView === currentLoad?.webView,
              navigationResponse.isForMainFrame,
              let response = navigationResponse.response as? HTTPURLResponse,
              response.statusCode >= 400 else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        finishCurrentLoad(success: false)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === currentLoad?.webView else { return }
        finishCurrentLoad(success: true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === currentLoad?.webView else { return }
        finishCurrentLoad(success: false)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard webView === currentLoad?.webView else { return }
        finishCurrentLoad(success: false)
    }
}
