import Foundation
import Darwin

/// One usage row as it arrives from the exporter. Decoded defensively — the `/api/oauth/usage`
/// schema has not been verified against a live response, so anything malformed is dropped rather
/// than trusted.
struct UsageRow: Decodable {
    let title: String
    let percent: Int
    let resetsAt: TimeInterval?   // epoch seconds, or nil when the response omits it
}

private struct UsageMessage: Decodable {
    let v: Int
    let updatedAt: TimeInterval
    let rows: [UsageRow]
}

/// The loopback server. The widget owns the socket because it is the stable process (a
/// LaunchAgent); the exporter connects and pushes one NDJSON line per update. Only numbers and
/// times cross the wire, never a token, and nothing is written to disk.
///
/// One exporter at a time is expected. If it disconnects (Claude quit, or the patch was removed)
/// the widget is told so it can mark the last values stale.
final class UsageBridge {
    /// Fired on the main queue with fresh, valid data.
    var onData: (([UsageRow], TimeInterval) -> Void)?
    /// Fired on the main queue when the exporter disconnects.
    var onDisconnect: (() -> Void)?

    private let queue = DispatchQueue(label: "ai.yahelh.usage-bridge")

    func start() {
        queue.async { [weak self] in self?.serve() }
    }

    private func serve() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = BridgeProtocol.port.bigEndian
        addr.sin_addr.s_addr = inet_addr(BridgeProtocol.host)   // 127.0.0.1 — loopback only

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else { close(fd); return }

        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            handle(client)   // blocks until this exporter disconnects
        }
    }

    private func handle(_ fd: Int32) {
        defer {
            close(fd)
            DispatchQueue.main.async { [weak self] in self?.onDisconnect?() }
        }

        var buffer = Data()
        var handshakeDone = false
        var chunk = [UInt8](repeating: 0, count: 4096)

        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])

            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let line = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty
                else { continue }

                if !handshakeDone {
                    guard line == BridgeProtocol.magic else { return }  // unknown peer → drop
                    handshakeDone = true
                    continue
                }
                process(line)
            }

            if buffer.count > 1_000_000 { return }   // runaway guard
        }
    }

    private func process(_ line: String) {
        guard let data = line.data(using: .utf8),
              let msg = try? JSONDecoder().decode(UsageMessage.self, from: data)
        else { return }   // parse defensively; ignore anything we don't understand
        DispatchQueue.main.async { [weak self] in self?.onData?(msg.rows, msg.updatedAt) }
    }
}
