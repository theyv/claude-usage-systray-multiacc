# Claude Usage Systray — Multi-Account

A macOS menu bar app that monitors several [Claude.ai](https://claude.ai) accounts at once. It automatically puts the account with the most usable quota left in the menu bar, while the popover shows every account.

This project is a multi-account fork of [adntgv/claude-usage-systray](https://github.com/adntgv/claude-usage-systray). The original project remains the `upstream` Git remote.

![Claude Usage Systray](claude-usage-systray/Resources/Assets.xcassets/Image.imageset/Image.png)

## What it shows

Mirrors the data on `claude.ai/settings/usage`:

| Metric | Description |
|--------|-------------|
| **5h** | Current session usage and the exact reset day/time |
| **Weekly** | Weekly all-models usage and the exact reset day/time |
| **Fable** | Weekly Fable limit when returned by the API |

The menu-bar item selects the account with the highest remaining capacity (the lower of its remaining 5h and weekly quota). This means it naturally points to the account that is safest to use next.

## Multi-account and CCS

This fork understands [CCS](https://github.com/kaitranntt/ccs) account profiles. On launch it discovers profile directories in `~/.ccs/instances` and adds them by profile name. It reads a token only from that profile's `.credentials.json`; it does not copy CCS secrets into the app. A profile without a valid login is shown in the popover as needing login.

You can also add an account manually from **Accounts & settings → Add OAuth token**. Manual tokens are stored in the macOS Keychain, never in `UserDefaults`, logs, or this repository.

Colors update based on your configured warning/critical thresholds.

## Requirements

- macOS 13+
- [Claude Code](https://claude.ai/code) installed and logged in, or an OAuth token for each manually configured account

## Install

**Homebrew (recommended):**

```bash
brew tap adntgv/tap
brew install --cask claude-usage-systray
```

**Manual:**

Download the latest `ClaudeUsageSystray.zip` from the [Releases page](https://github.com/adntgv/claude-usage-systray/releases), unzip, and move `ClaudeUsageSystray.app` to `/Applications`. The app is notarized — macOS will open it normally on first launch.

## Build from source

```bash
git clone https://github.com/adntgv/claude-usage-systray
cd claude-usage-systray/claude-usage-systray
xcodebuild -scheme ClaudeUsageSystray -configuration Release build
open ~/Library/Developer/Xcode/DerivedData/ClaudeUsageSystray-*/Build/Products/Release/ClaudeUsageSystray.app
```

Or open `ClaudeUsageSystray.xcodeproj` in Xcode and run with ⌘R.

## Display modes

Toggle **Compact display** in Settings to switch between:

- **Compact (default):** `account: 35% · 71%` — the selected account plus its 5h and weekly usage
- **Normal:** icon + `71%` — weekly usage only

## How it works

The app calls the same internal endpoint that powers `claude.ai/settings/usage` for each configured account:

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <oauth_token>
anthropic-beta: oauth-2025-04-20
```

CCS tokens are read from their isolated profile files on each refresh. Manually added tokens are held in the macOS Keychain.

> **Note:** This endpoint is undocumented and may change. It requires Claude Code to be installed and logged in.

## Settings

| Setting | Default | Description |
|---------|---------|-------------|
| Compact display | On | Show both 5h and 7d in menu bar |
| Warning threshold | 80% | Orange color above this |
| Critical threshold | 90% | Red color above this |
| Usage alerts | On | macOS notification when thresholds are crossed |

## Running tests

```bash
xcodebuild test -project ClaudeUsageSystray.xcodeproj \
  -scheme ClaudeUsageSystrayTests \
  -destination 'platform=macOS'
```

## License

MIT
