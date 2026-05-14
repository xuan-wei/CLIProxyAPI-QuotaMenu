# CLIProxyAPI-QuotaMenu

A native macOS menu bar app for monitoring API quota usage across multiple AI providers, powered by [CLIProxyAPI](https://github.com/nicepkg/CLIProxyAPI).

## Why?

If you're running CLIProxyAPI to manage multiple AI coding assistant accounts, checking quota through a web dashboard every time is inconvenient. QuotaMenu lives in your menu bar and gives you instant access to quota status — one click to see all your accounts at a glance.

## Features

- **Multi-provider support** — Claude Code, Codex, Antigravity (Cloud Code), Gemini CLI, Kimi
- **Rich quota display** — usage percentage, progress bars, reset time countdown, plan badges (Max/Pro/prolite)
- **Per-account refresh** — refresh individual accounts without waiting for all
- **Hide/show accounts** — toggle visibility per account or per provider
- **Resizable panel** — drag to adjust height, remembers your preference
- **Multi-site support** — connect to multiple CLIProxyAPI instances
- **Auto-refresh** — configurable interval (5 min to 2 hours)
- **Alert notifications** — get notified when quota drops below threshold
- **Secure storage** — management keys stored in macOS Keychain
- **Launch at login** — optional auto-start via SMAppService
- **Left-click / right-click** — left-click opens quota panel, right-click opens settings menu

## Requirements

- macOS 14.0 (Sonoma) or later
- A running [CLIProxyAPI](https://github.com/nicepkg/CLIProxyAPI) instance with management API enabled

## Setup

1. Download the latest release or build from source
2. Remove the quarantine attribute (macOS blocks unsigned apps):
   ```bash
   xattr -cr /path/to/QuotaMenu.app
   ```
3. Launch QuotaMenu — a gauge icon appears in your menu bar
3. Right-click the icon → **Settings** → **Sites** tab → **Add Site**
4. Enter your CLIProxyAPI URL and management key
5. Left-click the icon to open the quota panel

## Build from Source

### Prerequisites

- Xcode 15+ with macOS 14 SDK
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

### Steps

```bash
cd QuotaMenu
xcodegen generate
xcodebuild -scheme QuotaMenu -configuration Release build
```

The built app will be in `~/Library/Developer/Xcode/DerivedData/QuotaMenu-*/Build/Products/Release/QuotaMenu.app`.

## How It Works

QuotaMenu connects directly to your CLIProxyAPI instance via its management API:

1. `GET /v0/management/auth-files` — discovers all configured accounts
2. `POST /v0/management/api-call` — proxies requests to each provider's quota API
3. `GET /v0/management/auth-files/download` — downloads auth file details (for project IDs)

All communication is authenticated with your management key (`Authorization: Bearer <key>`). No credentials are stored in the app bundle — keys are kept in macOS Keychain.

## Project Structure

```
QuotaMenu/
├── QuotaMenuApp.swift          # App entry, NSStatusItem (left/right click)
├── Models/
│   ├── Site.swift              # CLIProxyAPI connection config + SiteStore
│   └── QuotaData.swift         # QuotaItem, QuotaWindow, QuotaExtra
├── Services/
│   ├── QuotaService.swift      # API fetcher (Claude/Codex/Antigravity/Gemini/Kimi)
│   └── NotificationService.swift
├── ViewModels/
│   └── QuotaViewModel.swift    # State management, grouping, ordering
├── Views/
│   ├── QuotaMenuView.swift     # Main panel layout
│   ├── QuotaListView.swift     # Provider-grouped list
│   ├── QuotaRowView.swift      # Account card with progress bars
│   └── SettingsView.swift      # Sites, notifications, general settings
└── Utilities/
    ├── KeychainHelper.swift    # Keychain read/write/delete
    ├── PanelManager.swift      # Resizable floating NSPanel
    └── SettingsWindowManager.swift  # Independent NSWindow manager
```

## License

MIT

## Contributors

- **Xuan Wei** ([@xuan-wei](https://github.com/xuan-wei))
- **Claude** by [Anthropic](https://www.anthropic.com) — AI pair programming assistant
