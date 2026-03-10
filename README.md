# claude-billing-hooks

A global git hook that tracks Claude API token usage and calculates the billable cost of each commit.

## How it works

- Installs global `pre-commit` and `post-commit` hooks via `git config --global core.hooksPath`
- **pre-commit**: delegates to the local repo's hook if one exists
- **post-commit**: gets token usage and real API cost from `ccusage`, calculates commit cost, logs to CSV

**Formula:**

```
commit_cost = (commit_tokens / block_tokens) × block_api_cost × markup × coef
```

Equivalent to `commit_tokens × price_per_token × markup × coef` — each commit is priced independently based on actual API cost.

The snapshot stores the ccusage block's `startTime` alongside token count. If the block changes between commits, a new baseline is saved automatically and cost is not charged for that transition.

After each `git commit`:

```
наценка [100]:
коэф (0-1) [1]: 0.3

────────────────────────────────
  коммит : a3f2c1 — fix auth bug
  токены : 3200  (API: $0.03)
  наценка: 100 × 0.3
  💰     : $3.00
────────────────────────────────
```

**First commit** in a repo saves the baseline silently:

```
📍 первый коммит: baseline токенов сохранён (45230)
```

**New ccusage block** detected between commits:

```
♻ новый блок ccusage, сохраняем baseline (112000)
```

## Requirements

- `node`, `npx`, `git` in PATH
- [`ccusage`](https://github.com/ryoppippi/ccusage) accessible via `npx ccusage`

## Installation

```bash
bash claude-billing-hooks.sh
```

Run once — works globally across all repositories.

## Files

| Path | Description |
|---|---|
| `~/.git-hooks/` | Global hook scripts |
| `~/.claude-commits.csv` | Full commit cost log |
| `~/.cache/claude-tracker/` | Per-repo token snapshots |

## Defaults

Hardcoded in the script:

```bash
DEFAULT_MARKUP=100   # markup over API cost
DEFAULT_COEF=1       # attribution coefficient
```

Change and reinstall to update defaults. Per-commit overrides via prompts.

## View log

```bash
cat ~/.claude-commits.csv
```

CSV columns: `timestamp, project, commit, message, tokens, api_cost_usd, markup, coef, cost_usd`
