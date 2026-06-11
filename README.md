# CostBar

A tiny native macOS menu bar app that shows what your Claude usage actually costs.

**Menu bar:** your real extra-usage billing for the current month (the metered dollars on top of your Claude seat). Click it for the full picture:

- **Extra usage billed** — true billing vs your monthly cap, with a progress bar and your live session/weekly rate limits
- **Monthly history** — flip between months with chevrons, see API-equivalent totals and daily averages
- **Stacked bar chart** — cost per day, colored by model (Opus, Sonnet, Haiku, Fable). Hover any bar for that day's per-model cost and token breakdown

## Two numbers, two meanings

| Number | Source | What it is |
|---|---|---|
| True billing (top card + menu bar) | Anthropic's usage endpoint, via your Claude Code login | Real dollars billed this month beyond your seat |
| API-equivalent (chart + history) | `ccusage` reading your local Claude Code logs | What your usage *would* cost at API list prices — useful for spotting expensive days and models, not a bill |

If true billing is unavailable (not logged in to Claude Code), the menu bar falls back to the API-equivalent with a `~` prefix.

## Install

Requirements: macOS 14+, [Claude Code](https://claude.com/claude-code) installed and logged in, node/npm (`brew install node`), Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/wmurphy-sketch/costbar.git
cd costbar
bash install.sh
```

To update later: `git pull && bash build.sh`

That checks dependencies, installs `ccusage` if needed, compiles the app locally (~5 seconds), installs to `/Applications/CostBar.app`, and launches it. Because it's built on your machine, there are no Gatekeeper warnings.

First time it reads your Claude Code credential, macOS shows a Keychain prompt — click **Always Allow**.

## Privacy

Everything runs locally. The app:
- reads your Claude Code conversation logs (`~/.claude/projects/`) via `ccusage` — never uploads them
- reads your Claude Code OAuth token from your Keychain and calls exactly one Anthropic endpoint (`api.anthropic.com/api/oauth/usage`) — the same call Claude Code's `/usage` command makes
- talks to nothing else, stores nothing remotely, has no analytics

## Uninstall

```bash
pkill -x CostBar; rm -rf /Applications/CostBar.app
```

## Hacking

One Swift file: `main.swift` (~600 lines, SwiftUI + Swift Charts, zero dependencies). Edit, then `bash build.sh` to rebuild and reinstall. Refresh interval, popover size, and model colors are all near-the-top constants.

Built at Basic Capital by Will Murphy + Claude.
