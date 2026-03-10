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

A single global snapshot tracks the token count after each commit across all repositories. The delta for each commit equals tokens spent since the last commit — regardless of which project they were used in.

The snapshot also stores the ccusage block's `startTime`. If the block changes between commits, a new baseline is saved automatically and cost is not charged for that transition.

After each `git commit`:

```
markup [100]:
coef (0-1) [1]: 0.3

────────────────────────────────
  commit : a3f2c1 — fix auth bug
  tokens : 3200  (API: $0.03)
  markup : 100 × 0.3
  💰     : $0.90
────────────────────────────────
```

**First commit** saves the baseline silently:

```
📍 first commit: token baseline saved (45230)
```

**New ccusage block** detected between commits:

```
♻ new ccusage block, saving baseline (112000)
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
| `~/.cache/claude-tracker/` | Global token snapshot |

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
