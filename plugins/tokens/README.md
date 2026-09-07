# tokens

A Claude Code plugin that charts your token usage over time, and optionally
syncs it to a tal account so the same history is available there too.

```
/tokens              # last 14 days, bar chart
/tokens --calendar   # year-at-a-glance heatmap
/tokens --days 30    # last 30 days
/tokens --weeks      # bucket by week
/tokens --all        # everything on disk
/tokens --project tal-main
/tokens --mono       # grayscale heatmap ramp
/tokens --sync       # report totals to a linked tal account
```

## The startup card

The plugin ships a `SessionStart` hook that prints the calendar heatmap, a
one-line summary, and the top five models and projects when you open Claude
Code — the same at-a-glance view as `/stats`, but scoped to token spend and
drawn from your own transcripts.

It runs only on `startup` (not on resume, clear, or compact), takes ~0.2s over
14 MB of transcripts, and emits its output as a hook `systemMessage`, so the
card is shown to you and never enters the model's context.

To turn it off without uninstalling, set `CLAUDE_TOKENS_NO_STARTUP=1` in your
environment. To remove it entirely, delete `hooks/hooks.json`.

The grid is always 53 weeks wide — 55 columns including the weekday gutter —
so it says the same thing the website does whatever the terminal width is. The
breakdowns are capped at five rows each with the remainder rolled into one
line, again matching the site, so a machine with forty project directories
cannot push the grid off the top of the scrollback. Everything honors
`NO_COLOR`.

### Rendering constraints

Claude Code renders a hook `systemMessage` as `"<hookName> says: <content>"`
inside one Ink `Text` node with `dimColor` forced on and `wrap="wrap"`. Three
consequences shape the card:

- The `"tokens says: "` prefix would shift the first grid row right, so the
  card leads with a newline to start every row at column 0.
- The forced dim is a `\e[2m` wrapper; the card's own `\e[0m` resets clear it
  at the first colored cell, so the ramp shows through at full intensity.
- Output over 10,000 characters is spilled to disk and replaced with a file
  reference. Cells are run-length encoded into shared color spans, which keeps
  a full year grid near 1 KB instead of 6 KB.

These follow the host's current rendering path; if a future version changes
how `systemMessage` is displayed, the card's spacing is what would drift.

## Why not `/usage`?

`/usage` is already a built-in Claude Code command (with aliases `/cost` and
`/stats`) — it shows your *current* session cost and plan-limit consumption.
Built-in names win, so a plugin command called `usage` would only be reachable
by its qualified form. This plugin answers a different question anyway: where
your tokens went *historically*, broken down by day, model, and project. The two
complement each other.

## How it works

Claude Code writes one JSONL transcript per session to
`~/.claude/projects/<slug>/<session-uuid>.jsonl`. Assistant records carry the
API `usage` block — input, output, cache-read and cache-write tokens — plus the
model, timestamp, and working directory. The plugin reads those files directly,
so it charts your full history immediately with no collection step and no
background process.

Transcripts are read-only, and nothing leaves the machine unless you link an
account (see below). No model ever sees any of this: the reader is plain Ruby,
and the startup card is emitted as a hook `systemMessage`, which Claude Code
shows you without adding it to the context window.

### Deduplication

A single API response is written to the transcript multiple times as the stream
progresses: each partial repeats the same `message.id` with a growing
`output_tokens` while the input and cache counts stay fixed. The script keeps
the maximum value seen per `message.id`, which is the completed response.
Summing every record instead would roughly double the totals.

### Cost and carbon

No rates are baked into this file. A table shipped inside a CLI goes stale
silently on every machine that has not updated, which is why the terminal
showed token counts only for a long time.

Instead a linked machine fetches the effective-dated rate table and the carbon
factors from the server, caches them at `~/.config/tal/rates.json`, and does the
arithmetic locally. The cache refreshes on every session start, alongside the
sync, and `tokens.rb --rates` forces it. Two things a baked table could not
have: it follows the server without a plugin release, and it knows how old it
is, so a figure drawn from a month-old copy says `rates 45 days old` instead of
quietly presenting itself as current.

The whole effective-dated table comes down rather than today's rates, because
the card prices a year of history and a day in March has to be priced at
March's rate. The arithmetic is a port of the server's `Pricing` and
`UsageFootprint` and is meant to agree with the website to the cent.

An unlinked machine, or one that has never reached the server, draws the card
exactly as it did before: tokens only, with no placeholder and no error. A
model with no rate on file is priced at the Opus-tier fallback and the line says
`some models unpriced`.

Estimates ignore subscription plans, batch discounts and org pricing, and will
not match an invoice. Carbon is inference only — training, networking, your own
machine and idle capacity are all outside it, which makes it a floor.

### One device

The card reads this machine's transcripts and cannot see any other, so its
totals are marked `from this device`. The website adds up every linked machine
and will show more. Said plainly so the two disagreeing looks like arithmetic
rather than a bug.

## Syncing to a tal account

Sign in and link a machine. The site prints a command once:

```
tokens.rb --link tal_…
tokens.rb --sync     # report now
tokens.rb --rates    # refresh the cached pricing and carbon tables
tokens.rb --unlink   # stop, and forget the token
```

The token is stored in `~/.config/tal/credentials.json` (mode 0600); the server
keeps only its SHA-256 digest. After linking, the `SessionStart` hook reports in
a detached child process, so a slow or unreachable server never delays a
session. That same process refreshes the rate cache, whether or not there is
anything to report — a machine that has not worked this week still wants
current rates for the history it already has.

Unlinking deletes the cached rates too. They came from that account and cannot
be refreshed once the credential is gone, so they go with it rather than aging
indefinitely on a machine that can no longer correct them.

What is sent is one row per local day, model, project and speed tier: token
counts and a response count. No prompts, no file contents, no paths beyond the
project directory's name. A report replaces the days it covers rather than
adding to them, so re-sending is harmless — and totals are stored per device, so
a second machine cannot overwrite the first one's day.

## Exporting the heatmap

`--export` writes the calendar to files, so anything else on the machine can
display it:

```
tokens.rb --export             # to the platform's data directory
tokens.rb --export ~/dashboard # or anywhere you like
```

Two files land in that directory:

| | |
|---|---|
| `heatmap.svg` | the year grid, self-contained, no external fonts or references |
| `usage.json` | every day in the window with its token count, plus totals and models |

Nothing is sent anywhere and no account is involved. The transcripts are already
on this machine, so an export works signed out, offline, and with no linking
step — it reads the same files the terminal view reads.

The default directory follows the platform: `%LOCALAPPDATA%\tal` on Windows,
`$XDG_DATA_HOME/tal` if set, otherwise `~/.local/share/tal`.

**Project names are not in either file.** The heatmap is about days, and an
export is the kind of thing that gets pasted into a README, so there is nothing
in it to leak. Model names and token counts are.

### Keeping it current

An export is a snapshot. To refresh it whenever a session starts, add a second
command to the plugin's `SessionStart` hook, or run it on a schedule:

```
# cron, hourly
0 * * * * ruby ~/.claude/plugins/tokens/scripts/tokens.rb --export

# launchd, systemd timers and Task Scheduler all work the same way
```

### Somewhere to put it

`usage.json` suits anything that computes; `heatmap.svg` suits anything that
displays. A few that need no more than the file:

- **A README or wiki** — commit the SVG and reference it like any other image.
- **Übersicht / GeekTool** — point a widget at the SVG.
- **Obsidian, Notion, a static site** — embed it from a synced folder.
- **A phone** — export into a cloud-synced directory and read it from a widget.

## Installing

From GitHub:

```
/plugin marketplace add Tal-AI-pwa/tokens-plugin
/plugin install tokens@tal
```

From a checkout of this repo:

```
/plugin marketplace add ./
/plugin install tokens@tal
```

## Requirements

Ruby 2.6 or newer, stdlib only — no gems, no bundler, no install step.

2.6 is the floor on purpose: it is the version macOS still ships, so the plugin
runs on a stock Mac with nothing added. Nothing here uses syntax or methods
newer than that, and the export is byte-identical on 2.6 and on 4.x. Most Linux
distributions ship 3.x. On Windows, Ruby is not present by default and has to be
installed.
