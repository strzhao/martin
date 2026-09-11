#!/bin/bash
# ttl_comment_judge.sh — TTL 否决信号语义判读（机械哨兵命中后的 AI 复核层）
#
# 背景（09-10 rq-20260910-107156 两连误报）：execute.sh TTL 第 4 关对近 5 评论做
# 机械关键词筛选（duplicate of / wontfix / not planned / closing as / closed as），
# 但 AI-triage 机器人 36 分钟后自行改判（"Re-triaged from duplicate to related:
# the author's delta holds up"）——字面命中旧信号，语义上 issue 仍然活着。
# 机械门看不见语义，循环烧深检预算。本脚本 = 歧义升级层：
#
#   输入: REPO + ISSUE（环境变量），近 5 评论由本脚本经 gh 拉取（复用 GH_BIN）
#   输出: 单行 stdout —— PASS（语义活，放行）/ BLOCK（语义死，维持拦截）
#   exit: 0=判读完成（以 stdout 为准）  非 0=判读不可用（调用方自行回退机械结果）
#
# 判读者选择（成本从低到高，首个可用者胜出）：
#   1. HERMES_BIN -z（hermes 单次任务，主模型已有 key，与 contrib 流水线同源）
#   2. claude -p（nvm 探测，同 run-watch.sh 三级解析范式）
#   双双不可用 → exit 3，调用方回退机械判定（fail-closed 不放行）
#
# 快照契约（防幻觉）：评论原文经文件传入判读者，prompt 只给规则与路径，不给窗口
# 内容复述权；判读者只许输出 PASS/BLOCK 单词。
set -uo pipefail

REPO="${REPO:?REPO required}"
ISSUE="${ISSUE:?ISSUE required}"
GH_BIN="${GH_BIN:-gh}"
LOG="${LOG:-/tmp/ttl-judge-$$.log}"

# --- 拉 5 条评论快照（时间序 + 序号，越后越新）---
SNAP="$(mktemp /tmp/ttl-snap-XXXXXX.md)"
trap 'rm -f "$SNAP"' EXIT
if ! "$GH_BIN" api "repos/${REPO}/issues/${ISSUE}/comments?per_page=5" 2>>"$LOG" \
  | jq -r 'if type == "array" then
      (to_entries | map("[#\(.key+1)] \(.value.created_at // "?") | \(.value.author.login // "ghost"):\n\(.value.body // "")\n") | join("\n---\n"))
    else "SHAPE_ERROR" end' > "$SNAP" 2>>"$LOG"; then
  echo "snapshot fetch failed" >&2
  exit 3
fi
if grep -q "SHAPE_ERROR" "$SNAP" || [[ ! -s "$SNAP" ]]; then
  echo "snapshot shape error or empty" >&2
  exit 3
fi

PROMPT="$(mktemp /tmp/ttl-prompt-XXXXXX.md)"
trap 'rm -f "$SNAP" "$PROMPT"' EXIT
cat > "$PROMPT" <<'EOF'
你在复核一个 GitHub issue 的"否决信号"门禁。下面附件是按时间排序的最近评论快照。

任务：判断该 issue 的**最新有效状态**是否已被否决。
判定为 BLOCK 的条件（全部满足才 BLOCK）：窗口中存在"重复/不修/关闭"类信号，且窗口内**没有任何后续评论撤销、改判或反驳**它（改判信号例：re-triaged、not a duplicate、related、重新分类、明确表示 issue 仍然成立/作者增量成立）。注意：引用旧信号的讨论（如"re the triage note..."）不是撤销本身，以窗口内最新的权威改判为准。
判定为 PASS 的条件：最新有效状态是"问题活issue 仍然成立"，或窗口中根本没有否决信号。

规则：只依据快照文本，不猜测窗口外信息。**只输出一个词：PASS 或 BLOCK**，不许输出其他任何内容。

快照文件路径：SNAPFILE
EOF
sed -i '' "s|SNAPFILE|$SNAP|" "$PROMPT" 2>/dev/null || sed -i "s|SNAPFILE|$SNAP|" "$PROMPT"

# --- 判读者 1: hermes -z ---
HERMES_BIN="${HERMES_BIN:-}"
if [[ -z "$HERMES_BIN" ]]; then
  HERMES_BIN="$(command -v hermes 2>/dev/null || true)"
fi
if [[ -z "$HERMES_BIN" && -x "$HOME/.local/bin/hermes" ]]; then
  HERMES_BIN="$HOME/.local/bin/hermes"
fi

run_verdict() {
  local out=""
  # 判读者 1: hermes -z（读文件走 hermes 的终端工具；120s 上限防挂死 collect 链）
  if [[ -n "$HERMES_BIN" ]]; then
    out="$("$HERMES_BIN" -z "读取文件 $SNAP 的全文，然后按以下规则判读并只输出 PASS 或 BLOCK 一个词：判断 issue 最新有效状态是否已被否决。BLOCK 条件=存在重复/不修/关闭信号且窗口内无任何后续撤销/改判/反驳（re-triaged/not a duplicate/related 等改判算撤销）；PASS 条件=最新状态 issue 仍成立或无否决信号。只依据快照，不猜窗口外。快照: $(cat "$SNAP" | head -c 6000)" 2>>"$LOG" | tail -5 | grep -Eo "PASS|BLOCK" | tail -1)"
    [[ -n "$out" ]] && { echo "$out"; return 0; }
  fi
  # 判读者 2: claude -p（nvm 三级探测，同 run-watch.sh 范式）
  local CLAUDE_BIN
  CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
  [[ -z "$CLAUDE_BIN" ]] && CLAUDE_BIN="$(ls -t "$HOME"/.nvm/versions/node/*/bin/claude 2>/dev/null | head -1 || true)"
  if [[ -n "$CLAUDE_BIN" ]]; then
    out="$("$CLAUDE_BIN" -p "$(cat "$PROMPT")" --allowedTools "Read" 2>>"$LOG" | grep -Eo "PASS|BLOCK" | tail -1)"
    [[ -n "$out" ]] && { echo "$out"; return 0; }
  fi
  return 3
}

if run_verdict; then
  exit 0
else
  echo "no judge available" >&2
  exit 3
fi
