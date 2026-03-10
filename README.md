# claude-billing-hooks

A global git hook that tracks Claude API token usage and calculates the cost of each commit.

## How it works

- Installs global `pre-commit` and `post-commit` hooks via `git config --global core.hooksPath`
- **pre-commit**: snapshots the current token count from `ccusage` before the commit
- **post-commit**: reads the snapshot, calculates the token delta, prompts for session rate and coefficient, then displays and logs the estimated cost

After each `git commit` you'll see:

```
📍 токены до коммита: 45230

ставка за сессию [150]:
коэф (0-1) [1]: 0.3

────────────────────────────────
  коммит : a3f2c1 — fix auth bug
  токены : 3200 / 48430 в сессии
  ставка : $150 × 0.3
  💰     : $2.97
────────────────────────────────
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
| `~/.claude-tracker.json` | Saved default rate |
| `~/.claude-commits.log` | Full commit cost log |
| `~/.cache/claude-tracker/` | Temporary token snapshots |

## Change default rate

```bash
nano ~/.claude-tracker.json
```

## View log

```bash
cat ~/.claude-commits.log
```