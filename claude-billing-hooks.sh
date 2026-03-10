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
#   формула: (токены_коммита / токены_сессии) × стоимость_API_сессии × наценка × коэф
#   каждый коммит считается независимо — цена пропорциональна реальной стоимости токенов.
#
# УСТАНОВКА:
#   bash claude-billing-hooks.sh
#
# ПОСЛЕ УСТАНОВКИ:
#   просто делай git commit как обычно.
#   в терминале появится:
#
#     наценка [3]:
#     коэф (0-1) [1]: 0.3
#
#     ────────────────────────────────
#       коммит : a3f2c1 — fix auth bug
#       токены : 3200 (API: $0.03)
#       наценка: 3 × 0.3
#       💰     : $0.09
#     ────────────────────────────────
#
# СМЕНИТЬ НАЦЕНКУ:
#   nano ~/.claude-tracker.json
#
# ЛОГ ВСЕХ КОММИТОВ (CSV):
#   cat ~/.claude-commits.csv
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
  echo "наценка — во сколько раз твоя цена выше стоимости API (например 3 = берёшь втрое дороже)"
  read -r -p "наценка [3]: " MARKUP < /dev/tty
  MARKUP=${MARKUP:-3}
  if ! [[ "$MARKUP" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "некорректное значение, используем 3"
    MARKUP=3
  fi
  echo "{\"markup\": $MARKUP}" > "$CONFIG_FILE"
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
LOG_FILE="$HOME/.claude-commits.csv"

REPO_PATH=$(git rev-parse --show-toplevel 2>/dev/null)
PROJECT=$(basename "$REPO_PATH")
if command -v md5sum &>/dev/null; then
  REPO_HASH=$(printf "%s" "$REPO_PATH" | md5sum | cut -c1-8)
else
  REPO_HASH=$(printf "%s" "$REPO_PATH" | md5 | cut -c1-8)
fi
SNAPSHOT_FILE="$SNAPSHOT_DIR/.tokens-$REPO_HASH"

# получаем токены и стоимость активного блока
read TOKENS_NOW COST_USD <<< $(npx ccusage blocks --json 2>/dev/null | node -e '
  const d = JSON.parse(require("fs").readFileSync("/dev/stdin", "utf8"));
  const active = (d.data || d.blocks || []).find(b => b.isActive);
  if (active) {
    process.stdout.write(active.totalTokens + " " + active.costUSD);
  } else {
    process.stdout.write("0 0");
  }
' 2>/dev/null)
TOKENS_NOW=${TOKENS_NOW:-0}
COST_USD=${COST_USD:-0}

# если снапшота нет — первый коммит, сохраняем baseline
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
    printf "♻ сессия ccusage сбросилась, считаем токены с начала сессии\n" > /dev/tty
    DELTA=$TOKENS_NOW
  else
    printf "⚠ токены не изменились с последнего коммита\n" > /dev/tty
    echo "$TOKENS_NOW" > "$SNAPSHOT_FILE"
    exit 0
  fi
fi

DEFAULT_MARKUP=$(node -e "
  try {
    const c = JSON.parse(require('fs').readFileSync('$CONFIG_FILE', 'utf8'));
    process.stdout.write(String(c.markup || 3));
  } catch(e) { process.stdout.write('3'); }
" 2>/dev/null)
DEFAULT_MARKUP=${DEFAULT_MARKUP:-3}

printf "\n" > /dev/tty
read -r -p "наценка [$DEFAULT_MARKUP]: " MARKUP < /dev/tty
MARKUP=${MARKUP:-$DEFAULT_MARKUP}
if ! [[ "$MARKUP" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then MARKUP=$DEFAULT_MARKUP; fi

read -r -p "коэф (0-1) [1]: " COEF < /dev/tty
COEF=${COEF:-1}
if ! [[ "$COEF" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]]; then COEF=1; fi

# сохраняем наценку
node -e "
  try {
    const fs = require('fs');
    const c = JSON.parse(fs.readFileSync('$CONFIG_FILE', 'utf8'));
    c.markup = Number('$MARKUP');
    fs.writeFileSync('$CONFIG_FILE', JSON.stringify(c, null, 2));
  } catch(e) {}
" 2>/dev/null

# стоимость этого коммита по API: пропорционально токенам в блоке
# cost_api = (DELTA / TOKENS_NOW) * COST_USD
# итог = cost_api * MARKUP * COEF
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

# CSV: экранируем сообщение коммита (обёртка в кавычки, двойные кавычки удваиваем)
COMMIT_MSG_CSV=$(printf '%s' "$COMMIT_MSG" | sed 's/"/""/g')

[ ! -f "$LOG_FILE" ] && printf "timestamp,project,commit,message,tokens,api_cost_usd,markup,coef,cost_usd\n" >> "$LOG_FILE"

printf '"%s","%s","%s","%s",%s,%s,%s,%s,%s\n' \
  "$TIMESTAMP" "$PROJECT" "$COMMIT_HASH" "$COMMIT_MSG_CSV" \
  "$DELTA" "$COST_API" "$MARKUP" "$COEF" "$COST" >> "$LOG_FILE"

# сохраняем снапшот для следующего коммита
echo "$TOKENS_NOW" > "$SNAPSHOT_FILE"
chmod 600 "$SNAPSHOT_FILE"
EOF

chmod +x "$GLOBAL_HOOKS_DIR/pre-commit"
chmod +x "$GLOBAL_HOOKS_DIR/post-commit"

echo ""
echo "✓ установлено — работает во всех репозиториях"
echo "✓ лог: $HOME/.claude-commits.csv"
