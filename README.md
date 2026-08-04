# Claude Usage Widget

A small always-on-top macOS widget that shows how much of your Claude quota is used right now — the
same three rows as Claude's `/usage` panel (5-hour limit, weekly, weekly per-model), without
opening it manually.

The widget appears **only when a Claude Desktop window is actually visible** on some display, and
floats above whatever you're working on — even on a different display, even when Claude is not the
active app. When Claude is fully covered, minimised, or on another Space, the widget hides itself.

## How it works

A single native Swift agent (`LSUIElement`, no Dock icon):

- **`UsageFetcher`** — every 60s it reads the OAuth token **Claude Code already stores in the macOS
  Keychain** (item `Claude Code-credentials`) and calls `GET /api/oauth/usage` itself, then maps the
  response to the three rows.
- **`ClaudeVisibility`** — decides when the widget is on screen, using window-occlusion metadata
  only (no Screen Recording permission).
- **`WidgetPanel`** — the floating panel that draws the rows.

The token is read by spawning the stable, Apple-signed `/usr/bin/security` binary, so the one-time
Keychain **"Always Allow"** grant survives app rebuilds. The token is used **read-only** — it is
never refreshed (so Claude Code's refresh token is never rotated) and never written anywhere. The
only thing persisted to disk is the widget's window position, in `UserDefaults`.

If the access token is expired, the widget shows its last values dimmed as **stale** until Claude
Code refreshes the token during normal use.

## Build & run

Requires the Swift toolchain from the Command Line Tools (no Xcode, no SwiftPM).

```sh
./build.sh                 # builds build/ClaudeUsageWidget.app and build/probe
./install.sh               # copies the app to ~/Applications
./install.sh --login       # also start at login via a LaunchAgent
```

On first launch, macOS asks to allow `security` to read the Claude Code Keychain item — click
**Always Allow**. Try the UI without any Keychain/network using mock data:

```sh
WIDGET_MOCK=1 WIDGET_ALWAYS_SHOW=1 ./build/ClaudeUsageWidget.app/Contents/MacOS/ClaudeUsageWidget
```

`build/probe` is a standalone tool for debugging the visibility engine (`probe --dump`, or
`probe [seconds]` to watch the verdict change).

## Optional fallback: the in-process exporter (`patch/`)

`patch/` contains an earlier, **superseded** approach: a JavaScript exporter injected into Claude
Desktop's main process by `patch/patch.sh`, which pushes usage to the widget over a loopback socket.
It is kept as a reference/fallback for setups where reading the Keychain isn't desirable. The
default build does not use it, and patching Claude Desktop invalidates Anthropic's code signature
and is wiped by Claude updates.

The patch mechanics are derived from
[`toboly/claude-desktop-rtl-patch-mac`](https://github.com/toboly/claude-desktop-rtl-patch-mac),
itself based on the original patch by **shraga100**. Their license is preserved. This project is
**not** a fork of that repository.

## License

MIT — see [LICENSE](LICENSE).
