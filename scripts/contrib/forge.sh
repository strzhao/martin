#!/bin/bash
# forge.sh — 造货 lane：commit 进仓优先原则的执行引擎（09-09 升级，机制层强制）
#
# 深检 goods-gate 三态中 `forge-lane` 与库存维护的落地工具：把「缺口可修」变成
# 「单关注点 + 可剥离 + mutation 自证 + 基于 current main」的可 offer 库存 commit。
# 红线继承 build 车道：只到本地为止——绝不 push、绝不 gh pr create（L2 永不豁免）。
#
# 用法:
#   forge.sh init <slug> --repo <owner/name> [--issue <#>] [--dir <path>]
#                   在上游仓建 worktree + 分支 forge/<slug>（基于 origin/main），
#                   打印 worktree 路径；--dir 覆盖上游仓根（缺省 HERMES_AGENT_DIR，~/workspace/hermes-agent）
#   forge.sh register <slug> --branch <b> --sha <sha> --domain <d> [--proof <path>] [--notes <s>]
#                   成品入库（inventory.json，status=ready, kind=fork-commit）
#   forge.sh set-status <id> <ready|stale|in-flight|spent|needs-decision|dead|idea>
#   forge.sh check [--stale-days <n>]
#                   新鲜度巡检：列各项 base_sha 与 checked 距今天数（缺省 14 天标 STALE；
#                   base 落后量由 radar 每日研判对上游仓 rev-list 实查）
#   forge.sh list [--status <s>]
#
# exit code: 0=成功 1=失败 2=用法/数据错误
# seam: MARTIN_DIR / CONTRIB_DATA_DIR / HERMES_AGENT_DIR / FORGE_GIT（测试注入）
# 台账: contrib-data/inventory.json（唯一写入口=本脚本）；散文版 hermes-contribution.md §11
set -uo pipefail

MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"
CONTRIB="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"
INVENTORY="$CONTRIB/inventory.json"
UPSTREAM="${HERMES_AGENT_DIR:-$HOME/workspace/hermes-agent}"
GIT="${FORGE_GIT:-git}"

log() { echo "[forge] $*"; }
die() { echo "[forge] $*" >&2; exit "${2:-1}"; }

usage() {
  grep '^#   forge.sh' "$0" | sed 's/^#   //'
  exit 2
}

inv_require() {
  [[ -s "$INVENTORY" ]] || die "inventory.json 缺失（应为 contrib-data/inventory.json）" 2
  jq -e '.items' "$INVENTORY" >/dev/null 2>&1 || die "inventory.json 结构非法" 2
}

today() { date -u +%F; }

# ── 原子改写 inventory（单写方约定：forge lane 人工/卡内单线程；radar check 只读）──
inv_write() { # <jq-filter...> — stdin 透传给 jq，两跳均落 tmp+mv 原子替换
  local tmp="$INVENTORY.tmp" new="$INVENTORY.new"
  jq "$@" "$INVENTORY" > "$tmp" && \
    jq -c --arg d "$(date -u +%FT%TZ)" '.updated = $d' "$tmp" > "$new" && \
    mv "$new" "$INVENTORY" && rm -f "$tmp"
}

cmd="${1:-}"
shift || true
case "$cmd" in

  init)
    slug="${1:-}"; [[ -n "$slug" ]] || usage
    shift
    repo=""; issue=""; dir=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo) repo="$2"; shift 2 ;;
        --issue) issue="$2"; shift 2 ;;
        --dir) dir="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    [[ -n "$repo" ]] || die "init 需要 --repo <owner/name>" 2
    [[ "$slug" =~ ^[a-z0-9][a-z0-9-]{1,40}$ ]] || die "slug 只许小写字母数字连字符（2-41 位）" 2
    upstream="${dir:-$UPSTREAM}"
    [[ -d "$upstream/.git" ]] || die "上游仓不存在: $upstream （用 --dir 指定）" 2
    upstream="$(cd "$upstream" && pwd -P)"   # 规范化（symlink/别名路径），worktree 查重按 realpath 比对

    if ! "$GIT" -C "$upstream" fetch origin --quiet 2>/dev/null; then
      if "$GIT" -C "$upstream" rev-parse --verify --quiet origin/main >/dev/null; then
        log "警告：git fetch 失败（网络/限流），沿用本地 origin/main@$("$GIT" -C "$upstream" rev-parse --short origin/main)——offer 前必须重新 fetch 核对上游（占坑/漂移）"
      else
        die "git fetch 失败且本地无 origin/main ref（先手动 fetch 一次）"
      fi
    fi
    base="$("$GIT" -C "$upstream" rev-parse origin/main)" || die "origin/main 不存在" 2
    wt="$upstream/.claude/worktrees/forge-$slug"
    if "$GIT" -C "$upstream" worktree list --porcelain | grep -Fx "worktree $wt" >/dev/null; then
      die "worktree 已存在: $wt （复用或先 git worktree remove）"
    fi
    branch="forge/$slug"
    "$GIT" -C "$upstream" worktree add -b "$branch" "$wt" "$base" >/dev/null \
      || die "worktree 创建失败" 1
    # 台账自举：fresh 环境无 inventory.json 时先种空表（否则 init 项永不入账、register 卡死）
    [[ -s "$INVENTORY" ]] || printf '{\n  "version": 1,\n  "updated": "",\n  "note": "可 pick 库存台账（机读版；唯一写入口 scripts/contrib/forge.sh）",\n  "items": []\n}\n' > "$INVENTORY"
    inv_write --arg id "forge-$slug" --arg t "$(today)" --arg slug "$slug" \
      --arg repo "$repo" --arg issue "$issue" --arg base "$base" '
      .items = ((.items // []) + [{id: $id, title: ("forge/" + $slug), kind: "forge-commit",
          loc: ("fork branch forge/" + $slug + (if $issue != "" then " (base issue #" + $issue + ")" else "" end)),
          domain: ("repo:" + $repo), status: "in-flight", vehicle: "", notes: "",
          base_sha: $base, fork_sha: null, proof: null, checked: $t}]) | .' \
      || die "inventory 登记失败（worktree 已建于 $wt ，请修复台账后 register）"
    log "worktree 就绪: $wt"
    log "分支: $branch  基座: ${base:0:12}（origin/main）"
    log "铁律：单关注点 + 可剥离 + mutation 自证（proof 落盘后 register）+ 绝不 push"
    ;;

  register)
    slug="${1:-}"; [[ -n "$slug" ]] || usage
    shift
    branch=""; sha=""; domain=""; proof=""; notes=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --branch) branch="$2"; shift 2 ;;
        --sha) sha="$2"; shift 2 ;;
        --domain) domain="$2"; shift 2 ;;
        --proof) proof="$2"; shift 2 ;;
        --notes) notes="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    inv_require
    [[ -n "$branch" && -n "$sha" && -n "$domain" ]] || die "register 需要 --branch --sha --domain" 2
    [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]] || die "sha 形态非法: $sha" 2
    [[ -z "$proof" || -s "$proof" ]] || die "proof 文件不存在: $proof" 2
    inv_write --arg id "forge-$slug" --arg b "$branch" --arg s "$sha" \
      --arg d "$domain" --arg p "$proof" --arg n "$notes" --arg t "$(today)" '
      def ready_fields: .branch = $b | .fork_sha = $s | .domain = $d | .proof = $p
           | .notes = $n | .status = "ready" | .kind = "fork-commit" | .checked = $t;
      .items = (
        ((.items // []) | map(if .id == $id then ready_fields else . end))
        + (if any(.items[]; .id == $id)
           then []
           else [{id: $id, title: ("forge/" + $id), kind: "fork-commit",
                  loc: ("fork branch " + $b), domain: $d, status: "ready",
                  vehicle: "", notes: $n, base_sha: null, branch: $b,
                  fork_sha: $s, proof: $p, checked: $t} | ready_fields]
           end))' \
      || die "登记失败（inventory 写盘失败）"
    log "已入库: forge-$slug → $branch @ ${sha:0:12}（domain=$domain, proof=${proof:-未附}）"
    ;;

  set-status)
    id="${1:-}"; st="${2:-}"
    inv_require
    [[ -n "$id" && -n "$st" ]] || usage
    case "$st" in ready|stale|in-flight|spent|needs-decision|dead|idea) ;;
      *) die "status 只许 ready|stale|in-flight|spent|needs-decision|dead|idea" 2 ;;
    esac
    inv_write --arg id "$id" --arg st "$st" --arg t "$(today)" \
      '.items = ((.items // []) | map(if .id == $id then .status = $st | .checked = $t else . end))
       | if (any(.items[]; .id == $id)) then . else error("inventory 无 " + $id) end' \
      || die "登记失败（inventory 无 $id 或写盘失败）" 2
    log "$id → $st"
    ;;

  check)
    stale_days="${STALE_DAYS:-14}"
    if [[ "${1:-}" == "--stale-days" ]]; then stale_days="${2:-14}"; fi
    inv_require
    now="$(date -u +%s)"
    while IFS=$'\t' read -r id st kind loc checked base_sha; do
      [[ -z "$id" ]] && continue
      age_days=""
      if [[ "$checked" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        age_days=$(( (now - $(date -u -j -f %F "$checked" +%s 2>/dev/null || echo "$now")) / 86400 ))
      fi
      flag=""
      [[ -n "$age_days" && "$age_days" -gt "$stale_days" ]] && flag="STALE(checked>${stale_days}d)"
      printf '%s\t%s\t%s\t%s\t%s\t%s%s\n' "$id" "$st" "${kind}" "$loc" "${base_sha:-—}" "${age_days}d-since-check" "${flag:+ 旗=$flag}"
    done < <(jq -r '.items[] | [.id, .status, .kind, .loc, (.checked // ""), (.base_sha // "")] | @tsv' "$INVENTORY")
    log "列: id/status/kind/loc/base_sha/checked龄。ready 项 base_sha 落后量由 radar 对上游仓实查：git -C ~/workspace/hermes-agent rev-list --count <base_sha>..origin/main"
    ;;

  list)
    st=""
    if [[ "${1:-}" == "--status" ]]; then st="${2:-}"; fi
    inv_require
    if [[ -n "$st" ]]; then
      jq -r --arg st "$st" '.items[] | select(.status == $st) | "\(.id)\t\(.status)\t\(.kind)\t\(.domain)\t\(.fork_sha // .loc)"' "$INVENTORY"
    else
      jq -r '.items[] | "\(.id)\t\(.status)\t\(.kind)\t\(.domain)\t\(.fork_sha // .loc)"' "$INVENTORY"
    fi
    ;;

  *)
    usage ;;
esac
