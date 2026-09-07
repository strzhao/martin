#!/bin/bash
# rq.sh — ready-queue + 深检预算唯一 CLI（contrib-watch 快车道）
#
# ready-queue.json / budget.json 的所有写操作必须经本脚本（目录锁防并发）。
# 设计要点：
#   - 状态机迁移合法性强制（validate/set 双查）
#   - secret 正则拦截（任何字段命中 ghp_/github_pat_/sk-/私钥块 → 拒绝写入）
#   - 同 issue 同时只允许一条活项（去重合并原则）
#   - budget reserve 在 deep-check 启动前占用（防并发超发），失败按旋钮决定是否返还
#
# 用法:
#   rq.sh init
#   rq.sh add --issue N --disposition D --score S [--pr N] [--title T] [--source scan|radar|manual]
#             [--lane deep|probe] [--age-hours H] [--premises-json '...'] [--ammo-json '...'] [--drill] [--note N]
#   rq.sh set <id> <state> [--note N]
#   rq.sh amend <id> [--disposition D] [--pr N] [--note N]  # 深检重裁决等场景修正非状态字段（白名单字段 + 全程留痕）
#   rq.sh next --lane deep|probe          # 输出 priority 最高且 state=queued 的 id（无则输出空行，exit 0——契约固化，调用方依赖输出而非 exit code）
#   rq.sh list [--state S] [--oneline]
#   rq.sh show <id> [--json]
#   rq.sh tunnel-deploy <id> <url> <slug> [code]  # notify.sh 部署审批页后登记（code=短码，可空=旧调用方）
#   rq.sh tunnel-removed <id>
#   rq.sh set-draft <id> <path>
#   rq.sh retry-failed
#   rq.sh sweep                           # 48h 搁置/过期 + tunnel 超期审计
#   rq.sh budget reserve <id> --lane deep|probe | budget refund <id> --lane ... | budget status
#   rq.sh validate
set -euo pipefail

MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"
CONTRIB="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"
QUEUE="$CONTRIB/ready-queue.json"
BUDGET="$CONTRIB/budget.json"
CONFIG="$CONTRIB/config.json"
LOCKDIR="${RQ_LOCKDIR:-/tmp/contrib-rq.lock}"
# 命令 seam（默认值=现状硬编码；测试套件经此注入影子 stub，生产语义零改变）
TUNNEL_BIN="${TUNNEL_BIN:-tunnel}"

# 不用 jq 的 // 运算符：它把 JSON false 当 falsy（同 notify_dry_run:false 事故的同构缺陷）——
# 只把 null/缺失当缺省，false 是合法配置值；文件缺失也回 default（与 notify.sh cfg 同一语义）。
# `|| true` 必须留在替换内：本脚本 set -e，jq 打不开文件的非零码会经赋值语句杀死脚本
cfg() {
  local v
  v="$(jq -r "$1" "$CONFIG" 2>/dev/null || true)"
  if [[ -n "$v" && "$v" != "null" ]]; then
    echo "$v"
    return 0
  fi
  echo "$2"
}
now_iso() { date "+%Y-%m-%dT%H:%M:%S%z"; }
now_epoch() { date +%s; }
week_key() { date "+%G-W%V"; }

SECRET_RE='ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'

die() { echo "rq.sh: $*" >&2; exit 2; }

# --- 并发锁（写操作用） ---
acquire_lock() {
  local i=0
  until mkdir "$LOCKDIR" 2>/dev/null; do
    i=$((i+1)); [[ $i -gt 60 ]] && die "锁等待超时（/tmp/contrib-rq.lock 残留？手工检查）"
    sleep 1
  done
  trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT
}

ensure_files() {
  mkdir -p "$CONTRIB/pending" "$CONTRIB/runs/deep-check"
  [[ -f "$QUEUE" ]] || echo '{"version":1,"updated":"","items":[]}' > "$QUEUE"
  [[ -f "$BUDGET" ]] || jq -n '{limits:{week:3,day:1},days:{},weeks:{},probes:{}}' > "$BUDGET"
}

# --- secret 扫描：对任意 JSON 片段做文本级正则检查 ---
assert_no_secret() {
  if grep -Eq "$SECRET_RE" <<<"$1"; then
    die "secret 模式命中，拒绝写入（ready-queue 禁止携带凭据）"
  fi
}

# --- 状态机 ---
transitions_for() {
  case "$1" in
    queued)             echo "deep-check awaiting-approval expired shelved rejected failed" ;;
    # deep-check 的 expired 出口：深检期 TTL 复验可能发现 premise 死亡（如 issue 被 farm PR
    # 占坑，rq-20260906-104260 首例 09-07）——failed 会被次日 gate 自动重试，premise 死亡必须直达终态
    deep-check)         echo "awaiting-approval failed queued expired" ;;
    awaiting-approval)  echo "approved revise expired shelved rejected failed" ;;
    # approved 的 rejected/revise 出口：L2-A 短码路消费标记先行（collect 先 set approved 再按
    # verdict 落 rejected/revise，见 scripts/approval/collect.sh）——消费即占位，verdict 是第二跳
    approved)           echo "executed failed rejected revise" ;;
    revise)             echo "queued rejected expired" ;;
    failed)             echo "queued expired shelved rejected" ;;
    shelved)            echo "queued rejected expired" ;;
    expired|rejected|executed) echo "" ;;
    *) die "未知状态: $1" ;;
  esac
}

assert_transition() {
  local from="$1" to="$2"
  [[ "$from" == "$to" ]] && die "空迁移 $from"
  local allowed; allowed="$(transitions_for "$from")"
  [[ " $allowed " == *" $to "* ]] || die "非法迁移 $from → $to"
}

calc_priority() {
  # priority = score*6 + freshness(<6h=12/<24h=6/其余0) + lane_bonus(own-PR+4/review-evidence+2)
  local score="$1" age_hours="$2" disp="$3" fresh=0 bonus=0
  age_hours="${age_hours%%.*}"; [[ "$age_hours" =~ ^[0-9]+$ ]] || age_hours=999  # 浮点取整+非法值兜底
  if (( age_hours < 6 )); then fresh=12; elif (( age_hours < 24 )); then fresh=6; fi
  case "$disp" in
    own-PR) bonus=4 ;;
    review-evidence) bonus=2 ;;
  esac
  echo $(( score * 6 + fresh + bonus ))
}

# ---------------- init ----------------
cmd_init() {
  ensure_files
  echo "ready-queue 与 budget 已就绪"
}

# ---------------- add ----------------
cmd_add() {
  local issue="" disp="" score="" pr="null" title="" source="manual" lane="" age_hours="999"
  local premises_json="[]" ammo_json="[]" drill="" note=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --issue) issue="$2"; shift 2 ;;
      --disposition) disp="$2"; shift 2 ;;
      --score) score="$2"; shift 2 ;;
      --pr) pr="$2"; shift 2 ;;
      --title) title="$2"; shift 2 ;;
      --source) source="$2"; shift 2 ;;
      --lane) lane="$2"; shift 2 ;;
      --age-hours) age_hours="$2"; shift 2 ;;
      --premises-json) premises_json="$2"; shift 2 ;;
      --ammo-json) ammo_json="$2"; shift 2 ;;
      --drill) drill="drill"; shift ;;
      --note) note="$2"; shift 2 ;;
      *) die "add 未知参数: $1" ;;
    esac
  done
  [[ -n "$issue" && -n "$disp" && -n "$score" ]] || die "add 必须 --issue/--disposition/--score"
  case "$disp" in
    own-PR|review-evidence|probe-salvage) ;;
    *) die "disposition 必须是 own-PR|review-evidence|probe-salvage" ;;
  esac
  [[ "$score" =~ ^[0-9]+$ ]] || die "score 必须是整数"
  # lane 缺省规则：probe-salvage→probe；其余→deep
  [[ -z "$lane" ]] && { [[ "$disp" == "probe-salvage" ]] && lane="probe" || lane="deep"; }
  [[ "$lane" == "deep" || "$lane" == "probe" ]] || die "lane 必须是 deep|probe"
  [[ -z "$title" ]] && title="issue #${issue}"

  ensure_files
  acquire_lock

  local id
  id="rq-$(date +%Y%m%d)-${issue}"
  [[ -n "$drill" ]] && id="${id}-drill"

  # 同 id 任何已存在即拒绝（id 含日期，正常流不会重号；重入队属人工操作）
  local same_id
  same_id=$(jq -r --arg id "$id" '[.items[] | select(.id == $id)] | length' "$QUEUE")
  (( same_id > 0 )) && die "$id 已存在（state 见 rq.sh show），不接受重复入队"

  # 同 issue 单活项（不同 id 的活项）
  local dup
  dup=$(jq -r --arg issue "$issue" --arg id "$id" '
    [.items[] | select((.issue|tostring) == $issue and .id != $id
      and (.state as $s | ["queued","deep-check","awaiting-approval","approved"] | index($s) != null))]
    | .[0].id // ""' "$QUEUE")
  [[ -n "$dup" && -z "$drill" ]] && die "issue #$issue 已有活项 ${dup}，先处理再入队"

  # premises 结构校验：每条必须带 claim+evidence；verified_at 缺省补 now；status 缺省 alive
  local premises_ok
  premises_ok=$(jq -e '
    type == "array" and all(.[];
      type == "object" and has("claim") and has("evidence")
      and (.verified_at // "" | length > 0 or true))
  ' <<<"$premises_json" 2>/dev/null) || premises_ok=""
  [[ "$premises_ok" == "true" ]] || die "premises-json 必须是 [{claim,evidence,...}] 数组"
  premises_json=$(jq --arg now "$(now_iso)" 'map(. + {status: (.status // "alive"), verified_at: (.verified_at // $now)})' <<<"$premises_json")

  assert_no_secret "$title|$note|$premises_json|$ammo_json"

  local prio; prio="$(calc_priority "$score" "$age_hours" "$disp")"
  local ts; ts="$(now_iso)"; local ep; ep="$(now_epoch)"

  jq -n --arg id "$id" --argjson issue "$issue" --argjson pr "$pr" \
    --arg title "$title" --arg disp "$disp" --arg lane "$lane" --argjson score "$score" \
    --argjson prio "$prio" --arg source "$source" \
    --argjson premises "$premises_json" --argjson ammo "$ammo_json" \
    --arg ts "$ts" --argjson ep "$ep" --arg note "$note" --arg wk "$(week_key)" \
    '{id: $id, issue: $issue, pr: $pr, title: $title, disposition: $disp, lane: $lane,
      score: $score, priority: $prio, source: $source, state: "queued",
      premises: $premises, ammo: $ammo, draft: null,
      tunnel: {url: null, slug: null, code: null, deployed_at: null, removed_at: null},
      budget: {week: $wk, day: ($ts | .[0:10])},
      queued_at: $ts, queued_epoch: $ep, awaiting_at: null, awaiting_epoch: null,
      history: [{ts: $ts, event: "queued", note: (if $note == "" then "added via " + $source else $note end)}]}' \
    > "$CONTRIB/.rq-item.tmp"

  local newitem; newitem="$(cat "$CONTRIB/.rq-item.tmp")"
  jq --argjson item "$newitem" --arg now "$ts" \
    '.items += [$item] | .updated = $now' "$QUEUE" > "$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"
  rm -f "$CONTRIB/.rq-item.tmp"
  echo "$id"
}

# ---------------- set ----------------
cmd_set() {
  local id="" state="" note=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --note) note="$2"; shift 2 ;;
      *)
        if [[ -z "$id" ]]; then id="$1"; elif [[ -z "$state" ]]; then state="$1"; fi
        shift ;;
    esac
  done
  [[ -n "$id" && -n "$state" ]] || die "set 用法: rq.sh set <id> <state> [--note N]"
  ensure_files
  acquire_lock

  local cur
  cur=$(jq -r --arg id "$id" '.items[] | select(.id == $id) | .state' "$QUEUE")
  [[ -n "$cur" && "$cur" != "null" ]] || die "找不到 $id"
  assert_transition "$cur" "$state"

  local ts; ts="$(now_iso)"; local ep; ep="$(now_epoch)"
  jq --arg id "$id" --arg state "$state" --arg ts "$ts" --argjson ep "$ep" --arg note "$note" '
    .items |= map(if .id == $id then
      .state = $state
      | (if $state == "awaiting-approval" then .awaiting_at = $ts | .awaiting_epoch = $ep else . end)
      | .history += [{ts: $ts, event: $state, note: $note}]
      else . end) | .updated = $ts' "$QUEUE" > "$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"
  echo "$id → $state"
}

# ---------------- amend（非状态字段修正，白名单 + 留痕） ----------------
cmd_amend() {
  local id="" disp="" pr="" note=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disposition) disp="$2"; shift 2 ;;
      --pr) pr="$2"; shift 2 ;;
      --note) note="$2"; shift 2 ;;
      *)
        if [[ -z "$id" ]]; then id="$1"; shift; else die "amend 未知参数: $1"; fi ;;
    esac
  done
  [[ -n "$id" ]] || die "amend 用法: rq.sh amend <id> [--disposition D] [--pr N] [--note N]"
  [[ -n "$disp" || -n "$pr" ]] || die "amend 至少要给一个待改字段（--disposition/--pr）"
  if [[ -n "$disp" ]]; then
    case "$disp" in own-PR|review-evidence|probe-salvage) ;; *) die "disposition 必须是 own-PR|review-evidence|probe-salvage" ;; esac
  fi
  if [[ -n "$pr" ]]; then [[ "$pr" =~ ^[0-9]+$ ]] || die "pr 必须是数字"; fi
  assert_no_secret "$disp|$pr|$note"
  ensure_files
  acquire_lock

  local cur
  cur=$(jq -r --arg id "$id" '.items[] | select(.id == $id) | .state' "$QUEUE")
  [[ -n "$cur" && "$cur" != "null" ]] || die "找不到 $id"

  local ts; ts="$(now_iso)"
  local desc=""
  [[ -n "$disp" ]] && desc="disposition→$disp"
  [[ -n "$pr" ]] && desc="${desc:+$desc; }pr→$pr"
  jq --arg id "$id" --arg disp "$disp" --arg pr "$pr" --arg ts "$ts" --arg note "$note" --arg desc "$desc" '
    .items |= map(if .id == $id then
      (if $disp != "" then .disposition = $disp else . end)
      | (if $pr != "" then .pr = ($pr | tonumber) else . end)
      | .history += [{ts: $ts, event: "amend", note: ($desc + (if $note == "" then "" else "（" + $note + "）" end))}]
      else . end) | .updated = $ts' "$QUEUE" > "$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"
  echo "$id amended: $desc"
}

# ---------------- next ----------------
cmd_next() {
  local lane="deep"
  [[ "${1:-}" == "--lane" ]] && lane="${2:-deep}"
  ensure_files
  jq -r --arg lane "$lane" '
    [.items[] | select(.state == "queued" and .lane == $lane)]
    | sort_by(-.priority, .queued_epoch) | .[0].id // empty' "$QUEUE"
}

# ---------------- list / show ----------------
cmd_list() {
  local state="" oneline=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state) state="$2"; shift 2 ;;
      --oneline) oneline="1"; shift ;;
      *) shift ;;
    esac
  done
  ensure_files
  jq -r --argjson oneline "${oneline:-0}" --arg state "$state" '
    [.items[] | select($state == "" or .state == $state)]
    | if $oneline == 1 then
        .[] | "\(.id)\t\(.state)\tprio=\(.priority)\t\(.score)/15\t#\(.issue)\t\(.title[0:50])"
      else
        map({id, state, lane, disposition, score, priority, issue, queued_at})
      end' "$QUEUE"
}

cmd_show() {
  local id="${1:-}" as_json=""
  [[ "${2:-}" == "--json" ]] && as_json="1"
  [[ -n "$id" ]] || die "show 用法: rq.sh show <id> [--json]"
  ensure_files
  if [[ -n "$as_json" ]]; then
    jq --arg id "$id" '.items[] | select(.id == $id)' "$QUEUE"
  else
    jq -r --arg id "$id" '.items[] | select(.id == $id) |
      "id: \(.id)\nstate: \(.state)  lane: \(.lane)  disposition: \(.disposition)  \(.score)/15 prio=\(.priority)\nissue: #\(.issue)  pr: \(.pr // "-")\ntitle: \(.title)\ndraft: \(.draft // "-")\ntunnel: \(.tunnel.url // "-")\npremises: \(.premises | length) 条\nhistory: \(.history | map(.event) | join(" → "))"' "$QUEUE"
  fi
}

# ---------------- sweep ----------------
cmd_sweep() {
  ensure_files
  acquire_lock
  local ttl; ttl="$(cfg '.approval_ttl_hours' '48')"
  local ts; ts="$(now_iso)"; local ep; ep="$(now_epoch)"
  local out=""

  # awaiting-approval 超 TTL → shelved
  local n1
  n1=$(jq --argjson ep "$ep" --argjson ttl "$ttl" '
    [.items[] | select(.state == "awaiting-approval" and (.awaiting_epoch // 0) > 0
      and ($ep - .awaiting_epoch) > $ttl * 3600)] | length' "$QUEUE")
  if (( n1 > 0 )); then
    jq --argjson ep "$ep" --argjson ttl "$ttl" --arg ts "$ts" '
      .items |= map(if .state == "awaiting-approval" and (.awaiting_epoch // 0) > 0
        and ($ep - .awaiting_epoch) > $ttl * 3600 then
        .state = "shelved"
        | .history += [{ts: $ts, event: "shelved", note: "approval TTL \($ttl)h 到期"}]
        else . end)' "$QUEUE" > "$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"
    out="搁置 ${n1} 条 awaiting-approval（超 ${ttl}h）"
  fi

  # queued 超 TTL → expired（排队无人问津的存货，premise 大概率已变）
  local n2
  n2=$(jq --argjson ep "$ep" --argjson ttl "$ttl" '
    [.items[] | select(.state == "queued" and (.queued_epoch // 0) > 0
      and ($ep - .queued_epoch) > $ttl * 3600)] | length' "$QUEUE")
  if (( n2 > 0 )); then
    jq --argjson ep "$ep" --argjson ttl "$ttl" --arg ts "$ts" '
      .items |= map(if .state == "queued" and (.queued_epoch // 0) > 0
        and ($ep - .queued_epoch) > $ttl * 3600 then
        .state = "expired"
        | .history += [{ts: $ts, event: "expired", note: "queued TTL \($ttl)h 到期"}]
        else . end)' "$QUEUE" > "$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"
    out="${out:+${out}；}过期 ${n2} 条 queued（超 ${ttl}h）"
  fi

  # tunnel 超期审计（>7 天未删）
  if command -v "$TUNNEL_BIN" >/dev/null 2>&1; then
    local stale_slugs
    stale_slugs=$(jq -r --argjson ep "$ep" '
      .items[] | select(.tunnel.slug != null and .tunnel.removed_at == null
        and (.tunnel.deployed_at // "" | length > 0)) | .id' "$QUEUE" || true)
    for id in $stale_slugs; do
      local dep; dep=$(jq -r --arg id "$id" '.items[] | select(.id == $id) | .tunnel.deployed_epoch // 0' "$QUEUE")
      if (( dep > 0 && ep - dep > 7*86400 )); then
        local slug; slug=$(jq -r --arg id "$id" '.items[] | select(.id == $id) | .tunnel.slug' "$QUEUE")
        "$TUNNEL_BIN" rm "$slug" >/dev/null 2>&1 || true
        jq --arg id "$id" --arg ts "$ts" '
          .items |= map(if .id == $id then
            .tunnel.removed_at = $ts
            | .history += [{ts: $ts, event: "tunnel-rm", note: "7 天超期强删"}]
            else . end)' "$QUEUE" > "$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"
        out="${out:+${out}；}tunnel rm ${slug}（超期）"
      fi
    done
  fi
  [[ -n "$out" ]] && echo "$out" || echo ""
}

# ---------------- budget ----------------
cmd_budget() {
  local sub="${1:-status}"; shift || true
  ensure_files
  case "$sub" in
    reserve)
      local id="${1:-}"; shift || true
      local lane="deep"
      while [[ $# -gt 0 ]]; do case "$1" in
        --lane) lane="$2"; shift 2 ;;
        *) shift ;;
      esac; done
      [[ -n "$id" ]] || die "budget reserve 用法: budget reserve <id> --lane deep|probe"
      # 演练件不占真实预算（终态=drill，不进 approved.log）
      if [[ "$id" == *-drill ]]; then echo "OK(drill-不计额)"; exit 0; fi
      acquire_lock
      local wk day wk_used d_used wk_lim d_lim
      wk="$(week_key)"; day="$(date +%F)"
      if [[ "$lane" == "deep" ]]; then
        wk_lim="$(cfg '.deep_check_per_week' '3')"; d_lim="$(cfg '.deep_check_per_day' '1')"
        wk_used=$(jq -r --arg wk "$wk" '.weeks[$wk].used // 0' "$BUDGET")
        d_used=$(jq -r --arg d "$day" '.days[$d].used // 0' "$BUDGET")
        if (( wk_used >= wk_lim )); then echo "DENY week-limit"; exit 1; fi
        if (( d_used >= d_lim )); then echo "DENY day-limit"; exit 1; fi
        jq --arg wk "$wk" --arg d "$day" --arg id "$id" '
          .days[$d].used = ((.days[$d].used // 0) + 1)
          | .days[$d].items = ((.days[$d].items // []) + [$id])
          | .weeks[$wk].used = ((.weeks[$wk].used // 0) + 1)
          | .weeks[$wk].items = ((.weeks[$wk].items // []) + [$id])' "$BUDGET" > "$BUDGET.tmp" \
          && mv "$BUDGET.tmp" "$BUDGET"
      else
        d_lim="$(cfg '.probe_per_day' '1')"
        d_used=$(jq -r --arg d "$day" '.probes[$d].used // 0' "$BUDGET")
        if (( d_used >= d_lim )); then echo "DENY day-limit"; exit 1; fi
        jq --arg d "$day" --arg id "$id" '
          .probes[$d].used = ((.probes[$d].used // 0) + 1)
          | .probes[$d].items = ((.probes[$d].items // []) + [$id])' "$BUDGET" > "$BUDGET.tmp" \
          && mv "$BUDGET.tmp" "$BUDGET"
      fi
      echo "OK"
      ;;
    refund)
      local id="${1:-}"; shift || true
      local lane="deep"
      while [[ $# -gt 0 ]]; do case "$1" in
        --lane) lane="$2"; shift 2 ;;
        *) shift ;;
      esac; done
      acquire_lock
      local wk day allow
      wk="$(week_key)"; day="$(date +%F)"
      if [[ "$lane" == "probe" ]]; then
        allow="true"   # probe 轻量，失败即返还
      else
        allow="$(cfg '.refund_failed_deep_check' 'false')"
      fi
      [[ "$allow" == "true" ]] || { echo "SKIP(不返还)"; exit 0; }
      if [[ "$lane" == "deep" ]]; then
        jq --arg wk "$wk" --arg d "$day" --arg id "$id" '
          .days[$d].used = ([(.days[$d].used // 0) - 1, 0] | max)
          | .days[$d].items = ((.days[$d].items // []) - [$id])
          | .weeks[$wk].used = ([(.weeks[$wk].used // 0) - 1, 0] | max)
          | .weeks[$wk].items = ((.weeks[$wk].items // []) - [$id])' "$BUDGET" > "$BUDGET.tmp" \
          && mv "$BUDGET.tmp" "$BUDGET"
      else
        jq --arg d "$day" --arg id "$id" '
          .probes[$d].used = ([(.probes[$d].used // 0) - 1, 0] | max)
          | .probes[$d].items = ((.probes[$d].items // []) - [$id])' "$BUDGET" > "$BUDGET.tmp" \
          && mv "$BUDGET.tmp" "$BUDGET"
      fi
      echo "REFUNDED"
      ;;
    check)
      # 非突变探测：预算当天/当周是否还有余量（gate 用，不占额）
      local lane="deep"
      while [[ $# -gt 0 ]]; do case "$1" in --lane) lane="$2"; shift 2 ;; *) shift ;; esac; done
      local wk day wk_used d_used wk_lim d_lim
      wk="$(week_key)"; day="$(date +%F)"
      if [[ "$lane" == "deep" ]]; then
        wk_lim="$(cfg '.deep_check_per_week' '3')"; d_lim="$(cfg '.deep_check_per_day' '1')"
        wk_used=$(jq -r --arg wk "$wk" '.weeks[$wk].used // 0' "$BUDGET")
        d_used=$(jq -r --arg d "$day" '.days[$d].used // 0' "$BUDGET")
        if (( wk_used >= wk_lim )); then echo "DENY week";
        elif (( d_used >= d_lim )); then echo "DENY day";
        else echo "OK"; fi
      else
        d_lim="$(cfg '.probe_per_day' '1')"
        d_used=$(jq -r --arg d "$day" '.probes[$d].used // 0' "$BUDGET")
        if (( d_used >= d_lim )); then echo "DENY"; else echo "OK"; fi
      fi
      ;;
    status)
      local wk day
      wk="$(week_key)"; day="$(date +%F)"
      local wk_used d_used p_used wk_lim d_lim
      wk_lim="$(cfg '.deep_check_per_week' '3')"; d_lim="$(cfg '.deep_check_per_day' '1')"
      wk_used=$(jq -r --arg wk "$wk" '.weeks[$wk].used // 0' "$BUDGET")
      d_used=$(jq -r --arg d "$day" '.days[$d].used // 0' "$BUDGET")
      p_used=$(jq -r --arg d "$day" '.probes[$d].used // 0' "$BUDGET")
      echo "deep 本周 ${wk_used}/${wk_lim} · 今日 ${d_used}/${d_lim} · probe 今日 ${p_used}"
      ;;
    *) die "budget 子命令: reserve|refund|status" ;;
  esac
}

# ---------------- validate ----------------
cmd_validate() {
  ensure_files
  local errs=0
  # 1) 整体 JSON 合法 + secret 扫描
  if ! jq -e 'type == "object" and (.items | type == "array")' "$QUEUE" >/dev/null 2>&1; then
    echo "FAIL: ready-queue.json 结构非法"; errs=$((errs+1))
  fi
  if grep -Eq "$SECRET_RE" "$QUEUE"; then
    echo "FAIL: ready-queue 命中 secret 模式"; errs=$((errs+1))
  fi
  # 2) 逐项：id 唯一 / 状态合法 / 同 issue 单活项
  local dup_ids
  dup_ids=$(jq -r '.items | group_by(.id) | map(select(length > 1)) | length' "$QUEUE")
  (( dup_ids > 0 )) && { echo "FAIL: id 重复 ×$dup_ids"; errs=$((errs+1)); }
  local bad_state
  bad_state=$(jq -r '[.items[] | select((.state as $s |
    ["queued","deep-check","awaiting-approval","approved","revise","failed","shelved","expired","rejected","executed"] | index($s)) == null)] | length' "$QUEUE")
  (( bad_state > 0 )) && { echo "FAIL: 非法状态 ×$bad_state"; errs=$((errs+1)); }
  local multi_live
  multi_live=$(jq -r '
    [.items[] | select(.state as $s |
      ["queued","deep-check","awaiting-approval","approved"] | index($s) != null)
     | {id, issue}] | group_by(.issue) | map(select(length > 1)) | length' "$QUEUE")
  (( multi_live > 0 )) && { echo "FAIL: 同 issue 多活项 ×$multi_live"; errs=$((errs+1)); }
  (( errs == 0 )) && echo "validate: OK（$(jq '.items | length' "$QUEUE") 项）" || exit 1
}

# ---------------- 入口 ----------------
# source guard：测试套件 source 本文件复用纯函数（transitions_for/calc_priority 等）；默认 unset = 完全现状
[[ "${RQ_SOURCE_ONLY:-}" == "1" ]] && { return 0 2>/dev/null || exit 0; }

cmd="${1:-help}"; shift || true
case "$cmd" in
  init)    cmd_init ;;
  add)     cmd_add "$@" ;;
  set)     cmd_set "$@" ;;
  amend)   cmd_amend "$@" ;;
  next)    cmd_next "$@" ;;
  list)    cmd_list "$@" ;;
  show)    cmd_show "$@" ;;
  sweep)   cmd_sweep ;;
  tunnel-deploy)
    # tunnel-deploy <id> <url> <slug> [code] —— notify.sh 部署成功后登记
    # code = 审批页短码（approval_interactive 路）；旧调用方 3 参调用 → code 按 null 入账（C5 向后兼容）
    id="${1:-}"; url="${2:-}"; slug="${3:-}"; code="${4:-}"
    [[ -n "$id" && -n "$url" && -n "$slug" ]] || die "tunnel-deploy 用法: tunnel-deploy <id> <url> <slug> [code]"
    acquire_lock; ts="$(now_iso)"; ep="$(now_epoch)"
    jq --arg id "$id" --arg url "$url" --arg slug "$slug" --arg code "$code" --arg ts "$ts" --argjson ep "$ep" '
      .items |= map(if .id == $id then
        .tunnel = {url: $url, slug: $slug,
                   code: (if $code == "" then null else $code end),
                   deployed_at: $ts, deployed_epoch: $ep, removed_at: null}
        | .history += [{ts: $ts, event: "tunnel-deployed",
                        note: (if $code == "" then $url else ($url + "?key=" + $code) end)}]
        else . end)' "$QUEUE" > "$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"
    echo "OK"
    ;;
  tunnel-removed)
    # tunnel-removed <id> —— 审后即删登记
    id="${1:-}"
    [[ -n "$id" ]] || die "tunnel-removed 用法: tunnel-removed <id>"
    acquire_lock; ts="$(now_iso)"
    jq --arg id "$id" --arg ts "$ts" '
      .items |= map(if .id == $id then
        .tunnel.removed_at = $ts
        | .history += [{ts: $ts, event: "tunnel-removed", note: "审后即删"}]
        else . end)' "$QUEUE" > "$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"
    echo "OK"
    ;;
  set-draft)
    # set-draft <id> <path> —— deep-check/演练登记成稿路径（draft 非空是审批推送前置）
    id="${1:-}"; dpath="${2:-}"
    [[ -n "$id" && -n "$dpath" ]] || die "set-draft 用法: set-draft <id> <path>"
    [[ -f "$dpath" ]] || die "草稿文件不存在: $dpath"
    acquire_lock; ts="$(now_iso)"
    jq --arg id "$id" --arg d "$dpath" --arg ts "$ts" '
      .items |= map(if .id == $id then
        .draft = $d
        | .history += [{ts: $ts, event: "draft-set", note: $d}]
        else . end)' "$QUEUE" > "$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"
    echo "OK"
    ;;
  retry-failed)
    # failed → queued（次日 gate 重试）；drill 件不重试
    ensure_files; acquire_lock; ts="$(now_iso)"; ep="$(now_epoch)"
    jq --arg ts "$ts" --argjson ep "$ep" '
      .items |= map(if .state == "failed" and (.id | test("-drill$") | not) then
        .state = "queued"
        | .history += [{ts: $ts, event: "queued", note: "failed 重试晋升"}]
        else . end) | .updated = $ts' "$QUEUE" > "$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"
    echo "OK"
    ;;
  budget)  cmd_budget "$@" ;;
  validate) cmd_validate ;;
  help|*)  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
