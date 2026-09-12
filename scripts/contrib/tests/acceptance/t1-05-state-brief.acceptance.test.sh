#!/usr/bin/env bash
# =============================================================================
# t1-05-state-brief.acceptance.test.sh — state_brief.sh 值班卡 state brief 黑盒验收
# 覆盖谓词（det-machine 锁定子集）：
#   P1  WHEN `bash scripts/contrib/state_brief.sh --selftest` THEN exit=0
#       ∧ stdout 含 `--selftest 全绿` ∧ 无 `- [FAIL] ` 行（另加 ≥1 条 [PASS] 防零断言空转假绿）
#   P2  WHEN 真库实跑 `bash scripts/contrib/state_brief.sh` THEN exit=0 ∧ 六节标题前缀
#       `## 1) `..`## 6) ` 各恰一次 ∧ 每节恰一行 `^- 伤情判定：`（纯结构断言，禁断言具体卡 id）
#   P6  `bash scripts/contrib/tests/gate.sh` exit=0 且末行含 `GATE: PASS`
#   P8  坏库 fixture（截断 sqlite 文件头 bytes 的假 db）经 seam 注入 → 对应节行含
#       `[degraded]` ∧ 整体 exit=0（contrib 库→S1 / 主库→S2 两形态）
#   P10 WHEN `--out <tmpfile>` THEN tmpfile 内容与 stdout diff 为空
# Mutation-Survival fixture 矩阵（No-op 五问逐项落地）：
#   MX-S1 孤儿命中：status=blocked 卡提及 rq（ready-queue 中该 rq state=executed 全部终态）
#   MX-S2 ready+gave_up 命中（单卡 2 条 task_events gave_up，契约「某卡 ≥2 次」→告警；
#         kill「只按 status 过滤」No-op）+ gave_up×1 反向（不得告警）
#   MX-S3 approved 与 awaiting-approval 双形态进 S3；终态 executed 项必须被排除
#   MX-S4 budget 余量数值双向：9/10（余量 10%≤20%）→注意；1/10（余量 90%）→正常
#   MX-S5 flight 泄漏命中（登记卡不在板）+ 深检单飞槽命中（deepcheck 卡在板且 blocked）
#   MX-S6 events 双序列化形态（jq 紧凑 vs python json.dumps 带空格）双类计数→告警；
#         仅 >24h premise-dead 反向（24h 窗→正常）
#   MX0 零病理基线：全空 fixture → 总览行逐字 `总伤情：告警×0 注意×0 正常×6` 且零 degraded
#   MX-immutable-fallback 主库 WAL 形态（WAL 头、无 -wal/-shm 旁文件=生产主 board 真实
#         只读形态）immutable=1 回退读取：S2 非 [degraded] ∧ 与 delete 形态同内容库的
#         S2「计数：」「伤情判定：」行逐字节相等 ∧ 种子卡 id 双侧 S2 同现
#   唯一标记契约：孤儿命中断言只用「存在孤儿卡（§0 病例②）」「｜孤儿（所提 rq 全部终态」
#         两唯一标记，禁裸 token「孤儿」（S1 注意分支文案含该词——M-A 假绿根因）
#   用法错误闭集：未知 flag / --out 缺参 / --out 落盘失败 → exit 2
# SSOT：预注册验收谓词（autopilot 红队任务书全文=设计文档）+ 其 md 机器锚定字面量节
# 纪律：黑盒——对被测脚本全部观测仅经 `bash scripts/contrib/state_brief.sh`（exit/stdout），
#       绝不读其实现源码；fixture 经 STATE_BRIEF_CONTRIB_DB / STATE_BRIEF_MAIN_DB /
#       CONTRIB_DATA_DIR 三个 env seams 注入 mktemp 树（生产六源零写入零污染，真库实跑仅只读）；
#       fixture 时间一律运行时 date 相对构造（近 24h 内）；无 warn/skip 宽容，
#       任一硬断言失败立即 die 非零。bash 3.2 兼容；变量一律 ${var} 花括号形态。
# 产物：/tmp/autopilot-artifacts/t1-05.*.out
# =============================================================================
set -u

REPO_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel 2>/dev/null || echo "${MARTIN_DIR:-$HOME/workspace/martin}")"
SB="${REPO_ROOT}/scripts/contrib/state_brief.sh"
GATE="${REPO_ROOT}/scripts/contrib/tests/gate.sh"
ART="/tmp/autopilot-artifacts"
TMPBASE="${TMPDIR:-/tmp}"
mkdir -p "${ART}"

die(){ echo "ACCEPTANCE-FAIL[$1]: $2" >&2; exit 1; }
eq(){ [ "$1" = "$2" ] || die "$3" "期望 [$2] 实得 [$1]"; }
ne(){ [ "$1" != "$2" ] || die "$3" "期望 != [$2]，实得相等 [$1]"; }
ge(){ case "${1:-}" in ''|*[!0-9]*) die "$3" "非数值 [$1]（期望 >= ${2}）";; esac; [ "$1" -ge "$2" ] || die "$3" "期望 >= $2 实得 [$1]"; }
has(){ printf '%s' "$1" | grep -qF -- "$2" || die "$3" "未包含 [$2]（实际前 240 字节：$(printf '%s' "$1" | head -c 240)）"; }
hasnt(){ if printf '%s' "$1" | grep -qF -- "$2"; then die "$3" "不应包含却包含 [$2]"; fi; }
has_re(){ printf '%s' "$1" | grep -qE -- "$2" || die "$3" "未匹配正则 [$2]"; }
hasnt_re(){ if printf '%s' "$1" | grep -qE -- "$2"; then die "$3" "不应匹配却匹配 [$2]"; fi; }

# ---- 环境前提（fail closed，禁静默 skip） ----
for t in sqlite3 jq date grep awk; do
  command -v "${t}" >/dev/null 2>&1 || die "env" "本机缺 ${t}（fixture 构造依赖）"
done
[ -f "${SB}" ] || die "env" "被测脚本不存在（实现未合流？）: ${SB}"
[ -f "${GATE}" ] || die "env" "gate.sh 缺失: ${GATE}"

# ---- 运行时时间锚（禁日期钉死；近 24h 相对构造） ----
NOW="$(date +%s)"
DAY="$(date '+%Y-%m-%d')"
WEEK="$(date '+%G-W%V')"
DSTAMP="$(date '+%Y%m%d')"
ERR="$(mktemp "${TMPBASE}/t1-05-err.XXXXXX")" || die "env" "mktemp err 失败"

art(){ # art <artifact 名> <rc> <stdout> —— 三段式留证（stderr 另见 t1-05-err）
  { printf 'exit=%s\n--- stdout ---\n' "$2"; printf '%s\n' "$3"; } > "${ART}/$1"
}

# ---- fixture 工厂（宿主进程执行；写面仅 mktemp 树） ----
mk_board(){ # <db> — 空板（schema 镜像生产 kanban.db tasks/task_events 关键列）
  sqlite3 "$1" <<'SQL'
CREATE TABLE tasks (
  id TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT, assignee TEXT,
  status TEXT NOT NULL, priority INTEGER DEFAULT 0, created_by TEXT,
  created_at INTEGER NOT NULL, started_at INTEGER, completed_at INTEGER,
  workspace_kind TEXT NOT NULL DEFAULT 'scratch', workspace_path TEXT,
  branch_name TEXT, project_id TEXT, result TEXT, idempotency_key TEXT
);
CREATE TABLE task_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT NOT NULL, run_id INTEGER,
  kind TEXT NOT NULL, payload TEXT, created_at INTEGER NOT NULL
);
SQL
}
add_card(){ # <db> <id> <status> <assignee> <age_secs> <title> <body>
  local db="$1" id="$2" st="$3" as="$4" age="$5" ti="$6" bo="$7" ts
  ts=$(( NOW - age ))
  sqlite3 "${db}" "INSERT INTO tasks (id,title,body,assignee,status,created_by,created_at,workspace_kind) VALUES ('${id}','${ti}','${bo}','${as}','${st}','redteam',${ts},'scratch');"
}
add_event(){ # <db> <task_id> <kind> <age_secs> <payload>
  local db="$1" tid="$2" kind="$3" age="$4" pl="$5" ts
  ts=$(( NOW - age ))
  sqlite3 "${db}" "INSERT INTO task_events (task_id,kind,payload,created_at) VALUES ('${tid}','${kind}','${pl}',${ts});"
}
mk_budget(){ # <cdata-dir> <day_used> <week_used> — limits 定为 day=10 week=50（余量数值可 Arithmetic）
  local d="$1" du="$2" wu="$3"
  jq -n --arg day "${DAY}" --arg week "${WEEK}" --argjson du "${du}" --argjson wu "${wu}" \
    '{limits:{day:10,week:50},days:{($day):{used:$du,items:["fx-budget-item"]}},weeks:{($week):{used:$wu,items:["fx-budget-item"]}},probes:{($day):{used:0,items:[]}}}' \
    > "${d}/budget.json" || die "fx" "budget.json 写入失败"
}
mk_cdata(){ # <cdata-dir> — 零病理 contrib-data（空队列/零用量/空事件）
  local d="$1"
  jq -n --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%S+0000')" '{version:1,updated:$ts,items:[]}' > "${d}/ready-queue.json" || die "fx" "ready-queue.json 写入失败"
  mk_budget "${d}" 0 0
  : > "${d}/events.jsonl"
}
rq_add(){ # <rq.json> <id> <state>
  local f="$1" id="$2" st="$3" tmp
  tmp="${f}.tmp.$$"
  jq --arg id "${id}" --arg st "${st}" --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%S+0000')" \
    '.items += [{id:$id,state:$st,title:("fx "+$id),source:"scan",lane:"deep",disposition:"own-PR",queued_at:$ts,history:[]}]' \
    "${f}" > "${tmp}" || die "fx" "rq_add 失败: ${id}"
  mv "${tmp}" "${f}"
}
flight_scan(){ # <cdata-dir> <card_id> — kanban-flight-scan.json
  jq -n --arg c "$2" '{kind:"scan",card_id:$c,batch_file:"",created_epoch:0}' > "$1/kanban-flight-scan.json" || die "fx" "flight-scan 写入失败"
}
flight_deep(){ # <cdata-dir> <card_id> <rq_id> — kanban-flight-deepcheck.json
  jq -n --arg c "$2" --arg r "$3" '{kind:"deepcheck",card_id:$c,rq_id:$r,lane:"deep",batch_file:"",created_epoch:0}' > "$1/kanban-flight-deepcheck.json" || die "fx" "flight-deep 写入失败"
}
ev_add(){ # <events.jsonl> <class> <key> <summary> <hours_ago> <compact|spaced> — 双序列化形态
  local f="$1" cls="$2" key="$3" sum="$4" hrs="$5" mode="$6" ts
  ts="$(date -u -v-"${hrs}"H '+%Y-%m-%dT%H:%M:%S+0000')"
  if [ "${mode}" = "spaced" ]; then
    # python json.dumps 默认分隔符形态（冒号/逗号后带空格）——禁单形态 grep 的历史坑样本
    printf '{"ts": "%s", "class": "%s", "key": "%s", "channel": "contrib", "summary": "%s", "pushed": false, "attempts": 0, "pushed_at": null}\n' \
      "${ts}" "${cls}" "${key}" "${sum}" >> "${f}"
  else
    jq -cn --arg ts "${ts}" --arg cls "${cls}" --arg key "${key}" --arg sum "${sum}" \
      '{ts:$ts,class:$cls,key:$key,channel:"contrib",summary:$sum,pushed:false,attempts:0,pushed_at:null}' >> "${f}"
  fi
}
mk_fx(){ # → fixture 根（三 seam 完整形态：空板×2 + 零病理 contrib-data）
  local r
  r="$(mktemp -d "${TMPBASE}/t1-05-fx.XXXXXX")" || die "fx" "mktemp 失败"
  mkdir -p "${r}/contrib" "${r}/main" "${r}/contrib-data" || die "fx" "mkdir 失败"
  mk_board "${r}/contrib/kanban.db"
  mk_board "${r}/main/kanban.db"
  mk_cdata "${r}/contrib-data"
  printf '%s' "${r}"
}
mk_board_wal(){ # <db> — WAL 形态空板（schema 同 mk_board；PRAGMA journal_mode=WAL 建库，
  # 对应生产主 board 真实只读形态）。注意：此后的 sqlite3 写入（add_card 种子等）会重建
  # -wal/-shm 旁文件，故 checkpoint(TRUNCATE)+rm+形态自证不在本工厂内做，而由 wal_seal
  # 在场景内「最后一次库写入之后」调用。
  sqlite3 "$1" >/dev/null <<'SQL'
PRAGMA journal_mode=WAL;
CREATE TABLE tasks (
  id TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT, assignee TEXT,
  status TEXT NOT NULL, priority INTEGER DEFAULT 0, created_by TEXT,
  created_at INTEGER NOT NULL, started_at INTEGER, completed_at INTEGER,
  workspace_kind TEXT NOT NULL DEFAULT 'scratch', workspace_path TEXT,
  branch_name TEXT, project_id TEXT, result TEXT, idempotency_key TEXT
);
CREATE TABLE task_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT NOT NULL, run_id INTEGER,
  kind TEXT NOT NULL, payload TEXT, created_at INTEGER NOT NULL
);
SQL
}
wal_seal(){ # <db> <场景名> — 最后一次库写入之后：checkpoint(TRUNCATE)+rm -wal/-shm 旁文件
  # （本机 sqlite3 CLI 干净退出不删旁文件——实测残留；旁文件在则 mode=ro 可开、回退空转）
  # + 写后跑前形态自证：mode=ro 必败 ∧ immutable=1 必成，否则 die（防 fixture 形态漂移假绿/假红）
  local db="$1" p="$2"
  sqlite3 "${db}" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null 2>&1
  rm -f "${db}-wal" "${db}-shm"
  if sqlite3 "file:${db}?mode=ro" 'SELECT count(*) FROM tasks;' >/dev/null 2>&1; then
    die "${p}" "WAL 形态自证败：mode=ro 竟可开（旁文件未清，immutable 回退将空转）: ${db}"
  fi
  if ! sqlite3 "file:${db}?mode=ro&immutable=1" 'SELECT count(*) FROM tasks;' >/dev/null 2>&1; then
    die "${p}" "WAL 形态自证败：immutable=1 打不开: ${db}"
  fi
}
cleanup_trees(){ for d in "$@"; do [ -n "${d}" ] && [ -d "${d}" ] && rm -rf "${d}"; done; }

# ---- 黑盒运行器（stdout 承载；stderr 落 ${ERR}；rc 走 $?） ----
run_sb(){ # <errfile> [args...] → 生产默认态（unset 全部 seams + MARTIN_DIR，真库只读）
  local ef="$1"; shift
  env -u MARTIN_DIR -u STATE_BRIEF_CONTRIB_DB -u STATE_BRIEF_MAIN_DB -u CONTRIB_DATA_DIR \
    bash "${SB}" "$@" 2>"${ef}"
}
run_sb_fx(){ # <errfile> <fxroot> [args...] → 三 seam 注入 fixture 树
  local ef="$1" fx="$2"; shift 2
  env -u MARTIN_DIR \
    "STATE_BRIEF_CONTRIB_DB=${fx}/contrib/kanban.db" \
    "STATE_BRIEF_MAIN_DB=${fx}/main/kanban.db" \
    "CONTRIB_DATA_DIR=${fx}/contrib-data" \
    bash "${SB}" "$@" 2>"${ef}"
}

# ---- md 结构断言工具（机器锚定字面量） ----
section(){ # <md> <n> → 第 n) 节块（标题行后至下一节标题前）
  printf '%s\n' "$1" | awk -v n="$2" 'index($0, "## " n ") ") == 1 {p=1; next} /^## / {p=0} p'
}
ovr(){ # <md> → 总览行
  printf '%s\n' "$1" | grep -F -- '总伤情：' | head -n 1
}
verify_structure(){ # <label> <md> — P2 结构谓词复用面：六节标题各恰一次 + 每节恰一行判定行 + 总览行格式
  local lbl="$1" md="$2" i cnt blk jn
  for i in 1 2 3 4 5 6; do
    cnt="$(printf '%s\n' "${md}" | grep -cF -- "## ${i}) ")"
    eq "${cnt}" "1" "${lbl} 节标题前缀 ## ${i}) 恰一次"
    blk="$(section "${md}" "${i}")"
    jn="$(printf '%s\n' "${blk}" | grep -c -- '^- 伤情判定：')"
    eq "${jn}" "1" "${lbl} 节 ${i}) 恰一行 ^- 伤情判定："
  done
  jn="$(printf '%s\n' "${md}" | grep -c -- '^- 伤情判定：')"
  eq "${jn}" "6" "${lbl} 全文判定行恰 6"
  has_re "$(ovr "${md}")" '^总伤情：告警×[0-9]+ 注意×[0-9]+ 正常×[0-9]+( degraded×[0-9]+)?$' "${lbl} 总览行格式"
}

# =============================================================================
# MX-S1 — 孤儿命中：blocked 卡提及 rq，而该 rq 在 ready-queue 全部终态（executed）
#   kill 无孤儿检测 No-op / 只按 status 过滤 No-op
#   唯一标记契约：断言只用「存在孤儿卡（§0 病例②）」（判定行 reason）与
#   「｜孤儿（所提 rq 全部终态」（卡行后缀）两唯一标记，禁裸 token「孤儿」——
#   S1 注意分支生产文案（未触发孤儿/深检槽/超龄任一）也含该词，正/负样本撞车
#   即 M-A 假绿根因（父卡 t_582e238b mutation 自证实证）。
#   顺序理由（fail-fast 首死归因）：本场景是 M-A mutant（RQ_TERMINAL_RE 改坏）的直接
#   命中场景，置于 P1（selftest 全绿门）之前——acceptance fail-fast 首死必须落在咬合
#   场景本身，而非被同层防御层 P1 掩盖成 FAIL[P1]（注入必须剥离同类防御层，
#   patterns.md 2026-09-05）。
# =============================================================================
P="MX-S1-orphan"
RQ_ORPH="rq-${DSTAMP}-010101"
FX="$(mk_fx)"
add_card "${FX}/contrib/kanban.db" "t_fxorph1" "blocked" "contrib" 3600 \
  "深检 preflight ${RQ_ORPH} [deep]" "rq-id: ${RQ_ORPH}"
rq_add "${FX}/contrib-data/ready-queue.json" "${RQ_ORPH}" "executed"
OUT="$(run_sb_fx "${ERR}" "${FX}")"; RC=$?
art "t1-05.mx-s1.orphan.out" "${RC}" "${OUT}"
eq "${RC}" "0" "${P} exit=0"
verify_structure "${P}" "${OUT}"
S1BLK="$(section "${OUT}" "1")"
has "${S1BLK}" "存在孤儿卡（§0 病例②）" "${P} S1 判定行含孤儿唯一标记[存在孤儿卡（§0 病例②）]"
has "${S1BLK}" "｜孤儿（所提 rq 全部终态" "${P} S1 卡行含孤儿唯一后缀标记[｜孤儿（所提 rq 全部终态]"
has "${S1BLK}" "t_fxorph1" "${P} S1 卡清单含孤儿卡 t_fxorph1"
cleanup_trees "${FX}"
echo "PASS ${P}"

# =============================================================================
# MX-immutable-fallback — 主库 WAL 形态（WAL 头、无 -wal/-shm 旁文件=生产主 board
#   真实只读形态）下 immutable=1 回退读取：与 delete 形态同内容库对照，S2 读数一致。
#   kill 回退路径 No-op：immutable 改坏（→immutable=0）→ WAL 树 S2 [degraded] 且读数不等。
#   断言（契约 1:1）：(a) WAL 树 S2 无 [degraded]；(b) 两树 S2「计数：」行与
#   「伤情判定：」行逐字节相等（时间相关字段不比对，防 flaky）；(c) 种子卡 id 双侧 S2 同现。
#   种子卡不提及任何 rq id（防 RQ_TERMINAL_RE mutant 波及本场景首死归因）。
#   顺序理由（fail-fast 首死归因）：本场景是 M-B mutant（immutable=1 改坏）的直接命中
#   场景，置于 P1 之前，理由同 MX-S1-orphan（patterns.md 2026-09-05）。
# =============================================================================
P="MX-immutable-fallback"
FXA="$(mk_fx)"
FXB="$(mk_fx)"
rm -f "${FXB}/main/kanban.db"
mk_board_wal "${FXB}/main/kanban.db"
add_card "${FXA}/main/kanban.db" "t_fxwal1" "ready" "contrib" 1800 "fx immutable 回退种子卡" "fx 种子正文不含 rq"
add_card "${FXB}/main/kanban.db" "t_fxwal1" "ready" "contrib" 1800 "fx immutable 回退种子卡" "fx 种子正文不含 rq"
wal_seal "${FXB}/main/kanban.db" "${P}"
OUTA="$(run_sb_fx "${ERR}" "${FXA}")"; RCA=$?
OUTB="$(run_sb_fx "${ERR}" "${FXB}")"; RCB=$?
art "t1-05.mx-immutable-fallback.delete.out" "${RCA}" "${OUTA}"
art "t1-05.mx-immutable-fallback.wal.out" "${RCB}" "${OUTB}"
eq "${RCA}" "0" "${P} delete 形态树 exit=0"
eq "${RCB}" "0" "${P} WAL 形态树 exit=0"
verify_structure "${P}" "${OUTB}"
S2A="$(section "${OUTA}" "2")"
S2B="$(section "${OUTB}" "2")"
hasnt "${S2B}" "[degraded]" "${P} WAL 形态树 S2 无 [degraded]（immutable=1 回退成功）"
has "${S2B}" "t_fxwal1" "${P} WAL 形态树 S2 含种子卡 t_fxwal1（回退读数正确性）"
has "${S2A}" "t_fxwal1" "${P} delete 形态树 S2 含种子卡 t_fxwal1（对照面）"
eq "$(printf '%s\n' "${S2A}" | grep -F -- '计数：')" "$(printf '%s\n' "${S2B}" | grep -F -- '计数：')" "${P} 两树 S2 计数行逐字节相等"
eq "$(printf '%s\n' "${S2A}" | grep -F -- '伤情判定：')" "$(printf '%s\n' "${S2B}" | grep -F -- '伤情判定：')" "${P} 两树 S2 伤情判定行逐字节相等"
cleanup_trees "${FXA}" "${FXB}"
echo "PASS ${P}"

# =============================================================================
# P1 — --selftest 全绿
# =============================================================================
P="P1"
OUT="$(run_sb "${ERR}" --selftest)"; RC=$?
art "t1-05.p1.selftest.out" "${RC}" "${OUT}"
eq "${RC}" "0" "${P} --selftest exit（契约：全绿=0）"
has "${OUT}" "--selftest 全绿" "${P} 收尾字面量 --selftest 全绿"
hasnt "${OUT}" "- [FAIL] " "${P} 零 - [FAIL] 断言行"
PASSN="$(printf '%s\n' "${OUT}" | grep -c -- '^- \[PASS\] ')"
ge "${PASSN}" "1" "${P} 至少一条 - [PASS] 断言行（防零断言空转假绿）"
echo "PASS ${P}"

# =============================================================================
# P2 — 真库实跑：exit=0 + 六节结构（纯结构断言，禁断言具体卡 id）
# =============================================================================
P="P2"
PROD_CB="${HOME}/.hermes/kanban/boards/contrib/kanban.db"
PROD_MB="${HOME}/.hermes/kanban.db"
PROD_CD="${MARTIN_DIR:-${HOME}/workspace/martin}/contrib-data"
[ -f "${PROD_CB}" ] || die "env" "生产 contrib 板缺失: ${PROD_CB}"
[ -f "${PROD_MB}" ] || die "env" "生产主板缺失: ${PROD_MB}"
[ -d "${PROD_CD}" ] || die "env" "生产 contrib-data 缺失: ${PROD_CD}"
OUT="$(run_sb "${ERR}")"; RC=$?
art "t1-05.p2.real.out" "${RC}" "${OUT}"
eq "${RC}" "0" "${P} 真库实跑 exit=0"
verify_structure "${P}" "${OUT}"
echo "PASS ${P}"

# =============================================================================
# P6 — gate.sh 全绿
# =============================================================================
P="P6"
GOUT="$(bash "${GATE}" 2>"${ERR}")"; RC=$?
art "t1-05.p6.gate.out" "${RC}" "${GOUT}"
eq "${RC}" "0" "${P} gate.sh exit=0"
GLAST="$(printf '%s\n' "${GOUT}" | tail -n 1)"
has "${GLAST}" "GATE: PASS" "${P} 末行含 GATE: PASS（实得末行：${GLAST}）"
echo "PASS ${P}"

# =============================================================================
# P8 — 坏库 fail-closed 降级（contrib 库→S1 / 主库→S2；exit 恒 0）
# =============================================================================
mk_baddb(){ # <好库路径> — 截断 sqlite 文件头 bytes 的假 db（并自证已不可读通）
  local good="$1" bad="$2"
  head -c 32 "${good}" > "${bad}.trunc" && mv "${bad}.trunc" "${bad}"
  if sqlite3 "${bad}" 'SELECT COUNT(*) FROM tasks;' >/dev/null 2>&1; then
    die "P8" "截断假库仍可被 sqlite3 读通（缺陷样本无效）: ${bad}"
  fi
}
P="P8a"
FX="$(mk_fx)"
mk_baddb "${FX}/contrib/kanban.db" "${FX}/contrib/kanban.db"
OUT="$(run_sb_fx "${ERR}" "${FX}")"; RC=$?
art "t1-05.p8a.badcontrib.out" "${RC}" "${OUT}"
eq "${RC}" "0" "${P} 坏 contrib 库整体 exit（契约：含 degraded 亦 0）"
S1BLK="$(section "${OUT}" "1")"
has "${S1BLK}" "[degraded]" "${P} S1 判定行含 [degraded]（fail-closed 降级）"
has_re "$(ovr "${OUT}")" 'degraded×[1-9][0-9]*' "${P} 总览行 degraded×D 尾缀（D>=1）"
cleanup_trees "${FX}"
echo "PASS ${P}"

P="P8b"
FX="$(mk_fx)"
mk_baddb "${FX}/main/kanban.db" "${FX}/main/kanban.db"
OUT="$(run_sb_fx "${ERR}" "${FX}")"; RC=$?
art "t1-05.p8b.badmain.out" "${RC}" "${OUT}"
eq "${RC}" "0" "${P} 坏主库整体 exit（契约：含 degraded 亦 0）"
S2BLK="$(section "${OUT}" "2")"
has "${S2BLK}" "[degraded]" "${P} S2 判定行含 [degraded]（fail-closed 降级）"
cleanup_trees "${FX}"
echo "PASS ${P}"

# =============================================================================
# P10 — --out <tmpfile>：tmpfile 与 stdout diff 为空（字节级双文件 diff，规避 $() 尾换行剥离）
# =============================================================================
P="P10"
FX="$(mk_fx)"
OUTF="${ART}/t1-05.p10.outfile.md"
run_sb_fx "${ERR}" "${FX}" --out "${OUTF}" > "${ART}/t1-05.p10.stdout.md"; RC=$?
eq "${RC}" "0" "${P} --out exit=0"
[ -s "${OUTF}" ] || die "${P}" "--out 落盘文件缺失/空: ${OUTF}"
DIFFRC=0
/usr/bin/diff "${ART}/t1-05.p10.stdout.md" "${OUTF}" > "${ART}/t1-05.p10.diff.txt" 2>&1 || DIFFRC=$?
eq "${DIFFRC}" "0" "${P} tmpfile 与 stdout diff 为空"
cleanup_trees "${FX}"
echo "PASS ${P}"

# =============================================================================
# 用法错误闭集 — 未知 flag / --out 缺参 / --out 落盘失败 → exit 2
# =============================================================================
P="P-usage"
FX="$(mk_fx)"
OUT="$(run_sb_fx "${ERR}" "${FX}" --totally-bogus-flag)"; RC=$?
eq "${RC}" "2" "${P} 未知 flag → exit 2"
OUT="$(run_sb_fx "${ERR}" "${FX}" --out)"; RC=$?
eq "${RC}" "2" "${P} --out 缺参 → exit 2"
OUT="$(run_sb_fx "${ERR}" "${FX}" --out "${TMPBASE}/t1-05-no-such-dir-$$/x.md")"; RC=$?
eq "${RC}" "2" "${P} --out 落盘失败（目录不存在）→ exit 2"
cleanup_trees "${FX}"
echo "PASS ${P}"

# =============================================================================
# MX0 — 零病理基线：全空 fixture → 总览行逐字 + 六节全正常 + 零降级（fixture 管线对照面）
# =============================================================================
P="MX0-baseline"
FX="$(mk_fx)"
OUT="$(run_sb_fx "${ERR}" "${FX}")"; RC=$?
art "t1-05.mx0.baseline.out" "${RC}" "${OUT}"
eq "${RC}" "0" "${P} 基线 exit=0"
verify_structure "${P}" "${OUT}"
has "$(ovr "${OUT}")" "总伤情：告警×0 注意×0 正常×6" "${P} 零病理总览行逐字（六节全正常）"
hasnt "${OUT}" "[degraded]" "${P} 健康基线零降级标记"
hasnt_re "${OUT}" '^- 伤情判定：告警' "${P} 基线无任何节告警"
# fixture 自身可读性（sqlite/jq 读通；防 fixture 静默腐坏）
eq "$(sqlite3 "${FX}/contrib/kanban.db" 'SELECT COUNT(*) FROM tasks;')" "0" "${P} fixture contrib 板可读（0 卡）"
jq -e . "${FX}/contrib-data/ready-queue.json" >/dev/null 2>&1 || die "${P}" "fixture ready-queue.json 不可读"
jq -e . "${FX}/contrib-data/budget.json" >/dev/null 2>&1 || die "${P}" "fixture budget.json 不可读"
cleanup_trees "${FX}"
echo "PASS ${P}"

# =============================================================================
# MX-S2 — ready+gave_up 命中：主板 assignee=contrib status=ready 单卡 2 条
#   task_events kind=gave_up（契约「某卡 gave_up ≥2 次」→ 告警）；kill「只按 status 过滤」
#   No-op + 阈值 No-op。
#   [2026-09-13 编排裁决·红队铁律例外 E1-E3 留痕] 原稿为双卡各 1 事件、按聚合计数断言告警，
#   与契约字面「某卡 gave_up ≥2 次」（§0 病例③ 日报卡秒崩×2=同卡连崩）矛盾：跨卡聚合会把
#   两张卡各崩一次误报成崩溃循环（假阳性伤害值班环信噪比）。证据链：E1 断言≠契约字面 /
#   E2 契约语义源 §0 病例③ 为同卡 / E3 实现与契约一致且真库 t_92c903b0 gave_up×1→注意命中
#   清单符合「命中即可」验收口径。单事件反向用例由 MX-S2-gaveup1-negative 保留。
# =============================================================================
P="MX-S2-ready-gaveup"
FX="$(mk_fx)"
add_card "${FX}/main/kanban.db" "t_fxgx1" "ready" "contrib" 1800 "fx gave_up ready 秒崩卡" "fx"
add_event "${FX}/main/kanban.db" "t_fxgx1" "gave_up" 1500 '{"failures":1,"error":"fx"}'
add_event "${FX}/main/kanban.db" "t_fxgx1" "gave_up" 300 '{"failures":2,"error":"fx"}'
OUT="$(run_sb_fx "${ERR}" "${FX}")"; RC=$?
art "t1-05.mx-s2.gaveup.out" "${RC}" "${OUT}"
eq "${RC}" "0" "${P} exit=0"
verify_structure "${P}" "${OUT}"
S2BLK="$(section "${OUT}" "2")"
has "${S2BLK}" "gave_up" "${P} S2 含 gave_up 事件统计（域关键词）"
has "${S2BLK}" "gave_up×2" "${P} S2 计数 gave_up×2（同卡 2 次恰达告警阈值，防 ×0/×1 空转命中）"
has "${S2BLK}" "t_fxgx1" "${P} S2 含 ready 态 gave_up 卡 t_fxgx1（事件面穿透 status 过滤）"
has_re "${S2BLK}" '^- 伤情判定：告警 ——' "${P} S2 判定=告警（同卡 gave_up ×2 ≥ 阈值，契约「某卡 gave_up ≥2 次」）"
cleanup_trees "${FX}"
echo "PASS ${P}"

# MX-S2 反向：gave_up 事件计数=1（<2 阈值）→ 不得告警（kill 阈值恒告警 No-op）
P="MX-S2-gaveup1-negative"
FX="$(mk_fx)"
add_card "${FX}/main/kanban.db" "t_fxgx3" "ready" "contrib" 1800 "fx gave_up 单事件卡" "fx"
add_event "${FX}/main/kanban.db" "t_fxgx3" "gave_up" 1500 '{"failures":1,"error":"fx"}'
OUT="$(run_sb_fx "${ERR}" "${FX}")"; RC=$?
art "t1-05.mx-s2.gaveup1.out" "${RC}" "${OUT}"
eq "${RC}" "0" "${P} exit=0"
S2BLK="$(section "${OUT}" "2")"
hasnt_re "${S2BLK}" '^- 伤情判定：告警 ——' "${P} gave_up×1 未达阈值 → S2 判定非告警"
cleanup_trees "${FX}"
echo "PASS ${P}"

# =============================================================================
# MX-S3 — 悬空双形态：state=approved 与 state=awaiting-approval 均须进 S3；
#   终态 executed 项必须被排除（kill 只认 approved 单形态 / 全量透传 No-op）
# =============================================================================
P="MX-S3-dangling"
RQ_A="rq-${DSTAMP}-030101"
RQ_B="rq-${DSTAMP}-030202"
RQ_C="rq-${DSTAMP}-030303"
FX="$(mk_fx)"
rq_add "${FX}/contrib-data/ready-queue.json" "${RQ_A}" "approved"
rq_add "${FX}/contrib-data/ready-queue.json" "${RQ_B}" "awaiting-approval"
rq_add "${FX}/contrib-data/ready-queue.json" "${RQ_C}" "executed"
OUT="$(run_sb_fx "${ERR}" "${FX}")"; RC=$?
art "t1-05.mx-s3.dangling.out" "${RC}" "${OUT}"
eq "${RC}" "0" "${P} exit=0"
verify_structure "${P}" "${OUT}"
S3BLK="$(section "${OUT}" "3")"
has "${S3BLK}" "${RQ_A}" "${P} S3 含 approved 悬空项 ${RQ_A}"
has "${S3BLK}" "${RQ_B}" "${P} S3 含 awaiting-approval 悬空项 ${RQ_B}"
hasnt "${S3BLK}" "${RQ_C}" "${P} S3 排除终态项 ${RQ_C}（executed）"
cleanup_trees "${FX}"
echo "PASS ${P}"

# =============================================================================
# MX-S4 — budget 余量数值双向：9/10（当日余量 10%<=20%）→注意；1/10（90%）→正常
#   kill「恒正常」与「恒注意」双 No-op
# =============================================================================
P="MX-S4-budget-tight"
FX="$(mk_fx)"
mk_budget "${FX}/contrib-data" 9 9
OUT="$(run_sb_fx "${ERR}" "${FX}")"; RC=$?
art "t1-05.mx-s4.tight.out" "${RC}" "${OUT}"
eq "${RC}" "0" "${P} exit=0"
verify_structure "${P}" "${OUT}"
S4BLK="$(section "${OUT}" "4")"
has_re "${S4BLK}" '^- 伤情判定：注意 ——' "${P} 当日余量 10%（9/10）<=20% → S4 判定=注意"
cleanup_trees "${FX}"
echo "PASS ${P}"

P="MX-S4-budget-loose"
FX="$(mk_fx)"
mk_budget "${FX}/contrib-data" 1 1
OUT="$(run_sb_fx "${ERR}" "${FX}")"; RC=$?
art "t1-05.mx-s4.loose.out" "${RC}" "${OUT}"
eq "${RC}" "0" "${P} exit=0"
S4BLK="$(section "${OUT}" "4")"
has_re "${S4BLK}" '^- 伤情判定：正常 ——' "${P} 当日余量 90%（1/10）>20% → S4 判定=正常"
cleanup_trees "${FX}"
echo "PASS ${P}"

# =============================================================================
# MX-S5 — flight 残留双向：
#   a) 泄漏：kanban-flight-scan.json 登记卡不在板 → 「flight 泄漏」
#   b) 深检单飞槽：deepcheck 登记卡在板且 blocked → 「深检单飞槽」（且非泄漏）
# =============================================================================
P="MX-S5-flight-leak"
FX="$(mk_fx)"
flight_scan "${FX}/contrib-data" "t_fxleak1"
OUT="$(run_sb_fx "${ERR}" "${FX}")"; RC=$?
art "t1-05.mx-s5.leak.out" "${RC}" "${OUT}"
eq "${RC}" "0" "${P} exit=0"
verify_structure "${P}" "${OUT}"
S5BLK="$(section "${OUT}" "5")"
has "${S5BLK}" "flight 泄漏" "${P} S5 命中 flight 泄漏（登记卡不在板）"
has "${S5BLK}" "t_fxleak1" "${P} S5 泄漏项含登记卡 t_fxleak1"
cleanup_trees "${FX}"
echo "PASS ${P}"

P="MX-S5-deepcheck-slot"
RQ_SLOT="rq-${DSTAMP}-040404"
FX="$(mk_fx)"
add_card "${FX}/contrib/kanban.db" "t_fxslot1" "blocked" "contrib" 600 \
  "深检 preflight ${RQ_SLOT} [deep]" "rq-id: ${RQ_SLOT}"
rq_add "${FX}/contrib-data/ready-queue.json" "${RQ_SLOT}" "deep-check"
flight_deep "${FX}/contrib-data" "t_fxslot1" "${RQ_SLOT}"
OUT="$(run_sb_fx "${ERR}" "${FX}")"; RC=$?
art "t1-05.mx-s5.slot.out" "${RC}" "${OUT}"
eq "${RC}" "0" "${P} exit=0"
verify_structure "${P}" "${OUT}"
S5BLK="$(section "${OUT}" "5")"
has "${S5BLK}" "深检单飞槽" "${P} S5 命中深检单飞槽（登记卡 blocked 占用槽位）"
has "${S5BLK}" "t_fxslot1" "${P} S5 深检槽项含登记卡 t_fxslot1"
hasnt "${S5BLK}" "flight 泄漏" "${P} 在板 blocked 卡不构成 flight 泄漏（精确性反向）"
# 唯一标记负向锁（可分性谓词）：本场景卡提及的 rq 非终态（deep-check）→ 孤儿不触发。
# 观测块必须是 S1 节（禁施于 S5BLK——S5 节本就不含该标记，施于 S5 即真空断言）
S1BLK="$(section "${OUT}" "1")"
hasnt "${S1BLK}" "存在孤儿卡（§0 病例②）" "${P} S1 节无孤儿判定行唯一标记（提及 rq 非终态 → 孤儿不触发）"
cleanup_trees "${FX}"
echo "PASS ${P}"

# =============================================================================
# MX-S6 — events 24h 双向：
#   a) 近 24h 双序列化形态双类（jq 紧凑 pipeline-failure + python json.dumps 带空格
#      premise-dead）→ S6 命中两类且判定=告警（premise-dead 任意→告警）；
#      kill「单形态 grep」No-op（带空格形态漏检则 premise-dead 不可见/不告警）
#   b) 仅 >24h premise-dead → 24h 窗外 → 判定=正常（kill 忽略时间窗 No-op）
# =============================================================================
P="MX-S6-events-dual"
FX="$(mk_fx)"
ev_add "${FX}/contrib-data/events.jsonl" "pipeline-failure" "fx-evt-c" "fx compact pipeline-failure 样本" 2 "compact"
ev_add "${FX}/contrib-data/events.jsonl" "premise-dead" "fx-evt-s" "fx spaced premise-dead 样本" 1 "spaced"
OUT="$(run_sb_fx "${ERR}" "${FX}")"; RC=$?
art "t1-05.mx-s6.dual.out" "${RC}" "${OUT}"
eq "${RC}" "0" "${P} exit=0"
verify_structure "${P}" "${OUT}"
S6BLK="$(section "${OUT}" "6")"
has "${S6BLK}" "pipeline-failure×1" "${P} S6 计数 pipeline-failure×1（jq 紧凑形态，防 ×0 空转命中）"
has "${S6BLK}" "premise-dead×1" "${P} S6 计数 premise-dead×1（json.dumps 带空格形态，防 ×0 空转命中）"
has_re "${S6BLK}" '^- 伤情判定：告警 ——' "${P} S6 判定=告警（premise-dead 任意命中）"
cleanup_trees "${FX}"
echo "PASS ${P}"

P="MX-S6-events-window"
FX="$(mk_fx)"
ev_add "${FX}/contrib-data/events.jsonl" "premise-dead" "fx-evt-old" "fx 48h 前 premise-dead 样本" 48 "spaced"
OUT="$(run_sb_fx "${ERR}" "${FX}")"; RC=$?
art "t1-05.mx-s6.window.out" "${RC}" "${OUT}"
eq "${RC}" "0" "${P} exit=0"
S6BLK="$(section "${OUT}" "6")"
has_re "${S6BLK}" '^- 伤情判定：正常 ——' "${P} 仅 >24h premise-dead → 24h 窗外 → S6 判定=正常"
hasnt_re "${S6BLK}" '^- 伤情判定：告警 ——' "${P} 窗外事件不得触发告警"
cleanup_trees "${FX}"
echo "PASS ${P}"

echo "t1-05 state_brief 验收：全部场景通过"
exit 0
