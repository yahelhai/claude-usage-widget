import Foundation

/// One usage row. Decoded defensively — the `/api/oauth/usage` schema has not been verified
/// against a live response, so anything malformed is dropped rather than trusted.
struct UsageRow {
    let title: String
    let percent: Int
    let resetsAt: TimeInterval?   // epoch seconds, or nil
}

/// Fetches usage without patching Claude. Every poll it reads Claude Code's existing OAuth token
/// from the Keychain (read-only — never refreshed, so Claude Code's refresh token is never rotated),
/// calls `GET /api/oauth/usage`, and maps the response to the three rows the widget draws.
///
/// The token is read by spawning the stable, Apple-signed `/usr/bin/security` binary rather than
/// reading the Keychain from this ad-hoc-signed app directly: that way the one-time "Always Allow"
/// grant attaches to `security` and survives widget rebuilds.
final class UsageFetcher {
    /// Fired on the main queue with fresh rows.
    var onData: (([UsageRow]) -> Void)?
    /// Fired on the main queue when no fresh data is available (expired token, 401, network error).
    var onStale: (() -> Void)?

    private let keychainService = "Claude Code-credentials"
    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let pollInterval: TimeInterval = 60
    private var timer: Timer?
    private let session = URLSession(configuration: .ephemeral)

    func start() {
        pollNow()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollNow()
        }
    }

    func pollNow() {
        guard let token = readAccessToken() else {
            DispatchQueue.main.async { [weak self] in self?.onStale?() }
            return
        }
        fetch(token: token)
    }

    // MARK: - Keychain (read-only)

    private func readAccessToken() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-w", "-s", keychainService]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }   // denied / not found

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }

        // Never refresh: if the access token has expired, skip the call and let the widget go stale
        // until Claude Code refreshes it during normal use.
        if let expMs = oauth["expiresAt"] as? Double {
            let expSec = expMs > 1e12 ? expMs / 1000 : expMs
            if Date().timeIntervalSince1970 >= expSec { return nil }
        }
        return token
    }

    // MARK: - API

    private func fetch(token: String) {
        var req = URLRequest(url: usageURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        session.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            guard err == nil,
                  let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let data else {
                DispatchQueue.main.async { self.onStale?() }   // 401 etc. → stale, silent
                return
            }
            let rows = Self.mapRows(data)
            DispatchQueue.main.async {
                if rows.isEmpty { self.onStale?() } else { self.onData?(rows) }
            }
        }.resume()
    }

    // MARK: - Defensive mapping

    /// Map the response to the widget's rows. Tolerates a bare array or a wrapper object, matches
    /// kinds loosely, and orders the rows to match the reference panel (5-hour, weekly, per-model).
    static func mapRows(_ data: Data) -> [UsageRow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let list: [[String: Any]]
        if let arr = root as? [[String: Any]] {
            list = arr
        } else if let obj = root as? [String: Any] {
            list = (obj["utilizations"] ?? obj["rows"] ?? obj["data"]) as? [[String: Any]] ?? []
        } else {
            list = []
        }

        var ranked: [(rank: Int, row: UsageRow)] = []
        for e in list {
            let kind = ((e["kind"] as? String) ?? (e["type"] as? String) ?? "").lowercased()
            guard let percent = clampPct(e["percent"] ?? e["utilization"]) else { continue }
            let resetsAt = toEpoch(e["resets_at"] ?? e["resetsAt"])

            if kind.contains("hour") {
                ranked.append((0, UsageRow(title: "5-hour limit", percent: percent, resetsAt: resetsAt)))
            } else if kind.contains("scoped") {
                ranked.append((2, UsageRow(title: "Weekly · \(scopeName(e))", percent: percent, resetsAt: resetsAt)))
            } else if kind.contains("week") {
                ranked.append((1, UsageRow(title: "Weekly · all models", percent: percent, resetsAt: resetsAt)))
            }
        }
        return ranked.sorted { $0.rank < $1.rank }.map(\.row)
    }

    private static func scopeName(_ e: [String: Any]) -> String {
        if let scope = e["scope"] as? [String: Any] {
            if let model = scope["model"] as? [String: Any], let n = model["display_name"] as? String { return n }
            if let n = scope["display_name"] as? String { return n }
        }
        return "model"
    }

    private static func clampPct(_ v: Any?) -> Int? {
        let d: Double
        if let n = v as? Double { d = n }
        else if let n = v as? Int { d = Double(n) }
        else if let s = v as? String, let n = Double(s) { d = n }
        else { return nil }
        return min(100, max(0, Int(d.rounded())))
    }

    private static func toEpoch(_ v: Any?) -> TimeInterval? {
        if let n = v as? Double { return n > 1e12 ? n / 1000 : n }
        if let n = v as? Int { let d = Double(n); return d > 1e12 ? d / 1000 : d }
        if let s = v as? String {
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = withFraction.date(from: s) { return d.timeIntervalSince1970 }
            let plain = ISO8601DateFormatter()
            if let d = plain.date(from: s) { return d.timeIntervalSince1970 }
        }
        return nil
    }
}
