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
| API-equivalent (chart + history) | `ccusage` reading your local Claude Code logs | What your usage *would* cost at API list prices — useful for spotting expensive days and models, **not a bill** (see "How accurate is the per-day breakdown?" below) |

**Works with Claude Code in any IDE** — VS Code, JetBrains, Cursor, or a plain terminal. CostBar reads the credentials and logs the Claude Code CLI writes locally, so it doesn't matter where you run Claude Code. It does *not* see usage from claude.ai in a browser, the Claude desktop app, or raw API calls — only what goes through the Claude Code CLI.

**If your plan doesn't have extra-usage enabled** (e.g. plain Pro), there's no real bill to show — the app gracefully falls back to the API-equivalent estimate, labeled `Est. usage` with an `estimate` chip and a `~` in the menu bar. If you're simply not logged in to Claude Code yet, it shows `Billing…` until you are.

## How accurate is the per-day breakdown?

Be clear-eyed about this. Anthropic exposes exactly **one** authoritative billing figure: your **month-to-date** extra-usage total (the number in the top card and menu bar). That number is always exact — it comes straight from Anthropic's usage endpoint.

It does **not** expose any per-day or per-model history. There is no daily billing archive to read; we checked. So the daily chart and the per-model breakdown are computed from `ccusage`, which prices your local Claude Code logs at **API list rates**. On a normal day that's close, but on a heavy day — lots of Fable usage, or many subagents fanning out — the API-list estimate can run well above your actual subscription-billed cost (your effective rate is below list, and Fable is priced above Opus). **Treat the daily/per-model bars as a relative guide ("which days and models were heavy"), not as your exact bill.**

The accurate way to get a real *daily* number is to difference the month-to-date counter day over day (today's total − yesterday's total = today's real spend). That only works **going forward** from when tracking starts, because the past isn't stored anywhere retrievable.

**Bottom line:**
- **Month-to-date total** — exact, any time.
- **Historical per-day / per-model** — estimate only (API-list via ccusage); not your real bill.
- **Real overage billed today** — exact, and live intraday. CostBar snapshots the `used_credits` counter on every refresh into a local ledger (`overage-ledger.json`, recording each day's opening and latest reading). Today's overage = latest − today's opening reading, so it updates every ~10 min and is available the same day (no waiting for tomorrow). Past days diff against the prior day's close. Shown as `✓ Billed today` in the breakdown. Days you stay within your plan allowance correctly show **$0** — the counter only moves on billed overage. First-day caveat: "today's opening" is the first reading after the app launched, so overage accrued *before* first launch on day one sits in the baseline, not the delta; exact start-to-finish from the next full day.

The breakdown also shows `▪ Used today (est.)` — the ccusage activity estimate, which climbs as you work even within plan. Two questions, side by side: **billed** (exact, often $0) vs **used** (estimate, always moving).

**Why the estimate bars and the real total don't match:** the bars measure *activity* (priced at API rates); the total measures *overage billing* (only usage beyond your plan allowance). On days you stay within plan, you'll see activity on the bars but $0 real overage — both are correct, they answer different questions.

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
