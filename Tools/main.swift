import AppKit

// Standalone check for the visibility logic, before any UI exists.
// Run it, then drag windows over Claude / minimise it / switch Spaces and watch the verdict.
//
//   probe [seconds]   watch the verdict change (default 5s)
//   probe --dump      print the current window stack once

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
