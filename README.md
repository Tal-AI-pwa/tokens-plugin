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

This comes installed by default on MacOS.
