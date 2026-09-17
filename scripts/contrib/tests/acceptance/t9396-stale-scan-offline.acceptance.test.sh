#!/usr/bin/env bash
# =============================================================================
# t9396-stale-scan-offline.acceptance.test.sh — 卡 t_9396bbf3 红队验收（文件 2/5）
#   stale-pr-scan.sh 数据面行为契约（沙箱 + 测试专属 stub，零真网络）：
#   S3.P2 信封/items 合法性、S3.P4 字段形态、S3.P5 零判断面 det 代理、
#   S3.P6 外部命令闭集、S3.P7 bash -n、S8.P1 失败路径字节不变；
#   另按设计 §4.3-§4.5 锁：二次过滤、分页/分批、null 详情跳过、stamp 门槛、
#   日志字母表、原子落盘、直跑/tick 双模式 rc-stdout 矩阵。
# 谓词来源：state.md `## 验收场景` SSOT + `## 设计文档` §4/§5（contract_required）。
# 红队纪律：未读实现；stub 为测试专属（CONTRIB_TEST_STUBS 注入，共享 stub 零改动）；
#   每断言硬失败；无宽容跳过。真跑真数据（S3.P1/P3）见 t9396-stale-realrun 文件。
# =============================================================================
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${REPO_ROOT:-}" || ! -d "$REPO_ROOT" ]]; then
  echo "ACCEPTANCE-FAIL[env]: REPO_ROOT 不可解析: ${SELF_DIR}" >&2
  exit 1
fi
TESTS_ROOT="$REPO_ROOT/scripts/contrib/tests"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$REPO_ROOT/scripts/contrib}"
export DIM=acceptance
T_FILE="$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/assert.sh
source "$TESTS_ROOT/lib/assert.sh"
# shellcheck source=../lib/sandbox.sh
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "$T_FILE"

SCAN_SH="$REPO_ROOT/scripts/contrib/stale-pr-scan.sh"
FLUSH_SH="$REPO_ROOT/scripts/contrib/contrib-flush.sh"
UNIT_SH="$REPO_ROOT/scripts/contrib/tests/unit/stale-pr-scan.sh"
TODAY="2026-09-17"      # 全套冻结日（STUB_DATE_TODAY）
CUTOFF="2026-09-02"     # TODAY - STALE_DAYS(15)

# ---------------- 测试专属 stub 工厂（不改共享 stub 一字节） ----------------
# gh：仅拦截 stale-pr-scan 形态调用（search/issues / graphql），按 fixture 目录供数
# 并以共享 stub 同格式自记 calls.log；其余调用 exec 共享影子 stub（notify/pr list 等
# 行为逐字节保持共享 stub 语义）。date：共享语义 + 追加冻结 '+%F %T'。
make_my_stubs() { # <dir>
  local d="$1"
  mkdir -p "$d"
  cp "$TESTS_ROOT/stubs/"* "$d/" 2>/dev/null || true
  cat > "$d/gh" <<'STUB'
#!/bin/bash
# t9396 测试专属 gh stub：scan 形态拦截 + fixture 供数；其余 exec 共享 stub。
set -u
LOG_DIR="${STUB_LOG_DIR:-}"
if [[ -z "$LOG_DIR" ]]; then echo "stub gh: STUB_LOG_DIR 未设置" >&2; exit 97; fi
SHARED="${STUB_GH_SHARED:-}"
FIX="${STUB_SCAN_FIXTURE:-}"
is_scan=0; sub=""; page=""; ppage=""; jqexpr=""
prev=""
for a in "$@"; do
  if [[ "$prev" == "--jq" ]]; then jqexpr="$a"; fi
  case "$a" in
    graphql) sub="graphql" ;;
    search/issues) sub="search" ;;
    page=*) page="${a#page=}" ;;
    per_page=*) ppage="${a#per_page=}" ;;
  esac
  prev="$a"
done
if [[ "$sub" == "graphql" || "$sub" == "search" ]]; then
  is_scan=1
fi
if [[ "$is_scan" -eq 1 && -n "$FIX" ]]; then
  n=$(( $(cat "$LOG_DIR/.seq-gh" 2>/dev/null || echo 0) + 1 ))
  printf '%s\n' "$n" > "$LOG_DIR/.seq-gh"
  line="gh|$PWD|"; first=1
  for a in "$@"; do
    if [[ $first -eq 0 ]]; then line="$line "; fi
    line="$line$a"
    first=0
  done
  printf '%s\n' "$line" >> "$LOG_DIR/calls.log"
  if [[ "${STUB_SCAN_FAIL:-}" == "1" ]]; then
    echo "gh: request failed (t9396-stub-network-down)" >&2
    exit 1
  fi
  resp=""
  if [[ "$sub" == "graphql" ]]; then
    gseq=$(( $(cat "$FIX/.gseq" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$gseq" > "$FIX/.gseq"
    [[ -f "$FIX/graphql-$gseq.out" ]] && resp="$FIX/graphql-$gseq.out"
    [[ -z "$resp" && -f "$FIX/graphql-default.out" ]] && resp="$FIX/graphql-default.out"
  else
    if [[ "$ppage" == "1" ]]; then
      [[ -f "$FIX/total.out" ]] && resp="$FIX/total.out"
    else
      [[ "$page" == "" ]] && page=1
      [[ -f "$FIX/page-$page.out" ]] && resp="$FIX/page-$page.out"
    fi
  fi
  if [[ -z "$resp" ]]; then exit 0; fi
  if [[ -n "$jqexpr" ]]; then
    jq -r "$jqexpr" "$resp" 2>/dev/null || exit 3
  else
    cat "$resp"
  fi
  exit 0
fi
if [[ -n "$SHARED" && -x "$SHARED" ]]; then
  exec "$SHARED" "$@"
fi
echo "stub gh: STUB_GH_SHARED 未设置且非 scan 形态调用" >&2
exit 97
STUB
  chmod +x "$d/gh"
  cat > "$d/date" <<'STUB'
#!/bin/bash
# t9396 测试专属 date stub：共享语义 + '+%F %T' 冻结（日志行确定性）。
set -u
LOG_DIR="${STUB_LOG_DIR:-}"
if [[ -z "$LOG_DIR" ]]; then echo "stub date: STUB_LOG_DIR 未设置" >&2; exit 97; fi
if [[ -n "${STUB_DATE_TODAY:-}" ]]; then
  case "${1:-}" in
    '+%F') printf '%s\n' "$STUB_DATE_TODAY"; exit 0 ;;
    '+%H') printf '%s\n' "${STUB_DATE_HOUR:-00}"; exit 0 ;;
    '+%F %T') printf '%s %s:00:00\n' "$STUB_DATE_TODAY" "${STUB_DATE_HOUR:-00}"; exit 0 ;;
  esac
fi
exec /bin/date "$@"
STUB
  chmod +x "$d/date"
}

# ---------------- fixture 工厂 ----------------
build_fixture_main() { # <dir> 主链有货：3 辆真停滞 + 边界/新件混入（咬掉验证）
  local d="$1"
  mkdir -p "$d"
  printf '{"total_count":3}\n' > "$d/total.out"
  cat > "$d/page-1.out" <<'JSON'
{"items":[
 {"number":105,"updated_at":"2026-09-10T00:00:00Z"},
 {"number":106,"updated_at":"2026-09-05T00:00:00Z"},
 {"number":104,"updated_at":"2026-09-02T00:00:00Z"},
 {"number":103,"updated_at":"2026-09-01T12:00:00Z"},
 {"number":102,"updated_at":"2026-08-20T09:30:00Z"},
 {"number":101,"updated_at":"2026-08-01T08:00:00Z"}
]}
JSON
  local body300
  body300="$(printf 'x%.0s' {1..300})"
  jq -n --arg long "$body300" '{data:{repository:{
    a0:{number:103,title:"chore: stale three",updatedAt:"2026-09-01T12:00:00Z",mergeable:"MERGEABLE",changedFiles:5,isDraft:false,url:"https://github.com/NousResearch/hermes-agent/pull/103",author:{login:"devThree"},labels:{nodes:[]},latestReviews:{nodes:[]}},
    a1:{number:102,title:"fix: stale two",updatedAt:"2026-08-20T09:30:00Z",mergeable:"CONFLICTING",changedFiles:23,isDraft:true,url:"https://github.com/NousResearch/hermes-agent/pull/102",author:{login:"devTwo"},labels:{nodes:[{name:"sweeper:stale"},{name:"bug"}]},latestReviews:{nodes:[{author:{login:"OutThisLife"},state:"APPROVED",body:"lgtm",submittedAt:"2026-08-21T00:00:00Z"}]},files:{nodes:[{path:"a.md"},{path:"b/c.md"}],pageInfo:{hasNextPage:true}}},
    a2:{number:101,title:"feat: stale one",updatedAt:"2026-08-01T08:00:00Z",mergeable:"MERGEABLE",changedFiles:12,isDraft:false,url:"https://github.com/NousResearch/hermes-agent/pull/101",author:{login:"devOne"},labels:{nodes:[{name:"sweeper:salvage-candidate"}]},latestReviews:{nodes:[{author:{login:"teknium1"},state:"CHANGES_REQUESTED",body:("R:"+$long),submittedAt:"2026-08-15T00:00:00Z"},{author:{login:"driveBy"},state:"COMMENTED",body:"unrelated",submittedAt:"2026-08-16T00:00:00Z"}]},files:{nodes:[{path:"scripts/x.py"},{path:"scripts/lib/y.py"},{path:"docs/z.md"}],pageInfo:{hasNextPage:false}}}
  }}}' > "$d/graphql-1.out"
}

build_fixture_zero() { # <dir> 零命中
  local d="$1"
  mkdir -p "$d"
  printf '{"total_count":0}\n' > "$d/total.out"
  printf '{"items":[]}\n' > "$d/page-1.out"
}

build_fixture_batch() { # <dir> SCAN_LIMIT=60 分批：total 200 / 100 枚举 / 50+10 两批 GraphQL
  local d="$1"
  mkdir -p "$d"
  printf '{"total_count":200}\n' > "$d/total.out"
  jq -n '["23","22","21","20","19","18","17","16","15","14","13","12","11","10","09","08","07","06","05","04"] as $h |
    {items:[range(0;100) as $i | {number:(2001+$i), updated_at:("2026-08-31T" + $h[$i % 20] + ":00:00Z")}]}' > "$d/page-1.out"
  jq -n '{data:{repository:(reduce range(0;50) as $i ({}; . + {("a"+($i|tostring)):{
    number:(2001+$i), title:("stale "+(2001+$i|tostring)), updatedAt:"2026-08-31T00:00:00Z",
    mergeable:"MERGEABLE", changedFiles:1, isDraft:false,
    url:("https://github.com/NousResearch/hermes-agent/pull/"+(2001+$i|tostring)),
    author:{login:("dev"+(2001+$i|tostring))}, labels:{nodes:[]}, latestReviews:{nodes:[]}}}))}}' > "$d/graphql-1.out"
  jq -n '{data:{repository:(reduce range(0;10) as $i ({}; . + {("a"+($i|tostring)):{
    number:(2051+$i), title:("stale "+(2051+$i|tostring)), updatedAt:"2026-08-31T00:00:00Z",
    mergeable:"MERGEABLE", changedFiles:1, isDraft:false,
    url:("https://github.com/NousResearch/hermes-agent/pull/"+(2051+$i|tostring)),
    author:{login:("dev"+(2051+$i|tostring))}, labels:{nodes:[]}, latestReviews:{nodes:[]}}}))}}' > "$d/graphql-2.out"
}

build_fixture_null() { # <dir> null 详情跳过：a1（102 号车）详情 null（车已消失）
  local d="$1"
  mkdir -p "$d"
  build_fixture_main "$d"
  jq -n '{data:{repository:{
    a0:{number:103,title:"chore: stale three",updatedAt:"2026-09-01T12:00:00Z",mergeable:"MERGEABLE",changedFiles:5,isDraft:false,url:"u103",author:{login:"devThree"},labels:{nodes:[]},latestReviews:{nodes:[]}},
    a1:null,
    a2:{number:101,title:"feat: stale one",updatedAt:"2026-08-01T08:00:00Z",mergeable:"MERGEABLE",changedFiles:12,isDraft:false,url:"u101",author:{login:"devOne"},labels:{nodes:[]},latestReviews:{nodes:[]}}
  }}}' > "$d/graphql-1.out"
}

# ---------------- 运行/assert 小件 ----------------
JSONF=""; LOGF=""; FIX_MAIN=""

scan_run() { # [K=V ...] -- <scan.sh 参数...>：沙箱内跑被测脚本（stdout 透传；失败时内外 stderr/stdout 落控制台供分诊）
  # 09-17 收口修复（instrument repair）：收集的每个 K=V 必须带 -e 前缀再喂 sb_run——
  # 原实现裸传 K=V，sb_run 的参数循环遇首个裸 K=V 即停并将其误当 snippet
  # （bash -c "K=V" = 纯赋值，静默 exit 0），真 snippet 被丢弃 ⇒ 全部断言读旧/缺产物假红。
  local envs=() a rc=0
  local outfile="$SB_ROOT/tmp/scan-run.last.out"
  while [[ "${1:-}" != "--" ]]; do
    envs[${#envs[@]}]="-e"
    envs[${#envs[@]}]="$1"
    shift
  done
  shift
  local argsq=""
  for a in "$@"; do
    argsq+="$(printf '%q ' "$a")"
  done
  sb_run -e "STUB_SCAN_FIXTURE=$SB_ROOT/tmp/fixture" -e "STUB_GH_SHARED=$TESTS_ROOT/stubs/gh" \
    -e "STUB_DATE_TODAY=$TODAY" ${envs[@]+"${envs[@]}"} \
    "bash \"\$MARTIN_DIR/scripts/contrib/stale-pr-scan.sh\" $argsq" > "$outfile"
  rc=$?
  cat "$outfile" 2>/dev/null || true
  if [[ "$rc" -ne 0 ]]; then
    echo "--- scan_run rc=$rc 内层 stdout（tail 15）---" >&2
    tail -n 15 "$outfile" >&2
    echo "--- scan_run rc=$rc 内层 stderr（tail 20，SB_OUT_FILE）---" >&2
    sb_out 20 >&2
    echo "--- scan_run 诊断结束 ---" >&2
  fi
  return $rc
}

jqv() { # <expr> → JSON 字段值
  jq -r "$1" "$JSONF" 2>/dev/null
}
assert_ge() { # <actual> <min> [label]（assert 库无 ge，本地实现）
  if [[ "${1:-}" =~ ^[0-9]+$ && "${2:-}" =~ ^[0-9]+$ && "$1" -ge "$2" ]]; then
    _pass "${3:-}"
  else
    _fail "${3:-}" "actual=[$1] 期望 >= $2"
  fi
}
jq_assert() { # <expr> <label>
  if jq -e "$1" "$JSONF" >/dev/null 2>&1; then
    _pass "${2:-}"
  else
    _fail "${2:-}" "jq 断言失败: $1 （JSON 头: $(head -c 240 "$JSONF" 2>/dev/null)）"
  fi
}
tmp_count() { find "$SB_ROOT/contrib-data" -name '*.tmp' 2>/dev/null | wc -l | tr -d ' '; }

log_ok() { printf '%s/logs' "$SB_ROOT/contrib-data"; }

# =============================================================================
t_case "env 前置：被测脚本在位 + 沙箱工厂可用"
for f in "$SCAN_SH" "$FLUSH_SH" "$UNIT_SH"; do
  if [[ -f "$f" ]]; then _pass "文件在位: $(basename "$f")"; else _fail "文件在位" "缺失: $f"; fi
done

# =============================================================================
# S3.P7 bash -n 全绿（新/改 .sh）
# =============================================================================
t_case "S3.P7 全部新/改 .sh bash -n 全绿"
for f in "$SCAN_SH" "$FLUSH_SH" "$UNIT_SH"; do
  if bash -n "$f" 2>/dev/null; then
    _pass "bash -n 绿: $(basename "$f")"
  else
    _fail "bash -n" "语法门红: $f"
  fi
done

# =============================================================================
# S3.P6 外部命令闭集（fs 枚举）：脚本命令位 ⊆ {gh, jq, bash3.2 内置, /usr/bin 系}
# =============================================================================
strip_strings() { # stdin→stdout：跨行剥离单/双引号串内容（jq 程序等内嵌串不参与命令位枚举；
  #   heredoc 体含奇数引号时可能失步，属 best-effort，命中输出可人工分诊）
  awk -v sq="'" '
  { n=length($0); out=""; i=1
    while (i<=n) {
      c=substr($0,i,1)
      if (insq) { if (c==sq) insq=0; i++; continue }
      if (indq) { if (c=="\"") indq=0; i++; continue }
      if (c==sq) { insq=1; out=out " "; i++; continue }
      if (c=="\"") { indq=1; out=out " "; i++; continue }
      out=out c; i++
    }
    print out
  }'
}

extract_cmds() { # <file> → 命令位 token（排序去重；剥引号串→剥注释→切命令位→裸词过滤）
  strip_strings < "$1" \
    | sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]]#.*$//' \
    | sed -e 's/\$(/\n$(/g' \
    | tr ';|&' '\n\n\n' \
    | sed -e 's/^[[:space:]]*//' -e 's/^\$(//' -e '/^$/d' \
    | awk '{ if ($1=="!" || $1=="if" || $1=="elif" || $1=="while" || $1=="until") { if (NF>=2) print $2 } ; print $1 }' \
    | grep -vE '\)$' \
    | grep -vE '^[A-Za-z_][A-Za-z0-9_]*=' \
    | grep -v '^-' \
    | grep -E '^[A-Za-z_][A-Za-z0-9_-]*$' \
    | sort -u
}

t_case "S3.P6 命令枚举器自证（正向对照：违例语料必咬中；内嵌 jq 程序串不误报）"
_bad="$(mktemp "${TMPDIR:-/tmp}/t9396-extractor.XXXXXX")"
cat > "$_bad" <<'CORPUS'
python3 -c 1
git status
x=$(jq -r . .)
main() {
  gh api /x
}
AGG="$(printf '%s' "$j" | jq -r '.envelope | map(select(.k)) | @tsv')"
/usr/bin/python3 --version
CORPUS
_tok="$(extract_cmds "$_bad")"
assert_ge "$(printf '%s\n' "$_tok" | grep -cx 'python3' || true)" "1" "枚举器咬中 python3（非空转）"
assert_ge "$(printf '%s\n' "$_tok" | grep -cx 'git' || true)" "1" "枚举器咬中 git"
assert_ge "$(printf '%s\n' "$_tok" | grep -cx 'gh' || true)" "1" "枚举器咬中 gh"
assert_eq "$(printf '%s\n' "$_tok" | grep -cx 'main' || true)" "0" "函数定义名不误报为命令"
assert_ge "$(printf '%s\n' "$_tok" | grep -cx 'jq' || true)" "1" "命令替换内命令位咬中 jq"
for _w in map select; do
  assert_eq "$(printf '%s\n' "$_tok" | grep -cx "$_w" || true)" "0" "内嵌 jq 程序串「${_w}」不误报为命令"
done
rm -f "$_bad"

t_case "S3.P6 stale-pr-scan.sh 命令位 ⊆ 闭集（gh+jq+bash3.2 内置+/usr/bin 系）"
if [[ -f "$SCAN_SH" ]]; then
  # 09-17 收口修复（instrument repair，非放宽判据）：① ALLOW 按词比较（原整串当单 token，
  # 任何脚本都恒假红=断言不可满足）；② 赋值过滤收窄为行首赋值（原「含 = 即丢整段」弱化抽取）；
  # ③ 本文件内定义的函数名非外部命令，从命令位剔除；④ ALLOW 补 bash（脚本在 timeout 自重_exec
  # `bash "$0" --tick`，解释器本体与 timeout 同类，state.md 闭集「bash3.2 内置」的载体）。
  ALLOW=": [ [[ ]] { } if then else elif fi for while until do done case esac in function select time return local export readonly unset shift set trap exit printf echo read cd command builtin source test gh jq bash date mktemp mv rm mkdir grep awk sed sort cut tail head tr wc cat cmp comm uniq basename dirname sleep chmod cp ls timeout break continue exec eval true false"
  _toks="$(extract_cmds "$SCAN_SH")"
  _funcs="$(grep -oE '^[A-Za-z_][A-Za-z0-9_-]*\(\)' "$SCAN_SH" | sed 's/()$//' | sort -u)"
  if [[ -n "$_funcs" ]]; then
    _toks="$(printf '%s\n' "$_toks" | grep -xvF -f <(printf '%s\n' "$_funcs") 2>/dev/null || true)"
  fi
  # ⑤ 比较改单向 toks ∖ ALLOW（原 uniq -u 对称差会把「脚本未用到」的 ALLOW 词也报越界，
  # 必假红）；jq 程序字面量内建词（脚本单引号 jq 程序内的 floor/length/mktime 等，经 best-effort
  # 引号剥离残留，非 shell 命令位）从 token 侧机械剔除——真违例由下方全文本 raw_deny grep 兜底。
  JQ_BUILTINS="floor length mktime strptime strftime split join map select unique index startswith endswith test tojson fromjson keys to_entries has"
  _toks="$(printf '%s\n' "$_toks" | grep -xvF -f <(printf '%s\n' $JQ_BUILTINS) 2>/dev/null || true)"
  # shellcheck disable=SC2086
  _bad_cmds="$(printf '%s\n' $_toks | sort -u | comm -23 - <(printf '%s\n' $ALLOW | sort -u) || true)"
  _detail="$(printf '%s\n' "$_bad_cmds" | grep -c . || true)"
  if [[ "$_detail" -eq 0 ]]; then
    _pass "闭集外命令==0"
  else
    _refs=""
    while IFS= read -r tk; do
      [[ -z "$tk" ]] && continue
      _ln="$(grep -nF -- "$tk" "$SCAN_SH" 2>/dev/null | head -n 1 | cut -c1-120 || true)"
      _refs+="[$tk] @ ${_ln:-?}; "
    done < <(printf '%s\n' "$_bad_cmds")
    _fail "闭集外命令" "越界 ${_detail} 个: ${_refs}"
  fi
  for _deny in python3 perl yq ruby node npm curl wget sqlite3 osascript expect hermes claude tunnel git xargs; do
    assert_eq "$(printf '%s\n' "$_toks" | grep -cx "$_deny" || true)" "0" "禁用命令「${_deny}」零出现"
  done
  _raw_deny="$(grep -cE '(^|[^A-Za-z0-9_-])(python3|perl |yq|ruby|node |curl|wget|sqlite3|osascript|expect |git )([^A-Za-z0-9_-]|$)' "$SCAN_SH" || true)"
  assert_eq "$_raw_deny" "0" "原文禁用工具（含绝对路径形态）零出现"
  assert_eq "$(grep -cE 'grep +-?[a-zA-Z]*P([^a-zA-Z]|$)' "$SCAN_SH" || true)" "0" "bash3.2 禁项：grep -P 零出现"
  assert_eq "$(grep -cE 'sed +-[a-zA-Z]*i([^a-zA-Z]|$)' "$SCAN_SH" || true)" "0" "bash3.2 禁项：sed -i 零出现"
  assert_eq "$(grep -cw 'mapfile' "$SCAN_SH" || true)" "0" "bash3.2 禁项：mapfile 零出现"
  assert_eq "$(grep -cE 'declare (-[a-zA-Z]+)*A' "$SCAN_SH" || true)" "0" "bash3.2 禁项：declare -A 零出现"
  assert_eq "$(grep -cE '\$\{[A-Za-z_][A-Za-z0-9_]*,,' "$SCAN_SH" || true)" "0" "bash3.2 禁项：\${var,,} 零出现"
else
  _fail "S3.P6" "被测脚本缺失，闭集检查无法执行"
fi

# =============================================================================
# S3.P5 det 代理：脚本+JSON 零判断面字段（score/priority/verdict/recommend/worth/candidate）
# 判据面=剥离注释与引号串后的脚本本体（注释/内嵌 jq 串提及不算判断面）
# =============================================================================
t_case "S3.P5-det 脚本零判断面字面量 + 正向对照（匹配器对含 score 语料必须咬中）"
_ctrl="$(printf 'score = 1\npriority high\n' | grep -Eic '(^|[^a-z])(score|priority|verdict|recommend|worth|candidate)([^a-z]|$)' || true)"
assert_ge "$_ctrl" "1" "匹配器对判断面字面量命中>=1（非空转）"
if [[ -f "$SCAN_SH" ]]; then
  _strip="$(sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]]#.*$//' "$SCAN_SH" | strip_strings)"
  _hits="$(printf '%s\n' "$_strip" | grep -inE '(^|[^a-z])(score|priority|verdict|recommend|worth|candidate)([^a-z]|$)' || true)"
  assert_eq "$(printf '%s\n' "$_hits" | grep -c . || true)" "0" "脚本零判断面字面量（首处: $(printf '%s' "$_hits" | head -n 1))"
else
  _fail "S3.P5-det" "被测脚本缺失"
fi

# =============================================================================
# T1 主链有货（S3.P2/S3.P4 + 设计 §4.3 信封/item 契约 + §4.4 日志 + T3 二次过滤）
# =============================================================================
t_case "T1 主链直跑：exit 0 + 信封落盘（沙箱）"
MY_STUBS="$(mktemp -d "${TMPDIR:-/tmp}/t9396-stubs.XXXXXX")"
make_my_stubs "$MY_STUBS"
export CONTRIB_TEST_STUBS="$MY_STUBS"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
FIX_MAIN="$SB_ROOT/tmp/fixture"
build_fixture_main "$FIX_MAIN"
JSONF="$SB_ROOT/contrib-data/stale-pr-scan.json"
LOGF="$SB_ROOT/contrib-data/logs/stale-pr-scan.log"
out="$(scan_run --)"; rc=$?
assert_exit 0 "$rc" "直跑 exit==0（失败也须 fail-visible，此处应成功）"
[[ -s "$JSONF" ]] && _pass "JSON 落盘且非空: contrib-data/stale-pr-scan.json" || _fail "JSON 落盘" "产物缺失或为空"

t_case "T1/S3.P2 信封字段逐项（合法 JSON + 设计 §4.3.6 全字段）"
jq_assert '.' "JSON 合法（jq 可解析）"
jq_assert '.schema_version == 1' "schema_version==1"
jq_assert '.generated_at | type=="string" and length>0' "generated_at 非空 string"
jq_assert '.repo == "NousResearch/hermes-agent"' "repo==NousResearch/hermes-agent（SCAN_REPO 默认）"
jq_assert '.window_days == 15' "window_days==15（STALE_DAYS 默认）"
assert_eq "$(jqv '.cutoff')" "$CUTOFF" "cutoff==2026-09-02（TODAY-15d，jq 日期数学）"
assert_eq "$(jqv '.scan_order')" "updated_desc" "scan_order==updated_desc"
assert_eq "$(jqv '.total_count')" "3" "total_count==3（fixture）"
assert_eq "$(jqv '.scanned_count')" "3" "scanned_count==3"
jq_assert '.truncated == false' "truncated==false（scanned==total）"
assert_eq "$(jqv '.activity_band.newest')" "2026-09-01T12:00:00Z" "activity_band.newest==scanned 集 updatedAt 最大（设计 §4.3.6，ISO 全时间戳）"
assert_eq "$(jqv '.activity_band.oldest')" "2026-08-01T08:00:00Z" "activity_band.oldest==scanned 集 updatedAt 最小"
assert_eq "$(jqv '.status')" "ok" "status==ok"

t_case "T1/S3.P4 items 字段严格形态（13 字段闭集 + 全项一致 + 枚举序）"
jq_assert '.items | length == 3' "items 3 条"
assert_eq "$(jqv '[.items[].number] | join(" ")')" "103 102 101" "items 顺序==枚举序（updated desc）"
if jq -e --argjson want '["author","changed_files","changed_paths_domain","files_truncated","is_draft","labels","last_activity_at","mergeable","number","salvageability","sweeper_review","title","url"]' '(.items[0] | keys | sort) == $want' "$JSONF" >/dev/null 2>&1; then
  _pass "item 字段==13 字段闭集（09-17 口径补正：+files_truncated）"
else
  _fail "item 字段闭集" "keys 与设计 §4.3.6 的 13 字段（含口径补正 files_truncated）不一致"
fi
jq_assert '.items | map(keys | sort) | unique | length == 1' "全 items 字段集一致"
assert_eq "$(jqv '[.items[] | (.last_activity_at | .[0:10])] | join(" ")')" "2026-09-01 2026-08-20 2026-08-01" "last_activity_at 日期==枚举 updated 日期"
jq_assert '. as $r | ([($r.items[].changed_paths_domain | type == "array")] | all) and ([($r.items[].changed_paths_domain[] | select(test("/")))] | length == 0)' "changed_paths_domain 为列表且元素为一级目录路径（无「/」；09-17 口径补正：实采非空数组占位；含斜杠/非数组负例已验咬中）"
assert_eq "$(jqv '.items[] | select(.number==101) | .changed_paths_domain | join(",")')" "docs,scripts" "101 changed_paths_domain=一级目录去重有序（口径补正实采）"
assert_eq "$(jqv '.items[] | select(.number==101) | .files_truncated')" "false" "101 files_truncated=false（hasNextPage=false）"
assert_eq "$(jqv '.items[] | select(.number==102) | .files_truncated')" "true" "102 files_truncated=true（hasNextPage→文件数 >20 的 API 级事实）"
assert_eq "$(jqv '.items[] | select(.number==103) | .changed_paths_domain | length')" "0" "103 无 files 字段 → []（向后兼容形态）"
assert_eq "$(jqv '.items[] | select(.number==103) | .files_truncated')" "false" "103 无 files 字段 → files_truncated=false"
jq_assert '[.items[].number > 0] | all' "number 全为正整数"

t_case "T1 派生字段：sweeper 标签/review 摘录（原文抄录，SWEEPER_LOGINS 命中）"
assert_eq "$(jqv '.items[] | select(.number==103) | .sweeper_review.present')" "false" "103 无 sweeper review → present=false"
assert_eq "$(jqv '.items[] | select(.number==103) | .salvageability | length')" "0" "103 无 sweeper 标签 → salvageability=[]"
assert_eq "$(jqv '.items[] | select(.number==101) | .salvageability | join(",")')" "sweeper:salvage-candidate" "101 salvageability=标签名原文"
assert_eq "$(jqv '.items[] | select(.number==102) | .salvageability | join(",")')" "sweeper:stale" "102 salvageability=标签名原文"
assert_eq "$(jqv '.items[] | select(.number==101) | .sweeper_review.present')" "true" "101 present=true"
assert_eq "$(jqv '.items[] | select(.number==101) | .sweeper_review.reviewers | join(",")')" "teknium1" "101 reviewers 命中 SWEEPER_LOGINS"
assert_eq "$(jqv '.items[] | select(.number==102) | .sweeper_review.reviewers | join(",")')" "OutThisLife" "102 reviewers 命中"
assert_eq "$(jqv '[.items[] | select(.number==101) | .sweeper_review.reviewers[]] | index("driveBy")')" "null" "非 sweeper 账号（driveBy）不入 reviewers"
assert_eq "$(jqv '.items[] | select(.number==101) | .sweeper_review.snippets | length')" "1" "101 snippets 恰 1 条"
assert_eq "$(jqv '.items[] | select(.number==101) | .sweeper_review.snippets[0] | length')" "280" "snippet 截断 ≤280（300 字 body 咬到 280）"
assert_eq "$(jqv '.items[] | select(.number==102) | .mergeable')" "CONFLICTING" "102 mergeable 原文"
assert_eq "$(jqv '.items[] | select(.number==102) | .changed_files')" "23" "102 changed_files（>20 与 files_truncated=true 对齐）"
jq_assert '.items[] | select(.number==102) | .is_draft' "102 is_draft=true"
assert_eq "$(jqv '[.items[] | select(.number==102) | .labels[]] | join(",")')" "sweeper:stale,bug" "102 labels 原文"

t_case "T3 二次过滤：搜索边界混入件必被咬掉（==cutoff 咬掉，<cutoff 保留）"
assert_eq "$(jqv '[.items[].number] | index(104)')" "null" "104（updated==cutoff 2026-09-02）被咬掉（严格 <）"
assert_eq "$(jqv '[.items[].number] | index(105)')" "null" "105（新件 09-10）被咬掉"
assert_eq "$(jqv '[.items[].number] | index(106)')" "null" "106（新件 09-05）被咬掉"

t_case "T1 gh 调用形态：total 显式 -X GET + 枚举参数 + GraphQL 批量 1 次"
CALLS="$SB_STUBLOG/calls.log"
_total_line="$(grep 'search/issues' "$CALLS" | grep -E 'per_page=1([^0-9]|$)' | head -n 1 || true)"
[[ -n "$_total_line" ]] && _pass "total 调用在案" || _fail "total 调用" "calls.log 无 search/issues per_page=1 行"
assert_ge "$(printf '%s' "$_total_line" | grep -c -- '-X GET' || true)" "1" "total 调用显式 -X GET（形态 C 坑防御）"
_enum_line="$(grep 'search/issues' "$CALLS" | grep 'per_page=100' | head -n 1 || true)"
assert_ge "$(printf '%s' "$_enum_line" | grep -c 'sort=updated' || true)" "1" "枚举 sort=updated"
assert_ge "$(printf '%s' "$_enum_line" | grep -c 'order=desc' || true)" "1" "枚举 order=desc"
assert_eq "$(grep -c ' graphql ' "$CALLS" || true)" "1" "GraphQL 批量恰 1 次（3 辆 ≤50/批）"
_ql="$(grep ' graphql ' "$CALLS" | head -n 1 || true)"
for frag in 'latestReviews' 'labels(first:' 'mergeable' 'changedFiles' 'isDraft' 'files(first:20)'; do
  assert_ge "$(printf '%s' "$_ql" | grep -cF "$frag" || true)" "1" "GraphQL query 含「${frag}」"
done

t_case "T1/§4.4 日志字母表 + 原子落盘（零 .tmp 残留）"
[[ -s "$LOGF" ]] && _pass "日志落盘" || _fail "日志" "logs/stale-pr-scan.log 缺失"
assert_eq "$(grep -vcE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] stale-pr-scan (ok|FAILED)' "$LOGF" || true)" "0" "日志行全符合 [ts] stale-pr-scan ok|FAILED 单行字母表"
assert_ge "$(grep -c ' ok' "$LOGF" || true)" "1" "ok 行在场（与 mv 同次运行尾部落笔）"
assert_eq "$(tmp_count)" "0" "零 .tmp 残留（原子替换）"

t_case "S3.P5-det 产物 JSON 零判断面字段（递归键扫描）"
assert_eq "$(jq -r '[.. | objects | keys[] | select(test("^(score|priority|verdict|recommend|worth|candidate)$"))] | length' "$JSONF" || true)" "0" "JSON 递归键零判断面字段"
jq_assert '.window_days > 0' "窗口参数在信封（下游知切片）"
jq_assert '.truncated | type == "boolean"' "truncated 布尔（切片可判）"
sb_cleanup

# =============================================================================
# T2 零命中（S3.P4 items 空分支 + activity_band null）
# =============================================================================
t_case "T2 零命中：items==[] 且 activity_band null/null"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
FIX_MAIN="$SB_ROOT/tmp/fixture"
build_fixture_zero "$FIX_MAIN"
JSONF="$SB_ROOT/contrib-data/stale-pr-scan.json"
out="$(scan_run --)"; rc=$?
assert_exit 0 "$rc" "零命中直跑 exit==0"
jq_assert '.items == []' "items==[]"
assert_eq "$(jqv '.total_count')" "0" "total_count==0"
assert_eq "$(jqv '.scanned_count')" "0" "scanned_count==0"
assert_eq "$(jqv '.activity_band.newest')" "null" "空集 newest=null"
assert_eq "$(jqv '.activity_band.oldest')" "null" "空集 oldest=null"
assert_eq "$(jqv '.status')" "ok" "status==ok"
sb_cleanup

# =============================================================================
# T7 分批（SCAN_LIMIT=60 → 50+10 两批 GraphQL；items 顺序==枚举序）
# =============================================================================
t_case "T7 SCAN_LIMIT=60：两批 GraphQL + 枚举序 + truncated 语义"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
FIX_MAIN="$SB_ROOT/tmp/fixture"
build_fixture_batch "$FIX_MAIN"
JSONF="$SB_ROOT/contrib-data/stale-pr-scan.json"
out="$(scan_run "SCAN_LIMIT=60" --)"; rc=$?
assert_exit 0 "$rc" "分批直跑 exit==0"
assert_eq "$(jqv '.total_count')" "200" "total_count==200"
assert_eq "$(jqv '.scanned_count')" "60" "scanned_count==60（SCAN_LIMIT 采集上限）"
jq_assert '.truncated == true' "truncated==true（60<200，窗口切片未到底）"
assert_eq "$(jqv '.items | length')" "60" "items 60 条"
assert_eq "$(jqv '[.items[0].number, .items[59].number] | join(" ")')" "2001 2060" "items 首尾==枚举序前 60"
assert_eq "$(grep -c ' graphql ' "$SB_STUBLOG/calls.log" || true)" "2" "GraphQL 恰 2 批（50+10）"
assert_eq "$(jqv '.activity_band.newest')" "2026-08-31T00:00:00Z" "activity_band.newest（ISO 全时间戳）"
assert_eq "$(jqv '.activity_band.oldest')" "2026-08-31T00:00:00Z" "activity_band.oldest（ISO 全时间戳）"
sb_cleanup

# =============================================================================
# T8 null 详情跳过（已枚举但详情 null ⇒ 跳过不伪造；scanned_count 反映实发）
# CONTRACT_AMBIGUOUS: 「实发」= 实际发出详情请求的枚举数（非跳过后幸存数）；
#   依据 §4.3.6 truncated=scanned<total 的切片语义与实发语义对齐。
# =============================================================================
t_case "T8 详情 null 跳过：不入 items、不伪造、scanned_count 反映实发"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
FIX_MAIN="$SB_ROOT/tmp/fixture"
build_fixture_null "$SB_ROOT/tmp/fixture"
JSONF="$SB_ROOT/contrib-data/stale-pr-scan.json"
out="$(scan_run --)"; rc=$?
assert_exit 0 "$rc" "null 详情不致炸（跳过语义）"
assert_eq "$(jqv '.items | length')" "2" "items==2（null 车被跳过）"
assert_eq "$(jqv '[.items[].number] | join(" ")')" "103 101" "消失的 102 不在 items"
assert_eq "$(jqv '[.items[].number] | index(102)')" "null" "102 未被伪造"
# 09-17 口径收敛（非放宽）：CONTRACT_AMBIGUOUS 的「实发」二义收敛为「实交付 items 数」（==2）——
# 与单测 T8 锚（unit/stale-pr-scan.sh T8 scanned_count==2）及信封不变量 scanned_count==|items|
# 对齐，消费方永不见 3≠2 的自相矛盾；truncated=scanned<total 切片语义随之自洽。
assert_eq "$(jqv '.scanned_count')" "2" "scanned_count==2（实交付=幸存 items，与单测 T8 锚一致）"
sb_cleanup

# =============================================================================
# T4 stamp 门槛（--tick：缺=跑 / <6 天=skip / >=6 天=跑 / 跑完再 tick=skip）
# =============================================================================
t_case "T4a stamp：昨日 ok → tick 零 gh 调用、零 stdout、零产物（skip 态）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
FIX_MAIN="$SB_ROOT/tmp/fixture"
build_fixture_main "$FIX_MAIN"
JSONF="$SB_ROOT/contrib-data/stale-pr-scan.json"
LOGF="$SB_ROOT/contrib-data/logs/stale-pr-scan.log"
printf '[2026-09-16 08:00:00] stale-pr-scan ok prev-window\n' > "$LOGF"
out="$(scan_run -- --tick)"; rc=$?
assert_exit 0 "$rc" "tick skip 仍 exit 0（harness 契约）"
assert_eq "$out" "" "tick skip stdout 恒空"
assert_eq "$(stub_count gh)" "0" "skip 态零 gh 调用"
assert_eq "$(wc -l < "$LOGF" | tr -d ' ')" "1" "skip 态零日志行（无噪音）"
[[ -f "$JSONF" ]] && _fail "skip 不落盘" "skip 态竟产出 JSON" || _pass "skip 态不产出 JSON"

t_case "T4b stamp：7 天前 ok → 真跑；TICK_MIN_INTERVAL_DAYS seam 生效"
# 09-17 收口修复（instrument repair）：重播种 7 天前 ok 行——T4a 播的是昨日（skip 态），
# 原实现缺重播种 ⇒ age=1 <6 仍 skip ⇒「真跑」断言全假红（与单测 T4d 同款前置）。
printf '[2026-09-10 08:00:00] stale-pr-scan ok prev-window-7d\n' > "$LOGF"
out="$(scan_run -- --tick)"; rc=$?
assert_exit 0 "$rc" "7 天前 stamp → tick 真跑 exit 0"
assert_eq "$out" "" "tick 真跑 stdout 恒空"
assert_ge "$(stub_count gh)" "1" "真跑有 gh 调用"
assert_eq "$(wc -l < "$LOGF" | tr -d ' ')" "2" "真跑追加恰 1 行日志"
assert_ge "$(tail -n 1 "$LOGF" | grep -c ' ok' || true)" "1" "末行是新 ok 行"
_gh_before="$(stub_count gh)"
out="$(scan_run -- --tick)"; rc=$?
assert_exit 0 "$rc" "跑完后再 tick → exit 0"
assert_eq "$(stub_count gh)" "$_gh_before" "跑完后再 tick 零新增 gh 调用（stamp=今天）"
_seam_before="$(stub_count gh)"
out="$(scan_run "TICK_MIN_INTERVAL_DAYS=8" -- --tick)"; rc=$?
assert_exit 0 "$rc" "TICK_MIN_INTERVAL_DAYS=8 覆盖默认"
assert_eq "$(stub_count gh)" "$_seam_before" "seam 抬高后 7 天差 <8 → skip（零新增调用）"
sb_cleanup

# =============================================================================
# T5 直跑 fail-visible / T6 tick 失败静默（S8.P1：上一版 JSON 字节不变 + 零 .tmp + FAILED 日志）
# =============================================================================
t_case "T5/S8.P1 gh 失败态直跑：rc≠0 + 上一版 JSON 字节不变 + 零 .tmp + FAILED 日志含错误首行"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
FIX_MAIN="$SB_ROOT/tmp/fixture"
build_fixture_main "$FIX_MAIN"
JSONF="$SB_ROOT/contrib-data/stale-pr-scan.json"
LOGF="$SB_ROOT/contrib-data/logs/stale-pr-scan.log"
out="$(scan_run --)"; rc=$?
assert_exit 0 "$rc" "前置：成功跑出完好 JSON"
cp "$JSONF" "$SB_ROOT/tmp/prev-good.json"
_n1="$(wc -l < "$LOGF" | tr -d ' ')"
out="$(scan_run "STUB_SCAN_FAIL=1" --)"; rc=$?
assert_ne "$rc" "0" "直跑失败 fail-visible（rc≠0）"
assert_eq "$(tmp_count)" "0" "零 .tmp 残留（失败不留半成品）"
if cmp -s "$SB_ROOT/tmp/prev-good.json" "$JSONF"; then
  _pass "上一版完好 JSON 字节不变"
else
  _fail "JSON 字节不变" "失败态改写了上一版产物"
fi
assert_eq "$(wc -l < "$LOGF" | tr -d ' ')" "$((_n1 + 1))" "失败追加恰 1 行日志"
assert_ge "$(grep -c 'stale-pr-scan FAILED' "$LOGF" || true)" "1" "FAILED 行在案"
assert_ge "$(grep -c 't9396-stub-network-down' "$LOGF" || true)" "1" "FAILED 行嵌入 gh stderr 首行"

t_case "T6 gh 失败态 tick：恒 exit 0 + stdout 恒空 + FAILED 日志"
# 09-17 收口修复（instrument repair）：重播种过期 stamp——T5 前置跑留下今日 ok 行，
# tick 门槛命中 skip 态会短路掉失败路径（零 gh 调用零日志），与单测 T6 真失败语义不符。
printf '[2026-09-10 08:00:00] stale-pr-scan ok prev-window-expired\n' > "$LOGF"
_n2="$(wc -l < "$LOGF" | tr -d ' ')"
out="$(scan_run "STUB_SCAN_FAIL=1" -- --tick)"; rc=$?
assert_exit 0 "$rc" "tick 失败仍恒 exit 0"
assert_eq "$out" "" "tick 失败 stdout 恒空"
assert_eq "$(wc -l < "$LOGF" | tr -d ' ')" "$((_n2 + 1))" "FAILED 行追加"
assert_ge "$(grep -c 't9396-stub-network-down' "$LOGF" || true)" "1" "错误首行入日志（tr 换行后仍单行）"
sb_cleanup

t_finish
