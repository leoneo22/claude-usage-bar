# ClaudeUsageBar

A native macOS menu bar app that shows your Claude API usage at a glance.

```
⚡ 62%
```

Left-click the icon to open a live popup with progress bars and a reset countdown. Right-click for the context menu.

![macOS](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift](https://img.shields.io/badge/Swift-6.x-orange) ![License](https://img.shields.io/badge/license-MIT-green)

---

## Features

- **Menu bar icon** — live `⚡` with utilization percentage, turns `⚠` on errors
- **Usage popover** — 5-hour window, 7-day windows (Opus, Sonnet, Cowork), extra usage credits
- **Desktop widget** — compact floating bar showing just the 5-hour card, always-on-top, draggable
- **Detachable window** — pin the popover as a floating always-on-top window
- **Auto-Primer** — automatically primes your usage window 55 min after reset
- **Start at Login** — native macOS `SMAppService` integration
- **Smart polling** — 60s normal, 30s on errors, 5m backoff, instant on wake from sleep
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
git clone https://github.com/YOUR_USERNAME/claude-usage-bar.git
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

> **Keychain prompt:** The first time you launch, macOS will ask if ClaudeUsageBar can access the "Claude Code-credentials" Keychain item. Click **Always Allow** so it doesn't ask again.

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
- **7-Day Window** — rolling 7-day utilization (when active)
- **7-Day Opus / Sonnet / Cowork** — per-model 7-day windows (when active)
- **Extra Usage** — credits used vs monthly limit (when enabled)
- **Auto-Primer toggle** — enable/disable automatic priming
- **Footer** — last update time + manual refresh button

Progress bar colors: green (< 50%), yellow (50–80%), red (> 80%).

### Context menu (right-click)

| Item | Description |
|---|---|
| **Poll Now** | Fetch usage immediately |
| **Auto-Primer** | Toggle auto-primer on/off (checkmark = on) |
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

---

## Auto-Primer

When your 5-hour window resets, you have a fresh quota — but it doesn't start counting until your first message. Auto-Primer detects the reset and, 55 minutes later, sends a single `hi` to `claude-haiku-4-5-20251001` with `max_tokens: 1` to "prime" the window so the countdown starts.

**Cost:** ~3 input tokens per fire — negligible.

---

## Polling schedule

| Condition | Interval |
|---|---|
| Normal | Every 60 seconds |
| After an error | Every 30 seconds |
| 3+ consecutive errors | Every 5 minutes (backoff) |
| Rate limited (429) | 5 minutes |
| Mac wakes from sleep | Immediately |

---

## Code signing & Keychain

The build script auto-detects your code signing identity. If you have an Apple Development certificate, it uses that — giving the app a stable identity so Keychain remembers "Always Allow" across rebuilds.

If no signing identity is found, it falls back to ad-hoc signing (you may need to re-authorize Keychain access after each rebuild).

To check your signing identities:

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

---

## Troubleshooting

### `⚡ ⚠` in the menu bar

Your OAuth token expired and couldn't be refreshed automatically. Run `claude` in Terminal to re-authenticate, then use **Poll Now** from the right-click menu.

### "Claude Code credentials not found"

Claude Code is not authenticated on this machine. Run `claude` in Terminal and complete the login flow, then relaunch the app.

### Keychain prompt keeps appearing

If you don't have an Apple Development certificate, each rebuild changes the code signature. Either:
- Create a free signing identity via Xcode (Xcode → Settings → Accounts → Manage Certificates)
- Or open **Keychain Access**, find "Claude Code-credentials", and add `ClaudeUsageBar` to its **Access Control** list

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
    │   ├── ClaudeUsageBarApp.swift         # @main entry point
    │   ├── AppDelegate.swift               # NSStatusItem, popover, menus
    │   ├── FloatingWindowController.swift   # Detached popover window
    │   └── WidgetWindowController.swift     # Compact desktop widget
    ├── Core/
    │   ├── OAuthUsageProvider.swift         # Main data provider + API calls
    │   ├── UsagePoller.swift                # Timer + backoff logic
    │   ├── TokenRefresher.swift             # 401 recovery
    │   ├── AutoPrimer.swift                 # 55-min window priming
    │   ├── KeychainManager.swift            # Reads Claude Code token
    │   └── UsageProvider.swift              # Protocol
    ├── Models/
    │   ├── OAuthCredentials.swift
    │   └── UsageData.swift
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
