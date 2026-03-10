# claude-billing-hooks

A global git hook that tracks Claude API token usage and calculates the billable cost of each commit.

## How it works

- Installs global `pre-commit` and `post-commit` hooks via `git config --global core.hooksPath`
- **pre-commit**: delegates to the local repo's hook if one exists
- **post-commit**: gets token usage and real API cost from `ccusage`, calculates commit cost, logs to CSV

**Formula:**

```
commit_cost = (commit_tokens / session_tokens) × session_api_cost × markup × coef
```

Each commit is priced independently based on actual API cost — no fixed session size needed.

After each `git commit`:

```
наценка [100]:
коэф (0-1) [1]: 0.3

────────────────────────────────
  коммит : a3f2c1 — fix auth bug
  токены : 3200  (API: $0.03)
  наценка: 100 × 0.3
  💰     : $0.90
────────────────────────────────
```

**First commit** in a repo saves the baseline and exits:

```
📍 первый коммит: baseline токенов сохранён (45230)
```

If ccusage resets between commits (new 5-hour block):

```
♻ сессия ccusage сбросилась, считаем токены с начала сессии
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
| `~/.claude-tracker.json` | Saved markup value |
| `~/.claude-commits.csv` | Full commit cost log (CSV) |
| `~/.cache/claude-tracker/` | Per-repo token snapshots |

## Config

```json
{ "markup": 100 }
```

Change anytime:

```bash
nano ~/.claude-tracker.json
```

## View log

```bash
cat ~/.claude-commits.csv
```

CSV columns: `timestamp, project, commit, message, tokens, api_cost_usd, markup, coef, cost_usd`
