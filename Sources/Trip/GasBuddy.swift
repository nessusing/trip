import Foundation
import Observation
import UIKit
import WebKit

// GasBuddy's unofficial GraphQL API, behind Cloudflare. See SPEC.md「油价」.

enum GasBuddyError: Error, CustomStringConvertible {
    /// Cloudflare wants a human to click the Turnstile box.
    case challenge
    case noToken
    /// Cloudflare's per-IP rate limit; `retryAfter` seconds (600 when measured).
    case rateLimited(retryAfter: TimeInterval)
    /// Our own limit: too many requests in the last minute, or too soon after the last.
    case throttled
    /// Paused after a rate limit.
    case paused(until: Date)
    case http(Int)
    case bad(String)

    var description: String {
        switch self {
        case .challenge: "Cloudflare challenge"
        case .noToken: "no CSRF token"
        case .rateLimited(let seconds): "rate limited for \(Int(seconds)) s"
        case .throttled: "throttled"
        case .paused: "paused"
        case .http(let code): "HTTP \(code)"
        case .bad(let detail): detail
        }
    }
}

/// One way of reaching the GraphQL endpoint.
@MainActor
protocol GasBuddyPath: AnyObject {
    var name: String { get }
    /// The first page of stations around a point.
    func page(lat: Double, lng: Double) async throws -> GBPage
}

enum GasBuddyAPI {
    static let home = URL(string: "https://www.gasbuddy.com/home")!
    static let graphQL = URL(string: "https://www.gasbuddy.com/graphql")!

    static let query = """
        query LocationBySearchTerm($lat: Float, $lng: Float, $maxAge: Int) {
          locationBySearchTerm(lat: $lat, lng: $lng, priority: "locality") {
            stations(lat: $lat, lng: $lng, maxAge: $maxAge, priority: "locality") {
              cursor { next }
              results {
                id name latitude longitude priceUnit
                address { line1 locality }
                brands { name }
                hours { openingHours }
                prices { fuelProduct credit { price postedTime } cash { price postedTime } }
              }
            }
          }
        }
        """

    static func body(lat: Double, lng: Double) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "operationName": "LocationBySearchTerm",
            "query": query,
            "variables": ["maxAge": 0, "lat": lat, "lng": lng],
        ] as [String: Any])
    }

    /// Turns a response into a page or the right error.
    static func page(status: Int, retryAfter: String?, payload: Data) throws -> GBPage {
        switch status {
        case 200:
            do { return try GBPage.decode(payload) } catch { throw GasBuddyError.bad("decode: \(error)") }
        case 429:
            throw GasBuddyError.rateLimited(retryAfter: retryAfter.flatMap(TimeInterval.init) ?? 600)
        default:
            throw GasBuddyError.http(status)
        }
    }
}

// MARK: - Path A: hidden web view

/// A hidden WKWebView that loads gasbuddy.com/home (a real WebKit, so Cloudflare's
/// bot check passes) and runs fetch('/graphql') inside the page, where the cookies
/// and `window.gbcsrf` already are.
@MainActor
final class GasBuddyWeb: GasBuddyPath {
    let name = "WebView"
    let webView: WKWebView
    private var needsReload = true

    init() {
        let config = WKWebViewConfiguration()
        // Keep Cloudflare's clearance cookie across launches.
        config.websiteDataStore = .default()
        // WKWebView's default user agent has no "Version/… Safari/…", unlike Safari's.
        let major = UIDevice.current.systemVersion.split(separator: ".").first ?? "18"
        config.applicationNameForUserAgent = "Version/\(major).0 Mobile/15E148 Safari/604.1"
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: config)
    }

    func page(lat: Double, lng: Double) async throws -> GBPage {
        try await ensureToken()
        let body = String(decoding: try GasBuddyAPI.body(lat: lat, lng: lng), as: UTF8.self)
        let js = """
            const r = await fetch('/graphql', {
                method: 'POST', credentials: 'include',
                headers: {'Content-Type': 'application/json', 'apollo-require-preflight': 'true',
                          'gbcsrf': window.gbcsrf || ''},
                body: body});
            return JSON.stringify({status: r.status, retryAfter: r.headers.get('retry-after'),
                                   text: await r.text()});
            """
        let raw = try await webView.callAsyncJavaScript(js, arguments: ["body": body], contentWorld: .page)
        guard let text = raw as? String,
              let reply = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let status = reply["status"] as? Int, let payload = reply["text"] as? String
        else { throw GasBuddyError.bad("unexpected reply from page") }
        // 401/403: token or clearance is stale. A 429 is per IP; the token is fine.
        if status == 401 || status == 403 { needsReload = true }
        return try GasBuddyAPI.page(status: status, retryAfter: reply["retryAfter"] as? String,
                                    payload: Data(payload.utf8))
    }

    /// After the user has had the page on screen (to solve a challenge).
    func pageMayBeReady() async -> Bool {
        if let token = try? await currentToken(), !token.isEmpty {
            needsReload = false
            return true
        }
        return false
    }

    private func ensureToken() async throws {
        attachHidden()
        if !needsReload, let token = try? await currentToken(), !token.isEmpty { return }
        webView.load(URLRequest(url: GasBuddyAPI.home))
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(300))
            if let token = try? await currentToken(), !token.isEmpty {
                needsReload = false
                return
            }
        }
        throw webView.title == "Just a moment..." ? GasBuddyError.challenge : GasBuddyError.noToken
    }

    private func currentToken() async throws -> String? {
        try await webView.evaluateJavaScript("window.gbcsrf || ''") as? String
    }

    /// A web view outside any window may get its timers throttled, so keep it in the
    /// window, behind everything and invisible.
    func attachHidden() {
        guard webView.window == nil,
              let window = UIApplication.shared.connectedScenes
                  .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
        else { return }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        window.insertSubview(webView, at: 0)
    }

    /// Shows the page to the user (to click a Turnstile box) inside `container`.
    func show(in container: UIView) {
        webView.removeFromSuperview()
        webView.alpha = 1
        webView.isUserInteractionEnabled = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        if webView.url == nil { webView.load(URLRequest(url: GasBuddyAPI.home)) }
    }
}

// MARK: - Path C: plain URLSession

/// Fetches /home for the token and posts to /graphql directly. Cloudflare usually
/// refuses this (curl gets 403), but it costs nothing to try.
@MainActor
final class GasBuddyDirect: GasBuddyPath {
    let name = "Direct"
    private var token: String?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        return URLSession(configuration: config)
    }()

    func page(lat: Double, lng: Double) async throws -> GBPage {
        let token = try await currentToken()
        var request = URLRequest(url: GasBuddyAPI.graphQL)
        request.httpMethod = "POST"
        request.httpBody = try GasBuddyAPI.body(lat: lat, lng: lng)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "apollo-require-preflight")
        request.setValue(token, forHTTPHeaderField: "gbcsrf")
        request.setValue("https://www.gasbuddy.com", forHTTPHeaderField: "Origin")
        request.setValue(GasBuddyAPI.home.absoluteString, forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 || status == 403 { self.token = nil }
        return try GasBuddyAPI.page(status: status, retryAfter: http?.value(forHTTPHeaderField: "Retry-After"),
                                    payload: data)
    }

    private func currentToken() async throws -> String {
        if let token { return token }
        let (data, response) = try await session.data(from: GasBuddyAPI.home)
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200: break
        case 429:
            throw GasBuddyError.rateLimited(
                retryAfter: http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 600)
        case let status: throw GasBuddyError.http(status)
        }
        let html = String(decoding: data, as: UTF8.self)
        let marker = "window.gbcsrf"
        guard let at = html.range(of: marker)?.upperBound,
              let open = html[at...].firstIndex(where: { $0 == "\"" || $0 == "'" })
        else { throw GasBuddyError.noToken }
        let quote = html[open]
        let rest = html[html.index(after: open)...]
        guard let close = rest.firstIndex(of: quote), close > rest.startIndex else { throw GasBuddyError.noToken }
        let value = String(rest[..<close])
        token = value
        return value
    }
}

// MARK: - The chain

/// Tries the paths in order (starting from the one that last worked), keeps our own
/// request rate under Cloudflare's limit, and pauses everything after a 429.
@MainActor
@Observable
final class GasBuddyClient {
    /// All paths together: at most this many requests a minute (12/min measured safe)…
    static let perMinute = 6
    /// …and at least this long between two (bursts are what got us banned).
    static let minGap: TimeInterval = 3
    /// How long the path that worked stays first in line.
    static let stickyFor: TimeInterval = 6 * 3600

    let web = GasBuddyWeb()
    @ObservationIgnored private lazy var paths: [GasBuddyPath] = [web, GasBuddyDirect()]

    /// Which path last worked, and when.
    private(set) var lastSuccess: (path: String, at: Date)?
    private(set) var pausedUntil: Date?
    /// Set when the web view hit a Turnstile box; cleared when a request works.
    private(set) var needsHuman = false
    private(set) var lastError: String?

    @ObservationIgnored private var sticky: (index: Int, since: Date)?
    @ObservationIgnored private var sent: [Date] = []

    func isPaused(now: Date = .now) -> Bool { pausedUntil.map { $0 > now } ?? false }

    /// How long until a request would be let through; 0 if now.
    func wait(now: Date = .now) -> TimeInterval {
        if let pausedUntil, pausedUntil > now { return pausedUntil.timeIntervalSince(now) }
        sent.removeAll { now.timeIntervalSince($0) > 60 }
        var wait: TimeInterval = 0
        if sent.count >= Self.perMinute, let oldest = sent.first { wait = 60 - now.timeIntervalSince(oldest) }
        if let last = sent.last { wait = max(wait, Self.minGap - now.timeIntervalSince(last)) }
        return max(0, wait)
    }

    /// The first page of stations around a point.
    func stations(lat: Double, lng: Double) async throws -> [GBStation] {
        if let pausedUntil, pausedUntil > .now { throw GasBuddyError.paused(until: pausedUntil) }
        guard wait() == 0 else { throw GasBuddyError.throttled }

        var start = 0
        if let sticky, Date.now.timeIntervalSince(sticky.since) < Self.stickyFor { start = sticky.index }
        var lastError: Error = GasBuddyError.noToken
        for index in start..<paths.count {
            let path = paths[index]
            sent.append(.now)
            do {
                let page = try await path.page(lat: lat, lng: lng)
                if sticky?.index != index { sticky = (index, .now) }
                lastSuccess = (path.name, .now)
                needsHuman = false
                self.lastError = nil
                return page.results
            } catch GasBuddyError.rateLimited(let seconds) {
                // Per IP, so the other paths here would hit it too. (Path B, the home
                // server, would have its own IP; it isn't built yet.)
                pausedUntil = Date.now.addingTimeInterval(seconds)
                self.lastError = "Rate limited"
                throw GasBuddyError.rateLimited(retryAfter: seconds)
            } catch {
                if path === web, case GasBuddyError.challenge = error { needsHuman = true }
                lastError = error
                self.lastError = "\(path.name): \(error)"
            }
        }
        // Everything failed: start from the top next time.
        sticky = nil
        throw lastError
    }

    /// After the user closed the GasBuddy page they may have solved a challenge on.
    func pageClosed() async {
        web.attachHidden()
        if await web.pageMayBeReady() {
            needsHuman = false
            sticky = (0, .now)
        }
    }
}
