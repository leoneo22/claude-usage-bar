# ClaudeUsageBar

A native macOS menu bar app that shows your Claude usage at a glance.

```
⚡ 62%
```

Left-click the icon to open a live popup with progress bars and a reset countdown. Right-click for the context menu.

![macOS](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift](https://img.shields.io/badge/Swift-6.x-orange) ![License](https://img.shields.io/badge/license-MIT-green)

---

## Features

- **Menu bar icon** — live `⚡` with 5-hour utilization; appends `⚠ N%` when any weekly limit is running hot (≥ 80%); turns `⚡ ⚠` on auth errors
- **Usage popover** — 5-hour window, weekly windows (overall, Opus, Sonnet, Haiku, Cowork), extra usage credits
- **Desktop widget** — compact floating bar showing just the 5-hour card, always-on-top, draggable
- **Detachable window** — pin the popover as a floating always-on-top window
- **Auto-Primer** — sends a 1-token message seconds after your 5-hour window resets, so the fresh window starts counting immediately (with a gas-station ding when it fires)
- **Window state restore** — widget and floating window reopen where you left them after relaunch
- **Start at Login** — native macOS `SMAppService` integration
- **Zero password prompts** — owns its own Keychain item; asks for access exactly once, ever
- **Smart polling** — 3 min normal, faster on errors, exponential backoff on rate limits, instant on wake from sleep
- **Multi-monitor** — widget positions to the screen your cursor is on

---

## Requirements

- **macOS 14** (Sonoma) or later
- **Swift 6.x** — comes with Xcode 16+ or the Swift toolchain
- **Claude Code** installed and authenticated (`claude` CLI logged in)

---

## Quick Start

### 1. Verify Claude Code is authenticated

```bash
claude --version
security find-generic-password -s "Claude Code-credentials" > /dev/null && echo "OK"
```

If the second command prints `OK`, your credentials are in the Keychain.
If not, run `claude` in Terminal and complete the login flow first.

### 2. Clone and build

```bash
git clone https://github.com/leoneo22/claude-usage-bar.git
cd claude-usage-bar
bash scripts/bundle-app.sh
```

This compiles a release binary, packages it into `ClaudeUsageBar.app`, and code-signs it. Takes ~30 seconds on first build.

### 3. Install and launch

```bash
cp -R ClaudeUsageBar.app /Applications/
open /Applications/ClaudeUsageBar.app
```

The `⚡` icon appears in your menu bar immediately.

> **One-time Keychain prompt:** On first launch, macOS asks if ClaudeUsageBar can read the "Claude Code-credentials" Keychain item. Click **Always Allow**. The app copies the credentials into its own Keychain item and never touches Claude Code's again — so this prompt happens once, not on every poll or rebuild.

---

## Usage

| Action | Result |
|---|---|
| **Left-click** icon | Open/close the usage popup |
| **Right-click** icon | Open context menu |
| **Pin button** (top-right of popup) | Detach to a floating always-on-top window |
| **Refresh button** (bottom of popup) | Poll immediately |

### Popup contents

- **5-Hour Window** — rolling 5-hour utilization with a live countdown to reset
- **Weekly** — rolling 7-day utilization (when active)
- **Weekly Opus / Sonnet / Haiku / Cowork** — per-model weekly windows (when active)
- **Extra Usage** — credits used vs monthly limit (when enabled)
- **Auto-Primer toggle** — enable/disable automatic priming (persists across restarts)
- **Footer** — last update time + manual refresh button

Progress bar colors: green (< 50%), yellow (50–80%), red (> 80%).

### Menu bar warning

The icon normally shows your 5-hour window: `⚡ 12%`. If any *weekly* window reaches 80%, it appends the worst one — `⚡ 12% ⚠91%` — so a nearly-exhausted weekly cap can't sneak up on you while the 5-hour number looks healthy.

### Context menu (right-click)

| Item | Description |
|---|---|
| **Poll Now** | Fetch usage immediately |
| **Auto-Primer** | Toggle auto-primer on/off (checkmark = on) |
| **Test Primer Now** | Fire a primer message immediately |
| **Desktop Widget** | Toggle compact floating usage bar |
| **Move Widget Here** | Reposition widget to current screen |
| **Start at Login** | Launch at login via macOS ServiceManagement |
| **Quit ClaudeUsageBar** | Quit |

---

## Desktop Widget

A compact borderless bar showing just the 5-hour usage card. Enable it from the right-click menu.

- **Always on top** — stays above all windows
- **Draggable** — click and drag to reposition
- **All spaces** — visible on every desktop/space
- **Multi-monitor** — "Move Widget Here" repositions to your cursor's screen
- **Remembered** — if it was open when you quit, it reopens on next launch

---

## Auto-Primer

When your 5-hour window resets, the fresh quota doesn't start counting down until your first message. Auto-Primer detects the reset (two ways: the reset timestamp jumping forward, or an idle window at < 2% utilization) and about 10 seconds later sends a single `hi` to Haiku with `max_tokens: 1` — priming the window so the countdown starts immediately.

When it fires, you'll hear a synthesized gas-station "ding-ding" (respects system mute).

**Cost:** ~3 input tokens per fire — negligible.

---

## Polling schedule

| Condition | Interval |
|---|---|
| Normal | Every 3 minutes |
| After an error | Every 60 seconds |
| 3+ consecutive errors | Every 5 minutes |
| Rate limited (429) | Exponential: 2 → 4 → 8 → 10 min cap (respects `Retry-After`) |
| Keychain access denied | Every 10 minutes |
| Login expired (re-auth needed) | Every 10 minutes |
| Mac wakes from sleep | After 5 seconds |

"Poll Now" always fires immediately and resets all backoffs.

---

## How Keychain access works

ClaudeUsageBar maintains its **own** Keychain item (`ClaudeUsageBar-OAuth`):

1. **First launch:** reads Claude Code's item once (the single "Always Allow" prompt), copies the credentials into its own item.
2. **Everything after:** reads, writes, and token refreshes use only its own item. Owning the item means the app is on its trusted-apps list — no prompts, ever, including across rebuilds.
3. **Self-healing:** if the stored refresh token gets revoked (e.g. you re-log-in to Claude elsewhere), the app automatically re-bootstraps from Claude Code's item. If Claude Code's copy is also dead, the popup tells you exactly what to do (`claude` → `/login`).

The build script signs with your Apple Development certificate when available, giving the app a stable code-signing identity so Keychain trust survives rebuilds. Check yours with:

```bash
security find-identity -v -p codesigning
```

---

## Rebuilding after code changes

```bash
bash scripts/bundle-app.sh
```

Quit the running app first (`right-click → Quit`), then reopen:

```bash
cp -R ClaudeUsageBar.app /Applications/
open /Applications/ClaudeUsageBar.app
```

No Keychain re-authorization needed — the app's own item survives rebuilds.

---

## Troubleshooting

### `⚡ ⚠` in the menu bar

Left-click the icon — the banner at the top of the popup says exactly what's wrong:

- **"Login expired — run `claude` in Terminal, then /login"** — your refresh token was revoked (usually because you logged in again on another device or app). Open Terminal, run `claude`, type `/login`, complete the browser flow. The app recovers automatically within minutes (or right-click → Poll Now to skip the wait).
- **"Auth expired — re-authenticating…"** — transient; the app is refreshing its token. If it persists, treat it as login-expired above.
- **"Keychain access denied"** — right-click → Poll Now and click **Always Allow** on the prompt.

### "Claude Code credentials not found"

Claude Code is not authenticated on this machine. Run `claude` in Terminal and complete the login flow, then relaunch the app.

### Primer shows "❌ HTTP 404: …"

The primer's hardcoded model was retired. Update the model ID in `Sources/ClaudeUsageBar/Core/AutoPrimer.swift` and rebuild.

### App doesn't appear in menu bar

macOS may Gatekeeper-block unsigned apps. Run this once:

```bash
xattr -cr ClaudeUsageBar.app
open ClaudeUsageBar.app
```

---

## Project structure

```
claude-usage-bar/
├── Package.swift
├── scripts/
│   ├── Info.plist
│   ├── bundle-app.sh
│   ├── generate-icon.swift
│   └── AppIcon.icns
└── Sources/ClaudeUsageBar/
    ├── App/
    │   ├── ClaudeUsageBarApp.swift          # @main entry point
    │   ├── AppDelegate.swift                # NSStatusItem, popover, menus
    │   ├── FloatingWindowController.swift   # Detached popover window
    │   └── WidgetWindowController.swift     # Compact desktop widget
    ├── Core/
    │   ├── OAuthUsageProvider.swift         # Main data provider + API calls
    │   ├── UsagePoller.swift                # Timer + backoff logic
    │   ├── TokenRefresher.swift             # OAuth refresh + self-healing re-bootstrap
    │   ├── AutoPrimer.swift                 # Window priming after reset
    │   ├── KeychainManager.swift            # Own item + one-time Claude Code bootstrap
    │   └── UsageProvider.swift              # Protocol
    ├── Models/
    │   ├── OAuthCredentials.swift
    │   └── UsageData.swift
    ├── Utilities/
    │   └── FuelGaugeBell.swift              # Synthesized gas-station bell
    └── Views/
        ├── PopoverView.swift
        ├── UsageCardView.swift              # + ExtraUsageCardView
        ├── CountdownView.swift
        ├── ErrorBannerView.swift
        ├── FooterView.swift
        └── PrimerStatusView.swift
```

---

## License

MIT
