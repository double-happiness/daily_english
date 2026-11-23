#!/bin/bash
# 每日生成研发英语学习文件。
# 由 launchd 在每天 07:30 和用户登录时触发；当天文件已存在就直接退出（幂等），所以重复触发没有影响。
# 测试时可以用环境变量覆盖：LEARN_DIR=<目录> TARGET_DATE=<YYYY-MM-DD>
set -euo pipefail

LEARN_DIR="${LEARN_DIR:-$HOME/研发英语}"
TARGET_DATE="${TARGET_DATE:-$(date +%F)}"
PROMPT_FILE="$HOME/研发英语/.bin/prompt.md"
CLAUDE_BIN="$HOME/.local/bin/claude"
LOG_DIR="$LEARN_DIR/.logs"
LOG_FILE="$LOG_DIR/$TARGET_DATE.log"
LOCK_DIR="$LOG_DIR/.lock"

mkdir -p "$LOG_DIR"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"; }
# 测试时设 NO_NOTIFY=1 关掉系统通知
notify() {
  [[ "${NO_NOTIFY:-0}" == "1" ]] && return 0
  osascript -e "display notification \"$1\" with title \"研发英语\"" >/dev/null 2>&1 || true
}
fail() { log "error: $1"; notify "生成失败：$1，日志见 .logs/$TARGET_DATE.log"; exit 1; }

# 幂等：当天文件已存在就退出
if compgen -G "$LEARN_DIR/${TARGET_DATE}_Day*.md" >/dev/null; then
  exit 0
fi

# 防并发：登录触发和定时触发可能撞在一起。超过 30 分钟的锁视为上次异常退出留下的，清掉。
if [[ -d "$LOCK_DIR" ]] && [[ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +30)" ]]; then
  log "removing stale lock"
  rmdir "$LOCK_DIR"
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log "skip: another run in progress"
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

[[ -x "$CLAUDE_BIN" ]] || fail "claude not found at $CLAUDE_BIN"
[[ -f "$PROMPT_FILE" ]] || fail "prompt not found at $PROMPT_FILE"

prompt="$(<"$PROMPT_FILE")"
prompt="${prompt//\{\{DATE\}\}/$TARGET_DATE}"
prompt="${prompt//\{\{DIR\}\}/$LEARN_DIR}"

log "start generating for $TARGET_DATE in $LEARN_DIR"
cd "$LEARN_DIR"

# 只放行读、搜、新建文件；不加载 MCP 服务，禁用 shell / 编辑 / 联网
if ! "$CLAUDE_BIN" -p "$prompt" \
  --strict-mcp-config \
  --permission-mode acceptEdits \
  --allowedTools "Read" "Glob" "Grep" "Write" \
  --disallowedTools "Bash" "Edit" "NotebookEdit" "WebFetch" "WebSearch" "Agent" \
  --no-session-persistence \
  >>"$LOG_FILE" 2>&1; then
  fail "claude exited with non-zero status"
fi

# 校验产物：文件存在且恰好 20 句
generated="$(compgen -G "$LEARN_DIR/${TARGET_DATE}_Day*.md" | head -n 1 || true)"
[[ -n "$generated" ]] || fail "no file generated"

sentence_count="$(grep -cE '^### [0-9]+\. ' "$generated" || true)"
file_name="$(basename "$generated")"
if [[ "$sentence_count" != "20" ]]; then
  log "warn: $file_name has $sentence_count sentences, expected 20"
  notify "已生成 $file_name，但句子数是 $sentence_count，不是 20"
else
  log "done: $file_name"
  notify "今日 20 句已生成：$file_name"
fi
