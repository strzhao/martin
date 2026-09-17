#!/bin/bash
# stale-pr-scan.sh — 停滞 PR 数据面（只采集零判断；卡 t_9396bbf3，三链路改造之链3）
#
# WHY THIS EXISTS
#   上游仓 open PR 数万级，`gh pr list --limit` 只覆盖最新窗口（contrib-radar 口径：洪流下只回溯
#   2-3 天），停滞面不可见。本脚本走 search API：先 total_count（唯一权威总数），再 sort=updated
#   order=desc 取窗口切片，逐条按 updated_at 二次过滤（搜索边界必混入新件），GraphQL 批量取明细，
#   落 contrib-data/stale-pr-scan.json —— 纯事实清单，零 score/priority/candidate/worth 字段；
#   判断面在 deploy/contrib-operator/SKILL.md §3.7（operator 自决三问，不给阈值不给数字）。
#
# 模式
#   直跑（无参数） = 必扫（真 gh 取数）；失败 fail-visible：日志 FAILED 行 + 退出码非零。
#   --tick         = harness 周级调用面（scripts/contrib/contrib-flush.sh 挂载，同一确定性 tick 面）：
#       - stamp 门槛：从日志末条 ok 行取日期，距今 >= TICK_MIN_INTERVAL_DAYS 天才跑；缺失 = 该跑；
#         未到间隔 = 零 stdout、零 gh 调用、零日志行（无噪音）、exit 0。禁 date +%u 单点（机器当日
#         不在线就永久跳过），禁 .stamp 文件（无第三写点）。
#       - stdout 恒静默、恒 exit 0（flush 三契约：永远 exit 0 / stdout 不挤占 flush 行 / 失败不污染）。
#       - 有 timeout 可执行文件时整段裹 timeout 600；不可用则无护栏直跑（launchd 极简 PATH 常态）。
#
# 数据流（只采集零判断）
#   1. TODAY = date +%F；CUTOFF_DATE = TODAY - STALE_DAYS 天（jq strptime/mktime/strftime 内建）。
#   2. total_count = search/issues -f q="repo:<repo> is:pr is:open updated:<cutoff -author:strzhao"
#      -f per_page=1 --jq .total_count（必须显式 -X GET：gh api 带 -f 参数默认隐式转 POST，
#      对只读端点一律 404 = 假空集，09-14 形态 C 坑）。
#   3. 枚举 = 同查询手动翻页（page=N per_page=100 sort=updated order=desc），累计至 SCAN_LIMIT /
#      短页 / 空；二次过滤只留 updated_at 日期 < CUTOFF_DATE（字典序比较）。
#   4. 明细 = GraphQL 每批 50 个 number（alias 形 a1: pullRequest(number: N)，repository 包裹）；
#      已枚举但详情为 null（车已消失）⇒ 跳过不伪造，scanned_count 反映实发。
#   5. 派生字段全部原文抄录：salvageability[] = sweeper:* 标签名原文；sweeper_review = latestReviews
#      中命中 SWEEPER_LOGINS 的条目（snippets = body 截断 280 字符，纯摘录）；changed_paths_domain[]
#      = 该车变更文件路径的一级目录去重有序列表（files(first:20) 与明细同一批 GraphQL 并采，非逐辆
#      额外调用；纯采集事实零判断；09-17 陪跑员口径补正：不再空数组占位），文件数超过 20 时
#      files_truncated=true（files.pageInfo.hasNextPage 直采，恰为「>20」的 API 级事实）。
#   6. 信封 {schema_version, generated_at, repo, window_days, cutoff, scan_order, total_count,
#      scanned_count, truncated, activity_band, status, items}；truncated = scanned_count < total_count
#      （true = 窗口切片未到底，让下游知道这是切片不是全集）。
#
# 契约（改前先读）
#   1. 写点仅两面（均已在 tests/lib/production-writers.tsv 登记）：
#      contrib-data/stale-pr-scan.json（.tmp + mv 原子替换，notify.sh 先例）与
#      contrib-data/logs/stale-pr-scan.log（追加）；无第三写点。
#   2. 日志恒单行、恒 "[ts] stale-pr-scan " 前缀，tags 闭集 {ok, FAILED}；FAILED 行嵌错误正文
#      （合流输出压成单行：换行折叠为空格 + 200 字符截断，pretty JSON 错误可辨认非只剩 `{`）；
#      路径内联、不设 LOG 变量（write-attribution 源码派生守卫的
#      幻影写点坑，watch-due-patrol.sh 先例）；tick 跳过零行。
#   3. gh 调用全部只读（search/issues GET + graphql）；gh 失败（非零退出 / JSON 解析失败）一律
#      fail-visible 不静默；gh stderr 与 stdout 合流后按行形态解析（本脚本无独立 stderr 捕获通道，
#      也不引入 tmp 文件通道），形态不过守卫的行丢弃、无合规行按失败处理。
#
# SEAMS (tests only; defaults = production): MARTIN_DIR, CONTRIB_DATA_DIR, GH_BIN, SCAN_REPO,
#   STALE_DAYS, SCAN_LIMIT, SWEEPER_LOGINS, TICK_MIN_INTERVAL_DAYS.
# ROLLBACK: 删 contrib-flush.sh 尾部三行挂载 + rm 本文件 + 回退 tests/lib/production-writers.tsv
#   两行（一行 git/rm 全部可逆，对照表见本卡 card-notes.md）。
set -uo pipefail

MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"
CONTRIB="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"
REPO="${SCAN_REPO:-NousResearch/hermes-agent}"
STALE_DAYS="${STALE_DAYS:-15}"
SCAN_LIMIT="${SCAN_LIMIT:-1000}"
SWEEPER_LOGINS="${SWEEPER_LOGINS:-teknium1,OutThisLife}"
TICK_MIN_INTERVAL_DAYS="${TICK_MIN_INTERVAL_DAYS:-6}"

MODE="direct"
case "${1:-}" in
  "") MODE="direct" ;;
  --tick) MODE="tick" ;;
  *)
    printf 'usage: stale-pr-scan.sh [--tick]\n' >&2
    exit 2
    ;;
esac

TODAY="$(date +%F)"
# Inline log path (no LOG-style variable): a LOG-prefixed variable name makes the write-attribution
# source guard derive a phantom write point (`<log>_PARENT`), since its substitution is prefix-blind.
# Keep the two registered write points as the only CONTRIB-derived literals here.
[ -d "$CONTRIB/logs" ] || mkdir -p "$CONTRIB/logs" 2>/dev/null || true

scan_log() { # <detail> — always one physical line; tags closed set: ok | FAILED
  local detail
  detail="$(printf '%s' "$1" | tr '\n' ' ')"
  printf '[%s] stale-pr-scan %s\n' "$(date '+%F %T')" "${detail:0:200}" >>"$CONTRIB/logs/stale-pr-scan.log" 2>/dev/null || true
}

fail_and_exit() { # <rc> <detail> — direct: rc!=0 (fail-visible); tick: always exit 0, stdout silent
  local rc="$1" detail="$2"
  scan_log "FAILED rc=$rc: $detail"
  if [ "$MODE" = "tick" ]; then
    exit 0
  fi
  exit "$rc"
}

# ---- PATH: cron/launchd hand out a minimal PATH; append-only, never prepend (prepending
# /usr/bin ahead of an already-shadowed PATH turns the test suite's shadow stubs into no-ops).
# No node resolution on purpose: gh is a homebrew binary, no npm-wrapped CLI is called here.
for d in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin; do
  case ":$PATH:" in
    *":$d:"*) : ;;
    *) [ -d "$d" ] && PATH="$PATH:$d" ;;
  esac
done
export PATH

# gh binary: seam > PATH (same two-step resolution as the flush harness; no nvm glob needed).
GH="${GH_BIN:-}"
if [ -z "$GH" ]; then
  GH="$(command -v gh 2>/dev/null || true)"
fi

# ---- tick 模式：stamp 门槛 + timeout 护栏（先于一切 gh 调用与依赖校验）----
if [ "$MODE" = "tick" ]; then
  last_ok=""
  if [ -f "$CONTRIB/logs/stale-pr-scan.log" ]; then
    last_ok="$(awk '/^\[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\] stale-pr-scan ok/ { d = substr($0, 2, 10) } END { if (d != "") print d }' "$CONTRIB/logs/stale-pr-scan.log" 2>/dev/null || true)"
  fi
  if [ -n "$last_ok" ]; then
    age="$(jq -rn --arg t "$TODAY" --arg l "$last_ok" '((($t | strptime("%Y-%m-%d") | mktime) - ($l | strptime("%Y-%m-%d") | mktime)) / 86400) | floor' 2>/dev/null || true)"
    case "$age" in
      ''|*[!0-9]*) age="" ;;
    esac
    if [ -n "$age" ] && [ "$age" -lt "$TICK_MIN_INTERVAL_DAYS" ]; then
      exit 0   # 未到周级间隔：零输出零调用零日志（本脚本的静默哨兵形态）
    fi
  fi
  # stamp 已到期（或无 ok 行）：真跑。有 timeout 时裹 600s（哨兵变量防二次 exec 自包裹成环）；
  # 无 timeout 可执行文件 = 无护栏直跑（如实注释，launchd 极简 PATH 常态，flush 同款降级语义）。
  TIMEOUT_BIN="$(command -v timeout 2>/dev/null || true)"
  if [ -n "$TIMEOUT_BIN" ] && [ "${STALE_SCAN_TICK_INNER:-}" != "1" ]; then
    export STALE_SCAN_TICK_INNER=1
    exec "$TIMEOUT_BIN" 600 bash "$0" --tick
  fi
fi

# ---- 依赖与参数校验（fail-visible）----
if [ -z "$GH" ]; then
  fail_and_exit 1 "gh binary not found"
fi
case "$STALE_DAYS$SCAN_LIMIT$TICK_MIN_INTERVAL_DAYS" in
  *[!0-9]*)
    fail_and_exit 1 "STALE_DAYS/SCAN_LIMIT/TICK_MIN_INTERVAL_DAYS must be integers"
    ;;
esac
case "$REPO" in
  */*) : ;;
  *) fail_and_exit 1 "SCAN_REPO must be owner/name form" ;;
esac

CUTOFF_DATE="$(jq -rn --arg t "$TODAY" --argjson d "$STALE_DAYS" '($t | strptime("%Y-%m-%d") | mktime - $d * 86400 | strftime("%Y-%m-%d"))' 2>/dev/null)"
jq_rc=$?
if [ "$jq_rc" -ne 0 ] || [ -z "$CUTOFF_DATE" ]; then
  fail_and_exit 1 "cutoff date math FAILED (TODAY=$TODAY STALE_DAYS=$STALE_DAYS)"
fi

first_err() { # <合流输出> → 压成单行（换行折叠为空格、连续空格并一）+ 200 字符截断；空则占位，
  #   保证 FAILED 行永不为空尾巴。09-18 取证口径补正（t_9396bbf3）：gh 403/422 的 pretty JSON
  #   错误取 head -1 只剩一个 `{`，message 与 request ID 全丢——失败现场必须可事后复跑核对；
  #   fail-visible 语义不变（rc≠0 + FAILED 行），非放宽判据。
  local line
  line="$(printf '%s' "$1" | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-200)"
  [ -n "$line" ] || line="empty gh output"
  printf '%s' "$line"
}

# ---- total_count（唯一权威总数；显式 -X GET）----
SEARCH_Q="repo:$REPO is:pr is:open updated:<$CUTOFF_DATE -author:strzhao"
total_raw="$("$GH" api -X GET search/issues -f q="$SEARCH_Q" -f per_page=1 --jq '.total_count' 2>&1)"
gh_rc=$?
TOTAL_COUNT=""
if [ "$gh_rc" -eq 0 ]; then
  TOTAL_COUNT="$(printf '%s\n' "$total_raw" | awk '/^[0-9]+$/ { v = $0 } END { if (v != "") print v }')"
fi
if [ "$gh_rc" -ne 0 ] || [ -z "$TOTAL_COUNT" ]; then
  fail_and_exit 1 "search total_count FAILED: $(first_err "$total_raw")"
fi

# ---- 枚举（手动翻页 + 二次过滤；累计至 SCAN_LIMIT / 短页 / 空）----
ENUM=""
ENUM_N=0
page=1
while :; do
  page_raw="$("$GH" api -X GET search/issues -f q="$SEARCH_Q" -f page="$page" -f per_page=100 -f sort=updated -f order=desc --jq '.items[] | [.number, (.updated_at|.[0:10])] | @tsv' 2>&1)"
  gh_rc=$?
  if [ "$gh_rc" -ne 0 ]; then
    fail_and_exit 1 "search enumeration page=$page FAILED: $(first_err "$page_raw")"
  fi
  # 行形态守卫（number<TAB>YYYY-MM-DD）：合流输出里 gh 警告行在此被丢弃
  clean="$(printf '%s\n' "$page_raw" | awk -F'\t' 'NF == 2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/')"
  if [ -z "$clean" ]; then
    break   # 空页 = 枚举到底
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    num="${line%%$'\t'*}"
    d="${line#*$'\t'}"
    if [ "$ENUM_N" -lt "$SCAN_LIMIT" ] && [[ "$d" < "$CUTOFF_DATE" ]]; then
      ENUM="$ENUM$num	$d
"
      ENUM_N=$((ENUM_N + 1))
    fi
  done <<<"$clean"
  if [ "$ENUM_N" -ge "$SCAN_LIMIT" ]; then
    break   # 采集上限（窗口参数，非筛选阈值）：truncated 会如实告知下游切片未到底
  fi
  page_n="$(printf '%s\n' "$clean" | wc -l | tr -d ' ')"
  if [ "$page_n" -lt 100 ]; then
    break   # 短页 = 最后一页
  fi
  page=$((page + 1))
done

# ---- 明细（GraphQL 批量，每批 50 个；null 详情跳过不伪造）----
JQ_ITEMS='[.data.repository | to_entries[] | .value
  | select(. != null)
  | ((.latestReviews.nodes // []) | map(select(.author.login as $l | ($logins | split(",")) | index($l)))) as $hits
  | { number: .number,
      title: .title,
      author: .author.login,
      last_activity_at: .updatedAt,
      sweeper_review: { present: (($hits | length) > 0),
                        reviewers: ($hits | map(.author.login) | unique),
                        snippets: ($hits | map(if .body == null then "" else (.body | .[0:280]) end)) },
      salvageability: ([(.labels.nodes // [])[].name | select(startswith("sweeper:"))]),
      mergeable: .mergeable,
      changed_files: .changedFiles,
      changed_paths_domain: ([(.files.nodes // [])[].path | split("/")[0]] | unique),
      files_truncated: (.files.pageInfo.hasNextPage // false),
      labels: ([(.labels.nodes // [])[].name]),
      url: .url,
      is_draft: .isDraft }]'
OWNER="${REPO%%/*}"
RNAME="${REPO##*/}"
ITEMS_LINES=""
batch_list=""
batch_n=0

make_batch_query() { # 纯函数：全局 batch_list（换行分隔 number）→ GraphQL query（alias a1..aN）
  local q="query{repository(owner: \"$OWNER\", name: \"$RNAME\"){" w i=1
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    q="$q a${i}: pullRequest(number: $w) {number title updatedAt mergeable changedFiles isDraft url author{login} labels(first:20){nodes{name}} latestReviews(first:5){nodes{author{login} state body submittedAt}} files(first:20){nodes{path} pageInfo{hasNextPage}}}"
    i=$((i + 1))
  done <<<"$batch_list"
  q="$q}}"
  printf '%s' "$q"
}

run_batch() { # 全局入参 batch_list → 追加一批 items 到 ITEMS_LINES
  local q raw arr gh_rc jq_rc
  q="$(make_batch_query)"
  raw="$("$GH" api graphql -f query="$q" 2>&1)"
  gh_rc=$?
  if [ "$gh_rc" -ne 0 ]; then
    fail_and_exit 1 "graphql batch FAILED: $(first_err "$raw")"
  fi
  arr="$(printf '%s' "$raw" | jq -c --arg logins "$SWEEPER_LOGINS" "$JQ_ITEMS")"
  jq_rc=$?
  if [ "$jq_rc" -ne 0 ]; then
    fail_and_exit 1 "graphql response parse FAILED: $(first_err "$raw")"
  fi
  ITEMS_LINES="$ITEMS_LINES$arr
"
}

if [ "$ENUM_N" -gt 0 ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    batch_list="$batch_list${line%%$'\t'*}
"
    batch_n=$((batch_n + 1))
    if [ "$batch_n" -eq 50 ]; then
      run_batch
      batch_list=""
      batch_n=0
    fi
  done <<<"$ENUM"
  if [ "$batch_n" -gt 0 ]; then
    run_batch
    batch_list=""
    batch_n=0
  fi
fi

# ---- 组装与落盘（原子替换；成功后紧邻落 ok 日志行，佐证近邻 <=30s）----
ITEMS_ARRAY="$(printf '%s' "$ITEMS_LINES" | jq -s 'map(.[])')"
jq_rc=$?
if [ "$jq_rc" -ne 0 ]; then
  fail_and_exit 1 "items assembly FAILED"
fi
SCANNED="$(printf '%s' "$ITEMS_ARRAY" | jq '. | length')"
GENERATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
JSON="$CONTRIB/stale-pr-scan.json"
jq -n \
  --arg generated_at "$GENERATED_AT" \
  --arg repo "$REPO" \
  --argjson window_days "$STALE_DAYS" \
  --arg cutoff "$CUTOFF_DATE" \
  --argjson total "$TOTAL_COUNT" \
  --argjson items "$ITEMS_ARRAY" \
  '( $items | length ) as $scanned
  | ( $items
      | if length == 0 then { newest: null, oldest: null }
        else { newest: ([.[].last_activity_at] | max), oldest: ([.[].last_activity_at] | min) } end ) as $band
  | { schema_version: 1,
      generated_at: $generated_at,
      repo: $repo,
      window_days: $window_days,
      cutoff: $cutoff,
      scan_order: "updated_desc",
      total_count: $total,
      scanned_count: $scanned,
      truncated: ($scanned < $total),
      activity_band: $band,
      status: "ok",
      items: $items }' > "$JSON.tmp"
jq_rc=$?
if [ "$jq_rc" -ne 0 ]; then
  rm -f "$JSON.tmp" 2>/dev/null || true
  fail_and_exit 1 "envelope assembly FAILED"
fi
mv "$JSON.tmp" "$JSON"
scan_log "ok scanned=$SCANNED total=$TOTAL_COUNT cutoff=$CUTOFF_DATE"
exit 0
