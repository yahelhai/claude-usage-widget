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

    /// Why the widget is showing what it is showing. Distinguishing these matters: a retry fixes
    /// `.unreachable`, but nothing except signing in fixes `.signedOut`, so the UI must not offer
    /// the same remedy for both.
    /// Conforms to `Error` only so `readAccessToken()` can return it as a `Result` failure.
    enum Status: Equatable, Error {
        case ok
        case signedOut              // token empty, missing, or expired → retrying cannot help
        case unreachable(String)    // transport error or non-200 → retrying may help
        case denied                 // `security` refused: the Keychain prompt was denied
    }

    /// Fired on the main queue with fresh rows (always paired with a `.ok` status).
    var onData: (([UsageRow]) -> Void)?
    /// Fired on the main queue whenever the status changes.
    var onStatus: ((Status) -> Void)?
    /// Fired on the main queue around a poll, so the refresh control can dim while in flight.
    var onRefreshing: ((Bool) -> Void)?

    private(set) var status: Status = .ok

    private let keychainService = "Claude Code-credentials"
    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private var timer: Timer?
    private var unreachableAttempts = 0
    private var inFlight = false
    private let session = URLSession(configuration: .ephemeral)

    // Poll cadence per state. Signed out is polled briskly because the check is local and free:
    // the moment the user runs `claude auth login`, the widget recovers on its own.
    private static let okInterval: TimeInterval = 60
    private static let signedOutInterval: TimeInterval = 10
    private static let unreachableBackoff: [TimeInterval] = [15, 30, 60]

    func start() {
        pollNow()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func pollNow() {
        guard !inFlight else { return }

        switch readAccessToken() {
        case .success(let token):
            setRefreshing(true)
            fetch(token: token)
        case .failure(let failure):
            // No network call: there is nothing to authenticate with.
            update(status: failure)
            scheduleNext()
        }
    }

    // MARK: - Status plumbing

    private func update(status newStatus: Status) {
        if case .unreachable = newStatus {
            unreachableAttempts += 1
        } else {
            unreachableAttempts = 0
        }
        guard newStatus != status else { return }
        status = newStatus
        DispatchQueue.main.async { [weak self] in self?.onStatus?(newStatus) }
    }

    private func setRefreshing(_ value: Bool) {
        inFlight = value
        DispatchQueue.main.async { [weak self] in self?.onRefreshing?(value) }
    }

    /// Reschedules the timer for the current state. Called after every poll, so a state change
    /// takes effect on the next tick rather than waiting out the old interval.
    private func scheduleNext() {
        let delay: TimeInterval
        switch status {
        case .ok:
            delay = Self.okInterval
        case .signedOut, .denied:
            delay = Self.signedOutInterval
        case .unreachable:
            let i = min(unreachableAttempts, Self.unreachableBackoff.count) - 1
            delay = Self.unreachableBackoff[max(0, i)]
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                self?.pollNow()
            }
        }
    }

    // MARK: - Keychain (read-only)

    /// Returns the access token, or the status explaining why there isn't one. The four failure
    /// modes used to collapse into `nil`, which is what made the UI unable to say anything useful.
    private func readAccessToken() -> Result<String, Status> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-w", "-s", keychainService]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return .failure(.denied) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        // 44 is "item not found" (signed out); anything else non-zero is an access refusal.
        guard proc.terminationStatus == 0 else {
            return .failure(proc.terminationStatus == 44 ? .signedOut : .denied)
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return .failure(.signedOut) }

        // Never refresh: if the access token has expired, skip the call and wait for Claude Code to
        // refresh it during normal use. `expiresAt == 0` means "no live session", not "expired in
        // 1970" — both land on .signedOut, which is the honest answer either way.
        if let expMs = oauth["expiresAt"] as? Double {
            let expSec = expMs > 1e12 ? expMs / 1000 : expMs
            if expSec <= 0 || Date().timeIntervalSince1970 >= expSec { return .failure(.signedOut) }
        }
        return .success(token)
    }

    // MARK: - API

    private func fetch(token: String) {
        var req = URLRequest(url: usageURL)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        session.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            defer {
                self.setRefreshing(false)
                self.scheduleNext()
            }

            if let err {
                self.update(status: .unreachable(Self.shortReason(err)))
                return
            }
            guard let http = resp as? HTTPURLResponse, let data else {
                self.update(status: .unreachable("no response"))
                return
            }
            // A 401 here means the token was accepted by our expiry check but rejected upstream —
            // the session is gone, so it is a sign-out, not a transport problem.
            guard http.statusCode != 401, http.statusCode != 403 else {
                self.update(status: .signedOut)
                return
            }
            guard http.statusCode == 200 else {
                self.update(status: .unreachable("HTTP \(http.statusCode)"))
                return
            }

            let rows = Self.mapRows(data)
            guard !rows.isEmpty else {
                self.update(status: .unreachable("no rows in response"))
                return
            }
            self.update(status: .ok)
            DispatchQueue.main.async { self.onData?(rows) }
        }.resume()
    }

    private static func shortReason(_ error: Error) -> String {
        let ns = error as NSError
        switch ns.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "offline"
        case NSURLErrorTimedOut:
            return "timed out"
        default:
            return "network error"
        }
    }

    // MARK: - Defensive mapping

    /// Map the response to the widget's rows. The live payload is an object with a `limits` array of
    /// `{ kind, group, percent, resets_at, scope }`; we route by kind/group/scope and order the rows
    /// to match the reference panel (5-hour, weekly all-models, weekly per-model). Tolerates a bare
    /// array or other wrapper keys defensively in case the shape shifts.
    static func mapRows(_ data: Data) -> [UsageRow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let list: [[String: Any]]
        if let arr = root as? [[String: Any]] {
            list = arr
        } else if let obj = root as? [String: Any] {
            list = (obj["limits"] ?? obj["utilizations"] ?? obj["rows"] ?? obj["data"])
                as? [[String: Any]] ?? []
        } else {
            list = []
        }

        var ranked: [(rank: Int, row: UsageRow)] = []
        for e in list {
            let kind = ((e["kind"] as? String) ?? (e["type"] as? String) ?? "").lowercased()
            let group = (e["group"] as? String ?? "").lowercased()
            guard let percent = clampPct(e["percent"] ?? e["utilization"]) else { continue }
            let resetsAt = toEpoch(e["resets_at"] ?? e["resetsAt"])

            if kind.contains("session") || group == "session" || kind.contains("hour") {
                ranked.append((0, UsageRow(title: "5-hour limit", percent: percent, resetsAt: resetsAt)))
            } else if let name = scopeDisplayName(e) {   // any entry carrying a model scope
                ranked.append((2, UsageRow(title: "Weekly · \(name)", percent: percent, resetsAt: resetsAt)))
            } else if kind.contains("week") || group == "weekly" {
                ranked.append((1, UsageRow(title: "Weekly · all models", percent: percent, resetsAt: resetsAt)))
            }
        }
        return ranked.sorted { $0.rank < $1.rank }.map(\.row)
    }

    /// The display name of an entry's model scope, or nil when the entry isn't model-scoped.
    private static func scopeDisplayName(_ e: [String: Any]) -> String? {
        guard let scope = e["scope"] as? [String: Any] else { return nil }
        if let model = scope["model"] as? [String: Any], let n = model["display_name"] as? String { return n }
        if let n = scope["display_name"] as? String { return n }
        return nil
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
            // The API sends microsecond precision ("...00.609406+00:00") which ISO8601DateFormatter
            // won't parse. Strip fractional seconds and parse at whole-second precision.
            let cleaned = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
            let iso = ISO8601DateFormatter()
            if let d = iso.date(from: cleaned) { return d.timeIntervalSince1970 }
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = withFraction.date(from: s) { return d.timeIntervalSince1970 }
        }
        return nil
    }
}
