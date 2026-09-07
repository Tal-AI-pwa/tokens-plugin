---
description: Chart token usage over time (history, not plan limits)
argument-hint: [--days N] [--weeks] [--all] [--project NAME]
allowed-tools: Bash(ruby:*)
---

!`ruby "${CLAUDE_PLUGIN_ROOT}/scripts/tokens.rb" $ARGUMENTS`

The usage report above is already rendered for the user. Do not re-print it,
re-format it, or restate the numbers.

Respond with at most two sentences noting anything genuinely notable — a sharp
spike, a model or project dominating spend, an unusual cache-read ratio. If
nothing stands out, say nothing at all.

Costs are estimates computed from published per-million-token rates, not billed
amounts.
