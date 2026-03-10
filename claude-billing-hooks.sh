#!/bin/bash
# ─────────────────────────────────────────
# claude commit tracker — глобальная установка
# ─────────────────────────────────────────
#
# КАК РАБОТАЕТ:
#   устанавливается один раз глобально.
#   срабатывает при каждом git commit в любом репозитории.
#   считает токены, потраченные МЕЖДУ коммитами, и переводит в стоимость.
#
#   формула: (токены_коммита / токены_блока) × стоимость_API_блока × наценка × коэф
#   каждый коммит считается независимо — цена пропорциональна реальной стоимости токенов.
#
# УСТАНОВКА:
#   bash claude-billing-hooks.sh
#
# ПОСЛЕ УСТАНОВКИ:
#   просто делай git commit как обычно.
#   в терминале появится:
#
#     наценка [100]:
#     коэф (0-1) [1]: 0.3
#
#     ────────────────────────────────
#       коммит : a3f2c1 — fix auth bug
#       токены : 3200 (API: $0.03)
#       наценка: 100 × 0.3
#       💰     : $0.90
#     ────────────────────────────────
#
# ЛОГ ВСЕХ КОММИТОВ (CSV):
#   cat ~/.claude-commits.csv
#
# ─────────────────────────────────────────


for dep in node npx git; do
  if ! command -v "$dep" &>/dev/null; then
    echo "ошибка: '$dep' не найден в PATH" >&2
    exit 1
  fi
done

GLOBAL_HOOKS_DIR="$HOME/.git-hooks"
SNAPSHOT_DIR="$HOME/.cache/claude-tracker"
mkdir -p "$GLOBAL_HOOKS_DIR" "$SNAPSHOT_DIR"

git config --global core.hooksPath "$GLOBAL_HOOKS_DIR"

# ── pre-commit ────────────────────────────
cat > "$GLOBAL_HOOKS_DIR/pre-commit" << 'EOF'
#!/bin/bash
LOCAL_HOOK="$(git rev-parse --git-dir 2>/dev/null)/hooks/pre-commit"
if [ -x "$LOCAL_HOOK" ]; then
  "$LOCAL_HOOK" "$@" || exit $?
fi
EOF

# ── post-commit ───────────────────────────
cat > "$GLOBAL_HOOKS_DIR/post-commit" << 'EOF'
#!/bin/bash

# вызываем локальный хук репозитория (если есть)
LOCAL_HOOK="$(git rev-parse --git-dir 2>/dev/null)/hooks/post-commit"
if [ -x "$LOCAL_HOOK" ]; then
  "$LOCAL_HOOK" "$@"
fi

DEFAULT_MARKUP=100
DEFAULT_COEF=1

SNAPSHOT_DIR="$HOME/.cache/claude-tracker"
LOG_FILE="$HOME/.claude-commits.csv"
mkdir -p "$SNAPSHOT_DIR"

REPO_PATH=$(git rev-parse --show-toplevel 2>/dev/null)
PROJECT=$(basename "$REPO_PATH")
SNAPSHOT_FILE="$SNAPSHOT_DIR/.tokens-global"

# получаем токены, стоимость и startTime активного блока
read TOKENS_NOW COST_USD BLOCK_START <<< $(npx ccusage blocks --json 2>/dev/null | node -e '
  const d = JSON.parse(require("fs").readFileSync("/dev/stdin", "utf8"));
  const active = (d.data || d.blocks || []).find(b => b.isActive);
  if (active) {
    process.stdout.write(active.totalTokens + " " + active.costUSD + " " + active.startTime);
  } else {
    process.stdout.write("0 0 unknown");
  }
' 2>/dev/null)
TOKENS_NOW=${TOKENS_NOW:-0}
COST_USD=${COST_USD:-0}
BLOCK_START=${BLOCK_START:-unknown}

# если снапшота нет — первый коммит, сохраняем baseline
if [ ! -f "$SNAPSHOT_FILE" ]; then
  printf "%s %s" "$TOKENS_NOW" "$BLOCK_START" > "$SNAPSHOT_FILE"
  chmod 600 "$SNAPSHOT_FILE"
  printf "📍 первый коммит: baseline токенов сохранён (%s)\n" "$TOKENS_NOW" > /dev/tty
  exit 0
fi

read TOKENS_BEFORE BLOCK_START_BEFORE < "$SNAPSHOT_FILE"
DELTA=$((TOKENS_NOW - TOKENS_BEFORE))

# новый блок ccusage — сбрасываем baseline
if [ "$BLOCK_START" != "$BLOCK_START_BEFORE" ]; then
  printf "♻ новый блок ccusage, сохраняем baseline (%s)\n" "$TOKENS_NOW" > /dev/tty
  printf "%s %s" "$TOKENS_NOW" "$BLOCK_START" > "$SNAPSHOT_FILE"
  chmod 600 "$SNAPSHOT_FILE"
  exit 0
fi

if [ "$DELTA" -le 0 ]; then
  printf "⚠ токены не изменились с последнего коммита\n" > /dev/tty
  printf "%s %s" "$TOKENS_NOW" "$BLOCK_START" > "$SNAPSHOT_FILE"
  exit 0
fi

printf "\n" > /dev/tty
read -r -p "наценка [$DEFAULT_MARKUP]: " MARKUP < /dev/tty
MARKUP=${MARKUP:-$DEFAULT_MARKUP}
if ! [[ "$MARKUP" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then MARKUP=$DEFAULT_MARKUP; fi

read -r -p "коэф (0-1) [$DEFAULT_COEF]: " COEF < /dev/tty
COEF=${COEF:-$DEFAULT_COEF}
if ! [[ "$COEF" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]]; then COEF=$DEFAULT_COEF; fi

read COST_API COST <<< $(node -e "
  const delta = ${DELTA};
  const total = ${TOKENS_NOW} || 1;
  const costUSD = ${COST_USD} || 0;
  const costApi = (delta / total) * costUSD;
  const cost = costApi * ${MARKUP} * ${COEF};
  process.stdout.write(
    costApi.toFixed(4) + ' ' + (isFinite(cost) ? cost.toFixed(2) : '0.00')
  );
")

COMMIT_HASH=$(git rev-parse --short HEAD)
COMMIT_MSG=$(git log -1 --pretty=%s)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M')

{
  printf "\n"
  printf "────────────────────────────────\n"
  printf "  коммит : %s — %s\n" "$COMMIT_HASH" "$COMMIT_MSG"
  printf "  токены : %s  (API: \$%s)\n" "$DELTA" "$COST_API"
  printf "  наценка: %s × %s\n" "$MARKUP" "$COEF"
  printf "  💰     : \$%s\n" "$COST"
  printf "────────────────────────────────\n"
} > /dev/tty

COMMIT_MSG_CSV=$(printf '%s' "$COMMIT_MSG" | sed 's/"/""/g')

[ ! -f "$LOG_FILE" ] && printf "timestamp,project,commit,message,tokens,api_cost_usd,markup,coef,cost_usd\n" >> "$LOG_FILE"

printf '"%s","%s","%s","%s",%s,%s,%s,%s,%s\n' \
  "$TIMESTAMP" "$PROJECT" "$COMMIT_HASH" "$COMMIT_MSG_CSV" \
  "$DELTA" "$COST_API" "$MARKUP" "$COEF" "$COST" >> "$LOG_FILE"

printf "%s %s" "$TOKENS_NOW" "$BLOCK_START" > "$SNAPSHOT_FILE"
chmod 600 "$SNAPSHOT_FILE"
EOF

chmod +x "$GLOBAL_HOOKS_DIR/pre-commit"
chmod +x "$GLOBAL_HOOKS_DIR/post-commit"

echo ""
echo "✓ установлено — работает во всех репозиториях"
echo "✓ лог: $HOME/.claude-commits.csv"
