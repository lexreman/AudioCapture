import AppKit
import Observation

/// Is a newer version on GitHub? Asked only when Settings opens (at most once an hour while the app is open), never in the
/// background, and never with a notification: if there is one, Settings shows a row with a link to it.
/// The request carries nothing about the person; no cookies, no cache.
@MainActor @Observable
final class Updates {
    static let shared = Updates()
    struct Release: Equatable { let version: String; let page: URL }
    private(set) var available: Release?
    @ObservationIgnored private var lastCheck: Date?
    @ObservationIgnored private let endpoint = URL(string: "https://api.github.com/repos/lexreman/AudioCapture/releases/latest")!
    static let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    func check() {
        guard !testRun, lastCheck.map({ Date().timeIntervalSince($0) > 3600 }) ?? true else { return }
        lastCheck = Date()
        let endpoint = endpoint
        Task {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            var request = URLRequest(url: endpoint)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await URLSession(configuration: config).data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String, let page = (json["html_url"] as? String).flatMap(URL.init(string:))
            else { return }   // offline, not published yet, rate-limited: say nothing
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            available = Self.isNewer(version, than: Self.current) ? Release(version: version, page: page) : nil
        }
    }

    /// "1.2" > "1.1.9", "2" > "1.9", "1.0" == "1".
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// Development renders only.
    func _debugShow(_ release: Release?) { available = release }
}
