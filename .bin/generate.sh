#!/bin/bash
# 每日生成研发英语学习文件，提交并推送到远端。
# 由 launchd 在每天 07:00 和用户登录时触发：
#   - 当天文件还没生成：调用 claude -p 生成 → 校验 → 提交 → 推送
#   - 当天文件已存在：只补做没完成的提交和推送（比如上次推送时断网），所以重复触发没有影响
# 只提交当天新生成的文件，不碰工作区里其他未提交的改动；不 force push。
# 测试时可以用环境变量覆盖：LEARN_DIR=<目录> TARGET_DATE=<YYYY-MM-DD> NO_NOTIFY=1
set -euo pipefail

LEARN_DIR="${LEARN_DIR:-$HOME/研发英语}"
TARGET_DATE="${TARGET_DATE:-$(date +%F)}"
PROMPT_FILE="$HOME/研发英语/.bin/prompt.md"
CLAUDE_BIN="$HOME/.local/bin/claude"
BRANCH="main"
REMOTE="origin"
LOG_DIR="$LEARN_DIR/.logs"
LOG_FILE="$LOG_DIR/$TARGET_DATE.log"
LOCK_DIR="$LOG_DIR/.lock"

mkdir -p "$LOG_DIR"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"; }
notify() {
  [[ "${NO_NOTIFY:-0}" == "1" ]] && return 0
  osascript -e "display notification \"$1\" with title \"研发英语\"" >/dev/null 2>&1 || true
}
fail() { log "error: $1"; notify "$1，日志见 .logs/$TARGET_DATE.log"; exit 1; }

todays_file() { compgen -G "$LEARN_DIR/${TARGET_DATE}_Day*.md" | head -n 1 || true; }

sentence_count() { grep -cE '^### [0-9]+\. ' "$1" || true; }

# 当天文件如果还没进版本库，校验通过后单独提交（只 add 这一个文件）
commit_todays_file() {
  local file="$1" name day topic level count
  name="$(basename "$file")"

  if git ls-files --error-unmatch -- "$name" >/dev/null 2>&1; then
    return 0 # 已经提交过
  fi

  count="$(sentence_count "$file")"
  if [[ "$count" != "20" ]]; then
    fail "$name 有 $count 句，不是 20 句，未提交，请检查后手动提交"
  fi

  # 文件名形如 2026-11-24_Day02_站会入门.md
  day="$(sed -E 's/^[0-9-]+_Day([0-9]+)_.*$/\1/' <<<"$name")"
  topic="$(sed -E 's/^[0-9-]+_Day[0-9]+_(.*)\.md$/\1/' <<<"$name")"
  level="$(grep -m1 -oE 'L[0-9]+ [^*（]+' "$file" || echo '未标注')"

  git add -- "$name"
  git commit -q -F - <<EOF
docs(day$day): 新增 Day $day $topic 20 句

- $(head -n 1 "$file" | sed -E 's/^# //')
- 难度：$level
- 由 .bin/generate.sh 每日自动生成，已校验恰好 20 句

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
  log "committed: $(git log -1 --format='%h %s')"
}

# 本地有远端没有的提交就推送；远端有新提交时先 rebase 再推，有冲突就停下，不 force push
push_if_ahead() {
  if ! git fetch -q "$REMOTE" "$BRANCH" >>"$LOG_FILE" 2>&1; then
    log "warn: fetch failed, will retry next run"
    return 1
  fi

  local ahead
  ahead="$(git rev-list --count "$REMOTE/$BRANCH..HEAD")"
  if [[ "$ahead" == "0" ]]; then
    return 0
  fi

  if ! git merge-base --is-ancestor "$REMOTE/$BRANCH" HEAD; then
    log "remote has new commits, rebasing onto $REMOTE/$BRANCH"
    if ! git rebase -q --autostash "$REMOTE/$BRANCH" >>"$LOG_FILE" 2>&1; then
      git rebase --abort >>"$LOG_FILE" 2>&1 || true
      fail "已生成并提交，但和远端有冲突，未推送，需要手动处理"
    fi
  fi

  if ! git push -q "$REMOTE" "$BRANCH" >>"$LOG_FILE" 2>&1; then
    log "warn: push failed, will retry next run"
    return 1
  fi
  log "pushed $ahead commit(s) to $REMOTE/$BRANCH"
}

# 提交并推送；当前不在 main 分支或不是 git 仓库时跳过，避免推错分支
sync_to_remote() {
  local file="$1" name current_branch
  name="$(basename "$file")"

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log "warn: $LEARN_DIR is not a git repo, skip commit and push"
    return 0
  fi
  current_branch="$(git symbolic-ref --short HEAD 2>/dev/null || echo detached)"
  if [[ "$current_branch" != "$BRANCH" ]]; then
    log "warn: current branch is $current_branch, not $BRANCH, skip commit and push"
    notify "$name 已生成，但当前分支是 $current_branch，未提交推送"
    return 0
  fi

  commit_todays_file "$file"
  if push_if_ahead; then
    return 0
  fi
  notify "$name 已生成并提交，推送失败（可能是网络问题），下次登录或明早会自动重试"
  return 1
}

# 防并发：登录触发和定时触发可能撞在一起。超过 30 分钟的锁视为上次异常退出留下的，清掉。
if [[ -d "$LOCK_DIR" ]] && [[ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +30)" ]]; then
  log "removing stale lock"
  rmdir "$LOCK_DIR"
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

cd "$LEARN_DIR"

# 当天文件已存在：只补做提交和推送
existing="$(todays_file)"
if [[ -n "$existing" ]]; then
  sync_to_remote "$existing" || true
  exit 0
fi

[[ -x "$CLAUDE_BIN" ]] || fail "生成失败：找不到 $CLAUDE_BIN"
[[ -f "$PROMPT_FILE" ]] || fail "生成失败：找不到 $PROMPT_FILE"

prompt="$(<"$PROMPT_FILE")"
prompt="${prompt//\{\{DATE\}\}/$TARGET_DATE}"
prompt="${prompt//\{\{DIR\}\}/$LEARN_DIR}"

log "start generating for $TARGET_DATE in $LEARN_DIR"

# 只放行读、搜、新建文件；不加载 MCP 服务，禁用 shell / 编辑 / 联网
if ! "$CLAUDE_BIN" -p "$prompt" \
  --strict-mcp-config \
  --permission-mode acceptEdits \
  --allowedTools "Read" "Glob" "Grep" "Write" \
  --disallowedTools "Bash" "Edit" "NotebookEdit" "WebFetch" "WebSearch" "Agent" \
  --no-session-persistence \
  >>"$LOG_FILE" 2>&1; then
  fail "生成失败：claude 异常退出"
fi

generated="$(todays_file)"
[[ -n "$generated" ]] || fail "生成失败：没有产出文件"
log "generated: $(basename "$generated") ($(sentence_count "$generated") sentences)"

if sync_to_remote "$generated"; then
  notify "今日 20 句已生成并推送：$(basename "$generated")"
fi
