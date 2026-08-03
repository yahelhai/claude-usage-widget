import AppKit
import CoreGraphics

/// Decides whether a Claude Desktop window is actually visible on screen right now.
///
/// This is deliberately *not* "is Claude the frontmost app" — the widget must stay up while
/// you work in another app on another display, and must disappear only when Claude is truly
/// hidden: fully covered by another window, minimised, or on a Space you aren't looking at.
///
/// We read window metadata only (owner, bounds, layer). Window *titles* would require the
/// Screen Recording permission; we never ask for them, so this needs no permission at all.
enum ClaudeVisibility {
    static let bundleID = "com.anthropic.claudefordesktop"

    /// A three-pixel sliver peeking out from behind another window is technically visible but
    /// not meaningfully so. A window counts as visible once this fraction of it is unobstructed.
    static var minVisibleFraction = 0.02

    struct Result {
        /// The verdict the widget acts on.
        let visible: Bool
        /// Largest unobstructed fraction across Claude's windows, for diagnostics.
        let bestFraction: Double
        /// How many on-screen Claude windows were considered.
        let windowCount: Int
    }

    static func probe() -> Result {
        let pids = Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .map(\.processIdentifier)
        )
        guard !pids.isEmpty else { return Result(visible: false, bestFraction: 0, windowCount: 0) }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return Result(visible: false, bestFraction: 0, windowCount: 0)
        }

        // Front-to-back. Layer 0 is ordinary app windows: that skips the menu bar, the Dock,
        // and — usefully — our own floating panel, which would otherwise look like an occluder.
        let windows: [(pid: pid_t, rect: CGRect)] = raw.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  !rect.isEmpty
            else { return nil }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0.05 else { return nil }
            return (pid, rect)
        }

        var bestFraction = 0.0
        var claudeWindows = 0

        for (index, window) in windows.enumerated() where pids.contains(window.pid) {
            claudeWindows += 1
            let area = window.rect.width * window.rect.height
            guard area > 0 else { continue }

            // Only windows in front of this one can cover it. Another Claude window sitting on
            // top doesn't count — that window is itself visible, so Claude is still on screen.
            let occluders = windows[..<index]
                .filter { !pids.contains($0.pid) }
                .map(\.rect)

            let fraction = visibleArea(of: window.rect, under: occluders) / area
            bestFraction = max(bestFraction, fraction)
            if bestFraction >= 1 { break }
        }

        return Result(
            visible: claudeWindows > 0 && bestFraction >= minVisibleFraction,
            bestFraction: bestFraction,
            windowCount: claudeWindows
        )
    }

    static func isVisible() -> Bool { probe().visible }

    /// Area of `rect` left uncovered after punching every occluder out of it.
    private static func visibleArea(of rect: CGRect, under occluders: [CGRect]) -> Double {
        var remaining = [rect]
        for occluder in occluders {
            guard !remaining.isEmpty else { return 0 }
            remaining = remaining.flatMap { subtract(occluder, from: $0) }
        }
        return remaining.reduce(0) { $0 + Double($1.width * $1.height) }
    }

    /// Splits `rect` into the pieces that `cutter` does not cover (up to four bands around it).
    private static func subtract(_ cutter: CGRect, from rect: CGRect) -> [CGRect] {
        let overlap = rect.intersection(cutter)
        guard !overlap.isNull, !overlap.isEmpty else { return [rect] }

        var pieces: [CGRect] = []
        if overlap.minY > rect.minY {
            pieces.append(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY))
        }
        if overlap.maxY < rect.maxY {
            pieces.append(CGRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY))
        }
        if overlap.minX > rect.minX {
            pieces.append(CGRect(x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height))
        }
        if overlap.maxX < rect.maxX {
            pieces.append(CGRect(x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height))
        }
        return pieces.filter { $0.width > 0.5 && $0.height > 0.5 }
    }
}
