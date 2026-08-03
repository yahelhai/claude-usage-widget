# Claude Usage Widget

A small always-on-top macOS widget that shows how much of your Claude quota is used right now — the
same three rows as Claude's `/usage` panel (5-hour limit, weekly, weekly per-model), without
opening it manually.

The widget appears **only when a Claude Desktop window is actually visible** on some display, and
floats above whatever you're working on — even on a different display, even when Claude is not the
active app. When Claude is fully covered, minimised, or on another Space, the widget hides itself.

## How it works

Two pieces talk over a loopback socket on `127.0.0.1`:

- **`ClaudeUsageWidget.app`** — a native Swift menu-less agent (`LSUIElement`). It owns the socket,
  decides when to show itself (`ClaudeVisibility`), and draws the rows (`WidgetPanel`).
- **`usage-exporter.js`** — injected into Claude Desktop by a patch. It fetches
  `GET /api/oauth/usage` using a token the app already holds *in-process*, and pushes only
  percentages and reset times to the widget.

**No secrets leave Claude.** The token never crosses the socket, and nothing is written to disk
(only the widget's window position, in `UserDefaults`).

## Build & run

Requires the Swift toolchain from the Command Line Tools (no Xcode, no SwiftPM).

```sh
./build.sh                 # builds build/ClaudeUsageWidget.app and build/probe
./install.sh               # copies the app to ~/Applications
./install.sh --login       # also start at login via a LaunchAgent
```

Try the UI without touching Claude, using the mock feeder:

```sh
open build/ClaudeUsageWidget.app     # or run the binary with WIDGET_ALWAYS_SHOW=1 to force it visible
./build/probe feed                   # pushes fixed mock rows
./build/probe feed --animate         # rows that climb, to see the bar colour states
```

## Attribution

The injection patch is derived from
[`toboly/claude-desktop-rtl-patch-mac`](https://github.com/toboly/claude-desktop-rtl-patch-mac),
itself based on the original patch by **shraga100**. Their license is preserved. This project adds
a separate usage exporter and the native widget; it is **not** a fork of that repository.

Patching Claude Desktop replaces files inside `/Applications/Claude.app` and invalidates
Anthropic's code signature. A Claude update will wipe the patch — re-run it afterwards.

## License

MIT — see [LICENSE](LICENSE).
