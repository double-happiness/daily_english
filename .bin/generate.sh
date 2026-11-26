#!/bin/bash
# 每日生成研发英语学习文件，提交并推送到远端。
# 由 launchd 在每天 07:00、用户登录时触发，并且每 5 分钟触发一次检查（电脑真正醒来后几分钟内就能补做）：
#   - 当天已全部完成（文件已推到远端，微信已发或不需要发）：直接退出，不联网、不写日志
#   - 当天文件还没生成：调用 claude -p 生成 → 校验 → 提交 → 推送；每天最多尝试 MAX_ATTEMPTS（默认 6）次，
#     失败后至少隔 RETRY_INTERVAL_SECONDS（默认 30 分钟）再试；超时（多半是生成途中睡着了）不受这个限制，醒着时马上重试
#   - 当天文件已存在：只补做没完成的提交和推送（比如上次推送时断网），所以重复触发没有影响
#   - 电脑处于"半醒"（DarkWake，合盖睡眠期间系统短暂醒来做后台维护）：什么都不做，等真正开机再说
# 同一条桌面通知每天只弹一次，重试时遇到同样的问题不会反复打扰。
# 只提交当天新生成的文件，不碰工作区里其他未提交的改动；不 force push。
# 推送成功后把当天 20 句发到微信（Server酱），每天只发一次；sendkey 放在 ~/.config/daily_english/serverchan_key，没配就跳过。
# claude -p 超过 GENERATE_TIMEOUT_SECONDS（默认 20 分钟）没结束就终止：生成途中系统睡眠会让 API 连接挂死，进程永远等不到响应。
# 测试时可以用环境变量覆盖：LEARN_DIR=<目录> TARGET_DATE=<YYYY-MM-DD> NO_NOTIFY=1（同时关闭微信推送）
#   CLAUDE_BIN=<假的 claude 脚本> GENERATE_TIMEOUT_SECONDS=<秒> MAX_ATTEMPTS=<次数>
#   PMSET_BIN=<假的 pmset 脚本>（模拟半醒 / 完全唤醒） RETRY_INTERVAL_SECONDS=<秒>
set -euo pipefail

LEARN_DIR="${LEARN_DIR:-$HOME/研发英语}"
TARGET_DATE="${TARGET_DATE:-$(date +%F)}"
PROMPT_FILE="$HOME/研发英语/.bin/prompt.md"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
GENERATE_TIMEOUT_SECONDS="${GENERATE_TIMEOUT_SECONDS:-1200}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-6}"
PMSET_BIN="${PMSET_BIN:-/usr/bin/pmset}"
RETRY_INTERVAL_SECONDS="${RETRY_INTERVAL_SECONDS:-1800}"
BRANCH="main"
REMOTE="origin"
LOG_DIR="$LEARN_DIR/.logs"
LOG_FILE="$LOG_DIR/$TARGET_DATE.log"
LOCK_DIR="$LOG_DIR/.lock"
SENDKEY_FILE="${SENDKEY_FILE:-$HOME/.config/daily_english/serverchan_key}"
WECHAT_MARK="$LOG_DIR/$TARGET_DATE.wechat-sent"
NOTIFIED_FILE="$LOG_DIR/$TARGET_DATE.notified"
LAST_ATTEMPT_FILE="$LOG_DIR/$TARGET_DATE.last-attempt" # 上次开始生成的时间（epoch 秒）

mkdir -p "$LOG_DIR"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"; }
# 同一条通知每天只弹一次：弹过的内容记在 NOTIFIED_FILE 里
notify() {
  [[ "${NO_NOTIFY:-0}" == "1" ]] && return 0
  if [[ -f "$NOTIFIED_FILE" ]] && grep -qxF -- "$1" "$NOTIFIED_FILE"; then
    return 0
  fi
  printf '%s\n' "$1" >>"$NOTIFIED_FILE"
  osascript -e "display notification \"$1\" with title \"研发英语\"" >/dev/null 2>&1 || true
}
fail() { log "error: $1"; notify "$1，日志见 .logs/$TARGET_DATE.log"; exit 1; }

todays_file() { compgen -G "$LEARN_DIR/${TARGET_DATE}_Day*.md" | head -n 1 || true; }

sentence_count() { grep -cE '^### [0-9]+\. ' "$1" || true; }

# 带超时运行命令，超时返回 124。看门狗每 5 秒对一次墙上时间（date），不依赖 sleep 计时：
# 系统睡眠期间 sleep 的计时可能暂停，按墙上时间算，唤醒后几秒内就能发现已经超时。
# 超时先发 TERM，10 秒后还没退出再发 KILL。
run_with_timeout() {
  local timeout_seconds="$1" deadline command_pid watchdog_pid status=0
  shift
  deadline=$(($(date +%s) + timeout_seconds))

  "$@" &
  command_pid=$!

  (
    while (($(date +%s) < deadline)); do sleep 5; done
    kill -TERM "$command_pid" 2>/dev/null || exit 0
    sleep 10
    kill -KILL "$command_pid" 2>/dev/null || true
  ) &
  watchdog_pid=$!

  wait "$command_pid" || status=$?
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true

  if (($(date +%s) >= deadline)); then
    return 124
  fi
  return "$status"
}

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

# 读 Server酱 sendkey：环境变量优先，其次 SENDKEY_FILE；都没配时输出空串
read_sendkey() {
  local key="${SERVERCHAN_KEY:-}"
  if [[ -z "$key" && -f "$SENDKEY_FILE" ]]; then
    key="$(tr -d '[:space:]' <"$SENDKEY_FILE")"
  fi
  printf '%s' "$key"
}

# 把当天文件发到微信（Server酱）。发成功后写标记文件，重复触发不会重复发；
# 发送失败只记日志、不写标记，下次触发时重试，不影响提交推送的结果
send_wechat() {
  local file="$1" name day topic key resp
  [[ "${NO_NOTIFY:-0}" == "1" ]] && return 0
  [[ -f "$WECHAT_MARK" ]] && return 0

  key="$(read_sendkey)"
  if [[ -z "$key" ]]; then
    log "warn: no Server酱 sendkey, skip wechat push"
    return 0
  fi

  name="$(basename "$file")"
  day="$(sed -E 's/^[0-9-]+_Day([0-9]+)_.*$/\1/' <<<"$name")"
  topic="$(sed -E 's/^[0-9-]+_Day[0-9]+_(.*)\.md$/\1/' <<<"$name")"

  if ! resp="$(curl -sS -m 20 "https://sctapi.ftqq.com/$key.send" \
    --data-urlencode "title=研发英语 Day$day $topic" \
    --data-urlencode "desp@$file" 2>&1)"; then
    log "warn: wechat push failed, will retry next run: $resp"
    return 1
  fi
  if ! grep -qE '"code":[[:space:]]*0[,}]' <<<"$resp"; then
    log "warn: wechat push rejected, will retry next run: $resp"
    return 1
  fi
  touch "$WECHAT_MARK"
  log "wechat pushed: $name"
}

# 提交并推送；当前不在 main 分支或不是 git 仓库时跳过，避免推错分支。
# 返回 0：已推送；1：推送失败；2：跳过（没提交也没推送，调用方不能报「已推送」）
sync_to_remote() {
  local file="$1" name current_branch
  name="$(basename "$file")"

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log "warn: $LEARN_DIR is not a git repo, skip commit and push"
    return 2
  fi
  current_branch="$(git symbolic-ref --short HEAD 2>/dev/null || echo detached)"
  if [[ "$current_branch" != "$BRANCH" ]]; then
    log "warn: current branch is $current_branch, not $BRANCH, skip commit and push"
    notify "$name 已生成，但当前分支是 ${current_branch}，未提交推送"
    return 2
  fi

  commit_todays_file "$file"
  if push_if_ahead; then
    send_wechat "$file" || true
    return 0
  fi
  notify "$name 已生成并提交，推送失败（可能是网络问题），稍后自动重试"
  return 1
}

# 当天已全部完成：文件已在远端分支里（按上次 fetch / push 记下的远端引用判断，不联网），
# 微信也已发过或不需要发。每 5 分钟的检查靠它直接退出。
already_done() {
  local name
  name="$(basename "$1")"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  git cat-file -e "$REMOTE/$BRANCH:$name" 2>/dev/null || return 1
  [[ "${NO_NOTIFY:-0}" == "1" || -f "$WECHAT_MARK" || -z "$(read_sendkey)" ]]
}

# 电脑是否完全唤醒。合盖睡眠期间系统会每隔十几分钟"半醒"（DarkWake）几秒做后台维护，
# launchd 会趁这时补触发错过的任务；这时启动生成，几秒后系统又睡回去，claude -p 必然卡到超时。
# 半醒时 pmset 报告的系统能力里没有 Graphics，完全唤醒时有（屏幕熄灭但系统醒着也算完全唤醒）。
# pmset 调用失败或输出看不懂时按"完全唤醒"处理，不挡住生成。
system_fully_awake() {
  local state
  if ! state="$("$PMSET_BIN" -g systemstate 2>&1)"; then
    log "warn: pmset -g systemstate failed, assume fully awake: $state"
    return 0
  fi
  if ! grep -q 'Current System Capabilities are:' <<<"$state"; then
    log "warn: unexpected pmset output, assume fully awake: $state"
    return 0
  fi
  grep -qE 'Current System Capabilities are:.*Graphics' <<<"$state"
}

# 防并发：登录触发、定时触发和每 5 分钟的检查可能撞在一起。
# 锁目录里记下持锁进程号，只有那个进程已经不在了（上次异常退出留下的锁）才清掉；
# 不能只看锁的年龄，否则持锁进程还在跑时锁会被清掉，两次生成同时进行。
# 旧版本留下的锁没有进程号，超过 30 分钟视为过期。
lock_is_stale() {
  local pid
  if [[ -f "$LOCK_DIR/pid" ]]; then
    pid="$(<"$LOCK_DIR/pid")"
    # 核对命令行，防止进程号被别的进程复用
    ! ps -p "$pid" -o command= 2>/dev/null | grep -q 'generate\.sh'
  else
    [[ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +30)" ]]
  fi
}
if [[ -d "$LOCK_DIR" ]] && lock_is_stale; then
  log "removing stale lock"
  rm -f "$LOCK_DIR/pid"
  rmdir "$LOCK_DIR" 2>/dev/null || true
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  exit 0
fi
trap 'rm -f "$LOCK_DIR/pid"; rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
echo "$$" >"$LOCK_DIR/pid"

cd "$LEARN_DIR"

# 当天已全部完成就直接退出（不联网、不写日志）
existing="$(todays_file)"
if [[ -n "$existing" ]]; then
  already_done "$existing" && exit 0
fi

# 半醒时不生成也不推送，不算一次尝试：等电脑完全唤醒后的下一次触发再做
if ! system_fully_awake; then
  log "skip: system is in dark wake, wait until fully awake"
  exit 0
fi

# 当天文件已存在：只补做提交、推送和发微信
if [[ -n "$existing" ]]; then
  sync_to_remote "$existing" || true
  exit 0
fi

[[ -x "$CLAUDE_BIN" ]] || fail "生成失败：找不到 $CLAUDE_BIN"
[[ -f "$PROMPT_FILE" ]] || fail "生成失败：找不到 $PROMPT_FILE"

prompt="$(<"$PROMPT_FILE")"
prompt="${prompt//\{\{DATE\}\}/$TARGET_DATE}"
prompt="${prompt//\{\{DIR\}\}/$LEARN_DIR}"

# 每天最多尝试 MAX_ATTEMPTS 次，避免一直失败时反复调用 claude
attempts=0
if [[ -f "$LOG_FILE" ]]; then
  attempts="$(grep -c '] start generating for ' "$LOG_FILE" || true)"
fi
if ((attempts >= MAX_ATTEMPTS)); then
  notify "今天已尝试生成 ${attempts} 次仍未成功，停止自动重试；查看日志后手动运行 MAX_ATTEMPTS=99 bash .bin/generate.sh"
  exit 0
fi

# 两次生成之间至少隔 RETRY_INTERVAL_SECONDS：每 5 分钟检查一次，但失败后不要每 5 分钟就调一次 claude。
# 上次超时时会删掉这个记录（见下面），电脑真正醒来后的下一次检查就重试，不用再等。
if [[ -f "$LAST_ATTEMPT_FILE" ]]; then
  last_attempt="$(<"$LAST_ATTEMPT_FILE")"
  if [[ "$last_attempt" =~ ^[0-9]+$ ]] && (($(date +%s) - last_attempt < RETRY_INTERVAL_SECONDS)); then
    exit 0
  fi
fi

log "start generating for $TARGET_DATE in $LEARN_DIR"
date +%s >"$LAST_ATTEMPT_FILE"

# 只放行读、搜、新建文件；不加载 MCP 服务，禁用 shell / 编辑 / 联网
claude_status=0
run_with_timeout "$GENERATE_TIMEOUT_SECONDS" "$CLAUDE_BIN" -p "$prompt" \
  --strict-mcp-config \
  --permission-mode acceptEdits \
  --allowedTools "Read" "Glob" "Grep" "Write" \
  --disallowedTools "Bash" "Edit" "NotebookEdit" "WebFetch" "WebSearch" "Agent" \
  --no-session-persistence \
  >>"$LOG_FILE" 2>&1 || claude_status=$?
if [[ "$claude_status" == "124" ]]; then
  # 超时多半是生成途中系统睡着了，不是 claude 本身出错：删掉上次尝试的时间，电脑醒着时下一次检查马上重试
  rm -f "$LAST_ATTEMPT_FILE"
  # 变量后紧跟中文全角标点时必须加花括号：macOS 自带的 bash 3.2 会把全角字符当成变量名的一部分
  fail "生成超时：claude 超过 $(((GENERATE_TIMEOUT_SECONDS + 59) / 60)) 分钟未结束（多半是生成途中系统睡眠），已终止，电脑醒着时几分钟内自动重试"
elif [[ "$claude_status" != "0" ]]; then
  fail "生成失败：claude 异常退出（退出码 ${claude_status}）"
fi

generated="$(todays_file)"
[[ -n "$generated" ]] || fail "生成失败：没有产出文件"
log "generated: $(basename "$generated") ($(sentence_count "$generated") sentences)"

if sync_to_remote "$generated"; then
  notify "今日 20 句已生成并推送：$(basename "$generated")"
fi
