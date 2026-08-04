import AppKit

/// Ties the pieces together: the fetcher reads Claude Code's token and pulls usage, the visibility
/// engine decides when the panel is on screen, and the panel draws.
final class AppController: NSObject, NSApplicationDelegate {
    let panel = WidgetPanel()
    let fetcher = UsageFetcher()

    private var pollTimer: Timer?
    private var staleTimer: Timer?
    private var lastVisible = false
    private var lastUpdate: Date?
    private var announcedWindowID = false

    /// Testing aids: WIDGET_ALWAYS_SHOW=1 bypasses the visibility gate; WIDGET_MOCK=1 feeds fixed
    /// rows instead of reading the Keychain / calling the API.
    private let env = ProcessInfo.processInfo.environment
    private var alwaysShow: Bool { env["WIDGET_ALWAYS_SHOW"] == "1" }
    private var mock: Bool { env["WIDGET_MOCK"] == "1" }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)

        panel.rowsView.placeholder = "Waiting for usage…\nSign in to Claude Code to populate this."
        panel.rowsView.menu = buildMenu()

        if mock {
            apply(rows: Self.mockRows())
        } else {
            fetcher.onData = { [weak self] rows in self?.apply(rows: rows) }
            fetcher.onStale = { [weak self] in self?.panel.rowsView.stale = true }
            fetcher.start()
            staleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                guard let self, let last = self.lastUpdate else { return }
                if Date().timeIntervalSince(last) > 600 { self.panel.rowsView.stale = true }
            }
        }

        startVisibilityPolling()
    }

    private func apply(rows: [UsageRow]) {
        panel.rowsView.rows = rows.map {
            DisplayRow(title: $0.title, percent: $0.percent,
                       resetsAt: $0.resetsAt.map(Date.init(timeIntervalSince1970:)))
        }
        panel.rowsView.stale = false
        lastUpdate = Date()
        panel.fit(rowCount: max(rows.count, 1))
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
                print("WIDGET_WINDOW_ID=\(panel.windowNumber)")
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
