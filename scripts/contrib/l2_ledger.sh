#!/bin/bash
# l2_ledger.sh — L2 台账（approved.log）写入器 + own-PR 发布闸（fail-closed）
#
# 为什么存在（#108006 台账缺口，2026-09-11 实证）：
#   approved.log 此前只有一个写者 —— scripts/approval/execute.sh（L2-A 确定性链：
#   :259 do_approved / :327 release-gate）。两条真实路径因此没有台账：
#     ① execute.sh 的 own-PR 分支（:419）把 push 能力交给 coder lane 后就 exit，
#        永不抵达 :259 —— rq-20260907-104693 建卡实证：approved.log `grep -c 104693` = 0；
#     ② 会话内实时路（L2-B，oss-ops.md「L2-B 实时路」要求「执行后同样追加 approved.log」）
#        **没有工具**，只能手工 append：#108006 的 fork push（14:58:59）+ gh pr create
#        （15:00:12Z）走的就是这条路，当时连 ready-queue 项都没有（rq-20260911-108006 是
#        21:59 事后评估卡补记）⇒ 台账三处零记录，事后无法机械审计「已批未发 / 未批已发」。
#
# 本脚本给 own-PR 类对外动作（push fork + gh pr create）一个**唯一受控入口**：
#   publish = 批准证据闸（fail-closed）→ fork push → gh pr create → 同刻落 approved.log
#   record  = 单条台账写入（已有 push/评论动作的补记；5 列格式与 execute.sh 兼容）
#   check   = 只读判定「该分支/PR 是否已有台账」（零副作用，供巡检差集判定）
#
# 语义边界（与既有链兼容，不重写）：
#   - 台账只追加（append-only），不改历史行；写前对本脚本可判定的重复项幂等跳过（exit 0）
#   - 批准证据无法机械验证（L2-B 是人类会话明示）：本脚本的要求是把证据**记录在案**——
#     --approval 为空即 fail-closed 拒绝；证据原文（截断+转义）落台账第 3 列
#   - 绝不 force push、绝不 push 上游仓（remote URL 含 NousResearch/ 即拒）、绝不动 main/master
#   - push 成功但台账写入失败 → exit 9（现场保留：退出码即信号，由调用方/巡检兜底发现）
#   - check 零副作用（不写日志、不写状态），可被小时级巡检安全调用
#
# 用法:
#   l2_ledger.sh record --kind own-PR (--issue N | --pr N) --channel "<渠道标签>" \
#       --approval "<批准原文>" [--rq rq-xxx] [--branch B] [--url U] [--summary S] [--dry-run]
#   l2_ledger.sh publish --worktree <git 目录> --branch B --title T \
#       (--approval "<会话内明示原文>" | --rq <state=approved 的 rq id>) \
#       [--repo owner/name] [--remote fork] [--base main] [--body-file F] \
#       [--issue N] [--pr N] [--channel "<渠道标签>"] [--dry-run]
#   l2_ledger.sh check (--branch B | --pr N) [--ledger PATH]   # 0=有台账 1=无台账 2=用法错误
#
# seam（测试注入；生产缺省=真值）:
#   MARTIN_DIR / CONTRIB_DATA_DIR / APPROVED_LOG / GH_BIN / GIT_BIN / RQ_SH / L2_LEDGER_LOCKDIR
set -uo pipefail

MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"
CONTRIB="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"
CONFIG="$CONTRIB/config.json"
LEDGER="${APPROVED_LOG:-$MARTIN/approved.log}"
GH_BIN="${GH_BIN:-gh}"
GIT_BIN="${GIT_BIN:-git}"
RQ_SH="${RQ_SH:-$MARTIN/scripts/contrib/rq.sh}"
LOCKDIR="${L2_LEDGER_LOCKDIR:-/tmp/contrib-l2ledger.lock}"
LOG_DIR="$CONTRIB/logs"
LOG="$LOG_DIR/l2-ledger.log"
DEFAULT_REPO="NousResearch/hermes-agent"
SELF_DECIDED=""

# 与 rq.sh 同一 secret 口径：任何字段命中即拒绝写入
SECRET_RE='ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'

# 不用 jq `//`：它把 JSON false 当 falsy（09-05 事故）。只把 null/缺失当缺省。
cfg() {
  local v
  v="$(jq -r "$1" "$CONFIG" 2>/dev/null || true)"
  if [[ -n "$v" && "$v" != "null" ]]; then
    echo "$v"
    return 0
  fi
  echo "$2"
}

die() { echo "l2_ledger.sh: $*" >&2; exit 2; }

log() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  printf '[%s] l2-ledger: %s\n' "$(date '+%F %T')" "$*" >>"$LOG" 2>/dev/null || true
}

usage() {
  cat >&2 <<'EOF'
用法:
  l2_ledger.sh record --kind own-PR|evidence|release-gate|other (--issue N | --pr N)
      --channel "<渠道标签>" (--approval "<批准原文>" | --self-decided "<自决理由>")
      [--rq rq-xxx] [--branch B] [--url U] [--summary S] [--dry-run]
      ※ --self-decided = operator 自决路（宪法 §12）；release-gate 拒绝自决（ALWAYS_L2）
  l2_ledger.sh publish --worktree <git 目录> --branch B --title T
      (--approval "<会话内明示原文>" | --rq <state=approved 的 rq id> | --self-decided "<自决理由>")
      [--repo owner/name] [--remote fork] [--base main] [--body-file F]
      [--issue N] [--pr N] [--channel "<渠道标签>"] [--dry-run]
  l2_ledger.sh check (--branch B | --pr N) [--ledger PATH]
EOF
  exit 2
}

# sanitize <文本> — 单行化 + 竖线转义（approved.log 用 " | " 分列，字段内绝不留竖线）
sanitize() {
  printf '%s' "${1:-}" | tr '\n\r' '  ' | sed 's/[|]/／/g; s/^[[:space:]]*//; s/[[:space:]]*$//'
}

assert_no_secret() { # <文本> <字段名>
  if grep -Eq "$SECRET_RE" <<<"$1"; then
    die "$2 命中 secret 模式，拒绝写入台账"
  fi
}

acquire_lock() {
  local i=0
  until mkdir "$LOCKDIR" 2>/dev/null; do
    i=$((i + 1))
    [[ $i -gt 60 ]] && die "锁等待超时（$LOCKDIR 残留？手工检查）"
    sleep 1
  done
  trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT
}

disp_cn() {
  case "$1" in
    own-PR)       echo "own-PR 处置" ;;
    evidence)     echo "evidence 评审" ;;
    release-gate) echo "发版提审门" ;;
    other)        echo "对外动作" ;;
    *)            echo "$1" ;;
  esac
}

# ledger_has <needle> → 0=命中（只读）
ledger_has() {
  [[ -f "$LEDGER" ]] || return 1
  grep -qF -- "$1" <(tr -d '\r' <"$LEDGER")
}

# ---- 自决路与日写动作上限（09-14 用户拍板：判断优先，机械层只做极端异常兜底）----
# 阈值定调：正常量级 1-3 写动作/日。软告警 10（照常执行，WARNING 进日志供简报拣选）；
# 硬闸 30（物理拒绝——正常 10 倍以上才触发，到达即属失控/循环/被俘形态，与 AI 判断对错无关）。
LEDGER_DAILY_WARN=10
LEDGER_DAILY_HARD=30
daily_cap_check() {
  local today n
  today="$(date '+%Y-%m-%d')"
  n=0
  [[ -f "$LEDGER" ]] && n="$(grep -c "^${today}" "$LEDGER" 2>/dev/null || true)"
  n="${n:-0}"
  if (( n >= LEDGER_DAILY_HARD )); then
    die "当日对外写动作已 ${n} 条（硬闸 ${LEDGER_DAILY_HARD}，极端异常兜底）——停止写动作；正常 1-3/日，达此数必属异常，需人工核查后再放行"
  fi
  if (( n >= LEDGER_DAILY_WARN )); then
    echo "l2_ledger.sh: WARNING 当日对外写动作 ${n} 条（软告警线 ${LEDGER_DAILY_WARN}）——超出正常量级" >&2
  fi
}

# resolve_self_decided <kind>：把 --self-decided 归一化成批准原文；ALWAYS_L2 机械拒绝
# （release-gate = 物理不可逆，永远要用户具体批准——机制层，operator 无权重做，宪法 §12）
resolve_self_decided() {
  local kind="$1"
  [[ -z "$SELF_DECIDED" ]] && return 0
  [[ "$kind" == "release-gate" ]] && die "release-gate 属 ALWAYS_L2（物理不可逆），拒绝自决路——必须用户具体批准（宪法 §12）"
  [[ -z "$(sanitize "$approval")" ]] || die "--self-decided 与 --approval 互斥（自决动作不需要也不允许同时挂用户批准）"
  approval="自决: ${SELF_DECIDED}"
}

# 幂等预检：本脚本可判定的重复形态（rq 锚 / 分支锚优先；URL 锚仅在无其它锚时作为唯一判据
# —— 同一 URL 配不同分支/不同 rq 是**新动作**，不得被误判为重复而漏记）→ 命中 ALREADY（exit 0）
already_ledgered() {
  local why=""
  [[ -n "${OUT_RQ:-}" ]] && ledger_has "rq ${OUT_RQ}" && why="rq ${OUT_RQ}"
  if [[ -z "$why" && -n "${OUT_BRANCH:-}" ]] && ledger_has "branch=${OUT_BRANCH}"; then
    why="branch=${OUT_BRANCH}"
  fi
  if [[ -z "$why" && -z "${OUT_RQ:-}" && -z "${OUT_BRANCH:-}" && -n "${OUT_URL:-}" ]] \
    && ledger_has "$OUT_URL"; then
    why="$OUT_URL"
  fi
  [[ -n "$why" ]] || return 1
  printf 'ALREADY-LEDGERED %s\n' "$why"
  return 0
}

# append_ledger — 用 OUT_* 变量组行并追加（5 列，` | ` 分隔，与 execute.sh 同形）
# 列: <ts> | hermes-contrib | <ref> <disp>（<channel>执行[，rq <id>]）：<批准原文> | <channel> | <detail>
append_ledger() {
  local ref disp third detail line
  if [[ -n "${OUT_ISSUE:-}" ]]; then
    ref="issue #${OUT_ISSUE}"
  elif [[ -n "${OUT_PR:-}" ]]; then
    ref="PR #${OUT_PR}"
  else
    ref="own-PR（未绑 issue）"
  fi
  disp="$(disp_cn "$OUT_KIND")"
  third="${ref} ${disp}（${OUT_CHANNEL}执行"
  [[ -n "${OUT_RQ:-}" ]] && third="${third}，rq ${OUT_RQ}"
  third="${third}）：${OUT_APPROVAL}"
  detail=""
  [[ -n "${OUT_URL:-}" ]] && detail="${OUT_URL}"
  [[ -n "${OUT_BRANCH:-}" ]] && detail="${detail}${detail:+ }branch=${OUT_BRANCH}"
  [[ -n "${OUT_SUMMARY:-}" ]] && detail="${detail}${detail:+ — }${OUT_SUMMARY}"
  [[ -n "$detail" ]] || detail="（无 URL/分支锚）"
  line="$(date '+%Y-%m-%dT%H:%M:%S%z') | hermes-contrib | ${third} | ${OUT_CHANNEL} | ${detail}"
  if [[ "${OUT_DRY:-false}" == "true" ]]; then
    printf '[dry-run] approved.log += %s\n' "$line"
    return 0
  fi
  acquire_lock
  if ! printf '%s\n' "$line" >>"$LEDGER"; then
    return 9
  fi
  log "approved.log + ${ref}（kind=${OUT_KIND} channel=${OUT_CHANNEL} rq=${OUT_RQ:-无} branch=${OUT_BRANCH:-无}）"
  return 0
}

# emit_self_decided_event — 宪法 §12「可见性契约 2：当日全部自决动作进当日简报」的机制落点。
# 为什么必须由落账处自己 emit：自决动作此前只写 approved.log / l2-ledger.log，而 notify.sh 的
# flush 只读 contrib-data/events.jsonl ⇒ 自决路在结构上永远进不了简报（09-15 首单实证：
# 00:15:46 执行完，01:0x 当日简报文件仍不存在，靠班次手写兜底）。落账是自决路的唯一必经点，
# 事件在这里 emit 即覆盖全部自决动作（record + publish 两条路共用本函数）。
# 简报级路由（route=brief，不进微信批）由 notify.sh 的 is_brief_only 决定：class `self-decided`
# 在 config.brief_only_classes 闭集内（replace 语义见 notify.sh 注释）。
# 边界：emit 失败只记日志、绝不改变台账写入结果（台账是权威，简报是它的可读投影）；
# --dry-run 与幂等跳过路（already_ledgered 早返回）不 emit。key 带落账时刻 ⇒ 同锚点的一日多次
# 自决各成一行（同 key 会被 notify.sh 合并成 occurrences+1 而丢掉前一条的可见性）。
emit_self_decided_event() {
  [[ -n "$SELF_DECIDED" ]] || return 0
  [[ "${OUT_DRY:-false}" == "true" ]] && return 0
  local anchor="${OUT_RQ:-}"
  [[ -n "$anchor" ]] || anchor="${OUT_BRANCH:-}"
  [[ -n "$anchor" ]] || anchor="${OUT_PR:+pr${OUT_PR}}"
  [[ -n "$anchor" ]] || anchor="issue${OUT_ISSUE:-0}"
  local key
  key="selfdecided-${anchor}-$(date +%s)"
  if bash "$MARTIN/scripts/contrib/notify.sh" event self-decided --key "$key" --channel contrib \
      --summary "自决: $(sanitize "$SELF_DECIDED")（${OUT_KIND} ${anchor}）" >>"$LOG" 2>&1; then
    log "self-decided 事件已入账（key=${key}）"
  else
    log "self-decided 事件 emit 失败（key=${key}）——台账已落，当日简报可见性缺失"
  fi
  return 0
}

# ---------------- record ----------------
cmd_record() {
  local kind="" issue="" pr="" rq="" branch="" url="" channel="" approval="" summary="" dry="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kind)     kind="${2:-}"; shift 2 ;;
      --issue)    issue="${2:-}"; shift 2 ;;
      --pr)       pr="${2:-}"; shift 2 ;;
      --rq)       rq="${2:-}"; shift 2 ;;
      --branch)   branch="${2:-}"; shift 2 ;;
      --url)      url="${2:-}"; shift 2 ;;
      --channel)  channel="${2:-}"; shift 2 ;;
      --approval) approval="${2:-}"; shift 2 ;;
      --self-decided) SELF_DECIDED="${2:-}"; shift 2 ;;
      --summary)  summary="${2:-}"; shift 2 ;;
      --dry-run)  dry="true"; shift ;;
      -h|--help)  usage ;;
      *) die "record 未知参数: $1" ;;
    esac
  done
  case "$kind" in
    own-PR|evidence|release-gate|other) ;;
    "") die "record 缺 --kind（own-PR|evidence|release-gate|other）" ;;
    *) die "record --kind 非法: $kind" ;;
  esac
  [[ -n "$issue" || -n "$pr" ]] || die "record 需 --issue 或 --pr（台账锚点）"
  [[ -n "$channel" ]] || die "record 缺 --channel（渠道标签，如 \"L2-B 会话内批准\"）"
  # fail-closed：无批准原文 = 无 L2 依据，拒绝落账（宁可漏记，不可伪造依据）
  resolve_self_decided "$kind"
  [[ -n "$(sanitize "$approval")" ]] || die "record 缺批准来源（--approval \"<批准原文>\" 或 --self-decided \"<自决理由>\"；L2 语义：对外动作必有批准或自决留痕）"
  [[ -z "$issue" || "$issue" =~ ^[0-9]+$ ]] || die "record --issue 必须是数字"
  [[ -z "$pr" || "$pr" =~ ^[0-9]+$ ]] || die "record --pr 必须是数字"

  assert_no_secret "$approval" "--approval"
  assert_no_secret "$channel" "--channel"
  assert_no_secret "$summary" "--summary"
  assert_no_secret "$branch" "--branch"

  OUT_KIND="$kind"; OUT_ISSUE="$issue"; OUT_PR="$pr"; OUT_RQ="$rq"
  OUT_BRANCH="$branch"; OUT_URL="$url"; OUT_DRY="$dry"
  OUT_CHANNEL="$(sanitize "$channel")"
  OUT_APPROVAL="$(sanitize "$approval")"
  OUT_SUMMARY="$(sanitize "$summary")"

  if already_ledgered; then
    [[ "$dry" == "true" ]] || log "record ${OUT_RQ:-${OUT_BRANCH:-$issue}} 已在账（幂等跳过）"
    return 0
  fi
  [[ "$dry" == "true" ]] || daily_cap_check
  if ! append_ledger; then
    echo "l2_ledger.sh: approved.log 写入失败（路径/权限异常：${LEDGER}）" >&2
    return 9
  fi
  emit_self_decided_event
  return 0
}

# ---------------- check（只读，零副作用） ----------------
cmd_check() {
  local branch="" pr="" ledger="$LEDGER"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch) branch="${2:-}"; shift 2 ;;
      --pr)     pr="${2:-}"; shift 2 ;;
      --ledger) ledger="${2:-}"; shift 2 ;;
      -h|--help) usage ;;
      *) die "check 未知参数: $1" ;;
    esac
  done
  [[ -n "$branch" || -n "$pr" ]] || die "check 需 --branch 或 --pr"
  [[ -z "$pr" || "$pr" =~ ^[0-9]+$ ]] || die "check --pr 必须是数字"
  [[ -f "$ledger" ]] || { echo "MISSING（台账不存在: ${ledger}）"; return 1; }
  local hay
  hay="$(tr -d '\r' <"$ledger")"
  # ① 新格式显式分支 token（publish/record 必带）
  if [[ -n "$branch" ]] && grep -qF -- "branch=$branch" <<<"$hay"; then
    echo "LEDGERED branch=$branch"
    return 0
  fi
  # ② 旧格式（09-11 前手工行）以裸分支名出现——长度 >= 6 才认，防短串误配
  if [[ -n "$branch" ]] && (( ${#branch} >= 6 )) && grep -qF -- "$branch" <<<"$hay"; then
    echo "LEDGERED branch=${branch}（裸提及，历史手工行）"
    return 0
  fi
  # ③ PR/issue 数字锚（URL 或 #N；后随非数字防 108006→1080061 误配）
  if [[ -n "$pr" ]] && { grep -qE "(pull|issues)/${pr}([^0-9]|$)" <<<"$hay" \
    || grep -qE "#${pr}([^0-9]|$)" <<<"$hay"; }; then
    echo "LEDGERED pr=$pr"
    return 0
  fi
  echo "MISSING branch=${branch:-} pr=${pr:-}"
  return 1
}

# ---------------- publish（own-PR 唯一受控发布入口，fail-closed） ----------------
cmd_publish() {
  local worktree="" branch="" title="" repo="" remote="fork" base="main" body_file=""
  local issue="" pr="" rq="" channel="" approval="" dry="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --worktree)  worktree="${2:-}"; shift 2 ;;
      --branch)    branch="${2:-}"; shift 2 ;;
      --title)     title="${2:-}"; shift 2 ;;
      --repo)      repo="${2:-}"; shift 2 ;;
      --remote)    remote="${2:-}"; shift 2 ;;
      --base)      base="${2:-}"; shift 2 ;;
      --body-file) body_file="${2:-}"; shift 2 ;;
      --issue)     issue="${2:-}"; shift 2 ;;
      --pr)        pr="${2:-}"; shift 2 ;;
      --rq)        rq="${2:-}"; shift 2 ;;
      --channel)   channel="${2:-}"; shift 2 ;;
      --approval)  approval="${2:-}"; shift 2 ;;
      --self-decided) SELF_DECIDED="${2:-}"; shift 2 ;;
      --dry-run)   dry="true"; shift ;;
      -h|--help)   usage ;;
      *) die "publish 未知参数: $1" ;;
    esac
  done
  [[ -n "$worktree" && -n "$branch" && -n "$title" ]] || die "publish 需 --worktree --branch --title"
  case "$branch" in
    main|master) die "拒绝对 ${branch} 发布（own-PR 只允许功能分支）" ;;
  esac
  REPO="${repo:-$(cfg '.repo' "$DEFAULT_REPO")}"
  CHANNEL="$(sanitize "${channel:-L2-B 会话内批准}")"

  # ① 批准证据（fail-closed 核心闸；置于一切 git/gh 动作之前——无批准即零动作）
  resolve_self_decided "own-PR"
  local evidence=""
  if [[ -n "$rq" ]]; then
    local st
    st="$(bash "$RQ_SH" show "$rq" --json 2>/dev/null | jq -r '.state // empty' 2>/dev/null || true)"
    [[ "$st" == "approved" ]] || die "rq ${rq} state=${st:-未知}（非 approved），拒绝 publish"
    evidence="已批（L2-A，rq ${rq}）"
    [[ "$CHANNEL" == "L2-B 会话内批准" ]] && CHANNEL="L2-A tunnel 短码批准"
  elif [[ -n "$(sanitize "$approval")" ]]; then
    evidence="$(sanitize "$approval")"
  else
    die "publish 缺批准证据：--approval \"<会话内明示原文>\" 或 --rq <state=approved 的 rq id> 或 --self-decided \"<自决理由>\""
  fi
  assert_no_secret "$evidence" "--approval"
  assert_no_secret "$title" "--title"
  [[ "$dry" == "true" ]] || daily_cap_check

  # ② git 上下文校验
  if ! "$GIT_BIN" -C "$worktree" rev-parse --git-dir >/dev/null 2>&1; then
    die "publish --worktree 不是 git 工作树: $worktree"
  fi

  # ③ remote 校验：必须存在，且绝不指向上游仓
  local remote_url
  remote_url="$("$GIT_BIN" -C "$worktree" remote get-url "$remote" 2>/dev/null)" \
    || die "remote ${remote} 在 ${worktree} 不存在（own-PR 必须 push 自有 fork）"
  case "$remote_url" in
    *NousResearch/*) die "remote ${remote} 指向上游仓（${remote_url}），拒绝 push；own-PR 必须 push fork" ;;
  esac
  local owner
  owner="$(printf '%s' "$remote_url" | sed -E 's#^.*github\.com[:/]##; s#/.*$##')"
  [[ -n "$owner" ]] || die "无法从 remote URL 解析 owner: ${remote_url}"

  # ④ 幂等预检：已有 PR → 只补台账，绝不重 push
  local existing="" pr_out
  pr_out="$("$GH_BIN" pr list --repo "$REPO" --head "${owner}:${branch}" --state all --json number,url 2>/dev/null || true)"
  existing="$(printf '%s' "$pr_out" | jq -r 'if type == "array" and length > 0 then (.[0].url // "") else "" end' 2>/dev/null || true)"

  if [[ "$dry" == "true" ]]; then
    echo "[dry-run] 批准证据: ${evidence}"
    echo "[dry-run] 台账渠道标签: ${CHANNEL}"
    if [[ -n "$existing" ]]; then
      echo "[dry-run] 已有 PR ${existing} → 跳过 push，仅补台账"
    else
      echo "[dry-run] ${GIT_BIN} -C ${worktree} push ${remote} ${branch}（无 --force）"
      echo "[dry-run] ${GH_BIN} pr create --repo ${REPO} --base ${base} --head ${owner}:${branch} --title ${title}${body_file:+ --body-file ${body_file}}"
    fi
    OUT_DRY="true"
    OUT_KIND="own-PR"; OUT_ISSUE="$issue"; OUT_PR="$pr"; OUT_RQ="$rq"
    OUT_BRANCH="$branch"; OUT_URL="$existing"
    if [[ -n "$existing" ]]; then
      OUT_SUMMARY="dry-run：已有 PR → 仅补台账"
    else
      OUT_SUMMARY="dry-run：push ${remote}/${branch} + gh pr create"
    fi
    OUT_CHANNEL="$CHANNEL"; OUT_APPROVAL="$evidence"
    [[ -n "$existing" || -n "$issue" || -n "$pr" ]] || OUT_ISSUE=""
    append_ledger
    return 0
  fi

  local pr_url="$existing"
  if [[ -z "$existing" ]]; then
    # ⑤ push fork（唯一形态：git push <remote> <branch>，永不 force）
    if ! "$GIT_BIN" -C "$worktree" push "$remote" "$branch"; then
      die "git push ${remote} ${branch} 失败（拒绝 force/重试；现场保留，人工处置）"
    fi
    log "publish: pushed ${remote}/${branch}（worktree=${worktree}）"
    # ⑥ 开 PR
    local resp rc=0
    if [[ -n "$body_file" ]]; then
      resp="$("$GH_BIN" pr create --repo "$REPO" --base "$base" --head "${owner}:${branch}" \
        --title "$title" --body-file "$body_file" 2>&1)" || rc=$?
    else
      resp="$("$GH_BIN" pr create --repo "$REPO" --base "$base" --head "${owner}:${branch}" \
        --title "$title" 2>&1)" || rc=$?
    fi
    if (( rc != 0 )); then
      die "gh pr create 失败（rc=${rc}）：已 push ${remote}/${branch}，PR 未建 —— 补建后务必 l2_ledger.sh record 记账；$(printf '%s' "$resp" | tail -c 200)"
    fi
    pr_url="$(printf '%s' "$resp" | grep -Eo 'https://github\.com/[^[:space:]]+/pull/[0-9]+' | tail -1 || true)"
    [[ -n "$pr_url" ]] || printf 'l2_ledger.sh: 警告：PR 已建但未解析到 URL（gh 输出：%s），台账以分支锚记账\n' \
      "$(printf '%s' "$resp" | tail -c 200)" >&2
    log "publish: PR created ${pr_url:-未解析}"
  else
    log "publish: 已有 PR ${existing} → 跳过 push（幂等）"
  fi

  # ⑦ 同刻落台账（push/开 PR 与记账同一进程，无法分离）
  OUT_KIND="own-PR"; OUT_ISSUE="$issue"; OUT_PR="$pr"; OUT_RQ="$rq"
  OUT_BRANCH="$branch"; OUT_URL="$pr_url"
  if [[ -n "$existing" ]]; then
    OUT_SUMMARY="已有 PR ${existing} → 仅补台账（未 push）"
  else
    OUT_SUMMARY="push ${remote}/${branch} + gh pr create"
  fi
  OUT_CHANNEL="$CHANNEL"; OUT_APPROVAL="$evidence"; OUT_DRY="false"
  if [[ -n "$pr_url" ]]; then
    local prnum
    prnum="$(printf '%s' "$pr_url" | grep -Eo '[0-9]+$' || true)"
    [[ -n "${OUT_PR:-}" ]] || OUT_PR="$prnum"
  fi
  [[ -n "${OUT_ISSUE:-}" || -n "${OUT_PR:-}" ]] || OUT_PR="0"
  if already_ledgered; then
    printf 'ALREADY-LEDGERED %s\n' "${OUT_RQ:-${OUT_BRANCH}}"
    return 0
  fi
  if ! append_ledger; then
    printf 'l2_ledger.sh: 严重：已 push/开 PR 但台账写入失败（%s）——请立即 l2_ledger.sh record 补记；巡检会报警\n' \
      "$LEDGER" >&2
    return 9
  fi
  emit_self_decided_event
  printf 'PUBLISHED %s branch=%s ledger=%s\n' "${pr_url:-无URL}" "$branch" "$LEDGER"
  return 0
}

# ---------------- 入口 ----------------
CMD="${1:-}"
shift || true
case "$CMD" in
  record)  cmd_record "$@" ;;
  check)   cmd_check "$@" ;;
  publish) cmd_publish "$@" ;;
  ""|-h|--help) usage ;;
  *) die "未知子命令: ${CMD}（record|check|publish）" ;;
esac
