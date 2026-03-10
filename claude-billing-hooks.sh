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
# УСТАНОВКА:
#   bash claude-billing-hooks.sh
#
# ПОСЛЕ УСТАНОВКИ:
#   просто делай git commit как обычно.
#   в терминале появится:
#
#     ставка за сессию [150]:
#     коэф (0-1) [1]: 0.3
#
#     ────────────────────────────────
#       коммит : a3f2c1 — fix auth bug
#       токены : 3200 / 48430 в сессии
#       💰     : $2.97
#     ────────────────────────────────
#
# СМЕНИТЬ ДЕФОЛТНУЮ СТАВКУ:
#   nano ~/.claude-tracker.json
#
# ЛОГ ВСЕХ КОММИТОВ:
#   cat ~/.claude-commits.log
#
# ─────────────────────────────────────────

# ── проверка зависимостей ─────────────────
for dep in node npx git; do
  if ! command -v "$dep" &>/dev/null; then
    echo "ошибка: '$dep' не найден в PATH" >&2
    exit 1
  fi
done

GLOBAL_HOOKS_DIR="$HOME/.git-hooks"
SNAPSHOT_DIR="$HOME/.cache/claude-tracker"
CONFIG_FILE="$HOME/.claude-tracker.json"
mkdir -p "$GLOBAL_HOOKS_DIR" "$SNAPSHOT_DIR"

git config --global core.hooksPath "$GLOBAL_HOOKS_DIR"

if [ ! -f "$CONFIG_FILE" ]; then
  read -r -p "базовая ставка за сессию (например 150): " RATE < /dev/tty
  RATE=${RATE:-150}
  if ! [[ "$RATE" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "некорректное значение, используем 150"
    RATE=150
  fi
  echo "{\"base_rate\": $RATE}" > "$CONFIG_FILE"
fi

# ── pre-commit ────────────────────────────
# только вызываем локальный хук репозитория (если есть)
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

CONFIG_FILE="$HOME/.claude-tracker.json"
SNAPSHOT_DIR="$HOME/.cache/claude-tracker"
LOG_FILE="$HOME/.claude-commits.log"

REPO_PATH=$(git rev-parse --show-toplevel 2>/dev/null)
if command -v md5sum &>/dev/null; then
  REPO_HASH=$(printf "%s" "$REPO_PATH" | md5sum | cut -c1-8)
else
  REPO_HASH=$(printf "%s" "$REPO_PATH" | md5 | cut -c1-8)
fi
SNAPSHOT_FILE="$SNAPSHOT_DIR/.tokens-$REPO_HASH"

# получаем текущие токены
TOKENS_NOW=$(npx ccusage blocks --json 2>/dev/null | node -e '
  const d = JSON.parse(require("fs").readFileSync("/dev/stdin", "utf8"));
  const active = (d.data || d.blocks || []).find(b => b.isActive);
  process.stdout.write(String(active ? active.totalTokens : 0));
' 2>/dev/null)
TOKENS_NOW=${TOKENS_NOW:-0}

# если снапшота нет — первый коммит, просто сохраняем baseline
if [ ! -f "$SNAPSHOT_FILE" ]; then
  echo "$TOKENS_NOW" > "$SNAPSHOT_FILE"
  chmod 600 "$SNAPSHOT_FILE"
  printf "📍 первый коммит: baseline токенов сохранён (%s)\n" "$TOKENS_NOW" > /dev/tty
  exit 0
fi

TOKENS_BEFORE=$(cat "$SNAPSHOT_FILE")
DELTA=$((TOKENS_NOW - TOKENS_BEFORE))

if [ "$DELTA" -le 0 ]; then
  if [ "$TOKENS_NOW" -gt 0 ] && [ "$TOKENS_NOW" -lt "$TOKENS_BEFORE" ]; then
    # сессия сбросилась (рестарт / новый блок) — считаем токены с начала новой сессии
    printf "♻ сессия ccusage сбросилась, считаем токены с начала сессии\n" > /dev/tty
    DELTA=$TOKENS_NOW
  else
    printf "⚠ токены не изменились с последнего коммита\n" > /dev/tty
    echo "$TOKENS_NOW" > "$SNAPSHOT_FILE"
    exit 0
  fi
fi

SESSION_TOKENS=$TOKENS_NOW
[ "$SESSION_TOKENS" -eq 0 ] && SESSION_TOKENS=1

DEFAULT_RATE=$(node -e "
  try {
    const c = JSON.parse(require('fs').readFileSync('$CONFIG_FILE', 'utf8'));
    process.stdout.write(String(c.base_rate || 150));
  } catch(e) { process.stdout.write('150'); }
" 2>/dev/null)
DEFAULT_RATE=${DEFAULT_RATE:-150}

printf "\n" > /dev/tty
read -r -p "ставка за сессию [$DEFAULT_RATE]: " RATE < /dev/tty
RATE=${RATE:-$DEFAULT_RATE}
if ! [[ "$RATE" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then RATE=$DEFAULT_RATE; fi

read -r -p "коэф (0-1) [1]: " COEF < /dev/tty
COEF=${COEF:-1}
if ! [[ "$COEF" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]]; then COEF=1; fi

# сохраняем новую ставку
node -e "
  try {
    const fs = require('fs');
    const c = JSON.parse(fs.readFileSync('$CONFIG_FILE', 'utf8'));
    c.base_rate = Number('$RATE');
    fs.writeFileSync('$CONFIG_FILE', JSON.stringify(c, null, 2));
  } catch(e) {}
" 2>/dev/null

COST=$(node -e "
  const cost = (${DELTA} / ${SESSION_TOKENS}) * ${RATE} * ${COEF};
  process.stdout.write(isFinite(cost) ? cost.toFixed(2) : '0.00');
")

COMMIT_HASH=$(git rev-parse --short HEAD)
COMMIT_MSG=$(git log -1 --pretty=%s)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M')

{
  printf "\n"
  printf "────────────────────────────────\n"
  printf "  коммит : %s — %s\n" "$COMMIT_HASH" "$COMMIT_MSG"
  printf "  токены : %s / %s в сессии\n" "$DELTA" "$SESSION_TOKENS"
  printf "  ставка : \$%s × %s\n" "$RATE" "$COEF"
  printf "  💰     : \$%s\n" "$COST"
  printf "────────────────────────────────\n"
} > /dev/tty

printf "%s | %s | %s | tokens:%s | session:%s | rate:%s | coef:%s | cost:$%s\n" \
  "$TIMESTAMP" "$COMMIT_HASH" "$COMMIT_MSG" \
  "$DELTA" "$SESSION_TOKENS" "$RATE" "$COEF" "$COST" >> "$LOG_FILE"

# сохраняем снапшот для следующего коммита
echo "$TOKENS_NOW" > "$SNAPSHOT_FILE"
chmod 600 "$SNAPSHOT_FILE"
EOF

chmod +x "$GLOBAL_HOOKS_DIR/pre-commit"
chmod +x "$GLOBAL_HOOKS_DIR/post-commit"

echo ""
echo "✓ установлено — работает во всех репозиториях"
echo "✓ лог: $HOME/.claude-commits.log"
