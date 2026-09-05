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

## States

The widget names what is actually wrong rather than dimming everything into one "stale" look:

| State | What you see | Poll rate |
|---|---|---|
| Normal | The three rows, plus `Updated HH:MM` in the footer | 5 min |
| Signed out | `Claude Code is signed out` and the command that fixes it — no stale numbers, which could be weeks old | 10s, Keychain only (no network) |
| Token expired | Normally invisible: renewed automatically. Only shown if renewal fails | 65s |
| Rate limited | Last known rows dimmed, footer says it is backing off | 5 → 10 → 15 min, or `Retry-After` |
| Can't reach Anthropic | Last known rows dimmed, footer explains why | 30s → 60s → 3 min backoff |
| Keychain denied | How to restore access | 10s |

**Polling follows visibility.** While the panel is hidden — Claude covered, minimised, or on another
Space — nothing is fetched at all.

`/api/oauth/usage` rate-limits, and these numbers move slowly, so the healthy interval is minutes,
not seconds. The **↻** control forces a poll but is ignored within 15s of the previous one, so it
can't be used to hammer a throttled endpoint.

**It recovers on its own.** While signed out it re-checks the Keychain every 10 seconds — a local,
free check — so the moment you run `claude auth login`, the widget repopulates without being
touched. The **↻** control in the bottom-right forces a poll immediately; it is mainly useful for
transient network failures, since no button can conjure a token that isn't there.

### Token renewal

Claude Code's access token lasts hours; the session behind it lasts weeks. Claude Desktop keeps its
own session and never renews the CLI's copy, so on a desktop-only machine that access token simply
goes stale and the widget would have nothing to call with.

An expired access token is therefore **not** treated as a sign-out. Claude Code renews and re-stores
its own token as a side effect of any authenticated CLI command, so the widget runs a cheap
read-only one (`claude mcp list`) and reads the Keychain again. Renewal happens entirely inside
Claude Code — the widget never rotates anything itself, so it cannot leave the CLI holding a token
it no longer recognises. Attempts are throttled to once a minute.

The CLI is located by absolute path rather than through a shell: a LaunchAgent starts with almost
no `PATH`, and a login shell does not read the `~/.zshrc` where the install puts it.

## Build & run

Requires the Swift toolchain from the Command Line Tools (no Xcode, no SwiftPM).

```sh
./build.sh                 # builds build/ClaudeUsageWidget.app and build/probe
./install.sh               # copies the app to ~/Applications
./install.sh --login       # also start at login via a LaunchAgent
```

On first launch, macOS asks to allow `security` to read the Claude Code Keychain item — click
**Always Allow**.

Only one instance runs at a time: launching again exits immediately rather than adding a second
panel. To restart the LaunchAgent copy, use
`launchctl kickstart -k gui/$(id -u)/ai.yahelh.claude-usage-widget`.

### Testing aids

Environment variables, all read at launch:

| Variable | Effect |
|---|---|
| `WIDGET_MOCK=1` | Fixed rows instead of reading the Keychain or calling the API |
| `WIDGET_ALWAYS_SHOW=1` | Bypass the visibility gate |
| `WIDGET_FORCE_STATUS=` | `signedOut`, `denied`, `rateLimited`, or `unreachable` — pins a failure state so its message can be checked without signing out or dropping the network |
| `WIDGET_SELF_TEST=1` | Clicks the refresh control and a row in the real window, prints whether each reached the handler, then exits |

```sh
WIDGET_MOCK=1 WIDGET_ALWAYS_SHOW=1 ./build/ClaudeUsageWidget.app/Contents/MacOS/ClaudeUsageWidget
```

`build/probe` is a standalone tool for debugging the visibility engine (`probe --dump`, or
`probe [seconds]` to watch the verdict change).

## License

MIT — see [LICENSE](LICENSE).
