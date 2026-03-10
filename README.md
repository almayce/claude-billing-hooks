# claude-billing-hooks

A global git hook that tracks Claude API token usage and calculates the cost of each commit.

## How it works

- Installs global `pre-commit` and `post-commit` hooks via `git config --global core.hooksPath`
- **pre-commit**: delegates to the local repo's `pre-commit` hook if one exists (no token logic)
- **post-commit**: reads the previous token snapshot, calculates the delta, prompts for session rate and coefficient, displays and logs the estimated cost, then saves a new snapshot for the next commit

The snapshot is stored per-repo (`~/.cache/claude-tracker/.tokens-<repo-hash>`), so tracking works independently across multiple repositories.

**First commit** in a repo saves the baseline and exits:

```
📍 первый коммит: baseline токенов сохранён (45230)
```

**Subsequent commits** prompt and show the cost:

```
ставка за сессию [150]:
коэф (0-1) [1]: 0.3

────────────────────────────────
  коммит : a3f2c1 — fix auth bug
  токены : 3200 / 48430 в сессии
  ставка : $150 × 0.3
  💰     : $2.97
────────────────────────────────
```

If ccusage resets between commits (new block / restart), the hook detects it and counts tokens from the start of the new session:

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
| `~/.claude-tracker.json` | Saved default rate |
| `~/.claude-commits.log` | Full commit cost log |
| `~/.cache/claude-tracker/` | Per-repo token snapshots |

## Change default rate

```bash
nano ~/.claude-tracker.json
```

## View log

```bash
cat ~/.claude-commits.log
```
