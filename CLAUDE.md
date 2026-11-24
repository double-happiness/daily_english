# CLAUDE.md

研发英语每日 20 句：面向准备进外企互联网公司的后端研发，每天一个 markdown 学习文件，4 级难度逐级递增。仓库是**公开的**。

## 技术栈

- 内容：Markdown（中文讲解 + 英文例句）
- 自动化：Bash 脚本 + macOS launchd + `claude -p` 生成 + Server酱 推送微信
- 远端：`git@github.com:double-happiness/daily_english.git`，分支 `main`

## 目录

| 路径 | 作用 |
|---|---|
| `00_课程表.md` | 难度等级表（L1–L4 句长 / 语法 / 词汇上限）和 40 天主题 |
| `YYYY-MM-DD_DayNN_主题.md` | 每日文件，恰好 20 句，`### N. 英文句子` 开头 |
| `.bin/generate.sh` | 每日生成 → 校验 20 句 → 只提交当天文件 → 推送 → 发微信 |
| `.bin/prompt.md` | 生成用提示词（`{{DATE}}` `{{DIR}}` 占位） |
| `.bin/微信推送配置.md` | Server酱 配置与排查步骤 |
| `.logs/` | 运行日志和 `<日期>.wechat-sent` 标记（已 gitignore） |

## 常用命令

```bash
# 手动跑一次（当天文件已存在时只补做提交 / 推送 / 发微信）
bash .bin/generate.sh

# 测试：指定目录和日期，关闭桌面通知和微信推送
LEARN_DIR=<目录> TARGET_DATE=2026-12-01 NO_NOTIFY=1 bash .bin/generate.sh

# 看当天日志
tail .logs/$(date +%F).log

# 校验句数
grep -cE '^### [0-9]+\. ' <每日文件>

# 定时任务：每天 07:00 + 登录时触发
launchctl list | grep dev-english-daily
```

## 编码与内容约定

- 每日文件版式以最新一份为模板：标题行、难度说明、导语、20 句（翻译 / 重点词 / 场景 / 前后对话）、单词表、发音提醒、复习、今日练习
- 严格遵守当天等级的句长和语法上限（见课程表）；20 句从易到难排列，不和已学句子重复
- 音标拿不准写 "—"，不要编
- 脚本改动保持 `set -euo pipefail`、显式错误处理、不 force push
- commit 用 Conventional Commits：`docs(dayNN)` / `feat(生成)` / `docs(课程)` 等

## 禁改 / 注意

- **Server酱 SendKey 只放 `~/.config/daily_english/serverchan_key`（600 权限），绝不进仓库**
- 已发布的每日文件不要改句子本身（复习部分按 Day/句号引用它们）
- `generate.sh` 会推送本地所有领先远端的提交——本地手动提交会被下一次定时任务一起推上去
- `.logs/` 不提交
