#!/bin/bash
# post-comment.sh — L2-auto 后评论投递薄包装：strip + 投递一条路（卡 t_ee058c57，2026-10-24）
#
# 为什么存在：剥离函数原是 execute.sh 私有函数，auto-gate（auto-gate.sh exit 0）裁定后的
# L2-auto 免隧道投递若图省事手工 `gh api -X POST …/comments -F body=@file`，头部 HTML 注释块
# 与「## 内部备注」段原样上线（2026-10-24 实证：issue #140178 首评 6369855435 外泄 3389 字节，
# 投递后回读抓到、PATCH 同 id 净化）。本通道 = 机械保证：凡不走 execute.sh 全链的评论投递
# 一律过本文件（strip 后才见 gh），手工直投路径清零；走 execute.sh 全链的投递不经此处。
#
# 用法：bash post-comment.sh <repo> <issue-or-pr-num> <draft-file>
#   repo   形如 Owner/Repo；num 为 issue 或 PR 号（issues/<num>/comments 对两者同语义，
#          与 execute.sh 投递端点一致）
#   draft  待投递稿件；头部 `<!-- -->` 注释块与「## 内部备注」尾段在投递前被剥离
# 环境变量 seam（沙箱测试用，生产缺省=真值）：
#   GH_BIN（缺省 gh）/ POST_COMMENT_DRY_RUN=true（只打印不投）
# 退出码：0=已投递（stdout=评论 html_url）或 dry-run；1=剥离后空正文（拒发）或 gh 失败；
#         2=用法/文件错误
# 边界：本包装只管 strip+投递；approved.log 台账与回执照仍属 execute.sh / 调用方职责。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/strip-comment.sh"
# fail-closed：共享库缺函数（坏 checkout/半截同步）→ 立即终止，绝不带病投递
declare -F strip_leading_comments >/dev/null 2>&1 || {
  echo "FATAL: strip-comment.sh 未提供 strip_leading_comments，终止" >&2
  exit 1
}

GH_BIN="${GH_BIN:-gh}"
DRY_RUN="${POST_COMMENT_DRY_RUN:-false}"

usage() { echo "usage: bash post-comment.sh <repo> <number> <draft-file>" >&2; exit 2; }

(( $# == 3 )) || usage
REPO="$1"; NUM="$2"; DRAFT="$3"
[[ "$REPO" == */* ]] || usage
[[ "$NUM" =~ ^[0-9]+$ ]] || usage
[[ -f "$DRAFT" ]] || { echo "post-comment: 稿件不存在: $DRAFT" >&2; exit 2; }

# 剥离到临时正文（macOS/BSD mktemp 的 X 串必须在模板末尾——execute.sh :768 同款教训）
BODY_FILE="$(mktemp "${TMPDIR:-/tmp}/post-comment-body-XXXXXX")"
trap 'rm -f "${BODY_FILE:-}" 2>/dev/null' EXIT
strip_leading_comments "$DRAFT" > "$BODY_FILE"
# fail-closed：剥后空正文绝不投递（防稿件全被剥 / 空文件静默发出空评论）
if [[ ! -s "$BODY_FILE" ]]; then
  echo "post-comment: 剥离后正文为空，拒发: $DRAFT" >&2
  exit 1
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "[dry-run] $GH_BIN api -X POST repos/$REPO/issues/$NUM/comments -F body=@$BODY_FILE"
  echo "[dry-run] 剥离后正文 $(wc -c < "$BODY_FILE" | tr -d ' ') 字节"
  exit 0
fi

# 投递走 -F @file（gh 官方语义：-F 的 @路径=读文件；`-f body=-` 会把字面量 "-" 当正文——
# execute.sh 投递段同款注记）
resp="$("$GH_BIN" api -X POST "repos/$REPO/issues/$NUM/comments" -F body=@"$BODY_FILE")" \
  && rc_gh=0 || rc_gh=$?
(( rc_gh != 0 )) && { echo "post-comment: gh 投递失败 rc=$rc_gh repo=$REPO num=$NUM" >&2; exit 1; }
url="$(jq -r 'if (type == "object") and ((.html_url? // "") | length > 0) then .html_url else "" end' <<<"$resp" 2>/dev/null)"
if [[ -n "$url" ]]; then
  echo "$url"
else
  # 形状容错同 execute.sh：正常 gh 必回 html_url；异常响应不伪造 URL，原样输出供调用方留证
  printf '%s\n' "$resp"
fi
