import AppKit

/// A single row as the widget draws it.
struct DisplayRow {
    let title: String
    let percent: Int
    let resetsAt: Date?
}

/// Draws the rows: title on the left, reset time + percentage on the right, a thin bar underneath.
/// Matches the usage panel in the reference screenshot. Below them sits a footer carrying the
/// freshness line and the refresh control.
final class RowsView: NSView {
    var rows: [DisplayRow] = [] { didSet { needsDisplay = true } }
    var status: UsageFetcher.Status = .ok { didSet { needsDisplay = true } }
    var lastUpdate: Date? { didSet { needsDisplay = true } }
    var isRefreshing = false { didSet { needsDisplay = true } }
    var placeholder: String? { didSet { needsDisplay = true } }

    /// Invoked when the refresh control is clicked.
    var onRefresh: (() -> Void)?

    /// Above 75% the bar turns amber, above 90% red. Set false to keep it always blue.
    var colourByLevel = true

    private var hoveringRefresh = false { didSet { needsDisplay = true } }

    static let width: CGFloat = 320
    static let rowHeight: CGFloat = 44
    static let padding: CGFloat = 14
    static let footerHeight: CGFloat = 24

    static func height(for count: Int) -> CGFloat {
        padding + CGFloat(max(count, 1)) * rowHeight + footerHeight + padding / 2
    }

    override var isFlipped: Bool { true }   // top-to-bottom layout

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        switch status {
        case .signedOut:
            drawMessage("Claude Code is signed out", command: "claude auth login")
        case .tokenExpired:
            // Reached only when automatic renewal failed; the session is still valid, so signing
            // in again would be the wrong advice.
            drawMessage("Token expired, renewing…", command: "claude mcp list")
        case .denied:
            drawMessage("Keychain access denied", command: nil,
                        hint: "Allow access to \(Self.keychainLabel), then refresh")
        case .ok, .unreachable, .rateLimited:
            drawRowsOrPlaceholder()
        }
        drawFooter()
        drawRefreshControl()
    }

    private func drawRowsOrPlaceholder() {
        guard !rows.isEmpty else {
            // Nothing cached yet. Only claim to be checking when we actually are — the footer
            // carries the reason in every other case, so this line stays neutral.
            let text: String
            if case .ok = status { text = placeholder ?? "" } else { text = "No data yet" }
            if !text.isEmpty { drawCentered(text, alpha: 0.5) }
            return
        }

        // Keep the last known numbers on screen while we can't refresh, but dimmed — the footer
        // says why. They are still the truth as of the timestamp, just not current.
        let dim: CGFloat = {
            switch status {
            case .unreachable, .rateLimited: return 0.4
            default: return 1.0
            }
        }()
        let pad = Self.padding
        var top = pad

        for (i, row) in rows.enumerated() {
            drawRow(row, atY: top, dim: dim)
            if i < rows.count - 1 {
                NSColor.white.withAlphaComponent(0.08 * dim).setStroke()
                let sep = NSBezierPath()
                sep.move(to: NSPoint(x: pad, y: top + Self.rowHeight))
                sep.line(to: NSPoint(x: bounds.width - pad, y: top + Self.rowHeight))
                sep.lineWidth = 1
                sep.stroke()
            }
            top += Self.rowHeight
        }
    }

    private func drawRow(_ row: DisplayRow, atY top: CGFloat, dim: CGFloat) {
        let pad = Self.padding
        let contentWidth = bounds.width - pad * 2

        let title = NSAttributedString(string: row.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85 * dim),
        ])
        title.draw(at: NSPoint(x: pad, y: top + 4))

        let pctStr = NSAttributedString(string: "\(row.percent)%", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7 * dim),
        ])
        let pctSize = pctStr.size()
        pctStr.draw(at: NSPoint(x: bounds.width - pad - pctSize.width, y: top + 5))

        if let resets = row.resetsAt {
            let s = NSAttributedString(string: "Resets " + Self.resetFormatter.string(from: resets),
                                       attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.45 * dim),
            ])
            let size = s.size()
            s.draw(at: NSPoint(x: bounds.width - pad - pctSize.width - 10 - size.width, y: top + 5))
        }

        let barY = top + Self.rowHeight - 15
        let barRect = NSRect(x: pad, y: barY, width: contentWidth, height: 3)
        NSColor.white.withAlphaComponent(0.12 * dim).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5).fill()

        let frac = max(0, min(1, CGFloat(row.percent) / 100))
        if frac > 0 {
            let fillRect = NSRect(x: pad, y: barY, width: max(3, contentWidth * frac), height: 3)
            barColour(for: row.percent).withAlphaComponent(dim).setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private func barColour(for percent: Int) -> NSColor {
        guard colourByLevel else { return Self.blue }
        if percent >= 90 { return Self.red }
        if percent >= 75 { return Self.amber }
        return Self.blue
    }

    /// The freshness line, bottom-left. This is the honest signal of how old the numbers are —
    /// it replaces the old "stale" badge, which said something was wrong but never what.
    private func drawFooter() {
        let text: String
        switch status {
        case .ok:
            text = lastUpdate.map { "Updated " + Self.clockFormatter.string(from: $0) } ?? ""
        case .unreachable(let reason):
            text = "Can't reach Anthropic · \(reason)"
        case .rateLimited:
            let stamp = lastUpdate.map { " · " + Self.clockFormatter.string(from: $0) } ?? ""
            text = "Rate limited, backing off\(stamp)"
        case .signedOut, .tokenExpired, .denied:
            text = ""
        }
        guard !text.isEmpty else { return }

        let s = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.35),
        ])
        s.draw(at: NSPoint(x: Self.padding, y: bounds.height - Self.footerHeight + 4))
    }

    /// A circular-arrow glyph, bottom-right. Always visible: a control that only appears when
    /// something breaks is a control nobody discovers.
    private func drawRefreshControl() {
        let alpha: CGFloat = isRefreshing ? 0.2 : (hoveringRefresh ? 0.75 : 0.35)
        let s = NSAttributedString(string: "↻", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        ])
        let size = s.size()
        let r = refreshRect
        s.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
    }

    private func drawMessage(_ title: String, command: String?, hint: String? = nil) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center

        let titleStr = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.8),
            .paragraphStyle: para,
        ])
        let bodyStr: NSAttributedString? = {
            if let command {
                return NSAttributedString(string: command, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: Self.blue.withAlphaComponent(0.9),
                    .paragraphStyle: para,
                ])
            }
            if let hint {
                return NSAttributedString(string: hint, attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.45),
                    .paragraphStyle: para,
                ])
            }
            return nil
        }()

        let contentWidth = bounds.width - Self.padding * 2
        let area = NSSize(width: contentWidth, height: 400)
        let titleH = titleStr.boundingRect(with: area, options: [.usesLineFragmentOrigin]).height
        let bodyH = bodyStr?.boundingRect(with: area, options: [.usesLineFragmentOrigin]).height ?? 0
        let gap: CGFloat = bodyStr == nil ? 0 : 8
        let usable = bounds.height - Self.footerHeight
        var y = (usable - (titleH + gap + bodyH)) / 2

        titleStr.draw(in: NSRect(x: Self.padding, y: y, width: contentWidth, height: titleH))
        y += titleH + gap
        bodyStr?.draw(in: NSRect(x: Self.padding, y: y, width: contentWidth, height: bodyH))
    }

    private func drawCentered(_ text: String, alpha: CGFloat) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let s = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
            .paragraphStyle: para,
        ])
        let size = s.boundingRect(with: NSSize(width: bounds.width - 28, height: 200),
                                  options: [.usesLineFragmentOrigin])
        let r = NSRect(x: 14, y: (bounds.height - Self.footerHeight - size.height) / 2,
                       width: bounds.width - 28, height: size.height)
        s.draw(in: r)
    }

    // MARK: - Refresh control interaction

    private var refreshRect: NSRect {
        NSRect(x: bounds.width - Self.padding - 16,
               y: bounds.height - Self.footerHeight + 2,
               width: 16, height: 16)
    }

    /// Generous target — the glyph is small, and the panel is a click-through-averse floating window.
    private var refreshHitRect: NSRect { refreshRect.insetBy(dx: -8, dy: -6) }

    /// Centre of the refresh control, in view coordinates. Used by the self-test to click exactly
    /// where the glyph is drawn, so drawing and hit-testing can't drift apart unnoticed.
    var refreshControlCenter: NSPoint { NSPoint(x: refreshRect.midX, y: refreshRect.midY) }

    /// The panel can never become key, so every click into it is a "first mouse" click, which
    /// AppKit swallows by default. Without this the refresh control would be permanently dead.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if refreshHitRect.contains(point) {
            if !isRefreshing { onRefresh?() }
            return   // consume, so isMovableByWindowBackground doesn't start dragging the panel
        }
        super.mouseDown(with: event)   // anywhere else keeps the drag-to-move behaviour
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: refreshHitRect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        hoveringRefresh = true
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        hoveringRefresh = false
        NSCursor.arrow.set()
    }

    // MARK: - Constants

    static let keychainLabel = "Claude Code-credentials"

    static let blue = NSColor(srgbRed: 0x3B / 255, green: 0x82 / 255, blue: 0xF6 / 255, alpha: 1)
    static let amber = NSColor(srgbRed: 0xF5 / 255, green: 0x9E / 255, blue: 0x0B / 255, alpha: 1)
    static let red = NSColor(srgbRed: 0xEF / 255, green: 0x44 / 255, blue: 0x44 / 255, alpha: 1)

    static let resetFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE h:mm a"   // e.g. "Mon 5:00 AM", local timezone
        return f
    }()

    static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

/// The floating panel. Borderless, non-activating, always on top, never steals focus, and doesn't
/// vanish in Mission Control. Its position is fixed wherever the user drags it and persists across
/// launches — it does not follow Claude's display.
final class WidgetPanel: NSPanel, NSWindowDelegate {
    let rowsView = RowsView()
    private let posKey = "widgetOriginV1"

    init() {
        let size = NSSize(width: RowsView.width, height: RowsView.height(for: 3))
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        delegate = self

        let container = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        container.material = .hudWindow
        container.state = .active
        container.blendingMode = .behindWindow
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        container.autoresizingMask = [.width, .height]

        rowsView.frame = container.bounds
        rowsView.autoresizingMask = [.width, .height]
        container.addSubview(rowsView)
        contentView = container

        restorePosition(defaultSize: size)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Resize to fit the row count, keeping the top edge anchored where the user placed it.
    func fit(rowCount: Int) {
        let h = RowsView.height(for: rowCount)
        guard abs(h - frame.height) > 0.5 else { return }
        var f = frame
        f.origin.y -= (h - f.height)
        f.size.height = h
        setFrame(f, display: true)
    }

    private func restorePosition(defaultSize: NSSize) {
        if let arr = UserDefaults.standard.array(forKey: posKey) as? [Double], arr.count == 2 {
            let frame = NSRect(origin: NSPoint(x: arr[0], y: arr[1]), size: defaultSize)
            if NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) {
                setFrameOrigin(frame.origin)
                return
            }
        }
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            setFrameOrigin(NSPoint(x: vf.maxX - defaultSize.width - 20,
                                   y: vf.maxY - defaultSize.height - 20))
        }
    }

    func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set([Double(frame.origin.x), Double(frame.origin.y)], forKey: posKey)
    }
}
