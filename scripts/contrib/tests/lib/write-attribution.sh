#!/bin/bash
# =============================================================================
# write-attribution.sh — 生产 contrib-data 变更的「写入归属」引擎（卡 t_cbf34542）
#
# 问题本体：判据「套件对生产 contrib-data 零写入」原用「全量 shasum 前后 diff 行数==0」求值
# （s4 4.P1 / t1-04 4.1）。只要套件运行窗口与生产写手（launchd com.stringzhao.approval-collect
# 每 90s 跑 scripts/approval/collect.sh 追加 contrib-data/logs/approval-collect.log）重叠，
# diff 必然非 0 ⇒ 门恒定红。恒定红的门会被训练成被忽略；为让它绿去放宽又退回假绿。
#
# 本引擎给判据加**写入归属定性**：把「窗口内变更」机械拆成
#   ① 生产写手写的 → external（evidence 行 + PASS）
#   ② 套件/未知写的 → suite（默认 deny ⇒ 判红）
#   ③ 判据面外路径 → outside-surface（evidence 行，不判失败；非套件可达写面，见 README）
#
# 归属规则（证据**合取**，全部机械、零人眼）：
#   路径归属 变更路径 ∈ 生产写手清单（闭集，逐条带实测证据）
#   追加语义 head -c <before_size> after 的 sha256 == before 快照哈希 ∧ inode 不变
#   记录形态 追加块**逐行**落在该写手输出字母表内（无块级容错：套件写入不得被生产写入掩蔽）
#   时序自证 追加块中 ≥1 条记录的内嵌时间戳 ∈ [窗口起−120s, 窗口止+120s]
#   时序近邻 corroborated-* 另需 |佐证记录时间戳 − 锚| ≤ 30s（存在性佐证会被
#            「套件恰在佐证写手活跃窗内写入」掩蔽 ⇒ 必须钉住「改文件」与「落记录」的同次运行近邻性）
#   删除时点锚 删除不留内容、也没有「被删那一刻」的文件 mtime（= 其创建时刻）⇒ corroborated-delete
#            的锚改取**父目录 mtime**（富快照 sidecar `<out>.dirs` 承载；语义 = 该目录最后一次条目增删，
#            unlink 即触发；是删除时刻的上界，同目录无后续条目增删时恰等于删除时刻）
#   金丝雀短路 变更文件新增内容含 `S4-P1-` 前缀行 ⇒ 无条件 suite/canary-marker（先于佐证判定；
#            本 harness 注入物是确定事实，真实泄漏仍由存在性 + 时序近邻拦截）；
#            删除类无内容可读 ⇒ 改判**路径形态**（basename 以 `S4-P1-` 开头），先于清单匹配
#   默认 deny：任一证据不成立（含清单缺失/空/不可解析、路径新增/删除）⇒ 归 suite。
#
# API（契约逐字，见 state.md「契约规约」）：
#   wa_registry_default <tests_root>             → stdout=清单路径；env WA_REGISTRY 覆盖
#   wa_snapshot <repo_root> <out>                → 富快照 <sha256>\t<size>\t<mtime>\t<inode>\t<relpath>
#                                                  + 目录侧车 <out>.dirs（同 5 列，sha 列=<DIR>、size 列=0）
#   wa_classify <repo> <before> <after> <reg> <out> <t0> <t1> → 逐变更文件 WA-CLASS 行 + 末行计数
#   wa_selftest <tmpdir>                         → 合成树全形态自证（rc=0 iff 全部与预期一致）
#   wa_inject <mode> <repo_root> <registry> [<arg4> [<arg5>]] → canary-create / canary-append /
#     external-append / delete-plant <repo> <reg> <canary|external> /
#     delete-fire <repo> <reg> <path> <canary|external>（两段式删除对照；每次恰 1 行 WA-INJECT）
#   wa_wait_external <repo> <before_snap> <max_sec> [poll_sec] → 弹性等待真实生产写手落笔
#
# 纪律：
#   - 只读生产树：库本身零写入（唯一写生产树的入口是显式 opt-in 的 wa_inject）；产物落
#     调用方指定路径（<out> 及其 .diff/.tmp 兄弟件）
#   - PATH 自足（launchd 极简 PATH + run.sh shim PATH）：只用 /usr/bin/diff（绝对 pin）与
#     find/stat/shasum/head/tail/wc/sort/tr/awk/sed/grep/mktemp/date/sleep；禁 jq/perl/python3
#   - bash 3.2 兼容（macOS 自带）：无关联数组、无 mapfile、无 ${var,,}
#   - diff 调用一律落在本库内（acceptance 文件的命令位 diff 调用点由守卫钉死：s4=2 / t1-04=1）
# =============================================================================

# 时间戳形态常量（字母表首捕获组的机械校验用；全角门规避：全部走 ${var} 花括号形态）
WA_TS_DATE_SHAPE='[0-9]{4}-[0-9]{2}-[0-9]{2}'
WA_TS_TIME_SHAPE='[0-9]{2}:[0-9]{2}:[0-9]{2}'
# 时序自证窗口松弛：记录时间戳允许比窗口早/晚各 120s（launchd 采样相位 + 落笔延迟）
WA_WINDOW_SLACK=120
# 时序近邻阈值：corroborated-* 的佐证记录与变更文件 mtime 的最大间隔（秒）
WA_CORR_PROXIMITY=30
# 注入物标记前缀（金丝雀可 grep、可追责；命中即无条件 suite/canary-marker）
WA_MARKER_PREFIX='S4-P1-'
# exit 码闭集：0=成功 1=自证/等待未达预期 2=依赖或输入缺失（fail-closed）
WA_DEP_DIFF='/usr/bin/diff'

wa__fail() { # <msg> → stderr（调用方据 rc=2 处理）
  printf 'WA-DEP-FAIL: %s\n' "$1" >&2
}

# =============================================================================
# 1. 清单：路径、解析与匹配
# =============================================================================

# wa_registry_default <tests_root> → stdout=清单路径；exit 0（正常）/ 2（WA_REGISTRY 覆盖值非法）
# 覆盖值必须存在且非空，否则 fail-closed（绝不回退默认清单——那会让「清单缺失」变成静默绿）
wa_registry_default() {
  local tests_root="${1:-}"
  if [[ -n "${WA_REGISTRY:-}" ]]; then
    if [[ -s "$WA_REGISTRY" ]]; then
      printf '%s' "$WA_REGISTRY"
      return 0
    fi
    wa__fail "WA_REGISTRY 覆盖值不存在或为空: ${WA_REGISTRY}（fail-closed，不回退默认清单）"
    return 2
  fi
  if [[ -z "$tests_root" ]]; then
    wa__fail "wa_registry_default 缺参数 <tests_root>"
    return 2
  fi
  printf '%s' "$tests_root/lib/production-writers.tsv"
  return 0
}

# wa__alpha_ts_re <alphabet> → stdout=首捕获组 ERE；rc 1=非法（无组 / 嵌套括号 / 括号不配对）
# 机械实现：字符扫描（跳转义与方括号表达式），首个未嵌套 '(' 起匹配到其配对 ')'。
# ⚠️ 字母表经 ENVIRON 传入而非 `awk -v`：-v 会对值做转义解释（实测 `\[` 被吃成 `[`，
# 方括号分支随即把 `(` 当字符类吞掉 ⇒ 首捕获组提取失败），ENVIRON 逐字节传递。
wa__alpha_ts_re() {
  WA_ALPHA_ARG="${1:-}" awk 'BEGIN {
    re = ENVIRON["WA_ALPHA_ARG"]
    n = length(re); depth = 0; start = 0; out = ""; bad = 0
    for (i = 1; i <= n; i++) {
      c = substr(re, i, 1)
      if (c == "\\") { i++; continue }
      if (c == "[") {
        if (substr(re, i + 1, 1) == "[") {          # [[:name:]] 内嵌字符类
          j = index(substr(re, i + 1), ":]")
          if (j > 0) { i = i + 1 + j } else { i++ }
          continue
        }
        i++
        while (i <= n && substr(re, i, 1) != "]") i++
        continue
      }
      if (c == "(") { if (depth > 0) { bad = 1; break }; depth++; if (start == 0) start = i; continue }
      if (c == ")") {
        if (depth > 0) {
          depth--
          if (out == "" && start > 0) { out = substr(re, start + 1, i - start - 1); start = -1 }
        } else { bad = 1; break }
        continue
      }
    }
    if (bad || depth != 0 || out == "") { exit 1 }
    printf "%s", out
  }'
}

# wa__alpha_valid <alphabet> → 0=合法（首捕获组是行首方括号内的记录时间戳）；1=非法
wa__alpha_valid() {
  local alpha="${1:-}" tsre="" pre=""
  tsre="$(wa__alpha_ts_re "$alpha")" || return 1
  case "${tsre}" in
    *"${WA_TS_DATE_SHAPE}"*) : ;;
    *) return 1 ;;
  esac
  case "${tsre}" in
    *"${WA_TS_TIME_SHAPE}"*) : ;;
    *) return 1 ;;
  esac
  # 首捕获组必须锚在行首方括号内（记录时间戳本位；其余形态只作同块补充形态）
  pre="${alpha%%\(*}"
  [[ "$pre" == '^\[' ]] || return 1
  return 0
}

# wa__registry_load <registry> → 载入 WA_R_* 数组；rc 0=合法；2=缺失/空/结构非法（fail-closed）
# 结构：非注释非空行必须恰 5 个 TAB 字段且逐字段非空；mode ∈ 闭集；
#   append-records ⇒ 字母表首捕获组为记录时间戳；corroborated-* ⇒ 佐证路径非 :none；
#   corroborated-delete 另需字母表恒为 :none（字段 4/5 的语义位不得互换 ⇒ DbC 双向校验）。
WA_R_N=0
wa__registry_load() {
  local reg="${1:-}" line="" nf=0 f1="" f2="" f3="" f4="" f5=""
  WA_R_N=0
  WA_R_PAT=(); WA_R_WRITER=(); WA_R_MODE=(); WA_R_ALPHA=(); WA_R_CORR=()
  if [[ -z "$reg" || ! -f "$reg" || ! -s "$reg" ]]; then
    wa__fail "清单缺失或为空: ${reg:-<空>}"
    return 2
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "${line}" in
      ''|'#'*) continue ;;
    esac
    nf="$(printf '%s' "$line" | awk -F'\t' '{print NF}')"
    if [[ "$nf" != "5" ]]; then
      wa__fail "清单字段数非 5（NF=${nf}）: ${line}"
      return 2
    fi
    IFS=$'\t' read -r f1 f2 f3 f4 f5 <<< "$line"
    if [[ -z "$f1" || -z "$f2" || -z "$f3" || -z "$f4" || -z "$f5" ]]; then
      wa__fail "清单字段存在空值: ${line}"
      return 2
    fi
    case "${f3}" in
      append-records)
        wa__alpha_valid "$f4" || { wa__fail "字母表首捕获组非记录时间戳（或无捕获组/含嵌套括号）: ${f1}"; return 2; }
        ;;
      corroborated-rewrite|corroborated-create)
        [[ "$f5" == ':none' ]] && { wa__fail "corroborated-* 条目佐证路径不得为 :none: ${f1}"; return 2; }
        ;;
      corroborated-delete)
        # 删除类 DbC：字段 4 必须 :none ∧ 字段 5 必须非 :none（缺一 ⇒ fail-closed，禁静默降级）
        [[ "$f4" == ':none' ]] || { wa__fail "corroborated-delete 条目字母表必须为 :none（删除无内容形态可自证）: ${f1}"; return 2; }
        [[ "$f5" != ':none' ]] || { wa__fail "corroborated-delete 条目佐证路径不得为 :none: ${f1}"; return 2; }
        ;;
      *)
        wa__fail "mode 不在闭集 {append-records,corroborated-rewrite,corroborated-create,corroborated-delete}: ${f3}"
        return 2
        ;;
    esac
    WA_R_PAT[${#WA_R_PAT[@]}]="$f1"
    WA_R_WRITER[${#WA_R_WRITER[@]}]="$f2"
    WA_R_MODE[${#WA_R_MODE[@]}]="$f3"
    WA_R_ALPHA[${#WA_R_ALPHA[@]}]="$f4"
    WA_R_CORR[${#WA_R_CORR[@]}]="$f5"
  done < "$reg"
  WA_R_N="${#WA_R_PAT[@]}"
  if [[ "$WA_R_N" -lt 1 ]]; then
    wa__fail "清单无有效条目（禁空集静默绿）: ${reg}"
    return 2
  fi
  return 0
}

# wa__registry_match <path> → stdout=首个匹配条目下标；rc 1=无匹配（⇒ outside-surface）
# 字段 1 是 shell glob 模式（bash case 语义），非正则；精确路径即字面模式。
wa__registry_match() {
  local p="${1:-}" i=0
  for ((i = 0; i < WA_R_N; i++)); do
    # shellcheck disable=SC2254  # 意图即 glob 匹配（字段 1 是 shell 模式，非字面量）
    case "$p" in
      ${WA_R_PAT[$i]}) printf '%s' "$i"; return 0 ;;
    esac
  done
  return 1
}

# wa__registry_match_mode <path> <mode> → stdout=首个「mode 相符且路径匹配」的条目下标；rc 1=无
# ⚠ 删除分支**必须**经本函数取行：wa__registry_match 是首匹配即返回，而同一路径面可能先命中
#   创建行（本例 `pending/*` 的 create 行在前）⇒ 用它取删除行机械不可达（E-1）。
wa__registry_match_mode() {
  local p="${1:-}" want="${2:-}" i=0
  for ((i = 0; i < WA_R_N; i++)); do
    [[ "${WA_R_MODE[$i]}" == "$want" ]] || continue
    # shellcheck disable=SC2254
    case "$p" in
      ${WA_R_PAT[$i]}) printf '%s' "$i"; return 0 ;;
    esac
  done
  return 1
}

# =============================================================================
# 2. 富快照（内容 + 元数据一次承载，避免双快照取点不同步）
# =============================================================================

# wa_snapshot <repo_root> <out> → 0；2=contrib-data 缺失 / stat/find 失败 / 快照为空（禁空快照）
#   主文件 <out>：<sha256>\t<size>\t<mtime>\t<inode>\t<relpath>（格式/行数语义冻结，逐字节不变）
#   侧车 <out>.dirs：目录表，同 5 列但 sha 列恒字面量 `DIR`、size 列恒 `0`（承载目录 mtime 删除锚）；
#     含 contrib-data 自身与其全部子目录；与主文件同一次遍历、同 `sort -z` 序。
#     落盘走临时件 + mv（禁产出半份 sidecar）；**所有失败返回路径都清掉 `<out>.dirs` 与本轮临时件**
#     ——$ART 固定路径复用场景下，上一轮 sidecar 会冒充本轮锚（R-9①）。
wa_snapshot() {
  local repo_root="${1:-}" out="${2:-}"
  if [[ -z "$repo_root" || -z "$out" ]]; then
    wa__fail "wa_snapshot 参数缺失"
    return 2
  fi
  if [[ ! -d "$repo_root/contrib-data" ]]; then
    wa__fail "contrib-data 缺失: $repo_root/contrib-data"
    return 2
  fi
  local list="${out}.list.$$" sorted="${out}.sorted.$$"
  local dirs="${out}.dirs" dirs_tmp="${out}.dirs.tmp.$$"
  rm -f "$dirs" "$dirs_tmp"
  if ! ( cd "$repo_root" && find contrib-data \( -type f -o -type d \) -print0 ) > "$list" 2>/dev/null; then
    rm -f "$list" "$sorted" "$dirs" "$dirs_tmp"
    wa__fail "find contrib-data 失败: $repo_root"
    return 2
  fi
  if ! sort -z < "$list" > "$sorted" 2>/dev/null; then
    rm -f "$list" "$sorted" "$dirs" "$dirs_tmp"
    wa__fail "sort -z 失败"
    return 2
  fi
  : > "$out" || { rm -f "$list" "$sorted" "$dirs" "$dirs_tmp"; wa__fail "快照文件不可写: $out"; return 2; }
  : > "$dirs_tmp" || { rm -f "$list" "$sorted" "$out" "$dirs" "$dirs_tmp"; wa__fail "侧车文件不可写: $dirs"; return 2; }
  local rel="" f="" st="" size="" mt="" ino="" sha_line="" sha="" n=0 nd=0
  while IFS= read -r -d '' rel; do
    f="$repo_root/$rel"
    # 快照遍历期间被并发删除：该条目在本次快照中不存在（合法瞬态）；其余情况 fail-closed
    if [[ ! -e "$f" ]]; then
      continue
    fi
    if [[ -d "$f" ]]; then
      st="$(stat -f '%m %i' "$f" 2>/dev/null)" || st=""
      if [[ -z "$st" ]]; then
        if [[ -e "$f" ]]; then
          rm -f "$list" "$sorted" "$dirs" "$dirs_tmp"
          wa__fail "目录 stat 失败: $rel"
          return 2
        fi
        continue
      fi
      mt="${st%% *}"
      ino="${st#* }"
      printf 'DIR\t0\t%s\t%s\t%s\n' "$mt" "$ino" "$rel" >> "$dirs_tmp"
      nd=$((nd + 1))
      continue
    fi
    st="$(stat -f '%z %m %i' "$f" 2>/dev/null)" || st=""
    if [[ -z "$st" ]]; then
      if [[ -e "$f" ]]; then
        rm -f "$list" "$sorted" "$dirs" "$dirs_tmp"
        wa__fail "stat 失败: $rel"
        return 2
      fi
      continue
    fi
    size="${st%% *}"
    st="${st#* }"
    mt="${st%% *}"
    ino="${st#* }"
    sha_line="$(shasum -a 256 "$f" 2>/dev/null)" || sha_line=""
    sha="${sha_line%% *}"
    if [[ -z "$sha" ]]; then
      if [[ -e "$f" ]]; then
        rm -f "$list" "$sorted" "$dirs" "$dirs_tmp"
        wa__fail "shasum 失败: $rel"
        return 2
      fi
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$sha" "$size" "$mt" "$ino" "$rel" >> "$out"
    n=$((n + 1))
  done < "$sorted"
  rm -f "$list" "$sorted"
  if [[ "$n" -lt 1 || ! -s "$out" ]]; then
    rm -f "$dirs" "$dirs_tmp"
    wa__fail "快照为空（contrib-data 无文件）: $repo_root"
    return 2
  fi
  if [[ "$nd" -lt 1 ]]; then
    rm -f "$dirs" "$dirs_tmp"
    wa__fail "目录侧车为空（contrib-data 自身缺行）: $repo_root"
    return 2
  fi
  mv "$dirs_tmp" "$dirs" 2>/dev/null || { rm -f "$dirs" "$dirs_tmp"; wa__fail "侧车落盘失败: $dirs"; return 2; }
  return 0
}

# =============================================================================
# 3. 归属判定
# =============================================================================

# 归属结论载体（类名赋值各恰一处 ⇒ mutation 可经单次 sed 注入「一律 external」/「未注册也放行」）
WA_CLS=""
WA_REASON=""
WA_EXTRA=""
WA_LAST_TS=""
WA_CORR_TS=""
WA_CORR_DT=""
wa__r_suite() { WA_CLS="suite"; WA_REASON="$1"; }
wa__r_external() { WA_CLS="external"; WA_REASON="$1"; }
wa__r_outside() { WA_CLS="outside-surface"; WA_REASON="outside-surface"; }

WA_C_TOTAL=0
WA_C_EXTERNAL=0
WA_C_SUITE=0
WA_C_OUTSIDE=0
wa__emit() { # <out> <path> → 追加一行 WA-CLASS 并计数
  printf 'WA-CLASS %s path=%s reason=%s%s\n' "${WA_CLS}" "$2" "${WA_REASON}" "${WA_EXTRA:+ ${WA_EXTRA}}" >> "$1"
  WA_C_TOTAL=$((WA_C_TOTAL + 1))
  case "${WA_CLS}" in
    suite) WA_C_SUITE=$((WA_C_SUITE + 1)) ;;
    external) WA_C_EXTERNAL=$((WA_C_EXTERNAL + 1)) ;;
    outside-surface) WA_C_OUTSIDE=$((WA_C_OUTSIDE + 1)) ;;
  esac
}

# wa__ts_key <ts 字符串> → stdout=14 位数字键；rc 1=不可解析（⇒ 视为窗口外）
wa__ts_key() {
  local k=""
  k="$(printf '%s' "${1:-}" | tr -cd '0-9')"
  case "${k}" in
    ??????????????) printf '%s' "$k"; return 0 ;;
  esac
  return 1
}

# wa__ts_epoch <ts 字符串> → stdout=epoch；rc 1=不可解析
wa__ts_epoch() {
  local e=""
  e="$(date -j -f "%Y-%m-%d %H:%M:%S" "${1:-}" +%s 2>/dev/null)" || e=""
  case "${e}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$e"
  return 0
}

# wa__corroborated <repo_root> <佐证字段> <lo_key> <hi_key> <变更文件 mtime_epoch>
#   → 0=佐证成立（置 WA_CORR_TS/WA_CORR_DT）；1=不成立
# 佐证成立充要条件：某佐证日志内存在一条记录同时满足
#   ① 形状合规（落该日志字母表）② 时间戳 ∈ 窗口 ③ |记录时间戳 − 变更文件 mtime| ≤ 30s
# 佐证字段以 '|' 分隔多佐证（任一成立即成立；多路取最近记录）；佐证日志自身必须是清单中的
# append-records 条目（否则该佐证源不可用 ⇒ 跳过；全不可用 ⇒ 归 suite，fail-closed）。
# **两态都落审计信息**：不成立时也置 WA_CORR_TS/WA_CORR_DT = 最近的在窗记录（失败态更需要审计），
# 无任何在窗记录时两者均为 `none`（`Δt=none ts=none`）。
wa__corroborated() {
  local repo_root="$1" corr="$2" lo_key="$3" hi_key="$4" mtime="$5"
  local corr_paths=() p="" idx="" alpha="" tsre="" logf="" ts="" k="" e="" dt="" abs_dt=""
  local p_lo_key="" p_hi_key="" best_dt="" best_ts=""
  WA_CORR_TS="none"
  WA_CORR_DT="none"
  p_lo_key="$(date -r $((mtime - WA_CORR_PROXIMITY)) +%Y%m%d%H%M%S)" || p_lo_key=""
  p_hi_key="$(date -r $((mtime + WA_CORR_PROXIMITY)) +%Y%m%d%H%M%S)" || p_hi_key=""
  [[ -n "$p_lo_key" && -n "$p_hi_key" ]] || return 1
  IFS='|' read -r -a corr_paths <<< "$corr"
  for p in ${corr_paths[@]+"${corr_paths[@]}"}; do
    [[ -n "$p" ]] || continue
    logf="$repo_root/$p"
    [[ -f "$logf" ]] || continue
    idx="$(wa__registry_match "$p")" || continue
    [[ "${WA_R_MODE[$idx]}" == "append-records" ]] || continue
    alpha="${WA_R_ALPHA[$idx]}"
    tsre="$(wa__alpha_ts_re "$alpha")" || continue
    [[ -n "$tsre" ]] || continue
    while IFS= read -r ts; do
      k="$(wa__ts_key "$ts")" || continue
      # 廉价前置筛（纯 bash）：须在窗口内才做 date 解析（避免逐行 fork）
      [[ "$k" -ge "$lo_key" && "$k" -le "$hi_key" ]] || continue
      e="$(wa__ts_epoch "$ts")" || continue
      dt=$((e - mtime))
      if [[ "$dt" -lt 0 ]]; then
        abs_dt=$((-dt))
      else
        abs_dt="$dt"
      fi
      if [[ "$abs_dt" -le "$WA_CORR_PROXIMITY" ]]; then
        WA_CORR_TS="$ts"
        WA_CORR_DT="$abs_dt"
        return 0
      fi
      if [[ -z "$best_dt" || "$abs_dt" -lt "$best_dt" ]]; then
        best_dt="$abs_dt"
        best_ts="$ts"
      fi
    done < <(LC_ALL=C grep -E "$alpha" "$logf" 2>/dev/null | LC_ALL=C grep -oE "$tsre" 2>/dev/null)
  done
  if [[ -n "$best_dt" ]]; then
    WA_CORR_TS="$best_ts"
    WA_CORR_DT="$best_dt"
  fi
  return 1
}

# wa__marker_hit <file> → 0=文件内含 `S4-P1-` 前缀行（注入物短路）；1=无
wa__marker_hit() {
  LC_ALL=C grep -qE "^${WA_MARKER_PREFIX}" "$1" 2>/dev/null
}

# wa__marker_hit_new <repo_root> <path> <kind> <bline> → 0=新增内容含注入 marker
#   C（新建）：整个文件即新增内容；M（改写）：只看**追加块**（前 before_size 字节是历史内容，
#   不得因历史遗留 marker 行把后续每次运行都判 red——生产日志跑过一次 canary-append 后即长期含该行）。
wa__marker_hit_new() {
  local root="$1" p="$2" kind="$3" bline="$4" size blk rc
  [[ -f "$root/$p" ]] || return 1
  if [[ "$kind" == "C" ]]; then
    wa__marker_hit "$root/$p"
    return $?
  fi
  size="$(wa__line_field "$bline" 2)"
  [[ -n "$size" ]] || return 1
  blk="$(mktemp "${TMPDIR:-/tmp}/wa-mk.XXXXXX")" || return 1
  tail -c "+$((size + 1))" "$root/$p" > "$blk" 2>/dev/null
  wa__marker_hit "$blk"
  rc=$?
  rm -f "$blk"
  return "$rc"
}

# wa__dirmtime <目录侧车文件> <目录相对路径> → stdout=mtime epoch；rc 1=侧车缺 / 无该目录行 / mtime 不可解析
# 删除的时点锚。侧车行格式 `<DIR>\t0\t<mtime>\t<inode>\t<relpath>` ⇒ 按第 5 列精确等值取第 3 列
# （禁用 grep 子串匹配：relpath 含正则元字符时语义漂移）。目录名经 ENVIRON 传入（同 wa__alpha_ts_re 纪律）。
wa__dirmtime() {
  local snap="${1:-}" dir="${2:-}" mt=""
  [[ -n "$snap" && -n "$dir" && -f "$snap" ]] || return 1
  mt="$(WA_DIR_ARG="$dir" awk -F'\t' 'BEGIN { d = ENVIRON["WA_DIR_ARG"] } $5 == d { print $3; exit }' "$snap" 2>/dev/null)" || mt=""
  case "${mt}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$mt"
  return 0
}

# wa__classify_one <repo_root> <path> <kind C|D|M> <before_line> <after_line> <lo_key> <hi_key> <after_dirs>
#   → 置 WA_CLS/WA_REASON/WA_EXTRA（不发射；发射由调用方统一做）
#   <after_dirs>：after 富快照的目录侧车路径（`<after>.dirs`），仅删除分支消费。
wa__classify_one() {
  local repo_root="$1" path="$2" kind="$3" bline="$4" aline="$5" lo_key="$6" hi_key="$7" after_dirs="${8:-}"
  local idx="" mode="" writer="" alpha="" corr=""
  WA_EXTRA=""
  # ---- 删除类的 marker 路径短路（**上提到清单匹配之前**，面内面外同；R-1）----
  # 删除不留内容 ⇒ 既有「新增内容含 marker 行」短路对 D 天然失效，路径是 D 唯一可读的自证面。
  if [[ "$kind" == "D" ]]; then
    case "${path##*/}" in
      "${WA_MARKER_PREFIX}"*) wa__r_suite "canary-marker"; WA_EXTRA="marker=hit"; return 0 ;;
    esac
  fi
  if ! idx="$(wa__registry_match "$path")"; then
    # 面外路径：marker 短路优先（注入物自证归属；QA 抓出的口径缺口 —— 原实现只在注册面分支判 marker，
    # 使「判据面外新建 S4-P1- 文件」落 outside-surface 而不判红，与「无条件 suite」契约不符）
    if wa__marker_hit_new "$repo_root" "$path" "$kind" "$bline"; then
      wa__r_suite "canary-marker"
      WA_EXTRA="surface=outside marker=hit"
      return 0
    fi
    wa__r_outside
    return 0
  fi
  mode="${WA_R_MODE[$idx]}"
  writer="${WA_R_WRITER[$idx]}"
  alpha="${WA_R_ALPHA[$idx]}"
  corr="${WA_R_CORR[$idx]}"
  local f="$repo_root/$path"

  # ---- 面内新建 ----
  if [[ "$kind" == "C" ]]; then
    if [[ -f "$f" ]] && wa__marker_hit "$f"; then
      wa__r_suite "canary-marker"
      WA_EXTRA="writer=${writer}"
      return 0
    fi
    if [[ "$mode" == "append-records" ]]; then
      wa__r_suite "created-unallowed"
      WA_EXTRA="writer=${writer}"
      return 0
    fi
    if wa__corroborated "$repo_root" "$corr" "$lo_key" "$hi_key" "$(wa__line_field "$aline" 3)"; then
      wa__r_external "corroborated-ok"
      WA_EXTRA="writer=${writer} Δt=${WA_CORR_DT}s ts=${WA_CORR_TS}"
    else
      wa__r_suite "no-corroboration"
      WA_EXTRA="writer=${writer} Δt=${WA_CORR_DT} ts=${WA_CORR_TS}"
    fi
    return 0
  fi

  # ---- 面内删除：仅显式 opt-in 的 corroborated-delete 面放行（其余 mode 面内一律判红）----
  # 证据合取（全部机械、零人眼）：路径 ∈ 删除面（闭集显式行）∧ 删除时点锚可取（父目录 mtime）∧
  #   佐证日志存在**在窗**合规记录 ∧ |记录 ts − 锚| ≤ WA_CORR_PROXIMITY。任一不成立 ⇒ suite（默认 deny）。
  if [[ "$kind" == "D" ]]; then
    local didx="" dwriter="" dcorr="" ddir="" anchor=""
    if ! didx="$(wa__registry_match_mode "$path" "corroborated-delete")"; then
      # 既有语义逐字保留：append-records / corroborated-rewrite / corroborated-create 面内的删除仍判红
      wa__r_suite "deleted"
      WA_EXTRA="writer=${writer}"
      return 0
    fi
    dwriter="${WA_R_WRITER[$didx]}"
    dcorr="${WA_R_CORR[$didx]}"
    ddir=""
    case "$path" in
      */*) ddir="${path%/*}" ;;
    esac
    anchor="$(wa__dirmtime "$after_dirs" "$ddir")" || anchor=""
    if [[ -z "$anchor" ]]; then
      # 锚不可用（侧车缺 / 父目录不在目录表 / mtime 非十进制）⇒ 保守方向判红
      wa__r_suite "no-delete-corroboration"
      WA_EXTRA="writer=${dwriter} dir_mtime=none"
      return 0
    fi
    if wa__corroborated "$repo_root" "$dcorr" "$lo_key" "$hi_key" "$anchor"; then
      wa__r_external "corroborated-delete-ok"
      WA_EXTRA="writer=${dwriter} Δt=${WA_CORR_DT}s ts=${WA_CORR_TS} dir_mtime=${anchor}"
    else
      wa__r_suite "no-delete-corroboration"
      WA_EXTRA="writer=${dwriter} Δt=${WA_CORR_DT} ts=${WA_CORR_TS} dir_mtime=${anchor}"
    fi
    return 0
  fi

  # ---- 面内改写 ----
  local b_sha b_size b_ino a_sha a_size a_mt a_ino
  b_sha="$(wa__line_field "$bline" 1)"
  b_size="$(wa__line_field "$bline" 2)"
  b_ino="$(wa__line_field "$bline" 4)"
  a_sha="$(wa__line_field "$aline" 1)"
  a_size="$(wa__line_field "$aline" 2)"
  a_mt="$(wa__line_field "$aline" 3)"
  a_ino="$(wa__line_field "$aline" 4)"

  # corroborated-*：先做注入物短路（先于佐证判定），再判佐证。
  # 注意：不做 inode 断言——重写类写手（notify.sh `jq > tmp && mv`）的正常机制就是 inode 替换，
  # 对 append-records 才成立「inode 不变」的追加语义证据。
  if [[ "$mode" != "append-records" ]]; then
    if wa__marker_hit "$f"; then
      wa__r_suite "canary-marker"
      WA_EXTRA="writer=${writer}"
      return 0
    fi
    if wa__corroborated "$repo_root" "$corr" "$lo_key" "$hi_key" "$a_mt"; then
      wa__r_external "corroborated-ok"
      WA_EXTRA="writer=${writer} Δt=${WA_CORR_DT}s ts=${WA_CORR_TS}"
    else
      wa__r_suite "no-corroboration"
      WA_EXTRA="writer=${writer} Δt=${WA_CORR_DT} ts=${WA_CORR_TS}"
    fi
    return 0
  fi

  # ---- append-records：追加语义 + 注入物短路 + 记录形态 + 时序自证 ----
  if [[ "$b_ino" != "$a_ino" ]]; then
    wa__r_suite "inode-changed"
    WA_EXTRA="writer=${writer}"
    return 0
  fi
  if [[ "$a_size" -lt "$b_size" ]]; then
    wa__r_suite "not-append-only"
    WA_EXTRA="writer=${writer}"
    return 0
  fi
  if [[ "$a_size" -eq "$b_size" ]]; then
    if [[ "$b_sha" == "$a_sha" ]]; then
      wa__r_suite "empty-append"
    else
      wa__r_suite "not-append-only"
    fi
    WA_EXTRA="writer=${writer}"
    return 0
  fi
  local pfix="" block=""
  pfix="$(head -c "$b_size" "$f" 2>/dev/null | shasum -a 256)" || pfix=""
  if [[ "${pfix%% *}" != "$b_sha" ]]; then
    wa__r_suite "not-append-only"
    WA_EXTRA="writer=${writer}"
    return 0
  fi
  block="$(tail -c "+$((b_size + 1))" "$f" 2>/dev/null)" || block=""
  if [[ -z "$block" ]]; then
    wa__r_suite "empty-append"
    WA_EXTRA="writer=${writer}"
    return 0
  fi
  local tsre="" line="" records=0 ts="" k=""
  if printf '%s\n' "$block" | LC_ALL=C grep -qE "^${WA_MARKER_PREFIX}" 2>/dev/null; then
    wa__r_suite "canary-marker"
    WA_EXTRA="writer=${writer} bytes_added=$((a_size - b_size))"
    return 0
  fi
  WA_LAST_TS=""
  tsre="$(wa__alpha_ts_re "$alpha")" || tsre=""
  if [[ -z "$tsre" ]]; then
    wa__r_suite "alphabet-violation"
    WA_EXTRA="writer=${writer}"
    return 0
  fi
  while IFS= read -r line; do
    records=$((records + 1))
    if ! printf '%s\n' "$line" | LC_ALL=C grep -qE "$alpha" 2>/dev/null; then
      # 逐行判定，无块级容错：套件写入不得被同块生产写入掩蔽
      wa__r_suite "alphabet-violation"
      WA_EXTRA="writer=${writer} bytes_added=$((a_size - b_size)) records=${records}"
      return 0
    fi
    ts="$(printf '%s\n' "$line" | LC_ALL=C grep -oE "$tsre" 2>/dev/null | head -n 1)"
    k="$(wa__ts_key "$ts")" || continue
    if [[ "$k" -ge "$lo_key" && "$k" -le "$hi_key" ]]; then
      WA_LAST_TS="$ts"
    fi
  done <<< "$block"
  if [[ -z "$WA_LAST_TS" ]]; then
    wa__r_suite "timestamp-out-of-window"
    WA_EXTRA="writer=${writer} bytes_added=$((a_size - b_size)) records=${records}"
    return 0
  fi
  wa__r_external "registered-append-ok"
  WA_EXTRA="writer=${writer} bytes_added=$((a_size - b_size)) records=${records} ts=${WA_LAST_TS}"
  return 0
}

# wa__line_field <快照行> <列号 1..5> → stdout=字段值（缺列=空）
wa__line_field() {
  local x="${1:-}" col="${2:-}" i=1
  while [[ "$i" -lt "$col" ]]; do
    case "$x" in
      *$'\t'*) x="${x#*$'\t'}" ;;
      *) x=""; break ;;
    esac
    i=$((i + 1))
  done
  case "$x" in
    *$'\t'*) x="${x%%$'\t'*}" ;;
  esac
  printf '%s' "$x"
}

# wa_classify <repo_root> <before_snap> <after_snap> <registry> <out> <t0> <t1>
#   → 0=归类完成（判据结果由调用方据计数断言）；2=依赖/输入缺失、清单非法、窗口非法、恒等式失配
#   <out>：逐变更文件一行 WA-CLASS；<out>.diff：全量原始 diff（差异一条都不隐藏）
#   stdout 末行：WA total=<n> external=<n> suite=<n> outside=<n> unclassified=<n> diff_lines=<n>
wa_classify() {
  local repo_root="${1:-}" before="${2:-}" after="${3:-}" reg="${4:-}" out="${5:-}" t0="${6:-}" t1="${7:-}"
  if [[ -z "$repo_root" || -z "$before" || -z "$after" || -z "$reg" || -z "$out" || -z "$t0" || -z "$t1" ]]; then
    wa__fail "wa_classify 参数缺失"
    return 2
  fi
  [[ -x "$WA_DEP_DIFF" ]] || { wa__fail "依赖缺失: $WA_DEP_DIFF 不可执行"; return 2; }
  [[ -s "$before" ]] || { wa__fail "before 快照缺失或为空: $before"; return 2; }
  [[ -s "$after" ]] || { wa__fail "after 快照缺失或为空: $after"; return 2; }
  case "$t0" in ''|*[!0-9]*) wa__fail "窗口起非整数: $t0"; return 2 ;; esac
  case "$t1" in ''|*[!0-9]*) wa__fail "窗口止非整数: $t1"; return 2 ;; esac
  if [[ "$t1" -lt "$t0" ]]; then
    wa__fail "窗口止 < 窗口起: $t0 $t1"
    return 2
  fi
  wa__registry_load "$reg" || return 2

  # 原始 diff 全量落盘（先落盘再判读：证据先于结论）
  local drc=0
  "$WA_DEP_DIFF" "$before" "$after" > "$out.diff" 2>&1 || drc=$?
  case "$drc" in
    0|1) : ;;
    *) wa__fail "diff 故障 rc=${drc}"; return 2 ;;
  esac
  local diff_lines=""
  diff_lines="$(wc -l < "$out.diff" | tr -d ' ')"

  # 变更集：按路径 join 前后快照（kind ∈ C=新建 / D=删除 / M=改写）
  local changed="${out}.changed.$$"
  awk -F'\t' 'BEGIN { OFS = "\037" }
    NR == FNR { b[$5] = $0; next }
    { a[$5] = $0 }
    END {
      for (p in b) { if (!(p in a)) print "D", p, b[p], "" }
      for (p in a) {
        if (!(p in b)) print "C", p, "", a[p]
        else if (a[p] != b[p]) print "M", p, b[p], a[p]
      }
    }' "$before" "$after" | sort > "$changed"

  WA_C_TOTAL=0; WA_C_EXTERNAL=0; WA_C_SUITE=0; WA_C_OUTSIDE=0
  : > "$out"
  local lo_key="" hi_key=""
  lo_key="$(date -r $((t0 - WA_WINDOW_SLACK)) +%Y%m%d%H%M%S)" || { rm -f "$changed"; wa__fail "date -r 失败"; return 2; }
  hi_key="$(date -r $((t1 + WA_WINDOW_SLACK)) +%Y%m%d%H%M%S)" || { rm -f "$changed"; wa__fail "date -r 失败"; return 2; }

  local kind="" path="" bline="" aline=""
  while IFS=$'\037' read -r kind path bline aline; do
    [[ -n "$path" ]] || continue
    WA_LAST_TS=""
    WA_CORR_TS=""
    WA_CORR_DT=""
    wa__classify_one "$repo_root" "$path" "$kind" "$bline" "$aline" "$lo_key" "$hi_key" "${after}.dirs"
    wa__emit "$out" "$path"
  done < "$changed"
  rm -f "$changed"

  # 恒等式（DbC）：total == external + suite + outside + unclassified ∧ unclassified == 0
  #              diff_lines == 0 ⇒ total == 0
  local unclassified=$((WA_C_TOTAL - WA_C_EXTERNAL - WA_C_SUITE - WA_C_OUTSIDE))
  if [[ "$unclassified" -ne 0 ]]; then
    wa__fail "归属计数恒等式失配: total=${WA_C_TOTAL} external=${WA_C_EXTERNAL} suite=${WA_C_SUITE} outside=${WA_C_OUTSIDE}"
    return 2
  fi
  if [[ "$diff_lines" -eq 0 && "$WA_C_TOTAL" -ne 0 ]]; then
    wa__fail "零 diff 却出现变更项（total=${WA_C_TOTAL}）"
    return 2
  fi
  printf 'WA total=%d external=%d suite=%d outside=%d unclassified=%d diff_lines=%d\n' \
    "$WA_C_TOTAL" "$WA_C_EXTERNAL" "$WA_C_SUITE" "$WA_C_OUTSIDE" "$unclassified" "$diff_lines"
  return 0
}

# =============================================================================
# 4. 注入器（唯一可写生产树的入口；显式 opt-in，每次注入必落 WA-INJECT 行）
# =============================================================================

# wa__first_idx <mode> → stdout=首个该 mode 条目下标；rc 1=无
wa__first_idx() {
  local want="$1" i=0
  for ((i = 0; i < WA_R_N; i++)); do
    if [[ "${WA_R_MODE[$i]}" == "$want" ]]; then
      printf '%s' "$i"
      return 0
    fi
  done
  return 1
}

# wa_inject <mode> <repo_root> <registry> [<arg4> [<arg5>]] → 0；2=未知 mode / 清单无可用目标 / 注入物自证失败
#   stdout=**恰 1 行** WA-INJECT 证据行（可 grep、可追责；调用方按单行 sed 解析 path=，多行会致清理面失效）
#   两段式删除对照（「窗口内创建 + 窗口内删除」在前后快照里双双不可见 ⇒ 必须拆成两段）：
#     delete-plant <repo> <reg> <canary|external>           → 快照**之前**植入探针文件
#     delete-fire  <repo> <reg> <path> <canary|external>    → 窗口**之内**真删（external 变体另落佐证记录）
wa_inject() {
  local mode="${1:-}" repo_root="${2:-}" reg="${3:-}" a4="${4:-}" a5="${5:-}"
  if [[ -z "$mode" || -z "$repo_root" || -z "$reg" ]]; then
    wa__fail "wa_inject 参数缺失"
    return 2
  fi
  wa__registry_load "$reg" || return 2
  local i="" p="" f="" line="" tsre="" now="" epoch="" clog="" clf=""
  now="$(date '+%Y-%m-%d %H:%M:%S')"
  epoch="$(date +%s)"
  case "$mode" in
    canary-create)
      i="$(wa__first_idx corroborated-create)" || { wa__fail "清单无 corroborated-create 目标"; return 2; }
      p="${WA_R_PAT[$i]}"
      p="${p%/\*}"
      p="${p}/${WA_MARKER_PREFIX}canary-create-${epoch}-$$.json"
      mkdir -p "$repo_root/${p%/*}" || { wa__fail "注入目录不可建: $repo_root/${p%/*}"; return 2; }
      f="$repo_root/$p"
      printf '%smode=canary-create epoch=%s pid=%s\n' "$WA_MARKER_PREFIX" "$epoch" "$$" > "$f" \
        || { wa__fail "注入写入失败: $p"; return 2; }
      printf 'WA-INJECT mode=canary-create path=%s bytes=%s writer=%s\n' \
        "$p" "$(wc -c < "$f" | tr -d ' ')" "${WA_R_WRITER[$i]}"
      return 0
      ;;
    canary-append|external-append)
      i="$(wa__first_idx append-records)" || { wa__fail "清单无 append-records 目标"; return 2; }
      p="${WA_R_PAT[$i]}"
      f="$repo_root/$p"
      [[ -f "$f" ]] || { wa__fail "注入目标不存在: $p"; return 2; }
      tsre="$(wa__alpha_ts_re "${WA_R_ALPHA[$i]}")" || tsre=""
      if [[ "$mode" == "canary-append" ]]; then
        line="${WA_MARKER_PREFIX}APPEND epoch=${epoch} mode=canary-append（字母表外，必须判红）"
      else
        line="[${now}] ${WA_R_WRITER[$i]}: ${WA_MARKER_PREFIX}external-append epoch=${epoch}（与写手 log() 逐字同构）"
      fi
      # 注入物自证：canary 必须落字母表外、external 必须落字母表内且时间戳可解析（否则 fail-closed）
      if printf '%s\n' "$line" | LC_ALL=C grep -qE "${WA_R_ALPHA[$i]}" 2>/dev/null; then
        if [[ "$mode" == "canary-append" ]]; then
          wa__fail "canary-append 注入行意外落在字母表内（金丝雀无效）"
          return 2
        fi
        if [[ "$mode" == "external-append" ]]; then
          [[ -n "$tsre" ]] || { wa__fail "external-append 无可解析时间戳捕获组"; return 2; }
          wa__ts_key "$now" >/dev/null || { wa__fail "external-append 时间戳键不可构造"; return 2; }
        fi
      else
        if [[ "$mode" == "external-append" ]]; then
          wa__fail "external-append 注入行未落字母表内（形态不同构）"
          return 2
        fi
      fi
      printf '%s\n' "$line" >> "$f" || { wa__fail "注入追加失败: $p"; return 2; }
      printf 'WA-INJECT mode=%s path=%s line=%s\n' "$mode" "$p" "$line"
      return 0
      ;;
    delete-plant)
      # 取首个 corroborated-delete 行（删除面显式 opt-in；无 ⇒ fail-closed）
      case "${a4}" in
        canary|external) : ;;
        *) wa__fail "delete-plant variant 不在闭集 {canary,external}: ${a4:-<空>}"; return 2 ;;
      esac
      i="$(wa__first_idx corroborated-delete)" || { wa__fail "清单无 corroborated-delete 目标"; return 2; }
      p="${WA_R_PAT[$i]}"
      p="${p%/\*}"
      if [[ "$a4" == "canary" ]]; then
        p="${p}/${WA_MARKER_PREFIX}delete-${epoch}-$$.json"
      else
        p="${p}/probe-delete-${epoch}-$$.json"
      fi
      mkdir -p "$repo_root/${p%/*}" || { wa__fail "注入目录不可建: $repo_root/${p%/*}"; return 2; }
      f="$repo_root/$p"
      if [[ "$a4" == "canary" ]]; then
        printf '%smode=delete-plant variant=canary epoch=%s pid=%s\n' "$WA_MARKER_PREFIX" "$epoch" "$$" > "$f" \
          || { wa__fail "注入写入失败: $p"; return 2; }
      else
        printf 'probe variant=external epoch=%s pid=%s\n' "$epoch" "$$" > "$f" \
          || { wa__fail "注入写入失败: $p"; return 2; }
      fi
      # 注入物自证（fail-closed）：文件必须存在且非空；canary 变体首行必须命中路径短路前缀语义
      [[ -s "$f" ]] || { wa__fail "delete-plant 注入物不存在或为空: $p"; return 2; }
      if [[ "$a4" == "canary" ]]; then
        case "$(head -n 1 "$f" 2>/dev/null)" in
          "${WA_MARKER_PREFIX}"*) : ;;
          *) wa__fail "delete-plant canary 注入物首行无 marker 前缀（短路不可达）: $p"; return 2 ;;
        esac
      fi
      printf 'WA-INJECT mode=delete-plant path=%s variant=%s writer=%s\n' "$p" "$a4" "${WA_R_WRITER[$i]}"
      return 0
      ;;
    delete-fire)
      case "${a5}" in
        canary|external) : ;;
        *) wa__fail "delete-fire variant 不在闭集 {canary,external}: ${a5:-<空>}"; return 2 ;;
      esac
      [[ -n "$a4" ]] || { wa__fail "delete-fire 缺 <path> 参数"; return 2; }
      i="$(wa__first_idx corroborated-delete)" || { wa__fail "清单无 corroborated-delete 目标"; return 2; }
      f="$repo_root/$a4"
      [[ -f "$f" ]] || { wa__fail "delete-fire 目标不存在: $a4"; return 2; }
      # 注入物自证：只允许删本引擎植入的探针（前缀具名）且路径须落在删除面内 —— 防止注入器被误用去删生产文件
      case "${a4##*/}" in
        "${WA_MARKER_PREFIX}"delete-*|probe-delete-*) : ;;
        *) wa__fail "delete-fire 目标非本引擎植入物（basename 须以 ${WA_MARKER_PREFIX}delete- 或 probe-delete- 开头）: $a4"; return 2 ;;
      esac
      # shellcheck disable=SC2254
      case "$a4" in
        ${WA_R_PAT[$i]}) : ;;
        *) wa__fail "delete-fire 目标不落在删除面模式内: $a4"; return 2 ;;
      esac
      if [[ "$a5" == "external" ]]; then
        # 佐证记录：与写手 log() 逐字同构（**非行首** marker ⇒ 不触发 canary-marker 短路），再真删
        clog="${WA_R_CORR[$i]%%|*}"
        [[ -n "$clog" && "$clog" != ":none" ]] || { wa__fail "corroborated-delete 行佐证路径不可用: ${WA_R_CORR[$i]}"; return 2; }
        clf="$repo_root/$clog"
        [[ -f "$clf" ]] || { wa__fail "佐证日志不存在: $clog"; return 2; }
        printf '[%s] %s: %sdelete-fire epoch=%s pid=%s（与写手 log() 逐字同构）\n' \
          "$now" "${WA_R_WRITER[$i]}" "$WA_MARKER_PREFIX" "$epoch" "$$" >> "$clf" \
          || { wa__fail "佐证记录追加失败: $clog"; return 2; }
      fi
      rm -f "$f" || { wa__fail "delete-fire 删除失败: $a4"; return 2; }
      [[ ! -e "$f" ]] || { wa__fail "delete-fire 自证失败（目标删除后仍存在）: $a4"; return 2; }
      printf 'WA-INJECT mode=delete-fire path=%s variant=%s ts=%s\n' "$a4" "$a5" "$now"
      return 0
      ;;
    *)
      wa__fail "未知注入 mode: ${mode}（闭集 canary-create|canary-append|external-append|delete-plant|delete-fire）"
      return 2
      ;;
  esac
}

# =============================================================================
# 5. 弹性等待（等真实生产写手落笔；不新增任何写面）
# =============================================================================

# wa_wait_external <repo_root> <before_snap> <max_sec> [poll_sec] → 0=观察到变更 1=超时未变更 2=参数非法
wa_wait_external() {
  local repo_root="${1:-}" before="${2:-}" max_sec="${3:-}" poll_sec="${4:-10}"
  case "$max_sec" in ''|*[!0-9]*) wa__fail "max_sec 非整数: ${max_sec}"; return 2 ;; esac
  case "$poll_sec" in ''|*[!0-9]*) wa__fail "poll_sec 非整数: ${poll_sec}"; return 2 ;; esac
  [[ "$poll_sec" -ge 1 ]] || { wa__fail "poll_sec 必须 >=1"; return 2; }
  [[ -s "$before" ]] || { wa__fail "before 快照缺失或为空: $before"; return 2; }
  local cur="${before}.wait.$$" waited=0 polls=0 n=0
  local cur_dirs="${cur}.dirs" cur_dtmp="${cur}.dirs.tmp.$$"
  while [[ "$waited" -le "$max_sec" ]]; do
    wa_snapshot "$repo_root" "$cur" || { rm -f "$cur" "$cur_dirs" "$cur_dtmp"; return 2; }
    polls=$((polls + 1))
    n="$("$WA_DEP_DIFF" "$before" "$cur" 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$n" -gt 0 ]]; then
      printf 'WA-WAIT mode=wait-external polls=%s waited=%s changed=1 diff_lines=%s\n' "$polls" "$waited" "$n"
      rm -f "$cur" "$cur_dirs" "$cur_dtmp"
      return 0
    fi
    if [[ "$waited" -ge "$max_sec" ]]; then
      break
    fi
    sleep "$poll_sec"
    waited=$((waited + poll_sec))
  done
  printf 'WA-WAIT mode=wait-external polls=%s waited=%s changed=0 diff_lines=0\n' "$polls" "$waited"
  rm -f "$cur" "$cur_dirs" "$cur_dtmp"
  return 1
}

# =============================================================================
# 6. 全形态自证（合成树；不触碰真实 contrib-data）
# =============================================================================
# wa_selftest <tmpdir> → 0=全部形态与预期一致；1=存在不符（明细逐行 stdout）
wa_selftest() {
  local tmp="${1:-}"
  if [[ -z "$tmp" || ! -d "$tmp" ]]; then
    printf 'WA-SELFTEST FAIL: 需要存在的 tmpdir 参数（实得 [%s]）\n' "${tmp:-<空>}"
    return 1
  fi
  local sb="" root="" reg="" art=""
  sb="$tmp/wa-selftest-$$"
  root="$sb/repo"
  reg="$sb/registry.tsv"
  art="$sb/art"
  rm -rf "$sb"
  mkdir -p "$root/contrib-data/logs" "$root/contrib-data/pending" "$root/contrib-data/scratch" "$art" || {
    printf 'WA-SELFTEST FAIL: 合成树建立失败: %s\n' "$sb"
    return 1
  }
  local ALPHA_C='^\[([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})\] collect: |^OK$'
  local ALPHA_N='^\[([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})\] notify: |^OK$'
  {
    printf 'contrib-data/logs/collect.log\tcollect\tappend-records\t%s\t:none\n' "$ALPHA_C"
    printf 'contrib-data/logs/notify.log\tnotify\tappend-records\t%s\t:none\n' "$ALPHA_N"
    printf 'contrib-data/logs/execute.log\texecute\tappend-records\t%s\t:none\n' "$ALPHA_C"
    printf 'contrib-data/state.json\tnotify\tcorroborated-rewrite\t:none\tcontrib-data/logs/notify.log\n'
    printf 'contrib-data/pending/*\tnotify\tcorroborated-create\t:none\tcontrib-data/logs/notify.log\n'
    printf 'contrib-data/pending/*\tnotify\tcorroborated-delete\t:none\tcontrib-data/logs/notify.log\n'
  } > "$reg"
  : > "$root/contrib-data/logs/collect.log"
  : > "$root/contrib-data/logs/notify.log"
  printf '{"state":"seed"}\n' > "$root/contrib-data/state.json"
  printf 'seed\n' > "$root/contrib-data/scratch/note.md"

  local fails=0 step=0 now="" t0="" t1="" in_ts="" far_ts=""
  now="$(date +%s)"; t0=$((now - 1)); t1=$((now + 1))
  in_ts="$(date -r "$now" +'%Y-%m-%d %H:%M:%S')"
  far_ts="$(date -r $((t1 + WA_WINDOW_SLACK + 1)) +'%Y-%m-%d %H:%M:%S')"

  # wa__st_snap <名>：快照到 $art/<名>
  wa__st_snap() { wa_snapshot "$root" "$art/$1"; }

  # wa__st_case <名> <期望类> <期望 reason> [期望条数]：对 $art/before vs $art/after 判归属并校验
  wa__st_case() {
    local name="$1" want_cls="$2" want_reason="$3" want_n="${4:-1}"
    local out="" summary="" cls="" reason="" got_n="" wanted_exact="" bad=0
    step=$((step + 1))
    out="$art/step${step}.out"
    summary="$(wa_classify "$root" "$art/before" "$art/after" "$reg" "$out" "$t0" "$t1")" || {
      printf 'WA-SELFTEST FAIL case=%s：wa_classify 非零退出\n' "$name"
      fails=$((fails + 1))
      return 0
    }
    got_n="$(wc -l < "$out" | tr -d ' ')"
    printf '%s\n' "$summary" > "$art/step${step}.summary"
    if [[ "$got_n" != "$want_n" ]]; then
      printf 'WA-SELFTEST FAIL case=%s：变更条数 %s != 期望 %s\n' "$name" "$got_n" "$want_n"
      fails=$((fails + 1))
      bad=1
    fi
    cls="$(grep -m1 '^WA-CLASS ' "$out" | sed -n 's/^WA-CLASS \([^ ]*\) .*/\1/p')"
    reason="$(grep -m1 '^WA-CLASS ' "$out" | sed -n 's/.* reason=\([^ ]*\).*/\1/p')"
    if [[ "$cls" != "$want_cls" || "$reason" != "$want_reason" ]]; then
      printf 'WA-SELFTEST FAIL case=%s：实得 [%s/%s] 期望 [%s/%s]\n' "$name" "$cls" "$reason" "$want_cls" "$want_reason"
      fails=$((fails + 1))
      bad=1
    fi
    case "$summary" in
      "WA total="*) : ;;
      *) printf 'WA-SELFTEST FAIL case=%s：末行计数形态异常 [%s]\n' "$name" "$summary"; fails=$((fails + 1)); bad=1 ;;
    esac
    case "$summary" in
      *" unclassified=0 "*) : ;;
      *) printf 'WA-SELFTEST FAIL case=%s：unclassified != 0 [%s]\n' "$name" "$summary"; fails=$((fails + 1)); bad=1 ;;
    esac
    wanted_exact=""
    [[ "$bad" -eq 0 ]] && printf 'WA-SELFTEST ok case=%s class=%s reason=%s\n' "$name" "$cls" "$reason"
    : "${wanted_exact}"
    return 0
  }
  # 断言某 case 的末行计数键值（防「类对了但计数键名漂移 / 恒等式失配」）
  wa__st_count() {
    local name="$1" key="$2" want="$3" exp=""
    exp="$(sed -n "s/^WA .* ${key}=\([0-9-]*\).*/\1/p" "$art/step${step}.summary" 2>/dev/null | head -n 1)"
    if [[ "$exp" == "$want" ]]; then
      printf 'WA-SELFTEST ok count case=%s %s=%s\n' "$name" "$key" "$want"
    else
      printf 'WA-SELFTEST FAIL count case=%s：%s=%s 期望 %s\n' "$name" "$key" "$exp" "$want"
      fails=$((fails + 1))
    fi
  }

  # --- 1 无变更 ---
  wa__st_snap before || { printf 'WA-SELFTEST FAIL 快照失败\n'; return 1; }
  wa__st_snap after || { printf 'WA-SELFTEST FAIL 快照失败\n'; return 1; }
  step=$((step + 1))
  local s1="" s1out="$art/step${step}.out"
  s1="$(wa_classify "$root" "$art/before" "$art/after" "$reg" "$s1out" "$t0" "$t1")" || {
    printf 'WA-SELFTEST FAIL case=no-change：wa_classify 非零退出\n'; fails=$((fails + 1))
  }
  case "$s1" in
    *"total=0 external=0 suite=0 outside=0 unclassified=0 diff_lines=0"*) printf 'WA-SELFTEST ok case=no-change\n' ;;
    *) printf 'WA-SELFTEST FAIL case=no-change：实得 [%s]\n' "$s1"; fails=$((fails + 1)) ;;
  esac

  # --- 2 合规追加（在窗）⇒ external/registered-append-ok ---
  wa__st_snap before
  printf '[%s] collect: 合规追加\n' "$in_ts" >> "$root/contrib-data/logs/collect.log"
  wa__st_snap after
  wa__st_case append-ok external registered-append-ok

  # --- 3 时间戳出窗（窗口止 +121s）⇒ suite/timestamp-out-of-window ---
  wa__st_snap before
  printf '[%s] collect: 出窗追加\n' "$far_ts" >> "$root/contrib-data/logs/collect.log"
  wa__st_snap after
  wa__st_case append-out-of-window suite timestamp-out-of-window

  # --- 4 边界同窗（恰等于窗口止 +120s）⇒ external ---
  local hi_ts=""
  hi_ts="$(date -r $((t1 + WA_WINDOW_SLACK)) +'%Y-%m-%d %H:%M:%S')"
  wa__st_snap before
  printf '[%s] collect: 边界追加\n' "$hi_ts" >> "$root/contrib-data/logs/collect.log"
  wa__st_snap after
  wa__st_case append-boundary external registered-append-ok

  # --- 5 字母表外（非 marker 前缀的套件泄漏）⇒ suite/alphabet-violation ---
  wa__st_snap before
  printf 'SUITE-LEAK-APPEND epoch=0\n' >> "$root/contrib-data/logs/collect.log"
  wa__st_snap after
  wa__st_case append-leak suite alphabet-violation

  # --- 6 混合块（合规 + 泄漏同块）⇒ suite/alphabet-violation（无块级容错）---
  wa__st_snap before
  { printf '[%s] collect: 合规行\n' "$in_ts"; printf 'SUITE-LEAK-MIXED epoch=0\n'; } >> "$root/contrib-data/logs/collect.log"
  wa__st_snap after
  wa__st_case append-mixed-block suite alphabet-violation

  # --- 7 注入 marker 短路（`S4-P1-` 前缀行）⇒ suite/canary-marker（先于形态判定）---
  wa__st_snap before
  printf '%sAPPEND epoch=0 marker 短路\n' "$WA_MARKER_PREFIX" >> "$root/contrib-data/logs/collect.log"
  wa__st_snap after
  wa__st_case append-marker-suite suite canary-marker

  # --- 8 空追加（仅换行）⇒ suite/empty-append ---
  wa__st_snap before
  printf '\n' >> "$root/contrib-data/logs/collect.log"
  wa__st_snap after
  wa__st_case append-empty suite empty-append

  # --- 9 原地重写（同 inode，前缀不匹配）⇒ suite/not-append-only ---
  wa__st_snap before
  printf '[%s] collect: 重写\n' "$in_ts" > "$root/contrib-data/logs/collect.log"
  wa__st_snap after
  wa__st_case rewrite-inplace suite not-append-only

  # --- 10 mv 替换式重写（inode 变更；append-records 追加语义反例）⇒ suite/inode-changed ---
  wa__st_snap before
  printf '[%s] collect: mv 整替\n' "$in_ts" > "$root/contrib-data/logs/collect.log.tmp"
  mv "$root/contrib-data/logs/collect.log.tmp" "$root/contrib-data/logs/collect.log"
  wa__st_snap after
  wa__st_case rewrite-inode suite inode-changed

  # --- 11 append-records 面内新建（execute.log 首建）⇒ suite/created-unallowed ---
  wa__st_snap before
  printf '[%s] execute: 首建\n' "$in_ts" > "$root/contrib-data/logs/execute.log"
  wa__st_snap after
  wa__st_case created-unallowed suite created-unallowed

  # --- 12 面内删除 ⇒ suite/deleted ---
  wa__st_snap before
  rm -f "$root/contrib-data/state.json"
  wa__st_snap after
  wa__st_case deleted suite deleted
  wa__st_count deleted suite 1

  # --- 13 corroborated-create 无佐证 ⇒ suite/no-corroboration ---
  wa__st_snap before
  printf '{"pending":1}\n' > "$root/contrib-data/pending/x.json"
  wa__st_snap after
  wa__st_case create-no-corroboration suite no-corroboration

  # --- 14 佐证日志在窗且近邻落笔后新建 ⇒ external/corroborated-ok ---
  printf '[%s] notify: 佐证落笔（近邻）\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$root/contrib-data/logs/notify.log"
  wa__st_snap before
  printf '{"pending":2}\n' > "$root/contrib-data/pending/y.json"
  wa__st_snap after
  wa__st_case create-corroborated external corroborated-ok

  # --- 15 corroborated-rewrite 且有近邻佐证（原地重写：重写类无 inode 断言）⇒ external/corroborated-ok ---
  wa__st_snap before
  printf '{"state":"rewritten-inplace"}\n' > "$root/contrib-data/state.json"
  wa__st_snap after
  wa__st_case rewrite-corroborated external corroborated-ok

  # --- 16 佐证记录在窗但远离 mtime（>30s）⇒ suite/no-corroboration（时序近邻主修自证）---
  #     先写一条「窗口内但时间戳远大于当前时刻」的记录：其 key 落在窗口内、却与 mtime 相距 >30s
  far_ts="$(date -r $((now + 90)) +'%Y-%m-%d %H:%M:%S')"
  printf '[%s] notify: 远邻佐证\n' "$far_ts" >> "$root/contrib-data/logs/notify.log"
  #     把「近邻」记录挪出窗口（改写 notify.log 为仅含远邻记录 + 窗口外记录），确保只剩远邻在窗记录
  : > "$root/contrib-data/logs/notify.log"
  printf '[%s] notify: 远邻佐证（在窗但 >30s）\n' "$far_ts" >> "$root/contrib-data/logs/notify.log"
  wa__st_snap before
  printf '{"pending":3}\n' > "$root/contrib-data/pending/z.json"
  wa__st_snap after
  wa__st_case create-far-corroboration suite no-corroboration

  # --- 17 注入 marker 短路（corroborated-create 路径 + 有近邻佐证）⇒ 仍判 suite/canary-marker ---
  printf '[%s] notify: 佐证落笔（近邻）\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$root/contrib-data/logs/notify.log"
  wa__st_snap before
  printf '%smode=canary-create epoch=0\n' "$WA_MARKER_PREFIX" > "$root/contrib-data/pending/canary.json"
  wa__st_snap after
  wa__st_case create-canary-marker suite canary-marker

  # --- 18 判据面外路径变更 ⇒ outside-surface ---
  wa__st_snap before
  printf 'outside change\n' > "$root/contrib-data/scratch/note.md"
  wa__st_snap after
  wa__st_case outside-surface outside-surface outside-surface
  wa__st_count outside-surface outside 1

  # --- 20 删除面内路径被删 + 父目录锚近邻佐证 ⇒ external/corroborated-delete-ok ---
  printf '{"d":1}\n' > "$root/contrib-data/pending/del-ok.json"
  printf '[%s] notify: 删除类佐证落笔（消费清理）\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$root/contrib-data/logs/notify.log"
  wa__st_snap before
  rm -f "$root/contrib-data/pending/del-ok.json"
  wa__st_snap after
  wa__st_case delete-corroborated external corroborated-delete-ok

  # --- 21 删除面内路径被删但佐证缺席（清空佐证日志）⇒ suite/no-delete-corroboration ---
  : > "$root/contrib-data/logs/notify.log"
  printf '{"d":2}\n' > "$root/contrib-data/pending/del-nocorr.json"
  wa__st_snap before
  rm -f "$root/contrib-data/pending/del-nocorr.json"
  wa__st_snap after
  wa__st_case delete-no-corroboration suite no-delete-corroboration

  # --- 22 删除类 marker 路径短路（先于清单匹配，面内面外同）⇒ suite/canary-marker ---
  printf '%smode=delete-plant\n' "$WA_MARKER_PREFIX" > "$root/contrib-data/pending/${WA_MARKER_PREFIX}delete-x.json"
  wa__st_snap before
  rm -f "$root/contrib-data/pending/${WA_MARKER_PREFIX}delete-x.json"
  wa__st_snap after
  wa__st_case delete-canary-marker suite canary-marker

  # --- 23 清单 fail-closed：空清单 ⇒ exit 2（禁空集静默绿）---
  local emptyreg="$sb/empty.tsv"
  : > "$emptyreg"
  if wa_classify "$root" "$art/before" "$art/after" "$emptyreg" "$art/empty.out" "$t0" "$t1" 2>/dev/null; then
    printf 'WA-SELFTEST FAIL case=empty-registry：空清单竟返回 0（禁空集静默绿）\n'
    fails=$((fails + 1))
  else
    printf 'WA-SELFTEST ok case=empty-registry（fail-closed）\n'
  fi

  if [[ "$fails" -eq 0 ]]; then
    printf 'WA-SELFTEST PASS（22 形态全部与预期一致）\n'
    return 0
  fi
  printf 'WA-SELFTEST FAIL（%d 项不符）\n' "$fails"
  return 1
}
