import AppKit

/// A single row as the widget draws it.
struct DisplayRow {
    let title: String
    let percent: Int
    let resetsAt: Date?
}

/// Draws the rows: title on the left, reset time + percentage on the right, a thin bar underneath.
/// Matches the usage panel in the reference screenshot.
final class RowsView: NSView {
    var rows: [DisplayRow] = [] { didSet { needsDisplay = true } }
    var stale = false { didSet { needsDisplay = true } }
    var placeholder: String? { didSet { needsDisplay = true } }

    /// Above 75% the bar turns amber, above 90% red. Set false to keep it always blue.
    var colourByLevel = true

    static let width: CGFloat = 320
    static let rowHeight: CGFloat = 44
    static let padding: CGFloat = 14

    static func height(for count: Int) -> CGFloat {
        padding * 2 + CGFloat(max(count, 1)) * rowHeight
    }

    override var isFlipped: Bool { true }   // top-to-bottom layout

    override func draw(_ dirtyRect: NSRect) {
        if let placeholder, rows.isEmpty {
            drawCentered(placeholder, alpha: 0.5)
            return
        }

        let dim: CGFloat = stale ? 0.4 : 1.0
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

        if stale { drawStaleBadge() }
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

    private func drawStaleBadge() {
        let s = NSAttributedString(string: "stale", attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.35),
        ])
        s.draw(at: NSPoint(x: Self.padding, y: bounds.height - 12))
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
        let r = NSRect(x: 14, y: (bounds.height - size.height) / 2,
                       width: bounds.width - 28, height: size.height)
        s.draw(in: r)
    }

    static let blue = NSColor(srgbRed: 0x3B / 255, green: 0x82 / 255, blue: 0xF6 / 255, alpha: 1)
    static let amber = NSColor(srgbRed: 0xF5 / 255, green: 0x9E / 255, blue: 0x0B / 255, alpha: 1)
    static let red = NSColor(srgbRed: 0xEF / 255, green: 0x44 / 255, blue: 0x44 / 255, alpha: 1)

    static let resetFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE h:mm a"   // e.g. "Mon 5:00 AM", local timezone
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
