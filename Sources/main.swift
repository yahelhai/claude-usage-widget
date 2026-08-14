import AppKit

/// Ties the pieces together: the fetcher reads Claude Code's token and pulls usage, the visibility
/// engine decides when the panel is on screen, and the panel draws.
final class AppController: NSObject, NSApplicationDelegate {
    let panel = WidgetPanel()
    let fetcher = UsageFetcher()

    private var pollTimer: Timer?
    private var lastVisible = false
    private var announcedWindowID = false

    /// Testing aids: WIDGET_ALWAYS_SHOW=1 bypasses the visibility gate; WIDGET_MOCK=1 feeds fixed
    /// rows instead of reading the Keychain / calling the API.
    private let env = ProcessInfo.processInfo.environment
    private var alwaysShow: Bool { env["WIDGET_ALWAYS_SHOW"] == "1" }
    private var mock: Bool { env["WIDGET_MOCK"] == "1" }

    /// WIDGET_FORCE_STATUS=signedOut|denied|unreachable pins the panel to a failure state, so the
    /// messages can be checked without actually signing out or pulling the network cable.
    private var forcedStatus: UsageFetcher.Status? {
        switch env["WIDGET_FORCE_STATUS"] {
        case "signedOut": return .signedOut
        case "denied": return .denied
        case "unreachable": return .unreachable("offline")
        default: return nil
        }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)

        panel.rowsView.placeholder = "Checking usage…"
        panel.rowsView.menu = buildMenu()
        panel.rowsView.onRefresh = { [weak self] in self?.refresh() }

        if let forcedStatus {
            if case .unreachable = forcedStatus { apply(rows: Self.mockRows()) }
            apply(status: forcedStatus)
        } else if mock {
            apply(rows: Self.mockRows())
        } else {
            fetcher.onData = { [weak self] rows in self?.apply(rows: rows) }
            fetcher.onStatus = { [weak self] status in self?.apply(status: status) }
            fetcher.onRefreshing = { [weak self] busy in self?.panel.rowsView.isRefreshing = busy }
            fetcher.start()
        }

        startVisibilityPolling()

        if env["WIDGET_SELF_TEST"] == "1" { runSelfTest() }
    }

    /// WIDGET_SELF_TEST=1: drive a click at the refresh control and at a row, in the real window,
    /// and report whether each reached the handler. Verifies the control's geometry and that a
    /// click elsewhere still falls through to the window's drag-to-move behaviour.
    private func runSelfTest() {
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            let view = panel.rowsView
            var fired = false
            view.onRefresh = { fired = true }

            func click(_ pointInView: NSPoint) -> Bool {
                fired = false
                guard let event = NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: view.convert(pointInView, to: nil),
                    modifierFlags: [], timestamp: 0,
                    windowNumber: panel.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1
                ) else { return false }
                view.mouseDown(with: event)
                return fired
            }

            let bounds = view.bounds
            let control = view.refreshControlCenter
            print("SELFTEST control_center=\(Int(control.x)),\(Int(control.y)) "
                + "bounds=\(Int(bounds.width))x\(Int(bounds.height))")
            print("SELFTEST control_inside_bounds=\(bounds.contains(control))")
            print("SELFTEST click_on_control_refreshes=\(click(control))")
            print("SELFTEST click_on_row_refreshes=\(click(NSPoint(x: 40, y: 30)))")
            print("SELFTEST accepts_first_mouse=\(view.acceptsFirstMouse(for: nil))")
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }

    private func apply(rows: [UsageRow]) {
        panel.rowsView.rows = rows.map {
            DisplayRow(title: $0.title, percent: $0.percent,
                       resetsAt: $0.resetsAt.map(Date.init(timeIntervalSince1970:)))
        }
        panel.rowsView.lastUpdate = Date()
        panel.fit(rowCount: max(rows.count, 1))
    }

    /// The fetcher owns the status; the panel only renders it. Message states get a fixed two-row
    /// height so the text isn't squeezed into a single row's worth of panel.
    private func apply(status: UsageFetcher.Status) {
        panel.rowsView.status = status
        switch status {
        case .signedOut, .denied:
            panel.fit(rowCount: 2)
        case .ok, .unreachable:
            panel.fit(rowCount: max(panel.rowsView.rows.count, 1))
        }
    }

    // MARK: Visibility

    private func startVisibilityPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.updateVisibility()
        }
        let nc = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateVisibility()
            }
        }
        updateVisibility()
    }

    private func updateVisibility() {
        let visible = alwaysShow || ClaudeVisibility.isVisible()
        guard visible != lastVisible else { return }
        lastVisible = visible
        if visible {
            panel.orderFrontRegardless()
            if !announcedWindowID {          // lets a test harness capture just this window
                announcedWindowID = true
                let f = panel.frame
                print("WIDGET_WINDOW_ID=\(panel.windowNumber) "
                    + "FRAME=\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))")
                fflush(stdout)
            }
        } else {
            panel.orderOut(nil)
        }
    }

    // MARK: Menu (no Dock icon, so the panel carries its own right-click menu)

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self
        return menu
    }

    @objc private func refresh() {
        if !mock { fetcher.pollNow() }
        updateVisibility()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Mock data (WIDGET_MOCK=1)

    private static func mockRows() -> [UsageRow] {
        var comps = DateComponents(); comps.weekday = 2; comps.hour = 5   // next Monday 5:00 AM
        let reset = Calendar.current
            .nextDate(after: Date(), matching: comps, matchingPolicy: .nextTime)?
            .timeIntervalSince1970
        return [
            UsageRow(title: "5-hour limit", percent: 0, resetsAt: nil),
            UsageRow(title: "Weekly · all models", percent: 7, resetsAt: reset),
            UsageRow(title: "Weekly · Fable", percent: 8, resetsAt: reset),
        ]
    }
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.run()
