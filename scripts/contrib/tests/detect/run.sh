#!/bin/bash
# detect/run.sh — 捕获自证 harness：按 5 类对被测脚本沙箱副本注入代表性缺陷，
# 断言 pristine 绿 / mutated 红 / diff>=1（本任务核心验收，红队可独立复现）
#
# 用法：bash tests/detect/run.sh [class]
#   class ∈ bool-parse | cwd-dep | ledger-vs-delivery | state-machine | bookkeeping（缺省=全 5 类）
# 末行 JSON：{"class":"...","cases":[{"name":"...","pristine_exit":N,"mutated_exit":N,"diff_lines":N},...],
#            "mutation_desc":"...","sandbox":"<path>"}
#   exit 0 当且仅当每 case pristine_exit==0 且 mutated_exit!=0 且 diff_lines>=1
# DETECT_KEEP=1 保留 mutated 沙箱（可用 CONTRIB_TEST_TARGET=<sandbox> 独立复现，不信任 harness 自述）
#
# 缺陷注入机制：对沙箱副本做**字面量锚点替换**（python3）；锚点不存在 → harness 自身报错退出
# （被测脚本漂移时立即暴露，不会静默假绿）。
set -uo pipefail

TESTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"

source "$TESTS_ROOT/lib/sandbox.sh"

PROBE_DIR="$TESTS_ROOT/detect/probes"
TMP_ANCHOR="$(mktemp "${TMPDIR:-/tmp}/contrib-anchor.XXXXXX")"
TMP_NEW="$(mktemp "${TMPDIR:-/tmp}/contrib-new.XXXXXX")"
trap 'rm -f "$TMP_ANCHOR" "$TMP_NEW"' EXIT

# diff 绝对路径解析：环境里可能存在不支持 -r 的第三方 diff 遮蔽系统版（环境依赖防御）
DIFF_BIN="/usr/bin/diff"
[[ -x "$DIFF_BIN" ]] || DIFF_BIN="$(command -v diff 2>/dev/null || printf 'diff')"

apply_mutation() { # <sandbox 脚本文件> <anchor-file> <new-file> → 0=注入成功
  python3 - "$1" "$2" "$3" <<'PYEOF'
import sys
path, anchorf, newf = sys.argv[1:4]
src = open(path).read()
anchor = open(anchorf).read()
new = open(newf).read()
if anchor not in src:
    sys.stderr.write("mutation anchor not found in %s（被测脚本漂移？）\n" % path)
    sys.exit(3)
open(path, "w").write(src.replace(anchor, new, 1))
PYEOF
}

snapshot_scripts() { # <src-dir> <dst-dir>
  mkdir -p "$2"
  cp "$1"/*.sh "$2/" 2>/dev/null || true
}

# ---------------- 缺陷用例注册表 ----------------
# 每个用例 = （锚点块 → 替换块）+ 探针脚本；锚点未命中即 harness 报错（防漂移假绿）

load_mutation() { # <name> → 填充 TMP_ANCHOR / TMP_NEW；echo probe 文件名
  case "$1" in
    bp-notify-cfg-false-collapse)
      cat >"$TMP_ANCHOR" <<'AEOF'
cfg() {
  local v
  v="$(jq -r "$1" "$CONFIG" 2>/dev/null)"
  [[ -n "$v" && "$v" != "null" ]] && { echo "$v"; return; }
  echo "$2"
}
AEOF
      cat >"$TMP_NEW" <<'NEOF'
cfg() {
  jq -r "$1 // $2" "$CONFIG" 2>/dev/null
}
NEOF
      echo "bool-parse-notify-dry.sh" ;;
    bp-deep-gate-auto-collapse)
      cat >"$TMP_ANCHOR" <<'AEOF'
auto="$(jq -r '.auto_deep_check' "$CONFIG" 2>/dev/null)"
if [[ -z "$auto" || "$auto" == "null" ]]; then
  auto="true"
fi
AEOF
      cat >"$TMP_NEW" <<'NEOF'
auto="$(jq -r '.auto_deep_check // true' "$CONFIG" 2>/dev/null)"
NEOF
      echo "bool-parse-deep-gate.sh" ;;
    cwd-rundeepcheck-no-cd)
      cat >"$TMP_ANCHOR" <<'AEOF'
cd "$MARTIN" || exit 1
AEOF
      cat >"$TMP_NEW" <<'NEOF'
: # mutated: cd removed（launchd cwd=/ 仿真缺陷再现）
NEOF
      echo "cwd-dep-rundeepcheck.sh" ;;
    ld-send-fail-still-marks-pushed)
      cat >"$TMP_ANCHOR" <<'AEOF'
    _send "$body" "contrib-watch 告警" || rc=$?
AEOF
      cat >"$TMP_NEW" <<'NEOF'
    _send "$body" "contrib-watch 告警" || true
NEOF
      echo "ledger-send-fail-marks-pushed.sh" ;;
    ld-success-ack-unbound)
      cat >"$TMP_ANCHOR" <<'AEOF'
  # 双保险：exit 0 也要 success:true 才算投递成功
  if [[ "$(jq -r '.success // false' "$NOTIFY_SEND_LAST" 2>/dev/null)" != "true" ]]; then
    log "hermes send exit=0 但 success≠true（$(head -c 200 "$NOTIFY_SEND_LAST" 2>/dev/null)）"
    return 1
  fi
AEOF
      cat >"$TMP_NEW" <<'NEOF'
  : # mutated: success:true 双保险拆除
NEOF
      echo "ledger-success-ack-unbound.sh" ;;
    sm-invalid-transition-guard-removed)
      cat >"$TMP_ANCHOR" <<'AEOF'
  assert_transition "$cur" "$state"
AEOF
      cat >"$TMP_NEW" <<'NEOF'
  : # mutated: 迁移守卫拆除
NEOF
      echo "state-invalid-transition-writes.sh" ;;
    sm-validate-closed-set-shrunk)
      cat >"$TMP_ANCHOR" <<'AEOF'
    ["queued","deep-check","awaiting-approval","approved","revise","failed","shelved","expired","rejected","executed"] | index($s)) == null)] | length' "$QUEUE")
AEOF
      cat >"$TMP_NEW" <<'NEOF'
    ["queued"] | index($s)) == null)] | length' "$QUEUE")
NEOF
      echo "state-closed-set-validate.sh" ;;
    bk-quota-limit-removed)
      cat >"$TMP_ANCHOR" <<'AEOF'
  local max_alerts; max_alerts="$(cfg '.max_alert_pushes_per_day' '3')"
AEOF
      cat >"$TMP_NEW" <<'NEOF'
  local max_alerts; max_alerts="99999"
NEOF
      echo "bookkeeping-quota-limit-removed.sh" ;;
    bk-dedup-key-check-removed)
      cat >"$TMP_ANCHOR" <<'AEOF'
  if grep -qF "\"key\":\"$key\"" "$EVENTS" 2>/dev/null; then
    log "event $key 已在账（幂等跳过）"
    return 0
  fi
AEOF
      cat >"$TMP_NEW" <<'NEOF'
  : # mutated: 同 key 幂等去重拆除
NEOF
      echo "bookkeeping-dedup-key-check-removed.sh" ;;
    bk-retry-attempts-bump-removed)
      cat >"$TMP_ANCHOR" <<'AEOF'
            o["attempts"] = o.get("attempts", 0) + 1
AEOF
      cat >"$TMP_NEW" <<'NEOF'
            pass  # mutated: 失败重试簿记拆除
NEOF
      echo "bookkeeping-retry-attempts-bump-removed.sh" ;;
    bk-alert-fallback-idempotency-removed)
      cat >"$TMP_ANCHOR" <<'AEOF'
    if (( maxed > 0 )) && [[ "$(state_get fallback_notice "$(today)")" != "1" ]]; then
AEOF
      cat >"$TMP_NEW" <<'NEOF'
    if (( maxed > 0 )); then
NEOF
      echo "bookkeeping-alert-fallback-idempotency-removed.sh" ;;
    *)
      echo "unknown case: $1" >&2
      return 1 ;;
  esac
}

class_cases() { # <class> → case 名列表（换行分隔）
  case "$1" in
    bool-parse)
      printf 'bp-notify-cfg-false-collapse\nbp-deep-gate-auto-collapse\n' ;;
    cwd-dep)
      printf 'cwd-rundeepcheck-no-cd\n' ;;
    ledger-vs-delivery)
      printf 'ld-send-fail-still-marks-pushed\nld-success-ack-unbound\n' ;;
    state-machine)
      printf 'sm-invalid-transition-guard-removed\nsm-validate-closed-set-shrunk\n' ;;
    bookkeeping)
      printf 'bk-quota-limit-removed\nbk-dedup-key-check-removed\nbk-retry-attempts-bump-removed\nbk-alert-fallback-idempotency-removed\n' ;;
    *)
      echo "unknown class: $1" >&2
      return 1 ;;
  esac
}

class_desc() {
  case "$1" in
    bool-parse) echo "config 布尔解析层塌缩（jq // 把 false 当 falsy → notify dry-run 静默化 / deep gate 开关失效）" ;;
    cwd-dep) echo "launchd cwd 依赖缺陷（run-deepcheck 缺 cd → claude 子进程 cwd=/ 找不到项目 skill）" ;;
    ledger-vs-delivery) echo "账面成功与实际送达分离（发送失败仍标 pushed / success 回执证据未绑定）" ;;
    state-machine) echo "状态机守卫拆除（非法迁移放行写入 / validate 状态闭集 schema 收缩误伤生产态）" ;;
    bookkeeping) echo "簿记回归（quota 限额、dedup 幂等、retry attempts、alert fallback 日幂等四处守卫拆除）" ;;
  esac
}

run_class() { # <class> → 0=全部 case pristine绿/mutated红/diff>=1
  local cls="$1" case_name probe all_ok=0
  local cases_json="" first=1
  PRISTINE_SNAP="$(mktemp -d "${TMPDIR:-/tmp}/contrib-pristine.XXXXXX")"
  SANDBOX_KEPT=""
  while IFS= read -r case_name; do
    [[ -z "$case_name" ]] && continue
    # 1) pristine 副本探针
    sb_new >/dev/null 2>&1 || { echo "detect: sandbox-fail" >&2; return 1; }
    local pristine_rc mutated_rc diff_lines
    bash "$PROBE_DIR/$(probe_of "$case_name")" >/dev/null 2>&1
    pristine_rc=$?
    rm -rf "$PRISTINE_SNAP"; snapshot_scripts "$SB_ROOT/scripts/contrib" "$PRISTINE_SNAP"
    sb_cleanup

    # 2) mutated 副本探针
    sb_new >/dev/null 2>&1 || { echo "detect: sandbox-fail" >&2; return 1; }
    probe="$(probe_of "$case_name")"
    local mfile
    mfile="$(mutation_target_file "$case_name")"
    load_mutation "$case_name" >/dev/null
    if ! apply_mutation "$SB_ROOT/scripts/contrib/$mfile" "$TMP_ANCHOR" "$TMP_NEW"; then
      echo "detect: [$case_name] 注入失败（锚点未命中）" >&2
      sb_cleanup
      return 1
    fi
    bash "$PROBE_DIR/$probe" >/dev/null 2>&1
    mutated_rc=$?
    diff_lines="$("$DIFF_BIN" -r "$PRISTINE_SNAP" "$SB_ROOT/scripts/contrib" 2>/dev/null | grep -c '^[<>]' || true)"
    [[ "$diff_lines" =~ ^[0-9]+$ ]] || diff_lines=0
    if [[ "${DETECT_KEEP:-}" == "1" ]]; then
      SANDBOX_KEPT="$SB_ROOT"
      echo "detect: [$case_name] mutated 沙箱保留于 ${SB_ROOT}（可 CONTRIB_TEST_TARGET=$SB_ROOT 复现）" >&2
      # 保留时禁用后续 sb_cleanup 对本沙箱的删除
      TESTS_KEEP=1 sb_cleanup
    else
      sb_cleanup
    fi

    # 3) 判定
    local case_ok=0
    [[ "$pristine_rc" -eq 0 && "$mutated_rc" -ne 0 && "$diff_lines" -ge 1 ]] && case_ok=1
    [[ $case_ok -eq 1 ]] || all_ok=1
    printf -v j '{\"name\":\"%s\",\"pristine_exit\":%d,\"mutated_exit\":%d,\"diff_lines\":%d}' \
      "$case_name" "$pristine_rc" "$mutated_rc" "$diff_lines"
    if [[ $first -eq 1 ]]; then
      cases_json="$cases_json$j"
      first=0
    else
      cases_json="$cases_json,$j"
    fi
    echo "detect: [$cls] $case_name pristine=$pristine_rc mutated=$mutated_rc diff=$diff_lines $([[ $case_ok -eq 1 ]] && echo OK || echo BROKEN)" >&2
  done < <(class_cases "$cls")
  CLASS_JSON="$cases_json"
  CLASS_SANDBOX="${SANDBOX_KEPT:-}"
  rm -rf "$PRISTINE_SNAP"
  return $all_ok
}

probe_of() {
  case "$1" in
    bp-notify-cfg-false-collapse) echo "bool-parse-notify-dry.sh" ;;
    bp-deep-gate-auto-collapse) echo "bool-parse-deep-gate.sh" ;;
    cwd-rundeepcheck-no-cd) echo "cwd-dep-rundeepcheck.sh" ;;
    ld-send-fail-still-marks-pushed) echo "ledger-send-fail-marks-pushed.sh" ;;
    ld-success-ack-unbound) echo "ledger-success-ack-unbound.sh" ;;
    sm-invalid-transition-guard-removed) echo "state-invalid-transition-writes.sh" ;;
    sm-validate-closed-set-shrunk) echo "state-closed-set-validate.sh" ;;
    bk-quota-limit-removed) echo "bookkeeping-quota-limit-removed.sh" ;;
    bk-dedup-key-check-removed) echo "bookkeeping-dedup-key-check-removed.sh" ;;
    bk-retry-attempts-bump-removed) echo "bookkeeping-retry-attempts-bump-removed.sh" ;;
    bk-alert-fallback-idempotency-removed) echo "bookkeeping-alert-fallback-idempotency-removed.sh" ;;
  esac
}

mutation_target_file() {
  case "$1" in
    bp-notify-cfg-false-collapse|ld-send-fail-still-marks-pushed|ld-success-ack-unbound|bk-quota-limit-removed|bk-dedup-key-check-removed|bk-retry-attempts-bump-removed|bk-alert-fallback-idempotency-removed)
      echo "notify.sh" ;;
    bp-deep-gate-auto-collapse) echo "deep_check_gate.sh" ;;
    cwd-rundeepcheck-no-cd) echo "run-deepcheck.sh" ;;
    sm-invalid-transition-guard-removed|sm-validate-closed-set-shrunk) echo "rq.sh" ;;
  esac
}

# ---------------- 入口 ----------------
overall=0
if [[ $# -ge 1 ]]; then
  CLASSES="$1"
else
  CLASSES="bool-parse cwd-dep ledger-vs-delivery state-machine bookkeeping"
fi

for cls in $CLASSES; do
  if ! class_cases "$cls" >/dev/null 2>&1; then
    echo "detect: 未知 class [$cls]（可选 bool-parse cwd-dep ledger-vs-delivery state-machine bookkeeping）" >&2
    exit 2
  fi
  run_class "$cls"
  rc=$?
  [[ $rc -ne 0 ]] && overall=1
  sandbox_json="null"
  if [[ -n "${CLASS_SANDBOX:-}" ]]; then
    printf -v sandbox_json '"%s"' "$CLASS_SANDBOX"
  fi
  printf '{"class":"%s","cases":[%s],"mutation_desc":"%s","sandbox":%s}\n' \
    "$cls" "${CLASS_JSON:-[]}" "$(class_desc "$cls")" "$sandbox_json"
done

exit $overall
