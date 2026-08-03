import AppKit
import Darwin

// Standalone check for the visibility logic, plus a mock feeder for the widget bridge.
//
//   probe [seconds]      watch the visibility verdict change (default 5s)
//   probe --dump         print the current window stack once
//   probe feed           push fixed mock rows to the widget and hold the connection open
//   probe feed --animate push mock rows that climb over time (for testing the bar states)

if CommandLine.arguments.contains("feed") {
    runFeeder(animate: CommandLine.arguments.contains("--animate"))
    exit(0)
}

if CommandLine.arguments.contains("--dump") {
    let pids = Set(
        NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeVisibility.bundleID)
            .map(\.processIdentifier)
    )
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    print("front-to-back, layer 0 only:")
    for info in raw {
        guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { continue }
        let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
        let mark = pids.contains(pid) ? "  <- CLAUDE" : ""
        print(String(format: "  %-22@ x=%.0f y=%.0f w=%.0f h=%.0f%@",
                     owner as NSString, rect.minX, rect.minY, rect.width, rect.height, mark))
    }
    let result = ClaudeVisibility.probe()
    print(String(format: "verdict: visible=%@ bestFraction=%.3f windows=%d",
                 result.visible ? "YES" : "no", result.bestFraction, result.windowCount))
    exit(0)
}

let deadline = Date().addingTimeInterval(Double(CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 5))
var last = ""

while Date() < deadline {
    let result = ClaudeVisibility.probe()
    let line = String(
        format: "visible=%@  bestFraction=%.3f  claudeWindows=%d  frontmost=%@",
        result.visible ? "YES" : "no ",
        result.bestFraction,
        result.windowCount,
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
    )
    if line != last {
        print("[\(Date().formatted(date: .omitted, time: .standard))] \(line)")
        fflush(stdout)
        last = line
    }
    usleep(400_000)
}

// MARK: - Mock feeder

/// Connects to the widget's loopback bridge and pushes fake rows shaped exactly like the real
/// exporter's output, so the UI and behaviour can be verified before Claude is ever touched.
func runFeeder(animate: Bool) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { print("feed: socket() failed"); return }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = BridgeProtocol.port.bigEndian
    addr.sin_addr.s_addr = inet_addr(BridgeProtocol.host)

    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else {
        print("feed: connect failed — is the widget running?")
        close(fd)
        return
    }

    func send(_ s: String) {
        var line = s + "\n"
        _ = line.withUTF8 { write(fd, $0.baseAddress, $0.count) }
    }
    send(BridgeProtocol.magic)

    // Next Monday 5:00 AM, local time, matching the reference screenshot.
    var comps = DateComponents(); comps.weekday = 2; comps.hour = 5
    let mondayReset = Calendar.current
        .nextDate(after: Date(), matching: comps, matchingPolicy: .nextTime)
        .map { Int($0.timeIntervalSince1970) } ?? Int(Date().timeIntervalSince1970)

    var p5 = 0, pWeek = 7, pFable = 8
    print("feed: connected, pushing rows (Ctrl-C to stop)")
    while true {
        let now = Int(Date().timeIntervalSince1970)
        send("""
        {"v":1,"updatedAt":\(now),"rows":[\
        {"title":"5-hour limit","percent":\(p5),"resetsAt":null},\
        {"title":"Weekly · all models","percent":\(pWeek),"resetsAt":\(mondayReset)},\
        {"title":"Weekly · Fable","percent":\(pFable),"resetsAt":\(mondayReset)}]}
        """)
        print("feed: 5h=\(p5)% week=\(pWeek)% fable=\(pFable)%")
        fflush(stdout)

        if animate {
            p5 = (p5 + 7) % 101
            pWeek = min(100, pWeek + 3)
            pFable = min(100, pFable + 5)
            usleep(1_500_000)
        } else {
            sleep(5)   // hold the connection open and keep the data fresh
        }
    }
}
