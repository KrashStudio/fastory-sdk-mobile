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
    private let loadTimeoutSeconds: TimeInterval = 30

    /// Live prewarmed webviews keyed by game slug, never presented yet (fresh state).
    private var pool: [String: WKWebView] = [:]
    /// Games waiting for a background load, most urgent first.
    private var queue: [(slug: String, url: URL)] = []
    /// Hub display order of the discovered games; drives pool eviction priority.
    private var hubOrder: [String] = []
    /// The game the player closed last — always the top preload priority.
    private var lastClosedSlug: String?
    private var currentLoad: (slug: String, webView: WKWebView)?
    private var loadTimeout: DispatchWorkItem?
    private var hubObservation: NSKeyValueObservation?
    private var isGameSheetPresented = false
    private var config: FastoryConfig?
    /// Seam for unit tests (network loads are not deterministic there); production always
    /// performs the real load.
    var startLoad: (WKWebView, URLRequest) -> Void = { webView, request in
        webView.load(request)
    }

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
    func takeWebView(slug: String) -> WKWebView? {
        if let webView = pool.removeValue(forKey: slug) {
            return webView
        }
        if let load = currentLoad, load.slug == slug {
            cancelLoadTimeout()
            currentLoad = nil
            load.webView.navigationDelegate = nil
            return load.webView
        }
        return nil
    }

    /// Suspends background loads while a game is being played.
    func gameSheetWillPresent() {
        isGameSheetPresented = true
    }

    /// The played webview is discarded by the sheet; queue a fresh copy of that game ahead
    /// of everything else so reopening it is instant and starts from a clean state.
    func gameSheetDidClose(slug: String, url: URL) {
        isGameSheetPresented = false
        guard !slug.isEmpty else {
            startNextLoadIfIdle()
            return
        }
        lastClosedSlug = slug
        queue.removeAll { $0.slug == slug }
        queue.insert((slug: slug, url: url), at: 0)
        startNextLoadIfIdle()
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

    /// Read-only query of the fanzone's SSR payload: visible Experience tiles and Crusher
    /// blocks of the active tab. Mirrors the web's own URL construction
    /// (`{storiesOrigin}/s/{slug}?utm_source=fanzone`) so preloads hit the exact URL a tap
    /// would navigate to. Must stay read-only — the SDK never alters page behavior.
    static func discoveryScript(storiesOrigin: URL?) -> String {
        let origin = storiesOrigin?.absoluteString ?? ""
        return """
        (function () {
          try {
            var data = window.__NEXT_DATA__;
            var fanzone = data && data.props && data.props.pageProps && data.props.pageProps.fanzoneData;
            if (!fanzone) return "[]";
            var tabSlug = new URLSearchParams(window.location.search).get("tab");
            var tabs = fanzone.tabs || [];
            var activeTabId = null;
            if (tabSlug && tabSlug !== "default") {
              for (var i = 0; i < tabs.length; i++) {
                if (tabs[i] && tabs[i].slug === tabSlug) { activeTabId = tabs[i].id; break; }
              }
            }
            var origin = "\(origin)" || window.location.origin;
            var urls = [];
            var seen = {};
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
            return JSON.stringify(urls);
          } catch (error) {
            return "[]";
          }
        })()
        """
    }

    /// Parses the discovery result and keeps only URLs URLPolicy would open in the game
    /// sheet, mapped to their load URL (embed/consent params added, like a real tap).
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

    private func schedule(_ games: [(slug: String, url: URL)]) {
        guard !games.isEmpty else { return }
        hubOrder = games.map(\.slug)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + loadTimeoutSeconds, execute: timeout)
    }

    private func cancelLoadTimeout() {
        loadTimeout?.cancel()
        loadTimeout = nil
    }
}

extension FastoryGamePreloader: WKNavigationDelegate {
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
