import AppKit

/// Ties the pieces together: the loopback bridge feeds rows in, the visibility engine decides when
/// the panel is on screen, and the panel draws. No networking happens here — the widget only
/// listens; the exporter inside Claude does the fetching.
final class AppController: NSObject, NSApplicationDelegate {
    let panel = WidgetPanel()
    let bridge = UsageBridge()

    private var pollTimer: Timer?
    private var staleTimer: Timer?
    private var lastVisible = false
    private var lastUpdate: Date?
    private var announcedWindowID = false

    /// Testing aid: WIDGET_ALWAYS_SHOW=1 bypasses the visibility gate so the panel can be inspected
    /// on its own, without Claude on screen.
    private let alwaysShow = ProcessInfo.processInfo.environment["WIDGET_ALWAYS_SHOW"] == "1"

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)

        panel.rowsView.placeholder = "Waiting for Claude…\nRun the usage patch to see your quota."
        panel.rowsView.menu = buildMenu()

        bridge.onData = { [weak self] rows, updatedAt in self?.apply(rows: rows, updatedAt: updatedAt) }
        bridge.onDisconnect = { [weak self] in self?.panel.rowsView.stale = true }
        bridge.start()

        startVisibilityPolling()
        staleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, let last = self.lastUpdate else { return }
            if Date().timeIntervalSince(last) > 600 { self.panel.rowsView.stale = true }
        }
    }

    private func apply(rows: [UsageRow], updatedAt: TimeInterval) {
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
        panel.rowsView.needsDisplay = true
        updateVisibility()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.run()
