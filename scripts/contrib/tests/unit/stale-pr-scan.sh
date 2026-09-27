#!/bin/bash
# stale-pr-scan.sh — Tier U：停滞 PR 数据面单测（卡 t_9396bbf3；形态照 unit/watch-due-patrol.sh）
#
# 覆盖（设计 §4.10 为权威规格，逐条对应）：
#   T1 正常有货：信封/item 字段逐项断言 + sweeper 标签与 review 摘录（280 字符截断）+ 日志 ok 行
#   T2 零命中：items=[]、activity_band null/null、truncated=false
#   T3 二次过滤真咬：搜索边界混入的边界新件（updated >= cutoff）必须被排除
#   T4 stamp 两态：昨日 ok → 零 gh 调用 stdout 空；缺失 → 真跑；7 天前 → 真跑；跑完后再 tick → skip
#   T5 直跑 fail-visible：rc!=0 + 日志 FAILED（嵌可辨认错误正文，pretty JSON 折叠单行）+ 上一版 JSON 字节不变 + 零 .tmp 残留
#   T6 tick 失败静默：rc=0 + stdout 空 + 日志 FAILED
#   T7 分批：SCAN_LIMIT=60 强制两批 GraphQL（50+10），items 顺序 = 枚举序（updated desc）
#   T8 null 详情跳过：已枚举但 GraphQL 详情为 null 的号 → 跳过不入 items、不伪造、scanned_count 实发
#
# stub 纪律：测试专属 stub 目录 = 共享 stubs 逐字节拷贝 + 本文件专属 gh stub（按调用序供 fixture：
#   第 n 次 gh 调用吃 fixtures/<n>.out，可选 <n>.err / <n>.rc；calls.log 与共享 stub 同格式），
#   经 CONTRIB_TEST_STUBS 注入，共享 stubs 一字节不改。fixture 全部走沙箱 STUB_LOG_DIR，禁真网络。
#   「今天」由 tests/stubs/date 的 STUB_DATE_TODAY 冻结（脚本内其余 date 形态透传 /bin/date）。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export DIM=unit

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "stale-pr-scan.sh"

# ---------------- 测试专属 stub 目录（共享拷贝 + 专用 gh，见头注） ----------------
SCAN_STUBS="$(mktemp -d "${TMPDIR:-/tmp}/stale-scan-stubs.XXXXXX")" || { echo "sandbox-fail"; exit 1; }
trap 'rm -rf "$SCAN_STUBS"' EXIT
for f in hermes claude gh tunnel osascript pgrep himalaya date; do
  if [ -f "$TESTS_ROOT/stubs/$f" ]; then
    cp "$TESTS_ROOT/stubs/$f" "$SCAN_STUBS/$f" || { echo "sandbox-fail"; exit 1; }
  fi
done
# 09-18 收口修复（instrument repair）：共享 date stub 只冻结 +%F（'+%F %T' 透传 /bin/date 真钟），
# 跨午夜跑本套件时 scan_log 的 ok 行落真日期 > 冻结 TODAY → stamp age 负数不可解析 → T4b 误判
# 「该跑」（+1 调用假红）。本套件专属 date stub 对齐 t9396 offline 文件形态：'+%F %T' 一并冻结。
cat > "$SCAN_STUBS/date" <<'DATESTUB'
#!/bin/bash
set -u
if [ -n "${STUB_DATE_TODAY:-}" ]; then
  case "${1:-}" in
    '+%F') printf '%s\n' "$STUB_DATE_TODAY"; exit 0 ;;
    '+%F %T') printf '%s 00:00:00\n' "$STUB_DATE_TODAY"; exit 0 ;;
  esac
fi
exec /bin/date "$@"
DATESTUB
chmod +x "$SCAN_STUBS/date"
{
  printf '#!/bin/bash\n'
  printf '# stale-pr-scan 单测专属 gh stub：第 n 次调用吃 fixtures/<n>.out（可选 .err/.rc）；无 fixture 落 [] 兜底\n'
  printf 'set -u\n'
  printf 'NAME="gh"\n'
  printf 'LOG_DIR="${STUB_LOG_DIR:-}"\n'
  printf 'if [ -z "$LOG_DIR" ]; then\n'
  printf '  echo "stub gh: STUB_LOG_DIR 未设置（拒绝在沙箱外运行）" >&2\n'
  printf '  exit 97\n'
  printf 'fi\n'
  printf 'mkdir -p "$LOG_DIR/bodies" "$LOG_DIR/fixtures" 2>/dev/null || true\n'
  printf 'n=$(( $(cat "$LOG_DIR/.seq-$NAME" 2>/dev/null || echo 0) + 1 ))\n'
  printf 'printf "%%s\\n" "$n" > "$LOG_DIR/.seq-$NAME"\n'
  printf 'line="$NAME|$PWD|"\n'
  printf 'first=1\n'
  printf 'for a in "$@"; do\n'
  printf '  if [ $first -eq 0 ]; then line="$line "; fi\n'
  printf '  line="$line$a"\n'
  printf '  first=0\n'
  printf 'done\n'
  printf 'printf "%%s\\n" "$line" >> "$LOG_DIR/calls.log"\n'
  printf 'fix="$LOG_DIR/fixtures/$n.out"\n'
  printf 'if [ ! -f "$fix" ]; then\n'
  printf '  printf "[]\\n"\n'
  printf '  exit 0\n'
  printf 'fi\n'
  printf 'if [ -f "$LOG_DIR/fixtures/$n.err" ]; then cat "$LOG_DIR/fixtures/$n.err" >&2; fi\n'
  printf 'cat "$fix"\n'
  printf 'if [ -f "$LOG_DIR/fixtures/$n.rc" ]; then exit "$(cat "$LOG_DIR/fixtures/$n.rc")"; fi\n'
  printf 'exit 0\n'
} > "$SCAN_STUBS/gh"
chmod +x "$SCAN_STUBS/gh"
export CONTRIB_TEST_STUBS="$SCAN_STUBS"   # 强制覆盖：run.sh 会全局注入共享 stubs，本套件必须用专属 gh stub

# ---------------- 沙箱助手 ----------------
scan_json() { printf '%s/contrib-data/stale-pr-scan.json' "$SB_ROOT"; }
scan_logf() { printf '%s/contrib-data/logs/stale-pr-scan.log' "$SB_ROOT"; }
fx_dir() { printf '%s/fixtures' "$SB_STUBLOG"; }
fx() { printf '%s/fixtures/%s' "$SB_STUBLOG" "$1"; }
sb_new_fx() { # sb_new + fixtures 目录（沙箱只建 bodies/，fixture 目录由本套件自建）
  sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
  mkdir -p "$(fx_dir)" || return 1
}
jf() { jq -r "$1" "$(scan_json)"; }
calls_n() {
  if [ -f "$SB_STUBLOG/calls.log" ]; then wc -l <"$SB_STUBLOG/calls.log" | tr -d ' '; else printf '0'; fi
}
scan_run() { # <direct|tick> <YYYY-MM-DD> [额外 K=V...] → stdout；rc 经 $? 透出
  local mode="$1" day="$2"
  shift 2
  # 沙箱默认零等待（PACE seam 的测试面；生产默认 30s 由扫描脚本自持）
  set -- "$@" "-e" "SCAN_SEARCH_PACE=0"
  if [ "$mode" = "tick" ]; then
    sb_run -e "STUB_DATE_TODAY=$day" "$@" 'bash "$MARTIN_DIR/scripts/contrib/stale-pr-scan.sh" --tick'
  else
    sb_run -e "STUB_DATE_TODAY=$day" "$@" 'bash "$MARTIN_DIR/scripts/contrib/stale-pr-scan.sh"'
  fi
}

# ---------------- fixture 助手 ----------------
X300="$(jq -rn '[range(0;300)] | map("x") | join("")')"
X280="$(jq -rn '[range(0;280)] | map("x") | join("")')"
pr_obj() { # <number> <updated_at> <review_login|-> <body> [files节点JSON] [hasNextPage] → GraphQL 明细对象（JSON 文本）
  # files 缺省 = 3 文件跨两个一级目录（scripts/×2 去重、docs/×1），hasNextPage=false；
  # 第 5/6 参可覆盖（T1 用 hasNextPage=true 验 files_truncated 口径）。
  local n="$1" up="$2" rl="$3" body="$4"
  local fnodes='[{"path":"scripts/a.sh"},{"path":"scripts/lib/b.py"},{"path":"docs/c.md"}]'
  local fmore="false"
  if [ "$#" -ge 5 ] && [ -n "$5" ]; then fnodes="$5"; fi
  if [ "$#" -ge 6 ] && [ -n "$6" ]; then fmore="$6"; fi
  jq -cn --argjson n "$n" --arg up "$up" --arg rl "$rl" --arg body "$body" \
    --argjson fnodes "$fnodes" --argjson fmore "$fmore" \
    '{ number: $n,
       title: ("stale PR " + ($n|tostring)),
       updatedAt: $up,
       mergeable: "MERGEABLE",
       changedFiles: 3,
       isDraft: false,
       url: ("https://github.com/NousResearch/hermes-agent/pull/" + ($n|tostring)),
       author: {login: "alice"},
       labels: {nodes: [{name: "type:fix"}, {name: "sweeper:blast-moderate"}]},
       latestReviews: {nodes: (if $rl == "-" then [] else [{author: {login: $rl}, state: "COMMENTED", body: $body, submittedAt: $up}] end)},
       files: {nodes: $fnodes, pageInfo: {hasNextPage: $fmore}} }'
}
gql_fix() { # <outfile> <objects-json-array（可含 null）> → repository 包裹 + a1..aN alias 的 GraphQL 响应
  jq -cn --argjson objs "$2" \
    '{data:{repository: ($objs | to_entries | map({("a" + ((.key + 1)|tostring)): .value}) | add // {})}}' > "$1"
}

# ================= T1 正常有货 =================
t_case "T1 直跑有货：rc=0、信封逐项、item 字段序、sweeper 标签/摘录 280 截断、日志 ok 行"
sb_new_fx
printf '5\n' > "$(fx 1.out)"
printf '111\t2026-08-20\n222\t2026-07-01\n' > "$(fx 2.out)"
P111="$(pr_obj 111 "2026-08-20T12:00:00Z" "teknium1" "$X300")"
P222="$(pr_obj 222 "2026-07-01T09:00:00Z" "randomguy" "friendly note" '[{"path":"a.md"},{"path":"b/c.md"}]' 'true')"
gql_fix "$(fx 3.out)" "[$P111, $P222]"
out="$(scan_run direct 2026-09-17)"; rc=$?
assert_exit 0 "$rc" "T1 rc=0"
assert_eq "$out" "" "T1 stdout 恒静默（数据走 JSON 不走 stdout）"
assert_eq "$(jf '.schema_version')" "1" "T1 schema_version=1"
assert_ne "$(jf '.generated_at')" "" "T1 generated_at 非空 string"
assert_eq "$(jf '.repo')" "NousResearch/hermes-agent" "T1 repo 默认 seam"
assert_eq "$(jf '.window_days')" "15" "T1 window_days=15（STALE_DAYS 默认）"
assert_eq "$(jf '.cutoff')" "2026-09-02" "T1 cutoff=冻结日-15d（jq 日期数学实算）"
assert_eq "$(jf '.scan_order')" "updated_desc" "T1 scan_order"
assert_eq "$(jf '.total_count')" "5" "T1 total_count 取自 search total"
assert_eq "$(jf '.scanned_count')" "2" "T1 scanned_count=实发明细数"
assert_eq "$(jf '.truncated')" "true" "T1 truncated=true（2<5 切片未到底）"
assert_eq "$(jf '.activity_band.newest')" "2026-08-20T12:00:00Z" "T1 activity_band.newest"
assert_eq "$(jf '.activity_band.oldest')" "2026-07-01T09:00:00Z" "T1 activity_band.oldest"
assert_eq "$(jf '.status')" "ok" "T1 status=ok"
assert_eq "$(jq -c '. | keys_unsorted' "$(scan_json)")" \
  '["schema_version","generated_at","repo","window_days","cutoff","scan_order","total_count","scanned_count","truncated","activity_band","status","items"]' \
  "T1 信封字段严格序（设计 §4.3.6）"
assert_eq "$(jf '.items | length')" "2" "T1 items 两条"
assert_eq "$(jq -c '.items[0] | keys_unsorted' "$(scan_json)")" \
  '["number","title","author","last_activity_at","sweeper_review","salvageability","mergeable","changed_files","changed_paths_domain","files_truncated","labels","url","is_draft"]' \
  "T1 item 字段严格序（设计 §4.3.6 + 09-17 口径补正 files_truncated）"
assert_eq "$(jf '.items[0].number')" "111" "T1 items[0].number=111（枚举序=updated desc）"
assert_eq "$(jf '.items[0].title')" "stale PR 111" "T1 title 原文抄录"
assert_eq "$(jf '.items[0].author')" "alice" "T1 author=author.login"
assert_eq "$(jf '.items[0].last_activity_at')" "2026-08-20T12:00:00Z" "T1 last_activity_at=updatedAt"
assert_eq "$(jf '.items[0].sweeper_review.present')" "true" "T1 sweeper_review.present（teknium1 命中）"
assert_eq "$(jq -c '.items[0].sweeper_review.reviewers' "$(scan_json)")" '["teknium1"]' "T1 reviewers 命中账号列表"
assert_eq "$(jq -c '.items[0].sweeper_review | keys_unsorted' "$(scan_json)")" '["present","reviewers","snippets"]' "T1 sweeper_review 字段序"
assert_eq "$(jf '.items[0].sweeper_review.snippets[0] | length')" "280" "T1 snippet 截断 280 字符"
assert_eq "$(jf '.items[0].sweeper_review.snippets[0]')" "$X280" "T1 snippet=body 原文前 280 字符（纯摘录不评价）"
assert_eq "$(jq -c '.items[0].salvageability' "$(scan_json)")" '["sweeper:blast-moderate"]' "T1 salvageability=sweeper:* 标签原文"
assert_eq "$(jf '.items[0].mergeable')" "MERGEABLE" "T1 mergeable 原文"
assert_eq "$(jf '.items[0].changed_files')" "3" "T1 changed_files"
assert_eq "$(jq -c '.items[0].changed_paths_domain' "$(scan_json)")" '["docs","scripts"]' "T1 changed_paths_domain=变更文件一级目录去重有序（09-17 口径补正实采，scripts/×2 去重）"
assert_eq "$(jf '.items[0].files_truncated')" "false" "T1 files_truncated=false（files ≤20，hasNextPage 直采）"
assert_eq "$(jq -c '.items[1].changed_paths_domain' "$(scan_json)")" '["a.md","b"]' "T1 无斜杠路径一级目录=路径自身（有序）"
assert_eq "$(jf '.items[1].files_truncated')" "true" "T1 files_truncated=true（hasNextPage→文件数 >20 的 API 级事实）"
assert_contains "$(jf '.items[0].labels | join(",")')" "type:fix" "T1 labels 含全量标签"
assert_contains "$(jf '.items[0].url')" "pull/111" "T1 url 原文"
assert_eq "$(jf '.items[0].is_draft')" "false" "T1 is_draft"
assert_eq "$(jf '.items[1].sweeper_review.present')" "false" "T1 非 sweeper 账号 review 不命中 present"
assert_eq "$(jq -c '.items[1].sweeper_review.reviewers' "$(scan_json)")" "[]" "T1 非命中 reviewers 空"
assert_eq "$(jq -c '.items[1].sweeper_review.snippets' "$(scan_json)")" "[]" "T1 非命中 snippets 空"
assert_file_contains "$(scan_logf)" "stale-pr-scan ok scanned=2 total=5" "T1 日志 ok 行（与 mv 同一次运行尾部）"
assert_stub_called_times "gh" "3" "T1 gh 调用序列：total → 翻页 → GraphQL 一批"
sb_cleanup

# ================= T2 零命中 =================
t_case "T2 零命中：items=[]、activity_band null/null、truncated=false"
sb_new_fx
printf '0\n' > "$(fx 1.out)"
out="$(scan_run direct 2026-09-17)"; rc=$?
assert_exit 0 "$rc" "T2 rc=0"
assert_eq "$(jf '.items | length')" "0" "T2 items 空"
assert_eq "$(jf '.activity_band.newest')" "null" "T2 activity_band.newest=null"
assert_eq "$(jf '.activity_band.oldest')" "null" "T2 activity_band.oldest=null"
assert_eq "$(jf '.scanned_count')" "0" "T2 scanned_count=0"
assert_eq "$(jf '.truncated')" "false" "T2 truncated=false（0<0 不成立）"
assert_eq "$(jf '.total_count')" "0" "T2 total_count=0"
assert_file_contains "$(scan_logf)" "stale-pr-scan ok scanned=0 total=0" "T2 日志 ok 行照落"
sb_cleanup

# ================= T3 二次过滤真咬 =================
t_case "T3 二次过滤：搜索边界混入的边界新件（updated >= cutoff）被咬掉"
sb_new_fx
printf '3\n' > "$(fx 1.out)"
printf '311\t2026-08-01\n312\t2026-09-16\n313\t2026-08-15\n' > "$(fx 2.out)"
P311="$(pr_obj 311 "2026-08-01T00:00:00Z" "-" "-")"
P313="$(pr_obj 313 "2026-08-15T00:00:00Z" "-" "-")"
gql_fix "$(fx 3.out)" "[$P311, $P313]"
out="$(scan_run direct 2026-09-17)"; rc=$?
assert_exit 0 "$rc" "T3 rc=0"
assert_eq "$(jf '.items | length')" "2" "T3 只留 cutoff 之前的两件"
assert_eq "$(jf '.items[0].number')" "311" "T3 items 序=枚举序"
assert_eq "$(jf '.items[1].number')" "313" "T3 边界新件 312 被咬掉"
assert_eq "$(jf '.truncated')" "true" "T3 truncated（2<3）"
assert_not_contains "$(jf '.items | map(.number) | join(",")')" "312" "T3 312 不入 items（字典序二次过滤实咬）"
sb_cleanup

# ================= T4 stamp 两态 =================
t_case "T4a 无日志（缺失=该跑）：tick 真跑并落 ok 行"
sb_new_fx
printf '0\n' > "$(fx 1.out)"
out="$(scan_run tick 2026-09-17)"; rc=$?
assert_exit 0 "$rc" "T4a tick 恒 exit 0"
assert_stub_called_times "gh" "2" "T4a 缺日志 → 真跑（total+翻页）"
assert_file_contains "$(scan_logf)" "stale-pr-scan ok" "T4a ok 行落日志（stamp 锚建立）"

t_case "T4b 同日再 tick：stamp 门槛命中 → 零 gh 调用、stdout 空"
out="$(scan_run tick 2026-09-17)"; rc=$?
assert_exit 0 "$rc" "T4b rc=0"
assert_eq "$out" "" "T4b skip 零输出"
assert_stub_called_times "gh" "2" "T4b 零新增 gh 调用（间隔不足不重跑）"
sb_cleanup

t_case "T4c 昨日 ok：age=1 < 门槛 → 零 gh 调用、stdout 空、不产 JSON"
sb_new_fx
printf '0\n' > "$(fx 1.out)"
printf '[2026-09-16 10:00:00] stale-pr-scan ok scanned=1 total=1\n' > "$(scan_logf)"
out="$(scan_run tick 2026-09-17)"; rc=$?
assert_exit 0 "$rc" "T4c rc=0"
assert_eq "$out" "" "T4c skip 零输出"
assert_stub_not_called "gh" "T4c 零 gh 调用"
if [ -f "$(scan_json)" ]; then
  assert_not_contains "json-exists" "json-exists" "T4c 不应产出 JSON（占位断言必败）"
else
  assert_eq "no-json" "no-json" "T4c 无 JSON 产出"
fi

t_case "T4d 七天前 ok：age=7 >= 门槛 → 真跑"
printf '[2026-09-10 10:00:00] stale-pr-scan ok scanned=9 total=9\n' > "$(scan_logf)"
out="$(scan_run tick 2026-09-17)"; rc=$?
assert_exit 0 "$rc" "T4d rc=0"
assert_stub_called_times "gh" "2" "T4d 到期真跑"
assert_file_contains "$(scan_logf)" "stale-pr-scan ok scanned=0 total=0" "T4d 新 ok 行覆盖 stamp 锚"
sb_cleanup

# ================= T5 直跑 fail-visible =================
# 09-18 取证口径补正（t_9396bbf3）：gh 403/422 的错误是 pretty JSON，旧 first_err 取 head -1
# 只剩一个 `{`——本用例 fixture 升级为多行 pretty JSON，断言 FAILED 行含可辨认错误正文
# （message 全文），并加防回潜锚（FAILED: 行尾不得只剩 `{`）。
t_case "T5 直跑失败：rc!=0 + 日志 FAILED 嵌可辨认错误正文 + 上一版 JSON 字节不变 + 零 .tmp 残留"
sb_new_fx
printf '{"schema_version":0,"note":"previous good scan"}\n' > "$(scan_json)"
cp "$(scan_json)" "$SB_STUBLOG/prev-json"
printf '' > "$(fx 1.out)"
cat > "$(fx 1.err)" <<'GHERR'
{
  "message": "You have exceeded a secondary rate limit (t9396-unit-rl req=t9396-unit-0001)",
  "documentation_url": "https://docs.github.com/rest/overview/resources-for-the-rate-limit"
}
GHERR
printf '1\n' > "$(fx 1.rc)"
out="$(scan_run direct 2026-09-17)"; rc=$?
assert_exit 1 "$rc" "T5 直跑失败 rc!=0（fail-visible）"
assert_eq "$out" "" "T5 stdout 仍静默（失败走日志与退出码）"
assert_file_contains "$(scan_logf)" 'stale-pr-scan FAILED rc=1: search total_count FAILED: { "message": "You have exceeded a secondary rate limit (t9396-unit-rl req=t9396-unit-0001)"' "T5 FAILED 行嵌可辨认错误正文（pretty JSON 折叠单行）"
assert_eq "$(grep 'stale-pr-scan FAILED' "$(scan_logf)" | grep -cE 'FAILED: \{ ?$' || true)" "0" "T5 防回潜：FAILED 行不再只剩一个 {"
assert_eq "$(cmp -s "$(scan_json)" "$SB_STUBLOG/prev-json" && echo same || echo diff)" "same" "T5 上一版 JSON 字节不变（整份不写保留旧版）"
if [ -f "$(scan_json).tmp" ]; then
  assert_not_contains "tmp-exists" "tmp-exists" "T5 不应残留 .tmp（占位断言必败）"
else
  assert_eq "no-tmp" "no-tmp" "T5 零 .tmp 残留"
fi
sb_cleanup

# ================= T6 tick 失败静默 =================
t_case "T6 tick 失败：rc=0 + stdout 空 + 日志 FAILED"
sb_new_fx
printf '' > "$(fx 1.out)"
printf 'gh: search failed (HTTP 502)\n' > "$(fx 1.err)"
printf '1\n' > "$(fx 1.rc)"
out="$(scan_run tick 2026-09-17)"; rc=$?
assert_exit 0 "$rc" "T6 tick 失败仍 exit 0（flush 三契约）"
assert_eq "$out" "" "T6 stdout 空"
assert_file_contains "$(scan_logf)" "stale-pr-scan FAILED rc=1" "T6 失败落 FAILED 日志"
if [ -f "$(scan_json)" ]; then
  assert_not_contains "json-exists" "json-exists" "T6 失败不产 JSON（占位断言必败）"
else
  assert_eq "no-json" "no-json" "T6 无半份 JSON"
fi
sb_cleanup

# ================= T7 分批 + 顺序 =================
t_case "T7 SCAN_LIMIT=60 强制两批 GraphQL：calls=4、items 顺序=枚举序"
sb_new_fx
printf '60\n' > "$(fx 1.out)"
tsv=""
i=0
while [ "$i" -lt 60 ]; do
  tsv="${tsv}$((4001 + i))	2026-08-01
"
  i=$((i + 1))
done
printf '%s' "$tsv" > "$(fx 2.out)"
OBJS="$(jq -cn '[range(0;60) as $i | {number: (4001+$i), title: ("stale PR " + (4001+$i|tostring)), updatedAt: "2026-08-01T00:00:00Z", mergeable: "MERGEABLE", changedFiles: 1, isDraft: false, url: ("https://github.com/NousResearch/hermes-agent/pull/" + (4001+$i|tostring)), author: {login: "alice"}, labels: {nodes: []}, latestReviews: {nodes: []}}]')"
jq -cn --argjson objs "$OBJS" '{data:{repository: ($objs[0:50] | to_entries | map({("a" + ((.key + 1)|tostring)): .value}) | add // {})}}' > "$(fx 3.out)"
jq -cn --argjson objs "$OBJS" '{data:{repository: ($objs[50:60] | to_entries | map({("a" + ((.key + 1)|tostring)): .value}) | add // {})}}' > "$(fx 4.out)"
out="$(scan_run direct 2026-09-17 -e "SCAN_LIMIT=60")"; rc=$?
assert_exit 0 "$rc" "T7 rc=0"
assert_stub_called_times "gh" "4" "T7 调用序列：total → 翻页 → GraphQL 50 → GraphQL 10"
assert_eq "$(jf '.items | length')" "60" "T7 items=60"
assert_eq "$(jf '.items[0].number')" "4001" "T7 首条=枚举序第 1"
assert_eq "$(jf '.items[49].number')" "4050" "T7 批 1 末条跨批边界前"
assert_eq "$(jf '.items[50].number')" "4051" "T7 批 2 首条接续枚举序"
assert_eq "$(jf '.items[59].number')" "4060" "T7 末条=枚举序第 60"
assert_eq "$(jf '.truncated')" "false" "T7 total=scanned=60 切片到底"
assert_file_contains "$(scan_logf)" "stale-pr-scan ok scanned=60 total=60" "T7 日志 ok 行"
sb_cleanup

# ================= T8 null 详情跳过 =================
t_case "T8 已枚举但 GraphQL 详情 null：跳过不入 items、不伪造、scanned_count 实发"
sb_new_fx
printf '3\n' > "$(fx 1.out)"
printf '501\t2026-08-05\n502\t2026-08-04\n503\t2026-08-03\n' > "$(fx 2.out)"
P501="$(pr_obj 501 "2026-08-05T00:00:00Z" "-" "-")"
P503="$(pr_obj 503 "2026-08-03T00:00:00Z" "-" "-")"
T8OBJS="$(jq -cn --argjson a "$P501" --argjson c "$P503" '[$a, null, $c]')"
gql_fix "$(fx 3.out)" "$T8OBJS"
out="$(scan_run direct 2026-09-17)"; rc=$?
assert_exit 0 "$rc" "T8 rc=0"
assert_eq "$(jf '.items | length')" "2" "T8 null 跳过后 items=2"
assert_eq "$(jf '.items[0].number')" "501" "T8 首条保留"
assert_eq "$(jf '.items[1].number')" "503" "T8 车已消失的 502 跳过不伪造"
assert_eq "$(jf '.scanned_count')" "2" "T8 scanned_count 反映实发"
assert_not_contains "$(jf '[.items[].number] | tostring')" "502" "T8 502 不入 items"
assert_eq "$(jf '.truncated')" "true" "T8 truncated（2<3）"
sb_cleanup

t_finish
