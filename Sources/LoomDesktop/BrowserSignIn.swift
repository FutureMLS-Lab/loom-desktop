import AppKit
import WebKit
import os

/// Credentials for a Loom that sits behind a browser sign-in — Google IAP and
/// proxies built on it, such as `*.loop.corp.discoloop.com`.
///
/// Such a proxy answers an unknown caller with a redirect to Google, and takes
/// a caller it knows by a cookie it set after the sign-in. A plain HTTP client
/// has neither half, so the sign-in happens in a web view (`BrowserSignIn`),
/// and the cookies it leaves for the server's host are copied here and sent on
/// every API request.
enum BrowserAuth {
    private static let jar = OSAllocatedUnfairLock(initialState: [HTTPCookie]())

    static func setCookies(_ cookies: [HTTPCookie]) {
        jar.withLock { $0 = cookies }
    }

    /// The cookies a browser would send to `url`: its host's (host-only or a
    /// parent domain), unexpired, path-matching, and secure ones only over TLS.
    static func cookies(for url: URL) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let path = url.path.isEmpty ? "/" : url.path
        let now = Date()
        return jar.withLock { all in
            all.filter { cookie in
                let domain = cookie.domain.lowercased()
                let matchesHost: Bool
                if domain.hasPrefix(".") {
                    let bare = String(domain.dropFirst())
                    matchesHost = host == bare || host.hasSuffix(domain)
                } else {
                    matchesHost = host == domain
                }
                guard matchesHost else { return false }
                if let expires = cookie.expiresDate, expires <= now { return false }
                if cookie.isSecure && url.scheme?.lowercased() != "https" { return false }
                return path.hasPrefix(cookie.path)
            }
        }
    }

    /// Whether this app holds a browser session for `baseURL`.
    static func isSignedIn(_ baseURL: String) -> Bool {
        guard let url = URL(string: baseURL + "/") else { return false }
        return !cookies(for: url).isEmpty
    }

    /// Adds whatever proves who we are to `request`: the browser session's
    /// cookies when there is one, otherwise the server's bearer token.
    ///
    /// Never both. IAP reads an `Authorization` header before any cookie and
    /// rejects a bearer that is not a Google token, so sending the Loom token
    /// alongside the cookie would lock us out. The Loom behind such a proxy
    /// trusts the proxy's own signed header instead.
    static func authorize(_ request: inout URLRequest) {
        if LoomSettings.googleSignIn, let url = request.url {
            let session = cookies(for: url)
            if !session.isEmpty {
                request.httpShouldHandleCookies = false
                for (name, value) in HTTPCookie.requestHeaderFields(with: session) {
                    request.setValue(value, forHTTPHeaderField: name)
                }
                return
            }
        }
        let token = LoomSettings.token
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    /// True when `response` is the proxy asking for a sign-in rather than
    /// Loom answering: a redirect followed to Google's sign-in page, or IAP's
    /// own refusal.
    static func needsSignIn(_ response: URLResponse?) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        if let host = http.url?.host?.lowercased(),
           host == "accounts.google.com" || host.hasSuffix(".accounts.google.com") {
            return true
        }
        if http.statusCode == 401 || http.statusCode == 403,
           http.value(forHTTPHeaderField: "X-Goog-IAP-Generated-Response")?.lowercased() == "true" {
            return true
        }
        return false
    }

    /// Called wherever a response is checked: starts a quiet renewal when the
    /// proxy wants a sign-in. Returns whether it did.
    @discardableResult
    static func noteResponse(_ response: URLResponse?) -> Bool {
        guard LoomSettings.googleSignIn, needsSignIn(response) else { return false }
        Task { @MainActor in BrowserSignIn.shared.renew() }
        return true
    }
}

/// The web view the sign-in happens in, and the window it is shown in when a
/// person has to take part.
///
/// Renewal is quiet first: the web view keeps Google's own session in WebKit's
/// default store, so once signed in, an expired proxy cookie is usually
/// replaced by loading the server again without anyone seeing it. Only when
/// that lands on a page asking for input does the window appear.
@MainActor
final class BrowserSignIn: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver, NSWindowDelegate {
    static let shared = BrowserSignIn()

    /// Posted when a sign-in or renewal has put fresh cookies in place.
    static let didSignIn = Notification.Name("com.loom.desktop.browser-signed-in")

    private var webView: WKWebView?
    private var window: NSWindow?
    private var targetHost = ""
    private var inFlight = false
    private var interactive = false
    private var lastRenewal = Date.distantPast
    private var windowClosedAt = Date.distantPast
    private var revealTimer: Timer?

    /// Google refuses to sign in inside a web view it recognises as embedded,
    /// so it is shown the user agent of the Safari this web view is.
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private var cookieStore: WKHTTPCookieStore { WKWebsiteDataStore.default().httpCookieStore }

    /// At launch: pick up a session left by an earlier run, and follow the
    /// cookie store from here on.
    func start() {
        cookieStore.add(self)
        harvest()
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in self.harvest() }
    }

    private func harvest(then done: (() -> Void)? = nil) {
        cookieStore.getAllCookies { cookies in
            // Google's own cookies stay in WebKit: only the server's host is
            // ever matched when a request is made, but they have no business
            // in this process's memory either.
            let kept = cookies.filter { !$0.domain.lowercased().contains("google.com") }
            BrowserAuth.setCookies(kept)
            done?()
        }
    }

    /// Show the sign-in window for `baseURL` (the Settings button).
    func signIn(baseURL: String) {
        begin(baseURL: baseURL, interactive: true)
    }

    /// Quietly renew the current server's session. Rate-limited: every failing
    /// request calls this, and one renewal answers them all.
    func renew() {
        guard LoomSettings.googleSignIn, !inFlight, Date().timeIntervalSince(lastRenewal) > 20 else { return }
        begin(baseURL: LoomSettings.baseURL, interactive: false)
    }

    private func begin(baseURL: String, interactive: Bool) {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: trimmed + "/api/projects"), let host = url.host else { return }
        targetHost = host.lowercased()
        inFlight = true
        lastRenewal = Date()
        self.interactive = interactive
        let view = webView ?? makeWebView()
        view.load(URLRequest(url: url))
        revealTimer?.invalidate()
        if interactive {
            showWindow()
        } else {
            // Still away from the server after a while: Google wants a person.
            // Not if they closed the window a moment ago — that was an answer.
            revealTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.inFlight,
                          Date().timeIntervalSince(self.windowClosedAt) > 300 else { return }
                    self.showWindow()
                }
            }
        }
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: config)
        view.customUserAgent = Self.userAgent
        view.navigationDelegate = self
        webView = view
        return view
    }

    private func showWindow() {
        guard let view = webView else { return }
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Sign in to Loom"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.contentView = view
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            // Closed by the person while a sign-in was still pending (closing
            // it ourselves on success is not a refusal).
            if self.inFlight { self.windowClosedAt = Date() }
            self.inFlight = false
            self.revealTimer?.invalidate()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.arrived(at: webView.url) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.arrived(at: webView.url) }
    }

    /// Back on the server's own host means the proxy let us through and has
    /// set its cookie: take it, and stand the web view down.
    private func arrived(at url: URL?) {
        guard inFlight, url?.host?.lowercased() == targetHost else { return }
        inFlight = false
        revealTimer?.invalidate()
        harvest { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.webView?.loadHTMLString("", baseURL: nil)
                if self.window?.isVisible == true {
                    self.window?.close()
                }
                NotificationCenter.default.post(name: Self.didSignIn, object: nil)
            }
        }
    }
}
