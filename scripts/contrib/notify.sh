#!/bin/bash
# notify.sh — contrib-watch 事件与微信推送层
#
# 设计要点：
#   - events.jsonl 是唯一告警账本（同 key 幂等，推送状态在文件里，失败自然重试）
#   - **外发消息规范（09-05 用户拍板）**：禁止 raw dump 直推。flush 分两级——
#     ①机械事件（premise-dead/own-pr-activity/budget）→ 脚本渲染规范化模板卡
#       （同审批卡哲学：结构化=高效消费，不经 LLM）
#     ②叙事事件（pipeline-failure/未知类）→ AI 摘要层（claude -p 生成三段式人话）；
#       摘要失败=搁置重试，**永不降级回 raw dump**；3 败后 osascript 本地机械提示兜底
#   - 渠道隔离/分域标头：event 支持 --channel；渠道解析三段——显式 --channel（空串=未传）
#     > class→域映射（default_channel_for_class：flashcards 产线类 → flashcards）> 缺省 contrib。
#     flush 按账本中实际出现的渠道分渠成批（contrib / flashcards 各至多一条消息、各取自己的
#     报头与主题；机械批次=速报头、叙事/AI 摘要=告警头）；非 {contrib,flashcards} 渠道事件只入账，
#     不进任何 flush 批（归各自域的简报/AI 会话消费）
#   - flush 无内置定时器（run-watch 已于 09-13 退役）；调用面两路双保险——① hermes cron job
#     `3e5c6e23e260` 的 `script` 字段（`~/.hermes/scripts/contrib-flush.sh`，每小时机械调用，
#     09-14 落地）② operator 班次收班契约。聚合未推送告警为一条微信；防双发三重
#     （min_interval + 当日计数 + /tmp 锁）
#   - 审批推送（🟡 卡片）与告警分开计数；回执独立计数不占限额（审批卡=规范化模板，豁免 AI 整理）
#   - hermes send 失败链：重试 1 次 → 事件保留 → 累计 3 败 osascript 本地通知兜底
#   - 审批卡推送（09-07 双修①）：rc==1 失败原地退避重试（默认 3 次×35s，跨 iLink 30s cooldown，
#     seam NOTIFY_CARD_ATTEMPTS/NOTIFY_CARD_BACKOFF）
#   - claude -p 模型 pin（09-07 双修②）：--model 剥 [1m]/[1M] 后缀（seam CLAUDE_MODEL_PIN；
#     来源链 settings.json env > 运行时 env），运行时 ANTHROPIC_MODEL 同步 sanitize
#   - notify_dry_run=true 时只打印完整消息体与目标，不触 hermes/tunnel（AI 摘要照常生成）
#   - **审批交互路（approval_interactive=true，09-05 L2-A 短码批准）**：发卡前由机器稿生成人读页
#     `<draft>.page.md`（⓪ 页首 `<!-- twq:submit-top -->` 指令：名字栏+提交按钮置顶，tunnel-cli ≥1.9.0
#     服务端渲染剥离；① interactive fence：radio id:verdict 批准/否决/需修改 + text id:comment
#     ② 中文 BLUF 头 ③ premises 证据表 ④ 机器稿 verbatim 附录；机器稿本体零改动），部署走
#     `tunnel drops approve <page> --name <slug>`；slug=[a-z0-9]{10}、短码=[a-km-np-z2-9]{6}
#     （去 0/o/1/l），短码经 ?key= 自动回填审批页名字栏；卡片渲染卡 v2 模板。
#     **dry-run 登记语义**：NOTIFY_DRY_RUN=true 时跳过真实部署与发送，但 slug/code 生成与
#     `rq.sh tunnel-deploy`（合成 url）照常——沙箱链依赖此登记。
#     部署失败/开关非 true → 完整回退旧文本卡路（行为兼容）。
#   - 摘要卡化（T5）：叙事事件批 → contrib digest 卡（kanban 异步，worker 生成三段式摘要并经
#     notify.sh send-digest 唯一外发通道发送）；flight 登记同 kind 单飞；done+sent:true 消费轮
#     零账本动作（双写禁止）且本轮不建新卡（防卡风暴）；卡失败/stale → fallback_ai()（原 claude -p
#     内联摘要路整段保留为兜底，3 败 osascript 不变）。机械路径/_send/限额/channel 语义零变化
#   - 人门提醒（gate-remind，09-14 缺口根治）：flush 内机械检测 contrib 板 blocked 且超
#     gate_remind_hours 的 `[draft]`/`[fix]` 卡（人门卡在用户侧无送达面）→ 落 human-gate
#     事件（key=gate-<task_id>，账本 key 幂等）；config 缺 key = 关闭
#   - 测试沙箱：CONTRIB_DATA_DIR=<dir> 可把账本/配置整体指向临时目录
#   - 命令 seam：TUNNEL_BIN / HERMES_BIN / OSASCRIPT_BIN / GATEWAY_PROBE_BIN / CLAUDE_BIN
#
# 用法:
#   notify.sh event <class> --key K --summary S [--channel C]   # 渠道缺省按 class 域映射（contrib/flashcards）
#   notify.sh flush                                             # 分渠聚合推送（每域至多一条）
#   notify.sh resolve --key K --summary S [--cluster C]         # 闭环：标记 resolved + ✅ 收尾卡
#   notify.sh approve <id> | approve --all
#   notify.sh receipt <id> --summary S
#   notify.sh fallback <text>
#   notify.sh send-digest --digest <摘要文件> --batch <批次json>   # 输出闭集 OK/FAIL <原因>
set -uo pipefail

MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"
CONTRIB="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"
SELF_BIN="${NOTIFY_SELF_BIN:-$MARTIN/scripts/contrib/notify.sh}"   # 自递归调用（cmd_approve 内嵌 event 上报）；勿用 $NOTIFY——那是调用方视角变量，09-06 曾致 unbound crash
CONFIG="$CONTRIB/config.json"
QUEUE="$CONTRIB/ready-queue.json"
EVENTS="$CONTRIB/events.jsonl"
STATE="$CONTRIB/notify-state.json"
# 人门检测读的板库（contrib 域唯一目标板，只读）。直读板库、不走 hermes kanban CLI：
# CLI 在 delegated worker 上下文被 write fence 拒（原文「kanban: delegate_task child contexts
# cannot mutate Kanban tasks or boards」）⇒ 用它会把检测放进一个会静默失效的依赖里；
# 读法固定 `?immutable=1`（09-14 实测：同刻 immutable rc=0 / mode=ro rc=14「unable to open
# database file」，因板库为 WAL 且静止时刻无 -wal/-shm）。
GATE_DB="$HOME/.hermes/kanban/boards/contrib/kanban.db"
RQ="$MARTIN/scripts/contrib/rq.sh"
LOCK="${NOTIFY_LOCK:-/tmp/contrib-notify.lock}"
# 命令 seam（默认值=现状硬编码；测试套件经此注入影子 stub，生产语义零改变）
HERMES_BIN="${HERMES_BIN:-hermes}"
# tunnel CLI 装在 nvm node bin（launchd/cron PATH 极简找不到——09-06 实证：run-watch 触发的
# 审批卡因 command -v tunnel 落空而静默降级旧卡路，两连发 104067/103969）：
# env seam 优先 → PATH 查找 → nvm 布局探测，命中后 nvm bin 目录进 PATH（tunnel 包装脚本需 node 本体）
TUNNEL_BIN="${TUNNEL_BIN:-}"
if [[ -z "$TUNNEL_BIN" ]]; then
  TUNNEL_BIN="$(command -v tunnel 2>/dev/null || true)"
fi
if [[ -z "$TUNNEL_BIN" ]]; then
  _tw_cand="$(ls -t "$HOME"/.nvm/versions/node/*/bin/tunnel 2>/dev/null | head -1 || true)"
  if [[ -n "$_tw_cand" ]]; then
    TUNNEL_BIN="$_tw_cand"
    # tunnel 是 node 包装脚本（exec node …）——node 本体也要可达，把 nvm bin 目录一并进 PATH
    PATH="$(dirname "$_tw_cand"):$PATH"
    export PATH
  fi
fi
TUNNEL_BIN="${TUNNEL_BIN:-tunnel}"
export TUNNEL_BIN
NOTIFY_SEND_LAST="${NOTIFY_SEND_LAST:-/tmp/contrib-send-last.json}"
OSASCRIPT_BIN="${OSASCRIPT_BIN:-osascript}"
GATEWAY_PROBE_BIN="${GATEWAY_PROBE_BIN:-pgrep}"
GH_BIN="${GH_BIN:-gh}"   # 发卡前 TTL 轻复验用（09-06 新增；沙箱经此注入 stub，勿裸调 gh）
CLAUDE_BIN="${CLAUDE_BIN:-}"   # 空=走 command -v claude 现状探测

# 模型 pin seam：settings.json/运行时 env 注入的模型名可能带 [1m]/[1M] 后缀，claude CLI 直接拒
# （09-07 实证：AI 摘要层 unrecognized_model glm-5.3-flash[1m] 整轮报废；09-06 deep-check 同族实证）。
# 优先级：CLAUDE_MODEL_PIN 显式覆盖 > ~/.claude/settings.json env.ANTHROPIC_MODEL 剥后缀 >
# 运行时 $ANTHROPIC_MODEL 剥后缀；空=不加 --model flag（现状语义）。运行时 env 同时剥后缀
# sanitize 子进程（16:10 失败向量是 launchd 运行时 env，不只 settings 文件）。
MODEL_PIN="${CLAUDE_MODEL_PIN:-}"
if [[ -z "$MODEL_PIN" ]]; then
  _raw="$(jq -r '.env.ANTHROPIC_MODEL // empty' "$HOME/.claude/settings.json" 2>/dev/null || true)"
  MODEL_PIN="${_raw%\[*\]}"
fi
if [[ -z "$MODEL_PIN" && -n "${ANTHROPIC_MODEL:-}" ]]; then
  MODEL_PIN="${ANTHROPIC_MODEL%\[*\]}"
fi
# 剥后缀 guard：仅当原值以 ] 结尾才算「带后缀」被剥，正常模型名不动（% 模式对无 ] 值本就原样，这里显式化意图）
if [[ -n "${ANTHROPIC_MODEL:-}" && "$ANTHROPIC_MODEL" == *"]" ]]; then
  export ANTHROPIC_MODEL="${ANTHROPIC_MODEL%\[*\]}"
fi
MODEL_FLAG=()
[[ -z "$MODEL_PIN" ]] || MODEL_FLAG=(--model "$MODEL_PIN")

# 不用 jq 的 // 运算符：它把 JSON false 当 falsy（notify_dry_run=false 曾被读成
# 默认 true，推送全静默 dry-run）——只把 null/缺失当缺省，false 是合法配置值
cfg() {
  local v
  v="$(jq -r "$1" "$CONFIG" 2>/dev/null)"
  [[ -n "$v" && "$v" != "null" ]] && { echo "$v"; return; }
  echo "$2"
}
ts() { date "+%Y-%m-%dT%H:%M:%S%z"; }
today() { date +%F; }
now_epoch() { date +%s; }

TARGET="$(cfg '.notify_target' '""')"
# 环境变量 override（仅测试/演练用）：NOTIFY_DRY_RUN=false notify.sh approve <id>
DRY_RUN="${NOTIFY_DRY_RUN:-$(cfg '.notify_dry_run' 'true')}"

ensure_state() {
  [[ -f "$STATE" ]] || echo '{"last_flush_epoch":0,"alerts":{},"approvals":{},"receipts":{}}' > "$STATE"
  touch "$EVENTS"
}

log() { echo "[$(date '+%F %T')] notify: $*" >> "$CONTRIB/logs/notify.log"; }
# 孪生闸门（occ_all_stalled）的 gh stderr 落点，与 execute.sh 的 $LOG 同角色（卡 t_b8ef4f58）
LOG="$CONTRIB/logs/notify.log"

acquire_lock() {
  local i=0
  until mkdir "$LOCK" 2>/dev/null; do
    i=$((i+1)); (( i > 30 )) && { log "锁等待超时，放弃本轮"; exit 0; }
    sleep 1
  done
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT
}

gateway_up() { "$GATEWAY_PROBE_BIN" -f "hermes_cli.main gateway" >/dev/null 2>&1; }

# _send <msg_file> <subject> → 0=成功 1=发送失败 3=网关不可达
_send() {
  local msg_file="$1" subject="$2"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "── [dry-run] 目标: $TARGET · 主题: $subject ──────────"
    cat "$msg_file"
    echo "──────────────────────────────────────────────"
    return 0
  fi
  if ! gateway_up; then
    # 探针只做诊断、不做否决：pgrep 在部分执行环境假阴性（09-05 21:14 实证——
    # hermes 工具内调 notify 时探针落空但网关实际存活，回执被拦死 rc=3）。
    # 可达性的唯一真值 = hermes send 自身结果。
    log "网关探针落空（pgrep），仍尝试投递（可达性以 send 结果为准）"
  fi
  local rc=0
  # 剥离 profile 定位 env：kanban worker 注入的 HERMES_HOME/HERMES_PROFILE 会使 hermes 在 contrib 作用域解析不到 weixin 目标（8/8 digest 卡 send-digest 全 FAIL 实证，t_f3876050）；env -u 对未设变量是 no-op，launchd 路零行为变化
  env -u HERMES_HOME -u HERMES_PROFILE \
    "$HERMES_BIN" send --to "$TARGET" --file "$msg_file" --subject "$subject" --json >"$NOTIFY_SEND_LAST" 2>>"$CONTRIB/logs/notify.log" || rc=$?
  if (( rc != 0 )); then
    log "hermes send 失败 rc=${rc}（$(head -c 200 "$NOTIFY_SEND_LAST" 2>/dev/null)）"
    return 1
  fi
  # 双保险：exit 0 也要 success:true 才算投递成功
  if [[ "$(jq -r '.success // false' "$NOTIFY_SEND_LAST" 2>/dev/null)" != "true" ]]; then
    log "hermes send exit=0 但 success≠true（$(head -c 200 "$NOTIFY_SEND_LAST" 2>/dev/null)）"
    return 1
  fi
  return 0
}

# _osascript <通知文本> [<标题>] — 标题按渠道（缺省 contrib-watch = 历史字面，contrib 路径逐字不变）
_osascript() {
  "$OSASCRIPT_BIN" -e "display notification \"$1\" with title \"${2:-contrib-watch}\" sound name \"Ping\"" 2>/dev/null || true
}

state_bump() { # state_bump <表名> <键> → 计数+1 并写回
  jq --arg t "$1" --arg k "$2" '.[$t][$k] = ((.[$t][$k] // 0) + 1)' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}
state_get() { jq -r --arg t "$1" --arg k "$2" '.[$t][$k] // 0' "$STATE"; }
state_set() { # state_set <表名> <键> <JSON值> → 置值并写回（--argjson：数字/布尔保型，契约 schema 防字符串化）
  jq --arg t "$1" --arg k "$2" --argjson v "$3" '.[$t][$k] = $v' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}

# ---------------- 事件分级（外发消息规范的机械/叙事两级） ----------------
# 机械事件 = 高频、语义固定，模板卡即可高效消费（不经 LLM）；其余一律走 AI 摘要
is_mechanical() {
  case "$1" in
    probe-premise-dead|own-pr-activity|deep-budget-exhausted|own-pr-unledgered) return 0 ;;
    *) return 1 ;;
  esac
}
class_title() {
  case "$1" in
    probe-premise-dead)     echo "候选折损（占坑出局）" ;;
    own-pr-activity)        echo "自有 PR 动静" ;;
    deep-budget-exhausted)  echo "深检配额用尽" ;;
    own-pr-unledgered)      echo "自有 PR 台账缺口（疑未获批就 push）" ;;
    *)                      echo "$1" ;;
  esac
}
# is_brief_only <class> → 0=简报级（无决策点：不进微信即时/摘要两路，降级进当日简报消费队列）
# 缺省闭集 {own-pr-info, visual-run-done}（收窄判决：机械类 fixture 不动=机械模板卡是设计标杆
# 形态；扩展走 config 覆盖）。语义 = **replace**：config.brief_only_classes 数组存在即整体
# 替代缺省表（不留隐式并集；空数组 = 无简报级类）。本卡不新增 config 键（生产零改动）。
is_brief_only() {
  local cls="$1" is_arr hit
  is_arr="$(jq -r 'if (.brief_only_classes | type) == "array" then "yes" else "no" end' "$CONFIG" 2>/dev/null || echo no)"
  if [[ "$is_arr" != "yes" ]]; then
    case "$cls" in
      own-pr-info|visual-run-done) return 0 ;;
      *) return 1 ;;
    esac
  fi
  hit="$(jq -r --arg c "$cls" '[.brief_only_classes[] | select(. == $c)] | length' "$CONFIG" 2>/dev/null || echo 0)"
  [[ "${hit:-0}" -ge 1 ]] && return 0
  return 1
}
class_action() {
  case "$1" in
    probe-premise-dead)     echo "farm 占坑属正常损耗，无需动作；radar 每日自动补新候选" ;;
    own-pr-activity)        echo "建议动作见各条；涉及 push/评论的动作需你批准（L2）" ;;
    deep-budget-exhausted)  echo "候选已自动排队，明日 09:37 自动重试；无需动作" ;;
    own-pr-unledgered)      echo "红线：该动作未落 approved.log。核对批准来源后用 scripts/contrib/l2_ledger.sh record 补记；今后发布一律走 l2_ledger.sh publish" ;;
    *)                      echo "" ;;
  esac
}

# ---------------- 渠道分域（修① 域分标头） ----------------
# class → 域映射：flashcards 产线事件由 harmony-space wrapper 写入同一份账本（martin scripts/
# 零发射这 6 类，grep 实证）——未显式声明渠道的发射方由此兜底归域；其余类缺省 contrib。
# 显式 --channel 永远优先（cmd_event 三段解析）。
default_channel_for_class() {
  case "$1" in
    visual-run-done|radar-failure|agc-crash-spike|release-blocked|build-failure|contract-failure)
      echo "flashcards" ;;
    *) echo "contrib" ;;
  esac
}
# 渠道 → 报头/主题（contrib 字面保持不变=既有契约；flashcards 取自己的报头/主题）
channel_header() { # <channel> → 微信告警报头
  case "$1" in
    flashcards) echo "🟠【flashcards 告警】" ;;
    *)          echo "🟠【contrib 告警】" ;;
  esac
}
channel_quick_header() { # <channel> → 机械模板卡速报头
  case "$1" in
    flashcards) echo "🟠【flashcards 速报】" ;;
    *)          echo "🟠【contrib 速报】" ;;
  esac
}
channel_subject() { # <channel> → hermes send 主题
  case "$1" in
    flashcards) echo "flashcards 告警" ;;
    *)          echo "contrib-watch 告警" ;;
  esac
}

# _render_mechanical_card <batch_file> <channel> → stdout 模板卡（同类归并 + 固定动作行）
# 直接读 batch_file（已按渠道/未推过滤）——勿再回读 EVENTS 重过滤（jq index()
# 上下文陷阱与双份过滤都是故障面）
_render_mechanical_card() {
  local batch_file="$1" ch="${2:-contrib}" cls n=0
  echo "$(channel_quick_header "$ch")$(date +%m-%d)"
  echo ""
  for cls in probe-premise-dead own-pr-activity deep-budget-exhausted own-pr-unledgered; do
    local batch
    batch="$(jq -r --arg cls "$cls" \
      'select(.class == $cls) | .summary | sub("^radar [0-9-]+ premise 复验："; "")' \
      "$batch_file" 2>/dev/null)"
    [[ -z "$batch" ]] && continue
    n=$((n+1))
    local cnt; cnt="$(wc -l <<<"$batch" | tr -d ' ')"
    echo "▪ $(class_title "$cls")（${cnt} 条）"
    sed 's/^/· /' <<<"$batch"
    echo "↳ $(class_action "$cls")"
    echo ""
  done
  echo "（明细: contrib-data/events.jsonl）"
}

# _ai_digest <batch_json_file> <out_file> <channel> → 0=成功生成摘要
# AI 摘要层：把叙事类事件整理成三段式人话。失败返回非 0，事件保留待下轮——
# 绝不把原始 JSON 兜底出去（外发消息规范红线）。prompt 走 stdin 直给 claude -p，
# 不依赖项目级 skill（run-deepcheck 缺 cd 教训：路径/skill 依赖都是故障面）。
# 报头/主题按渠道参数化（修①：contrib 字面不变，flashcards 取自己的标头）
_ai_digest() {
  local in_file="$1" out_file="$2" ch="${3:-contrib}"
  local claude_bin="$CLAUDE_BIN"
  [[ -z "$claude_bin" ]] && claude_bin="$(command -v claude 2>/dev/null)"
  # launchd 环境兜底：PATH 里没有 claude 时按 nvm 安装布局探测
  [[ -z "$claude_bin" ]] && claude_bin="$(ls -t "$HOME"/.nvm/versions/node/*/bin/claude 2>/dev/null | head -1)"
  if [[ -z "$claude_bin" ]]; then
    log "AI 摘要失败：claude 不可达（PATH 与 nvm 布局均未命中）"
    return 1
  fi
  local prompt="/tmp/contrib-digest-prompt-$$.txt"
  {
    cat <<'EOF'
你是 contrib-watch 流水线的告警播报员，读者是 Hermes Agent 的维护者本人（非程序员场景，微信阅读）。把下面的原始告警事件整理成一条微信消息：

1. 三段式：发生了什么 → 为什么与他有关/多重要 → 建议他做什么（多数场景是"无需动作"，就明说）
2. 中文人类可读，机制黑话翻译成人话；rq-id / PR# / issue# 只作引用锚点，不当正文
3. ≤300 字；同类多条事件归并成一行汇总；只使用事件里已有的事实，不编造、不臆测原因，不确定写"待查"
EOF
    echo "4. 首行固定格式：$(channel_header "$ch")MM-DD（用今天日期）"
    cat <<'EOF'
5. 只输出消息正文本身，不要任何解释、前言或代码块包裹

黑话对照（用于翻译，不得照抄）：
- probe-premise-dead：ready-queue 候选机会的 issue 空间被其他贡献者占坑，候选作废（上游 AI farm 生态的正常损耗）
- own-pr-activity：我们自己的上游 PR 有新动静（维护者评论/mergeable 翻转/停滞超期）
- pipeline-failure：contrib-watch 流水线自身某环节失败（scan/深检/推送等）
- deep-budget-exhausted：当日深检配额用尽，候选自动排队明日重试
- own-pr-unledgered：某次 fork push / 上游开 PR 没有对应的 approved.log 记录（红线：对外动作必须有批准台账）
- mail-needs-user：GitHub 通知邮件里有需要他本人关注的事项（维护者点名/占坑竞争/资产状态变化）
- rq-xxxxx：ready-queue 审批候选项编号；expired=已作废；awaiting-approval=等你审批

EOF
    echo "事件 JSON："
    cat "$in_file"
  } > "$prompt"
  # alarm 240s 防挂死；cwd=MARTIN（claude 需项目内环境）；prompt 走 stdin；
  # MODEL_FLAG：剥 [1m] 后缀的 --model（bash 3.2 + set -u 下空数组须 +guard 惯用法）
  ( cd "$MARTIN" && perl -e 'alarm 240; exec @ARGV' "$claude_bin" -p ${MODEL_FLAG[@]+"${MODEL_FLAG[@]}"} < "$prompt" > "$out_file.raw" 2> "$out_file.err" )
  local rc=$?
  rm -f "$prompt"
  (( rc != 0 )) && { log "AI 摘要失败 rc=${rc}（$(tail -c 200 "$out_file.err" 2>/dev/null)）"; rm -f "$out_file.raw" "$out_file.err"; return 1; }
  # 校验：非空、长度合理、无命令回显病征
  local size; size="$(wc -c < "$out_file.raw" | tr -d ' ')"
  if (( size == 0 || size > 4000 )) || grep -q "Unknown command" "$out_file.raw" 2>/dev/null; then
    log "AI 摘要输出不合格（size=${size}），按失败处理"
    rm -f "$out_file.raw" "$out_file.err"
    return 1
  fi
  # 首行格式兜底：AI 忘了加报头则补上（按渠道取标头）
  if ! head -1 "$out_file.raw" | grep -qF "【$ch"; then
    { echo "$(channel_header "$ch")$(date +%m-%d)"; echo ""; cat "$out_file.raw"; } > "$out_file"
  else
    mv "$out_file.raw" "$out_file"
  fi
  rm -f "$out_file.err"
  return 0
}

# ================= digest 卡化（T5：叙事批异步化 + send-digest 唯一外发通道） =================

# _digest_lock — send-digest 专用带超时锁获取（复用 flush 同一 LOCK 文件）。
# 不改动 acquire_lock 本身（flush/approve 依赖其超时静默 exit 0 语义）；send-digest 的
# 锁超时必须显式失败（FAIL lock-timeout + exit 1，worker 按失败收尾下轮兜底重试），
# 且自装 EXIT trap（rmdir 变量 LOCK 指向的锁目录）保进程退出必释锁。
_digest_lock() {
  local i=0
  until mkdir "$LOCK" 2>/dev/null; do
    i=$((i+1))
    if (( i > ${DIGEST_LOCK_TIMEOUT:-30} )); then
      echo "FAIL lock-timeout"
      exit 1
    fi
    sleep 1
  done
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT
}

# _digest_card_status <card_id> → stdout 卡状态（空=不可得）；hermes kanban list 带 30s
# alarm 包裹（launchd flush 防挂死），env -u 三 ANTHROPIC_* 变量（CC shell 劫持防御）。
# board seam（T6）：KANBAN_BOARD 非空时 pin（--board 父级 flag 插子命令前）；空=不 pin。
_digest_card_status() {
  local out
  local -a bargs=()
  [[ -n "${KANBAN_BOARD:-}" ]] && bargs=(--board "$KANBAN_BOARD")
  out="$(env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY \
    perl -e 'alarm 30; exec @ARGV' "$HERMES_BIN" kanban ${bargs[@]+"${bargs[@]}"} list --json 2>/dev/null || true)"
  printf '%s' "$out" | jq -r --arg id "$1" '[.[] | select(.id == $id)][0].status // empty' 2>/dev/null || true
}

# _digest_keys_md5 <keys_file> → md5 hex 前 8（md5(macOS, 可能在 /sbin) / md5sum(Linux) 双兼容；
# 探测失败返回空串——幂等键退化为 digest-<日期>- 前缀仍唯一可用）
_digest_keys_md5() {
  local h="" md5bin
  md5bin="$(command -v md5 2>/dev/null || true)"
  if [[ -z "$md5bin" && -x /sbin/md5 ]]; then md5bin=/sbin/md5; fi
  if [[ -n "$md5bin" && "$(basename "$md5bin")" == "md5" ]]; then
    h="$("$md5bin" -q "$1" 2>/dev/null)"
  else
    h="$(md5sum "$1" 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s' "${h:0:8}"
}

# _digest_batch_sent <batch_file> → true|false（显式 sent:true 控制行才算；缺失/false 均
# 为 false——不用 jq `//` 布尔塌缩口径）
_digest_batch_sent() {
  [[ -s "$1" ]] || { printf 'false'; return 0; }
  local n
  n="$(jq -s '[.[] | select(.sent == true)] | length' "$1" 2>/dev/null || echo 0)"
  [[ "${n:-0}" -ge 1 ]] && printf 'true' || printf 'false'
}

# _digest_cleanup_files <snapshot> — 消费/失败即删该轮全部派生文件（B-3 消费清理，T6）：
# 快照 + 摘要 + 卡 body + 卡 json（约定同 ts 前缀 digest-<ts>.{json,digest.md,body.md,card.json}）。
# 磁盘零残留；事件本体在账本（events.jsonl），删除派生文件不丢数据。
_digest_cleanup_files() {
  local snap="$1"
  if [[ -n "$snap" ]]; then
    rm -f "$snap" "${snap%.json}.digest.md" "${snap%.json}.body.md" "${snap%.json}.card.json"
  fi
}

# _send_result_fresh <started_epoch> → stdout：NOTIFY_SEND_LAST 路径（仅当其 mtime ≥ 调用起点，
# 即确实是本次 send 的回写）或空串（B-2 陈旧佐证防御，T6：send 失败回写不得携带上一轮成功
# 发送的残留遥测——那会把旧 send_result 冒充本次失败证据）
_send_result_fresh() {
  local started="$1" m
  [[ -s "$NOTIFY_SEND_LAST" ]] || { printf ''; return 0; }
  m="$(stat -f %m "$NOTIFY_SEND_LAST" 2>/dev/null || echo 0)"
  case "$m" in
    ''|*[!0-9]*) m=0 ;;
  esac
  if (( m >= started )); then
    printf '%s' "$NOTIFY_SEND_LAST"
  fi
  return 0
}

# _digest_write_sent <batch_file> <true|false> <reason> [send_result_file] — 批次文件尾部
# 追加 sent 控制行（send_result 佐证取 NOTIFY_SEND_LAST 快照；文件缺失/损坏时降级无佐证行）
_digest_write_sent() {
  local bf="$1" sent="$2" reason="$3" srf="${4:-}" line=""
  if [[ -n "$srf" && -s "$srf" ]]; then
    line="$(jq -cn --argjson s "$sent" --arg r "$reason" --arg ts "$(ts)" --slurpfile sr "$srf" \
      '{sent:$s, reason:(if $r == "" then null else $r end), sent_at:$ts, send_result:$sr[0]}' 2>/dev/null || true)"
  fi
  if [[ -z "$line" ]]; then
    line="$(jq -cn --argjson s "$sent" --arg r "$reason" --arg ts "$(ts)" \
      '{sent:$s, reason:(if $r == "" then null else $r end), sent_at:$ts, send_result:null}')"
  fi
  printf '%s\n' "$line" >>"$bf"
  log "digest 批次回写 sent=$sent reason=${reason:-none}"
}

# _flush_push_mark <keys_file> — 账本标记该批 pushed（flush 成功路 / send-digest 共享；
# 原内联 python 段整段提取，语义零变化）
_flush_push_mark() {
  python3 - "$EVENTS" "$1" <<'PYEOF'
import json, sys
p, keys_f = sys.argv[1], sys.argv[2]
keys = set(json.load(open(keys_f)))
out = []
for l in open(p):
    l = l.rstrip("\n")
    if not l.strip():
        continue
    try:
        o = json.loads(l)
        if o.get("pushed") is False and o.get("key") in keys:
            import datetime
            o["pushed"] = True
            o["pushed_at"] = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
        out.append(json.dumps(o, ensure_ascii=False))
    except Exception:
        out.append(l)
open(p, "w").write("\n".join(out) + "\n")
PYEOF
}

# _flush_attempts_bump <keys_file> [<channel>] — 失败批次 attempts+1 + 3 败 osascript 日幂等兜底（按渠道分立）
# （原内联段整段提取，语义零变化；2026-09-14 修：过滤/日幂等键/文案/标题四处原写死 contrib
#   ⇒ flashcards 渠道 3 败结构性永不弹本地提示，且两渠道共享单键互吃当日提示）
_flush_attempts_bump() {
  local ch="${2:-contrib}"
  python3 - "$EVENTS" "$1" <<'PYEOF' || true
import json, sys
p, keys_f = sys.argv[1], sys.argv[2]
keys = set(json.load(open(keys_f)))
out = []
for l in open(p):
    l = l.rstrip("\n")
    if not l.strip():
        continue
    try:
        o = json.loads(l)
        if o.get("pushed") is False and o.get("key") in keys:
            o["attempts"] = o.get("attempts", 0) + 1
        out.append(json.dumps(o, ensure_ascii=False))
    except Exception:
        out.append(l)
open(p, "w").write("\n".join(out) + "\n")
PYEOF
  # 连续 3 败 → osascript 本地机械提示（每渠道每至多一次/日，非 raw dump）
  # 日幂等键按渠道分立；contrib 沿用历史键名 `fallback_notice`（12.P4/E10 冻结契约 +
  # 生产状态免迁移），其余渠道 = fallback_notice_<ch>
  local day_key maxed
  case "$ch" in
    contrib) day_key="fallback_notice" ;;
    *)       day_key="fallback_notice_${ch}" ;;
  esac
  maxed=$(jq -s --arg ch "$ch" '[.[] | select(.pushed == false and (.channel // "contrib") == $ch and (.attempts // 0) >= 3)] | length' "$EVENTS" 2>/dev/null || echo 0)
    if (( maxed > 0 )) && [[ "$(state_get "$day_key" "$(today)")" != "1" ]]; then
      _osascript "${ch} ${maxed} 条告警多次推送未成（AI 摘要/通道失败），已挂账下轮重试——明细 contrib-data/events.jsonl" "${ch}-watch"
      state_set "$day_key" "$(today)" 1
    fi
}

# fallback_ai <batch_file> <keys_file> <unpushed> <narrative> <ep> <channel> → rc
# 旧 claude -p 内联摘要路整段保留为兜底（卡建失败/卡失败终态/stale/done-未发送时走此路）：
# _ai_digest → 空卡守卫 → _send → 账本标记 / attempts+1 + osascript。永不 raw dump。
fallback_ai() {
  local batch_file="$1" keys_file="$2" unpushed="$3" narrative="$4" ep="$5" ch="${6:-contrib}"
  local body="/tmp/contrib-alerts-fb-$$.txt"
  local rc=0
  _ai_digest "$batch_file" "$body" "$ch" || rc=1
  (( rc == 0 )) && log "叙事事件 ${narrative}/${unpushed} 条 → AI 摘要层（fallback 路）"
  if (( rc == 0 )); then
    # 空卡守卫（与 flush 机械路同一多模式 grep）
    if (( $(grep -v -e '^🟠' -e '^（明细' -e '^$' -e '^──' "$body" 2>/dev/null | wc -l | tr -d ' ') == 0 )); then
      log "渲染产物无实质内容（空卡守卫触发），按失败挂账"
      rc=1
    fi
  fi
  if (( rc == 0 )); then
    _send "$body" "$(channel_subject "$ch")" || rc=$?
  fi
  if (( rc == 0 )); then
    _flush_push_mark "$keys_file"
    state_bump alerts "$(today)"
    jq --argjson ep "$ep" '.last_flush_epoch = $ep' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
    log "告警已推送（${unpushed} 条事件，rendering=ai-digest-fallback）"
  else
    _flush_attempts_bump "$keys_file" "$ch"
    log "告警推送失败 rc=${rc}（${unpushed} 条事件保留，下轮重试）"
  fi
  rm -f "$body"
  return "$rc"
}

# _digest_card_body <snapshot> <digest_file> <channel> → stdout 卡 body（快照路径+摘要输出路径约定+
# 三段式规范（照抄 _ai_digest prompt）+ 红线：唯一外发通道=send-digest）
_digest_card_body() {
  local snapshot="$1" digest_file="$2" ch="${3:-contrib}"
  cat <<EOF
# contrib digest 摘要卡

## 任务

- 事件快照（权威数据源）: ${snapshot}
- 摘要输出文件（写到此路径）: ${digest_file}
- 接收渠道: contrib（微信，notify_target 取 config）
- 本批事件域: ${ch}（contrib/flashcards 共用同一微信目标；报头与主题按域取）
- 摘要规范权威: .claude/skills/contrib-watch/SKILL.md 模式六（digest 摘要卡）

## 摘要规范

1. 三段式：发生了什么 → 为什么与他有关/多重要 → 建议他做什么（多数场景是"无需动作"，就明说）
2. 中文人类可读，机制黑话翻译成人话；rq-id / PR# / issue# 只作引用锚点，不当正文
3. ≤300 字；同类多条事件归并成一行汇总；只使用事件里已有的事实，不编造、不臆测原因，不确定写"待查"
4. 首行固定格式：$(channel_header "$ch")MM-DD（用今天日期）

黑话对照（用于翻译，不得照抄）：
- probe-premise-dead：ready-queue 候选机会的 issue 空间被其他贡献者占坑，候选作废（上游 AI farm 生态的正常损耗）
- own-pr-activity：我们自己的上游 PR 有新动静（维护者评论/mergeable 翻转/停滞超期）
- pipeline-failure：contrib-watch 流水线自身某环节失败（scan/深检/推送等）
- deep-budget-exhausted：当日深检配额用尽，候选自动排队明日重试
- own-pr-unledgered：某次 fork push / 上游开 PR 没有对应的 approved.log 记录（红线：对外动作必须有批准台账）
- mail-needs-user：GitHub 通知邮件里有需要他本人关注的事项（维护者点名/占坑竞争/资产状态变化）
- rq-xxxxx：ready-queue 审批候选项编号；expired=已作废；awaiting-approval=等你审批

## 红线（必须遵守）

- 唯一外发通道 = bash scripts/contrib/notify.sh send-digest --digest <摘要输出文件> --batch <事件快照>（普通命令形态，-q 模式可用）；禁 hermes send 直调、禁其他任何外发
- 永不 raw dump：外发内容只允许摘要文件，原始事件 JSON 绝不直推
- -q 模式禁脚本形态：python -c / jq -e / 任何 * -e 一律不可用（用文件读写工具完成）
- send-digest 输出 FAIL（限额/锁超时/发送失败/空卡）属正常失败收尾，not 异常

## 收尾要求

- 摘要写完调 send-digest：输出 OK 且批次快照尾部出现 sent:true 控制行 → kanban_complete（必须同时传 summary 与 result）
- 输出 FAIL → 同样 complete（summary 写明 FAIL 原因）——编排层按失败终态走 fallback 兜底重试
EOF
}

# _digest_flush <batch_file> <keys_file> <unpushed> <narrative> <ep> <channel> → rc
# 叙事批 digest 卡化主路：flight 检查五分支 → 无登记则快照+建卡（异步）；任何失败分支
# 落 fallback_ai()。done+sent:true 消费轮零账本动作且本轮不建新卡（防每小时卡风暴）。
# flight 单槽不分渠道（跨渠道并存时后到批挂账顺延——告警时效粒度为小时级，串行可接受）。
_digest_flush() {
  local batch_file="$1" keys_file="$2" unpushed="$3" narrative="$4" ep="$5" ch="${6:-contrib}"
  local flight="$CONTRIB/kanban-flight-digest.json"
  local card_id="" snap="" frc=0
  if [[ -s "$flight" ]] && jq -e 'type == "object"' "$flight" >/dev/null 2>&1; then
    card_id="$(jq -r 'if .kind == "digest" then (.card_id // empty) else empty end' "$flight" 2>/dev/null || true)"
  fi

  if [[ -n "$card_id" ]]; then
    local status
    status="$(_digest_card_status "$card_id")"
    if [[ "$status" == "done" ]]; then
      snap="$(jq -r '.batch_file // empty' "$flight" 2>/dev/null || true)"
      if [[ -n "$snap" && -f "$snap" && "$(_digest_batch_sent "$snap")" == "true" ]]; then
        # worker 已发送并标记账本：清登记+清快照（消费即删不留磁盘噪音），flush 零重复动作
        # （账本双写禁止）；本轮 return 不再建新卡（新批下小时轮自然建卡）
        rm -f "$flight"
        _digest_cleanup_files "$snap"
        log "digest 卡 ${card_id} done 且已发送——消费闭环（零账本动作，本轮不建新卡）"
        return 0
      fi
      # done 但 sent 缺失/false：worker 完成但未发送=异常收口 → fallback
      rm -f "$flight"
      log "digest 卡 ${card_id} done 但批次未标 sent——异常收口，走 fallback"
      fallback_ai "$batch_file" "$keys_file" "$unpushed" "$narrative" "$ep" "$ch"
      frc=$?
      [[ -n "$snap" ]] && _digest_cleanup_files "$snap"
      return "$frc"
    fi
    if [[ "$status" == "blocked" ]]; then
      # 闭集 outcome 判定（T5 红队 D7：非闭集 outcome=可自愈，保留登记零 fallback）——
      # 同 scan/mail 先例：gave_up|crashed|timed_out|spawn_failed 才算失败终态
      local oc=""
      local -a sargs=()
      [[ -n "${KANBAN_BOARD:-}" ]] && sargs=(--board "$KANBAN_BOARD")
      oc="$(env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY \
        perl -e 'alarm 15; exec @ARGV' "$HERMES_BIN" kanban ${sargs[@]+"${sargs[@]}"} show "$card_id" --json 2>/dev/null \
        | jq -r '.runs[-1].outcome // empty' 2>/dev/null || true)"
      case "$oc" in
        gave_up|crashed|timed_out|spawn_failed)
          snap="$(jq -r '.batch_file // empty' "$flight" 2>/dev/null || true)"
          rm -f "$flight"
          log "digest 卡 ${card_id} 失败终态（blocked outcome=${oc}）——清登记走 fallback"
          fallback_ai "$batch_file" "$keys_file" "$unpushed" "$narrative" "$ep" "$ch"
          frc=$?
          [[ -n "$snap" ]] && _digest_cleanup_files "$snap"
          return "$frc"
          ;;
        *)
          log "digest 卡 ${card_id} blocked（outcome=${oc:-未知}，非重试耗尽）→ 保留登记（可自愈，stale 兜底）"
          return 0
          ;;
      esac
    fi
    # 非终态 → stale 检查（DIGEST_STALE_SECS 缺省 21600；摘要卡轻量 6h 足够）
    local created stale_secs
    created="$(jq -r '.created_epoch // 0' "$flight" 2>/dev/null || echo 0)"
    stale_secs="${DIGEST_STALE_SECS:-21600}"
    if [[ "$created" =~ ^[0-9]+$ ]] && (( ep - created > stale_secs )); then
      snap="$(jq -r '.batch_file // empty' "$flight" 2>/dev/null || true)"
      rm -f "$flight"
      "$SELF_BIN" event pipeline-failure --key "$(date +%F)-digest-stale" \
        --summary "digest 卡 ${card_id} 超 ${stale_secs}s 未终态（stale），已清登记走 fallback" >/dev/null 2>&1 || true
      log "digest 卡 ${card_id} stale（>${stale_secs}s）——清登记走 fallback"
      fallback_ai "$batch_file" "$keys_file" "$unpushed" "$narrative" "$ep" "$ch"
      frc=$?
      [[ -n "$snap" ]] && _digest_cleanup_files "$snap"
      return "$frc"
    fi
    log "digest 卡 ${card_id} 在飞（status=${status:-unknown}），本批挂账（attempts 不增）"
    return 0
  fi

  # —— 无登记：批次快照 + 建 digest 卡（幂等键 digest-<日期>-<md5(keys) 前 8>）——
  local ts_id snapshot digest_file body_file idem card_json rc=0 card_id_new
  ts_id="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$CONTRIB/pending"
  snapshot="$CONTRIB/pending/digest-$ts_id.json"
  digest_file="$CONTRIB/pending/digest-$ts_id.digest.md"
  body_file="$CONTRIB/pending/digest-$ts_id.body.md"
  cp "$batch_file" "$snapshot" || {
    log "digest 快照落盘失败（${snapshot}）——走 fallback"
    fallback_ai "$batch_file" "$keys_file" "$unpushed" "$narrative" "$ep" "$ch"
    return $?
  }
  idem="digest-$(date +%Y%m%d)-$(_digest_keys_md5 "$keys_file")"
  _digest_card_body "$snapshot" "$digest_file" "$ch" > "$body_file"
  card_json="$(bash "$MARTIN/scripts/contrib/kanban_card.sh" create \
    --kind digest --title "contrib digest 摘要卡 $ts_id" \
    --body-file "$body_file" --idempotency-key "$idem" \
    --json-out "$CONTRIB/pending/digest-$ts_id.card.json" 2>>"$CONTRIB/logs/notify.log")" || rc=$?
  if (( rc != 0 )); then
    log "digest 建卡失败（rc=${rc}）——走 fallback"
    fallback_ai "$batch_file" "$keys_file" "$unpushed" "$narrative" "$ep" "$ch"
    frc=$?
    rm -f "$digest_file"
    _digest_cleanup_files "$snapshot"
    return "$frc"
  fi
  card_id_new="$(printf '%s' "$card_json" | jq -r '.id // empty' 2>/dev/null || true)"
  if [[ -z "$card_id_new" ]]; then
    log "digest 建卡输出缺 id——走 fallback"
    fallback_ai "$batch_file" "$keys_file" "$unpushed" "$narrative" "$ep" "$ch"
    frc=$?
    rm -f "$digest_file"
    _digest_cleanup_files "$snapshot"
    return "$frc"
  fi
  # flight 四键（kind/card_id/batch_file=快照路径/created_epoch）——与 scan flight 同构
  jq -n --arg kind digest --arg id "$card_id_new" --arg bf "$snapshot" --argjson e "$ep" \
    '{kind: $kind, card_id: $id, batch_file: $bf, created_epoch: $e}' \
    >"$flight.tmp" && mv "$flight.tmp" "$flight"
  log "digest 卡已建 ${card_id_new}（snapshot=${snapshot}，idem=${idem}），本批挂账（attempts 不增）"
  return 0
}

# _batch_channel <batch_file> → 批次所属渠道（首个带 key 事件行的 channel，缺省 contrib）
# 批次形态=flush 建卡快照（恒有事件行）；异常形态回落 contrib（主题选择 fail-safe 到现状字面）
_batch_channel() {
  local ch
  ch="$(jq -r '[.[] | select(has("key")) | (.channel // "contrib")][0] // "contrib"' "$1" 2>/dev/null || true)"
  [[ -n "$ch" && "$ch" != "null" ]] || ch="contrib"
  printf '%s' "$ch"
}

# cmd_send_digest — worker 卡内唯一外发通道。输出闭集：stdout 一行 OK / FAIL <原因>；exit 0/1。
# 全程持 flush 同款 LOCK（自包带超时锁获取 + 自装 EXIT trap）；空卡守卫/限额/dry-run 与
# flush 同口径；成功后账本标记 pushed + state_bump alerts + 回写批次 sent:true。
# 主题按批次渠道取（contrib 字面不变，flashcards 取自己的主题）。
cmd_send_digest() {
  local digest="" batch="" ch="contrib"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --digest) digest="${2:-}"; shift 2 ;;
      --batch) batch="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "$digest" && -n "$batch" && -f "$digest" && -f "$batch" ]] || { echo "FAIL bad-usage"; exit 1; }
  ch="$(_batch_channel "$batch")"
  ensure_state
  # 幂等快路：批次已标 sent:true → 重复调用零副作用（防 worker 重试双发）
  if [[ "$(_digest_batch_sent "$batch")" == "true" ]]; then
    echo "OK"
    exit 0
  fi
  _digest_lock
  # 幂等快路锁内复查（qa-reviewer B-1：锁外判读与获锁之间存在并发双发窗口——
  # 两个并发 send-digest 都在锁前通过快路检查，串行过锁后不复查则第二批二次 _send）
  if [[ "$(_digest_batch_sent "$batch")" == "true" ]]; then
    echo "OK"
    exit 0
  fi
  # 空卡守卫（照抄 flush 同款多模式 grep：剔除报头/脚注/空行/分隔线后必须还有实质内容）
  if (( $(grep -v -e '^🟠' -e '^（明细' -e '^$' -e '^──' "$digest" 2>/dev/null | wc -l | tr -d ' ') == 0 )); then
    _digest_write_sent "$batch" false "empty-card"
    echo "FAIL empty-card"
    exit 1
  fi
  # 限额（与 flush 同数值口径；缺省值与生产 config 对齐 30——上限数值本身零改动）
  local max_alerts used
  max_alerts="$(cfg '.max_alert_pushes_per_day' '30')"
  used="$(state_get alerts "$(today)")"
  if (( used >= max_alerts )); then
    _digest_write_sent "$batch" false "limit"
    echo "FAIL limit"
    exit 1
  fi
  # dry-run：同 _send 语义打印完整消息体与目标；sent:false reason=dry-run + exit 0
  # （worker 据 OK normal-complete；下轮 flush 消费 done+sent:false → fallback 接管，账本收敛）
  if [[ "$DRY_RUN" == "true" ]]; then
    _send "$digest" "$(channel_subject "$ch")" || true
    _digest_write_sent "$batch" false "dry-run"
    echo "OK"
    exit 0
  fi
  local rc=0 keys_file send_started
  send_started="$(now_epoch)"   # B-2（T6）：佐证新鲜度基准——NOTIFY_SEND_LAST 的 mtime 必须
  _send "$digest" "$(channel_subject "$ch")" || rc=$?   # ≥ 本轮调用起点才算本次 send 的回写
  if (( rc == 0 )); then
    # 账本标记该批 pushed（按批次 keys；attempts 逻辑留给 flush fallback 路——防双重计数）
    keys_file="$(mktemp "${TMPDIR:-/tmp}/contrib-digest-keys-XXXXXX")"
    jq -s '[.[] | select(has("key")) | .key]' "$batch" >"$keys_file"
    _flush_push_mark "$keys_file"
    rm -f "$keys_file"
    state_bump alerts "$(today)"
    _digest_write_sent "$batch" true "" "$(_send_result_fresh "$send_started")"
    log "send-digest 摘要已发送并标记账本（批次 $(basename "$batch")）"
    echo "OK"
    exit 0
  fi
  _digest_write_sent "$batch" false "send" "$(_send_result_fresh "$send_started")"
  echo "FAIL send"
  exit 1
}

# ---------------- event 聚类（修② 同域同根因） ----------------
# 静默窗：同一根因（同 key 或同簇）推送后窗口内复发只更新既有行（不重推）；窗口外/未推送过
# → 置 pushed=false 进下轮 flush（带「第 N 次」上下文）。64bit 秒。
CLUSTER_REPUSH_SECS="${CLUSTER_REPUSH_SECS:-86400}"

# cluster_key_of <key> → 簇键：剥离日期 token（YYYY-MM-DD 与 YYYYMMDD）→ 压缩重复 '-'；
# 剥离后为空（key 本身即日期）→ 回退原 key（保持「同 key」语义，防空簇键吞并全量）
cluster_key_of() {
  local k
  k="$(printf '%s' "$1" | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}//g; s/[0-9]{8}//g; s/-+/-/g')"
  [[ -n "$k" ]] || k="$1"
  printf '%s' "$k"
}

# _events_splice <updates_file> — 账本行拼接（line-splice）：updates_file 每行
# "<行号>TAB<jq args JSON>TAB<jq 程序>"，命中行以 jq -c 就地更新（保紧凑形态/字段序），
# 未点名行逐行原样透传——绝不整本重排（python json.dumps 会把紧凑行改写成带空格形态，
# 打红紧凑 grep 与 harmony 侧双格式假设；09-09 T2 教训）
_events_splice() {
  local updates="$1" tmp="$EVENTS.tmp.$$" n=0 line ul uargs uprog new
  : > "$tmp"
  while IFS= read -r line; do
    n=$((n+1))
    ul=""; uprog=""
    while IFS=$'\t' read -r xl xa xp; do
      if [[ "$xl" == "$n" ]]; then ul="$xl"; uargs="$xa"; uprog="$xp"; break; fi
    done < "$updates"
    if [[ -n "$ul" && -n "$uprog" ]]; then
      new="$(printf '%s' "$line" | jq -c --argjson a "${uargs:-{\}}" "$uprog" 2>/dev/null || true)"
      [[ -n "$new" ]] || new="$line"
      printf '%s\n' "$new" >> "$tmp"
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$EVENTS"
  mv "$tmp" "$EVENTS"
}

# _event_line_of <key> <channel> → stdout：同 (key,channel) 命中首行行号（无命中=空串）。
# 预过滤双格式（jq 紧凑 / json.dumps 带空格），命中候选再逐行 jq 校验（key+channel 精确匹配）
_event_line_of() {
  local key="$1" ch="$2" line n raw
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    n="${line%%:*}"
    raw="${line#*:}"
    if printf '%s' "$raw" | jq -e --arg k "$key" --arg c "$ch" \
        '(.key == $k) and ((.channel // "contrib") == $c)' >/dev/null 2>&1; then
      printf '%s' "$n"
      return 0
    fi
  done < <(grep -nF -e "\"key\":\"$key\"" -e "\"key\": \"$key\"" "$EVENTS" 2>/dev/null || true)
  return 0
}

# _event_line_of_cluster <channel> <cluster> → stdout：同 (channel,cluster) 未 resolved 命中首行行号。
# 簇读法钉死：stored 优先（既有行 .cluster 字段），字段缺失按 cluster_key_of(.key) 重算（向后兼容）。
# resolved 历史不吞新告警（仅未 resolved 行参与聚类匹配）。
# ⚠️ 字段分隔用 \x1f（非 IFS 空白）——tab 会让 read 折叠空字段（cluster 缺失行字段错位，
#    重算缺省语义整条失效；25-09-13 沙箱实证）
_event_line_of_cluster() {
  local ch="$1" cl="$2" line n raw info lch lcl lkey lres
  [[ -n "$cl" ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    n="${line%%:*}"
    raw="${line#*:}"
    info="$(printf '%s' "$raw" | jq -r --arg sep "$(printf '\037')" '[(.channel // "contrib"), (.cluster // ""), (.key // ""), ((.resolved // false) | tostring)] | join($sep)' 2>/dev/null || true)"
    [[ -n "$info" ]] || continue
    IFS=$'\x1f' read -r lch lcl lkey lres <<<"$info"
    [[ "$lch" == "$ch" ]] || continue
    [[ "$lres" == "true" ]] && continue
    [[ -n "$lcl" ]] || lcl="$(cluster_key_of "$lkey")"
    [[ "$lcl" == "$cl" ]] || continue
    printf '%s' "$n"
    return 0
  done < <(grep -nF -e "$cl" -e '"cluster"' "$EVENTS" 2>/dev/null || true)
  return 0
}

# _epoch_of_pushed_at <pushed_at> → stdout epoch（偏移归一化后求差）；空/缺省/解析失败 → 空串。
# 双格式：cmd_event 路 date +%z（+0800）与 flush 标记路 python isoformat（+08:00）；
# 解析失败 = 视为未过期（调用方 fail-safe：宁可少推不可多推）
_epoch_of_pushed_at() {
  local s="${1:-}" ep
  [[ -n "$s" && "$s" != "null" ]] || { printf ''; return 0; }
  ep="$(python3 -c '
import sys, datetime
s = sys.argv[1].strip()
if s.endswith("Z"):
    s = s[:-1] + "+00:00"
if len(s) >= 5 and s[-5] in "+-" and s[-4:].isdigit():
    s = s[:-2] + ":" + s[-2:]
try:
    d = datetime.datetime.fromisoformat(s)
except ValueError:
    sys.exit(1)
if d.tzinfo is None:
    d = d.replace(tzinfo=datetime.timezone.utc)
print(int(d.timestamp()))
' "$s" 2>/dev/null || true)"
  case "$ep" in ''|*[!0-9]*) ep="" ;; esac
  printf '%s' "$ep"
}

# ---------------- event ----------------
# 落账语义（修② 聚类更新，替代旧「同 key 幂等跳过」）：
#   ① 完全同 (key,channel) 行存在 → 原位更新（occurrences=(occ//1)+1、ts/summary 刷新、cluster 落账）
#   ② 同 key 未命中时按 (channel,cluster) 查未 resolved 行，命中 → 原行更新（不追加，key 保持首行值）
#   ③ 均未命中 → 追加新行（occurrences=1、cluster 落账）
# 重推判定：原 pushed==false 或 now-pushed_at ≥ CLUSTER_REPUSH_SECS → 置 pushed=false（进下轮 flush）；
# 静默窗内保持 pushed=true（只记账不重推）；已 resolved 行被复发 → 重开（resolved=false 且 pushed=false）。
cmd_event() {
  local cls="${1:-}"; shift || true
  local key="" summary="" channel=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --key) key="$2"; shift 2 ;;
      --summary) summary="$2"; shift 2 ;;
      --channel) channel="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "$cls" && -n "$key" ]] || { echo "用法: event <class> --key K --summary S [--channel C]" >&2; exit 2; }
  # 渠道三段解析：显式 --channel（空串=未传）> class→域映射 > 缺省 contrib
  [[ -n "$channel" ]] || channel="$(default_channel_for_class "$cls")"
  [[ -n "$channel" ]] || channel="contrib"
  ensure_state
  local cluster; cluster="$(cluster_key_of "$key")"
  local upd="/tmp/contrib-event-upd-$$.tsv"
  : > "$upd"
  # ① 同 (key,channel) → ② 同 (channel,cluster) 未 resolved 行
  local lno; lno="$(_event_line_of "$key" "$channel")"
  [[ -n "$lno" ]] || lno="$(_event_line_of_cluster "$channel" "$cluster")"
  if [[ -n "$lno" ]]; then
    local old_line info lpushed lres lpat oep repush args_json
    old_line="$(sed -n "${lno}p" "$EVENTS")"
    info="$(printf '%s' "$old_line" | jq -r '[((.pushed // false) | tostring), ((.resolved // false) | tostring), (.pushed_at // "")] | @tsv' 2>/dev/null || true)"
    if [[ -z "$info" ]]; then
      log "event $key 既有行解析失败（line=${lno}），按新增行处理"
    else
      IFS=$'\t' read -r lpushed lres lpat <<<"$info"
      oep="$(_epoch_of_pushed_at "$lpat")"
      repush="false"
      if [[ "$lpushed" == "true" && -n "$oep" ]] && (( $(now_epoch) - oep >= CLUSTER_REPUSH_SECS )); then
        repush="true"
      fi
      args_json="$(jq -cn --arg ts "$(ts)" --arg summary "$summary" --arg cluster "$cluster" --argjson repush "$repush" \
        '{ts: $ts, summary: $summary, cluster: $cluster, repush: $repush}')"
      printf '%s\t%s\t%s\n' "$lno" "$args_json" \
        '.occurrences = ((.occurrences // 1) + 1) | .ts = $a.ts | .summary = $a.summary | .cluster = $a.cluster | (if .resolved == true then (.resolved = false | .pushed = false) elif $a.repush then .pushed = false else . end)' >> "$upd"
      _events_splice "$upd"
      rm -f "$upd"
      log "event ~ $cls $key (channel=$channel, line=${lno}, occurrences+1, repush=${repush})"
      return 0
    fi
  fi
  rm -f "$upd"
  jq -cn --arg ts "$(ts)" --arg cls "$cls" --arg key "$key" --arg summary "$summary" --arg ch "$channel" \
    --arg cluster "$cluster" --arg route "$(is_brief_only "$cls" && echo brief || echo push)" \
    '{ts: $ts, class: $cls, key: $key, channel: $ch, summary: $summary, pushed: false, attempts: 0, pushed_at: null, occurrences: 1, cluster: $cluster, route: $route}' \
    >> "$EVENTS"
  log "event + $cls $key (channel=$channel, cluster=$cluster)"
}

# ---------------- flush（告警聚合推送，分渠两级渲染） ----------------
# _flush_brief_mark <brief_keys_json_file> <channel> — 简报级降级标记：原行 pushed=true + route=brief
# （route=brief 行=operator 当日简报消费队列，账本可查；经 line-splice 保原行形态），
# **同时把该行 append 进当日简报文件 $CONTRIB/briefs/<today>.md 的固定小节**——否则「降级进
# 当日简报」只是一句无人兑现的账本标记（09-14 实证：账本标 route=brief，简报文件里 grep = 0）。
# 幂等：① 降级行不再进批（pushed=true）⇒ 重复 flush 不会二次追加；② 追加前按 key 查重（簇重推
# 会把 pushed 拨回 false 重新入批）⇒ 同 key 只成行一次。简报写失败只记日志、不回滚降级标记
# （账本仍是唯一权威，简报是它的可读投影）。
# 红线：不推进 last_flush_epoch、不占 attempts、不触发 osascript。
_flush_brief_mark() {
  local keys_file="$1" ch="$2" upd="/tmp/contrib-brief-upd-$$.tsv" k ln bf
  bf="$CONTRIB/briefs/$(today).md"
  : > "$upd"
  while IFS= read -r k; do
    [[ -n "$k" ]] || continue
    ln="$(_event_line_of "$k" "$ch")"
    [[ -n "$ln" ]] || continue
    printf '%s\t%s\t%s\n' "$ln" '{}' '.pushed = true | .route = "brief"' >> "$upd"
    _brief_append_record "$bf" "$k" "$ln"
  done < <(jq -r '.[]' "$keys_file" 2>/dev/null)
  if [[ -s "$upd" ]]; then
    _events_splice "$upd"
  fi
  rm -f "$upd"
}

# _brief_append_record <brief_file> <key> <账本行号> — 单条 route=brief 行落当日简报（append-only）。
#   形态：`- <ts> ｜ <class> ｜ \`<key>\` ｜ <summary> ｜ <channel>`（summary 的换行/制表折叠为空格，
#   保证恒单行）；文件不存在则建 `# contrib 简报 <date>` 头 + 固定小节头；小节头惰性补写
#   （既有人写简报不会被重排）。查重按反引号包裹的 key 做定长匹配，命中即跳过。
_brief_append_record() {
  local bf="$1" k="$2" ln="$3" hdr='## 简报队列（机械落账）' tick='`' rec=''
  grep -qF -- "$tick$k$tick" "$bf" 2>/dev/null && return 0
  rec="$(sed -n "${ln}p" "$EVENTS" 2>/dev/null | jq -r \
    '[(.ts // ""), (.class // ""), ((.key // "") | "`" + . + "`"), ((.summary // "") | gsub("[\n\r\t]"; " ")), (.channel // "contrib")] | join(" ｜ ")' 2>/dev/null || true)"
  [[ -n "$rec" ]] || { log "brief: 账本行解析失败（key=${k} line=${ln}），本轮不落简报"; return 0; }
  mkdir -p "$CONTRIB/briefs" 2>/dev/null || true
  if [[ ! -f "$bf" ]]; then
    printf '# contrib 简报 %s\n' "$(today)" >> "$bf" 2>/dev/null || { log "brief: 建头失败 $bf"; return 0; }
  fi
  grep -qF -- "$hdr" "$bf" 2>/dev/null || printf '\n%s\n\n' "$hdr" >> "$bf" 2>/dev/null || true
  printf -- '- %s\n' "$rec" >> "$bf" 2>/dev/null || log "brief: 写入失败（key=${k} file=${bf}）"
  return 0
}

# _flush_channel <channel> <ep> → rc —— 单渠道批次：选择 →（brief 降级标记）→ 渲染 → 发送 → 标记。
# 限额与 min_interval 由 cmd_flush 在分渠循环前统一把守（全渠道共享总闸，全局恰一次兜底）。
_flush_channel() {
  local ch="$1" ep="$2"
  local all="/tmp/contrib-all-${ch}-$$.jsonl"
  local brief_file="/tmp/contrib-brief-${ch}-$$.json"
  local batch_file="/tmp/contrib-batch-${ch}-$$.json" keys_file="/tmp/contrib-keys-${ch}-$$.txt"
  local body="/tmp/contrib-alerts-${ch}-$$.txt"
  jq -c --arg ch "$ch" 'select(.pushed == false and (.channel // "contrib") == $ch)' "$EVENTS" > "$all" 2>/dev/null
  local unpushed_all; unpushed_all="$(wc -l < "$all" | tr -d ' ')"
  if (( unpushed_all == 0 )); then rm -f "$all" "$brief_file" "$batch_file" "$keys_file" "$body"; return 0; fi
  # 修③推送门槛：brief-only 类不进微信批（即时/摘要两路皆出）——分类在 bash 侧完成
  # （jq 里调不到 bash 函数）；被排除行统一标记 pushed=true + route=brief
  local brief_keys="[]" k c
  while IFS=$'\t' read -r k c; do
    [[ -n "$k" ]] || continue
    is_brief_only "$c" && brief_keys="$(jq -c --arg k "$k" '. + [$k]' <<<"$brief_keys")"
  done < <(jq -r '[.key, .class] | @tsv' "$all" 2>/dev/null)
  printf '%s' "$brief_keys" > "$brief_file"
  local brief_n; brief_n="$(jq 'length' <<<"$brief_keys" 2>/dev/null || echo 0)"
  if (( ${brief_n:-0} > 0 )); then
    _flush_brief_mark "$brief_file" "$ch"
    log "${ch} 渠道 ${brief_n} 条简报级事件降级（route=brief，不进微信批）"
  fi
  # 微信批 = 全部未推行 − brief 降级行
  jq -c --slurpfile bk "$brief_file" 'select(.key as $k | ($bk[0] | index($k)) == null)' "$all" > "$batch_file" 2>/dev/null
  local unpushed; unpushed="$(wc -l < "$batch_file" | tr -d ' ')"
  if (( unpushed == 0 )); then rm -f "$all" "$brief_file" "$batch_file" "$keys_file" "$body"; return 0; fi
  # keys 存 JSON 数组（裸字符串会被 jq 当非法 JSON——空卡事故教训）
  jq -s '[.[].key]' "$batch_file" > "$keys_file"

  # 两级渲染：混有任何叙事事件 → 整批走 digest 卡（T5 异步化）；纯机械 → 模板卡
  # （分类逻辑必须在 bash/jq 侧完成——jq 里调不到 bash 函数）
  local narrative
  narrative="$(jq -s '[.[] | select((.class == "probe-premise-dead" or .class == "own-pr-activity" or .class == "deep-budget-exhausted" or .class == "own-pr-unledgered") | not)] | length' \
    "$batch_file" 2>/dev/null)"
  narrative="${narrative:-0}"

  local rc=0
  if (( narrative > 0 )); then
    if [[ "$(cfg '.notify_digest' 'true')" == "true" ]]; then
      # T5 卡化主路：叙事批 → digest 卡（异步），flight 五分支/建卡失败/stale 全部在
      # _digest_flush 内收口（兜底=fallback_ai 旧内联路）；本轮 rc 透传其返回值
      _digest_flush "$batch_file" "$keys_file" "$unpushed" "$narrative" "$ep" "$ch"
      local drc=$?
      rm -f "$all" "$brief_file" "$batch_file" "$keys_file" "$body"
      return "$drc"
    fi
    log "${ch} 渠道 notify_digest=false，叙事事件 ${narrative} 条挂账待 AI 会话转述"
    rc=1
  else
    _render_mechanical_card "$batch_file" "$ch" > "$body"
    log "${ch} 渠道纯机械事件 ${unpushed} 条 → 模板卡（不经 LLM）"
    # 空卡守卫：剔除报头/脚注/空行后必须还剩实质内容——模板卡排版要能通过；
    # 绝不发空壳卡、更不允许空卡把事件标记成已推（09-05 沙箱实测抓到此路径）
    # 注意用 grep -e 多模式：BSD grep 的 BRE 里 `^$\|..` 的 $ 中缀是字面量，交替会失效
    if (( $(grep -v -e '^🟠' -e '^（明细' -e '^$' -e '^──' "$body" 2>/dev/null | wc -l | tr -d ' ') == 0 )); then
      log "渲染产物无实质内容（空卡守卫触发），按失败挂账"
      rc=1
    fi
    if (( rc == 0 )); then
      _send "$body" "$(channel_subject "$ch")" || rc=$?
    fi
  fi

  if (( rc == 0 )); then
    # 只标记本轮批次（本渠道 + 批次内 key）；keys_file 是 JSON 数组
    _flush_push_mark "$keys_file"
    state_bump alerts "$(today)"
    jq --argjson ep "$ep" '.last_flush_epoch = $ep' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
    log "告警已推送（${ch} 渠道 ${unpushed} 条事件，rendering=template）"
  else
    # 失败：批次内 attempts+1（事件保留，下轮重试；永不 raw dump 兜底）
    _flush_attempts_bump "$keys_file" "$ch"
    log "告警推送失败 rc=${rc}（${ch} 渠道 ${unpushed} 条事件保留，下轮重试）"
  fi
  rm -f "$all" "$brief_file" "$batch_file" "$keys_file" "$body"
  # 失败 rc 向上传撑（契约：AI 摘要失败/发送失败 → rc≠0，事件保留重试）；
  # 调用方均容错（operator 班次收班契约不因 rc≠0 中断）
  return "$rc"
}

# ---------------- 人门提醒（gate-remind：blocked 的 [draft]/[fix] 卡无送达面） ----------------
# 缺口（2026-09-14 operator 实证）：人门卡（`[draft]`/`[fix]`）停在 blocked 等裁决，而 contrib
# 板零微信订阅（`kanban_notify_subs` 0 条）+ 简报不看卡 + 班次 job deliver=local
# ⇒ **用户永远不会被问到**，只能靠人主动开板。本函数 = 零 LLM 机械检测，挂在每轮 flush 上
# （唯一不依赖任何人注意力的位置）：读板 → 把「blocked ∧ 标题含 `[draft]`/`[fix]` ∧
# now-created_at > gate_remind_hours」的卡落一条 human-gate 事件（key=gate-<task_id>）。
# 幂等由账本 key 承担（同 key 原位更新、不重复成行，复发重推由既有静默窗 CLUSTER_REPUSH_SECS
# 管）；节流复用既有 min_interval / max_alert_pushes_per_day；外发走既有叙事批 → digest 卡路。
# config 取不到 gate_remind_hours ⇒ 0 = 关闭（缺配置不静默上线）。读板失败只记日志、不中断 flush。
_gate_remind() {
  local hours; hours="$(cfg '.gate_remind_hours' '0')"
  case "$hours" in ''|*[!0-9]*) hours=0 ;; esac
  (( hours > 0 )) || return 0
  [[ -f "$GATE_DB" ]] || { log "gate-remind: 板库不存在（${GATE_DB}），本轮跳过"; return 0; }
  local cutoff rc=0 recs
  cutoff=$(( $(now_epoch) - hours * 3600 ))
  recs="$(sqlite3 -separator $'\t' "file:${GATE_DB}?immutable=1" \
    "select id, replace(title, char(9), ' ') from tasks
      where status='blocked' and (title like '%[draft]%' or title like '%[fix]%')
        and created_at > 0 and created_at < ${cutoff};" 2>>"$LOG")" || rc=$?
  if (( rc != 0 )); then
    log "gate-remind: 板读取失败 rc=${rc}（${GATE_DB}），本轮跳过（下轮自愈）"
    return 0
  fi
  local id title n=0
  while IFS=$'\t' read -r id title; do
    [[ -n "$id" ]] || continue
    n=$((n+1))
    "$SELF_BIN" event human-gate --key "gate-${id}" --channel contrib \
      --summary "人门卡 ${id} 停在 blocked 超 ${hours}h，微信与简报均未送达：${title:0:70}（等你裁决或放行）" \
      >>"$LOG" 2>&1 || log "gate-remind: ${id} 事件落账失败"
  done <<<"$recs"
  (( n > 0 )) && log "gate-remind: ${n} 张人门卡超 ${hours}h 未送达，已落账（key=gate-<task_id>）"
  return 0
}

# cmd_flush — 分渠聚合推送：min_interval/限额全局把守 → 逐渠道独立成批（各至多一条消息）。
# 单渠无待推事件 → 该渠零发送零标头零标记；非 {contrib,flashcards} 渠道永不进批。
cmd_flush() {
  ensure_state
  acquire_lock
  local min_interval; min_interval="$(cfg '.notify_min_interval_min' '20')"
  local max_alerts; max_alerts="$(cfg '.max_alert_pushes_per_day' '30')"
  local ep; ep="$(now_epoch)"
  local last; last="$(jq -r '.last_flush_epoch // 0' "$STATE")"

  if (( ep - last < min_interval * 60 )); then
    log "距上次 flush 不足 ${min_interval}min（防 08 窗口双发），跳过"
    return 0
  fi

  # 人门检测（未决 [draft]/[fix] 卡无送达面）：必须排在渠道集计算**之前**——否则本轮新落的
  # human-gate 事件要等下一轮 flush 才被带走（边界实证：digest 消费轮不带走同轮新事件）。
  _gate_remind

  # 本轮渠道集 = 账本中未推事件实际出现的渠道 ∩ 合法闭集 {contrib,flashcards}
  # （其他渠道照旧只入账不进批；空集=零输出零标记零推进）
  local channels
  channels="$(jq -r 'select(.pushed == false) | (.channel // "contrib")' "$EVENTS" 2>/dev/null \
    | grep -E '^(contrib|flashcards)$' | sort -u | tr '\n' ' ' || true)"
  [[ -n "$(printf '%s' "$channels" | tr -d ' ')" ]] || return 0

  # 当日告警限额（两渠道共享总闸；检查置于分渠循环之前 → 限额判定全局一次，提示按渠各弹一条）
  local used; used="$(state_get alerts "$(today)")"
  if (( used >= max_alerts )); then
    local pend_n ch2 pn
    pend_n="$(jq -s '[.[] | select(.pushed == false) | select((.channel // "contrib") == "contrib" or (.channel // "contrib") == "flashcards")] | length' "$EVENTS" 2>/dev/null || echo 0)"
    # 分渠各弹一条：原先把两渠道合计数写成「contrib」单条文案 ⇒ 两渠道同时挂账时提示失真
    for ch2 in $channels; do
      pn="$(jq -s --arg ch "$ch2" '[.[] | select(.pushed == false and (.channel // "contrib") == $ch)] | length' "$EVENTS" 2>/dev/null || echo 0)"
      (( pn > 0 )) || continue
      _osascript "${ch2} 告警 ${pn} 条今日未推（限额 ${max_alerts} 已满），明日 09:17 对账补推" "${ch2}-watch"
    done
    log "告警限额已满（${used}/${max_alerts}），${pend_n} 条留待补推"
    return 0
  fi

  local rc_total=0 ch
  for ch in $channels; do
    _flush_channel "$ch" "$ep" || rc_total=$?
  done
  return "$rc_total"
}

# ---------------- approve（审批推送 🟡） ----------------
_build_approval_card() { # <id> → stdout 卡片文本（旧模板；approval_interactive 非 true 或降级时用）
  local id="$1"
  jq -r --arg id "$id" '.items[] | select(.id == $id) |
    "🟡【L2 审批 #\(.id)】\(if .disposition == "release-gate" then "发版提审门（批准 = 提审 hm release）" else "\(.disposition) 评论" end)\n类型: \(if .disposition == "release-gate" then "release-gate（AGC 发版批准门，issue 为合成号）" else "\(.disposition)（lane=\(.lane)）" end)\n目标: \(if .disposition == "release-gate" then "AGC 提审 · \(.title)" else "NousResearch/hermes-agent#\(.issue)" end)\n概要: \(.title[0:80])\n我方货: \(if (.goods_note // "") | length > 0 then .goods_note else "未判定（批前请确认是否涉及我方 PR/commit）" end)\n质量: \(.score)/15（prio \(.priority)）；\(if .lane == "probe" then "strategist 单轮" else "strategist+红队双审" end)已过\n审阅: \(.tunnel.url // "见全文")\n全文: ~/workspace/martin/contrib-data/pending/\(.id).md\n回复「批 #\(.id)」/「改 #\(.id): 意见」/「否 #\(.id)」；48h 无回复自动搁置"' "$QUEUE"
}

# ---- 交互路（approval_interactive=true）：slug/短码/人读页/卡 v2 ----

# 短码与 slug 采样（C4）：字符集均匀采样 —— urandom 字节拒绝采样（256 不被字符集长度整除时
# 丢弃越界值，防取模偏置）；LC_ALL=C 固定字节语义。slug=[a-z0-9]{10}；短码=[a-km-np-z2-9]{6}（去 0/o/1/l）
_sample_charset() { # <charset> <len> → stdout 采样串（失败 rc=1）
  local cs="$1" n="$2" out="" byte guard=0
  local range=$(( 256 / ${#cs} * ${#cs} ))
  while (( ${#out} < n )); do
    guard=$((guard + 1))
    (( guard > 64 )) && { log "随机采样异常（/dev/urandom 不可读？）"; return 1; }
    while IFS= read -r byte; do
      [[ -n "$byte" ]] || continue
      (( byte < range )) || continue
      out+="${cs:$(( byte % ${#cs} )):1}"
      (( ${#out} >= n )) && break
    done < <(LC_ALL=C head -c 64 /dev/urandom 2>/dev/null | LC_ALL=C od -An -tu1 | LC_ALL=C tr -s ' ' '\n')
  done
  printf '%s' "$out"
}
gen_slug() { _sample_charset 'abcdefghijklmnopqrstuvwxyz0123456789' 10; }
gen_code() { _sample_charset 'abcdefghijkmnpqrstuvwxyz23456789' 6; }

# disposition 表述 / lane 审核轮次（卡 v2 两处硬编码修正的口径源；jq 内联副本与其保持同构）
approval_disp_cn() {
  case "$1" in
    own-PR)          echo "own-PR 推进" ;;
    review-evidence) echo "evidence 评审" ;;
    probe-salvage)   echo "probe 取证" ;;
    release-gate)    echo "发版提审门" ;;
    *)               echo "$1" ;;
  esac
}
approval_rounds() {
  [[ "$1" == "probe" ]] && echo "strategist 单轮" || echo "strategist+红队双审"
}

_build_approval_card_v2() { # <id> <page-url> <code> <deadline> <ttl> → stdout 卡 v2（C6 行序固定）
  local id="$1" url="$2" code="$3" deadline="$4" ttl="$5"
  jq -rn --slurpfile q "$QUEUE" --arg id "$id" --arg url "$url" --arg code "$code" \
       --arg deadline "$deadline" --argjson ttl "$ttl" '
    ($q[0].items[] | select(.id == $id)) as $it |
    "🟡【L2 审批 #\($it.id)】\(if $it.disposition == "own-PR" then "own-PR 推进"
       elif $it.disposition == "review-evidence" then "evidence 评审"
       elif $it.disposition == "probe-salvage" then "probe 取证"
       elif $it.disposition == "release-gate" then "发版提审门（批准 = 提审 hm release）"
       else $it.disposition end)",
    (if $it.disposition == "release-gate"
     then "目标: AGC 发版提审 · \($it.title)（issue 为合成号，非 GitHub）"
     else "目标: NousResearch/hermes-agent#\($it.issue) · \($it.score)/15 · \(if $it.lane == "probe" then "strategist 单轮" else "strategist+红队双审" end)" end),
    "概要: \($it.title[0:80])",
    (if (($it.goods_note // "") | length) > 0
     then "\($it.goods_note)"
     else "我方货: 未判定（批前请确认本次是否涉及我方 PR/commit）" end),
    # 升级路专属：微信卡直接带出首个卡点（完整清单在页面顶部）
    (if (($it.escalate_reasons // []) | length) > 0
     then "🤔 我定不了: \($it.escalate_reasons[0][0:60])"
     else empty end),
    "✅ 点开即批（短码已自动填入）: \($url)?key=\($code)",
    "⏱ \($deadline) 前有效（\($ttl)h），超时自动搁置",
    "💬 微信备用: 批/否 #\($it.id)；改 #\($it.id): 意见"'
}

# _build_approval_page <id> <draft> <deadline> <ttl> → stdout 人读页 markdown
# ① 顶部 interactive fence（C2 形状：radio id:verdict 三选项固定顺序 + text id:comment）
# ② 中文 BLUF 头（rq 元数据）③ premises 证据表 ④ 机器稿全文 verbatim 附录（不包 fence，防草稿自身 fence 嵌套破坏）
# 全程 jq 模板渲染，不走 bash 字符串内插（全角标点变量名盲区）；机器稿本体零改动（C8 逐字投递语义）
# _build_approval_page <id> <draft> <deadline> <ttl> → stdout 人读页 markdown
# 09-06 决策单重构（用户审批体验反馈）：页=决策支持单页，非生产质检报告——
#   L0 一句话+动作/风险/时效（blockquote）→ L1 中文摘要（摘自草稿头部注释块
#   「审批页中文摘要」段，该段随注释块在投递时被 strip，永不外发）→ L2 复核锚点
#   （premises 结论表+链接）→ L3 原文附录（details 折叠，内容=真实投递载荷：
#   剥离头部注释块 + 截掉「## 内部备注」尾部）。无摘要段时降级=标题+premises。
_build_approval_page() {
  local id="$1" draft="$2" deadline="$3" ttl="$4"
  jq -rn --rawfile draftbody "$draft" --slurpfile q "$QUEUE" \
       --arg id "$id" --arg deadline "$deadline" --argjson ttl "$ttl" '
    ($q[0].items[] | select(.id == $id)) as $it |
    # 真实投递载荷 = 剥离头部注释块 + 截掉内部备注尾部（与 execute.sh 口径一致）
    ($draftbody | sub("(?s)^\\s*(<!--.*?-->\\s*)+"; "") | split("## 内部备注")[0]
      | gsub("\\s+$"; "")) as $payload |
    # 中文摘要：藏在头部注释块内（投递随注释剥离，不外发）
    # 分隔符容错（t_404ff5c1）：jq split 是**字面**匹配——原先写死「）＋全角冒号」，而既有稿件里
    # 「）：」「）:」「）【注记】：」三种写法并存，任一不命中即 $summary 为空 → L0 回退成 $it.title、
    # 要点层整段丢失（静默降级为「标题+premises」）。改为以**不含冒号/注记的段名**做不变量切分，
    # 再吸掉可选【…】注记与可选半/全角冒号：两种冒号写法（及带注记变体）都命中，稿件零改动。
    (($draftbody | split("审批页中文摘要（L1，不随评论发出）")) as $sp |
      if ($sp | length) > 1 then ($sp[1] | sub("^[【\\[][^】\\]]*[】\\]]"; "") | sub("^\\s*[：:]"; "")
        | split("-->")[0] | gsub("^\\s+|\\s+$"; ""))
      else "" end) as $summary |
    ($summary | split("\n") | map(gsub("^\\s+"; "") | select(test("\\S"))) ) as $slines |
    # L0 标签剥除同属字面量坑：稿件既有「一句话：」也有「L0:」写法，写死一种即漏剥
    (if ($slines | length) > 0 then ($slines[0] | sub("^(一句话|L0)\\s*[：:]\\s*"; "")) else $it.title end) as $l0 |
    (if $it.disposition == "own-PR" then "提交修复 PR（issue #\($it.issue)）"
     elif $it.disposition == "probe-salvage" then "在 issue #\($it.issue) 发一条取证评论"
     elif $it.disposition == "release-gate" then "批准 = 提审 hm release \($it.title | sub("^release "; ""))"
     else "在 PR #\($it.pr // $it.issue) 发一条技术评论" end) as $action |
    [ "```interactive",
      "id: verdict",
      "type: radio",
      (if $it.disposition == "release-gate"
       then "question: 批准提审？（批准 = hm release 提审 AGC，token 30min 内自动提审）"
       else "question: 批准发出？（批准 = 附录原文逐字投递到 GitHub）" end),
      "options:",
      "  - 批准",
      "  - 否决",
      "  - 需修改",
      "```",
      "",
      "```interactive",
      "id: comment",
      "type: text",
      "question: 意见（选填）",
      "placeholder: 选「需修改」时请写明修改点",
      "show_when: verdict=需修改",
      "```",
      "",
      "<!-- twq:submit-here -->",
      "",
      "# 审批：\($action)",
      "",
      "> \($l0)",
      (if $it.disposition == "release-gate"
       then "> **动作**：批准后 hm release 自动提审 AGC（gate token 30min TTL，单次消费）· ⏱ \($deadline) 前有效（逾期自动搁置）"
       else "> **动作**：以 strzhao 名义公开发表，发出后可编辑/删除 · ⏱ \($deadline) 前有效（逾期自动搁置）" end),
      "",
      # 升级路专属（09-06 默认自动/例外升级）：AI 定不了的点置顶——用户只需裁决这几条
      ((if (($it.escalate_reasons // []) | length) > 0
        then (["## 🤔 我需要什么才能决策（09-11 起：缺判断依据才升级，用户给依据/原则，不是替 AI 选）", ""]
              + [$it.escalate_reasons[] | "- " + .] + [""])
        else [] end)[]),
      (if $it.disposition == "release-gate" then "## 这次发版要提审什么" else "## 这条评论说了什么" end),
      "",
      (if ($slines | length) > 1 then ($slines[1:][] ) elif ($slines|length) == 1 then $slines[0]
       else "- \($it.title)（详见附录原文）" end),
      "",
      "## 复核锚点（每条都可点开自查）",
      "",
      "| 结论 | 依据 |",
      "|---|---|",
      ($it.premises[] |
        "| \((.claim // "") | gsub("[\\\\|\\n]"; " ") | .[0:160]) | \((.evidence // "") | gsub("[\\\\|\\n]"; " ") | .[0:160]) |"),
      "",
      (if $it.disposition == "release-gate" then
        "- 目标：AGC 发版提审（issue #\($it.issue) 为 appId 合成号，非 GitHub）"
      else
        "- 目标：[issue #\($it.issue)](https://github.com/NousResearch/hermes-agent/issues/\($it.issue))"
          + (if $it.pr then " · [PR #\($it.pr)](https://github.com/NousResearch/hermes-agent/pull/\($it.pr))" else "" end)
      end),
      "- 质量：\($it.score)/15 · \(if $it.lane == "probe" then "strategist 单轮" else "strategist+红队双审" end)已过 · 编号 \($it.id)（微信回「批/否 #\($it.id)」亦可）",
      (if (($it.goods_note // "") | length) > 0
       then "- 我方货：\($it.goods_note)"
       else "- 我方货：未判定（批前请确认本次是否涉及我方 PR/commit）" end),

      "",
      "---",
      "",
      "<details><summary>📄 英文原文附录（批准后将逐字发出，点开核对）</summary>",
      "",
      $payload,
      "",
      "</details>"
    ] | join("\n") + "\n"'
}

# _legacy_deploy <id> <draft> —— 旧审阅链接路（tunnel deploy + 3 参登记，code 缺省 null）
# approval_interactive 非 true 时是主路；交互路部署失败时是降级路
_legacy_deploy() {
  local id="$1" draft="$2"
  [[ "$DRY_RUN" == "true" ]] && return 0
  command -v "$TUNNEL_BIN" >/dev/null 2>&1 || return 0
  local cur_url; cur_url="$(jq -r --arg id "$id" '.items[] | select(.id == $id) | .tunnel.url // ""' "$QUEUE")"
  [[ -n "$cur_url" ]] && return 0
  local deploy_out url
  deploy_out=$("$TUNNEL_BIN" deploy "$draft" -n "$id" 2>/dev/null || true)
  url="$(grep -oE 'https?://[^ ]+' <<<"$deploy_out" | tail -1)"
  if [[ -n "$url" ]]; then
    "$RQ" tunnel-deploy "$id" "$url" "$id" >/dev/null
    log "approve ${id}: tunnel 已部署 ${url}"
  else
    log "approve ${id}: tunnel 部署失败（卡片将以全文路径代替）"
  fi
  return 0
}

# ── stalled-occupier 豁免（卡 t_b8ef4f58，2026-09-12）────────────────────────────
# 与 scripts/approval/execute.sh 的 occ_all_stalled 同源（孪生实现），必须同步演进：改一处必改另一处。
# 语义：占用 PR 全部停摆 >21 天 → rc=0 豁免放行；任一活跃（≤21 天）→ rc=1 走原判死文案；
#       gh 取证失败/形状异常/无锚可算 → rc=2 fail-closed（TTL_FAIL_REASON 落可诊断原因，维持拦截）。
# ⚠️ 锚口径设计偏差（卡 body 定稿 updatedAt 实证不可用，全文见 worktree state.md 设计方案节）：
#   #84087 的 updatedAt=2026-09-10 是我方 evidence review 评论顶起来的，按 updatedAt 判停摆恒
#   「活跃」、豁免永不触发。故锚 =「占坑者自身最后动作」= max(commits[].committedDate ∪
#   本人评论 createdAt)；第三方评论只顶 updatedAt（仅日志留痕），不作锚。
# 零 LLM / 零新依赖 / gh 只读（每占用 PR 一次 pr view）；日期解析 macOS BSD date -j -f（仓内惯例）。
occ_all_stalled() { # <repo> <foreign_pr_csv> → rc 0=全部停摆放行 | 1=活跃占坑 | 2=fail-closed
  local repo="$1" csv="$2" p view_out rc_v calc anchor_iso up_iso anchor_ep days
  local now cutoff old_ifs
  now="$(date +%s)"
  cutoff=$(( 21 * 86400 ))
  old_ifs="$IFS"
  IFS=","
  for p in $csv; do
    view_out="$(GH_REPO="$repo" "$GH_BIN" pr view "$p" --json commits,author,comments,updatedAt 2>>"$LOG")" \
      && rc_v=0 || rc_v=$?
    if (( rc_v != 0 )) || [[ -z "${view_out//[[:space:]]/}" ]]; then
      TTL_FAIL_REASON="gh pr view ${p} 取证失败（rc=${rc_v}），占坑判定 fail-closed"
      IFS="$old_ifs"
      return 2
    fi
    calc="$(jq -r '(.author.login // "") as $a |
      {anchor: (([.commits[]?.committedDate]
        + [.comments[]? | select((.author.login // "") == $a) | .createdAt | select(. != null)]) | max // ""),
        updatedAt: (.updatedAt // "")}' <<<"$view_out" 2>>"$LOG")"
    if [[ -z "$calc" ]]; then
      TTL_FAIL_REASON="gh pr view ${p} 响应形状异常（jq 解析失败），占坑判定 fail-closed"
      IFS="$old_ifs"
      return 2
    fi
    anchor_iso="$(jq -r '.anchor // ""' <<<"$calc")"
    up_iso="$(jq -r '.updatedAt // ""' <<<"$calc")"
    if [[ -z "$anchor_iso" ]]; then
      TTL_FAIL_REASON="gh pr view ${p} 既无 commit 也无作者评论（停摆锚不可算），占坑判定 fail-closed"
      IFS="$old_ifs"
      return 2
    fi
    anchor_ep="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$anchor_iso" "+%s" 2>/dev/null)" || true
    if [[ ! "${anchor_ep:-}" =~ ^[0-9]+$ ]]; then
      TTL_FAIL_REASON="gh pr view ${p} 停摆锚日期不可解析（anchor=${anchor_iso}），占坑判定 fail-closed"
      IFS="$old_ifs"
      return 2
    fi
    if (( now - anchor_ep > cutoff )); then
      days=$(( (now - anchor_ep) / 86400 ))
      log "stalled-occupier 豁免：#${p} 停摆 ${days} 天（anchor=${anchor_iso}，updatedAt=${up_iso}）"
    else
      IFS="$old_ifs"
      return 1
    fi
  done
  IFS="$old_ifs"
  return 0
}

cmd_approve() {
  ensure_state
  acquire_lock
  local target_id="${1:-}"
  # 09-06 用户拍板：审批卡不设日限额（原 max_approval_pushes_per_day 机制整体移除，
  # config key 留作历史兼容、代码不再读取；E10d 转为「不限额」回归守卫）
  # 交互路开关：只把 null/缺失当缺省（false），false 是合法配置值（jq `//` falsy 陷阱）
  local interactive; interactive="$(cfg '.approval_interactive' 'false')"
  local ttl; ttl="$(cfg '.approval_ttl_hours' '48')"
  local dry_pushed=0

  local ids
  if [[ "$target_id" == "--all" ]]; then
    ids=$(jq -r '.items[] | select(.state == "awaiting-approval" and .draft != null) | .id' "$QUEUE")
  else
    ids="$target_id"
  fi
  [[ -n "$ids" ]] || { log "approve: 无可推项"; return 0; }

  for id in $ids; do
    local draft; draft="$(jq -r --arg id "$id" '.items[] | select(.id == $id) | .draft // ""' "$QUEUE")"
    # 相对路径一律锚定工作区根（=dirname(CONTRIB)，生产环境即 martin 根、沙箱即沙箱根）转绝对：
    # tunnel bin 会先 cd 到 tunnel-cli 仓目录再 exec，相对路径参数（deploy/approve 的 page）
    # 会被错解析到该仓下而「路径不存在」（09-06 drill 发卡静默降级事故的根因）
    [[ -n "$draft" && "$draft" != /* ]] && draft="$(dirname "$CONTRIB")/$draft"
    if [[ -z "$draft" || ! -f "$draft" ]]; then
      log "approve $id: 草稿不存在（${draft}），跳过"
      continue
    fi
    # ── 发卡前 premise TTL 轻复验（09-06 build-104067 抓到的框架缺口：旧文本路有、短码链没有；
    #    #102413 教训「过期 premise 的审批卡绝不能推」。execute 时仍有完整 TTL 兜底，这里收窄
    #    「卡已推但 premise 已死」的窗口。检查失败不阻断——仅当明确判死才拦截（gh 抖动不误杀）。
    #    release-gate 项跳过：issue 为 appId 合成号，不对应 GitHub issue，gh 查询无意义 ──
    local disp_pre
    disp_pre="$(jq -r --arg id "$id" '.items[] | select(.id == $id) | .disposition // ""' "$QUEUE")"
    if [[ "$disp_pre" == "release-gate" ]]; then
      log "approve $id: release-gate 项跳过 gh premise 复验（issue 为合成号）"
    elif [[ "$DRY_RUN" != "true" ]] && command -v "$GH_BIN" >/dev/null 2>&1; then
      local iss st prs own_pr
      iss="$(jq -r --arg id "$id" '.items[] | select(.id == $id) | .issue // ""' "$QUEUE")"
      own_pr="$(jq -r --arg id "$id" '.items[] | select(.id == $id) | .pr // ""' "$QUEUE")"
      st="$(GH_REPO="$(cfg '.repo' 'NousResearch/hermes-agent')" "$GH_BIN" issue view "$iss" --json state --jq .state 2>/dev/null || true)"
      if [[ "$st" == "CLOSED" ]]; then
        log "approve $id: premise 死亡（issue #$iss 已关闭）——置 rejected，不发卡"
        "$RQ" set "$id" rejected --note "premise 死亡：issue 已关闭（发卡前 TTL 轻复验拦截）" >/dev/null 2>&1 || true
        "$SELF_BIN" event premise-dead --key "premise-dead-$id" \
          --summary "审批项 $id 的 issue #$iss 已关闭，发卡前拦截未推送" >/dev/null 2>&1 || true
        continue
      fi
      # 占坑检查只对 own-PR/probe-salvage 有意义；review-evidence 的 PR 引用是评论对象/背景（同 execute.sh 修正）
      local disp_chk
      disp_chk="$(jq -r --arg id "$id" '.items[] | select(.id == $id) | .disposition // ""' "$QUEUE")"
      if [[ "$disp_chk" == "review-evidence" ]]; then
        prs=""
      else
      prs="$(GH_REPO="$(cfg '.repo' 'NousResearch/hermes-agent')" "$GH_BIN" pr list --search "$iss in:body" --state open --json number 2>/dev/null \
        | jq -r --arg own "$own_pr" '[.[]?.number | tostring | select(. != $own)] | join(",")' 2>/dev/null || true)"
      fi
      if [[ -n "$prs" && "$prs" != "null" ]]; then
        # 停摆豁免（卡 t_b8ef4f58）：与 execute.sh ttl_verify 第 2 项同源同步演进。
        # 全部停摆 → 豁免继续发卡；任一活跃 → 走原判死文案（一字不改）；
        # rc=2 取证失败 → fail-closed 拦截（不发卡；note/event 注明 fail-closed，不误报 premise 死亡）。
        local occ_rc=0
        occ_all_stalled "$(cfg '.repo' 'NousResearch/hermes-agent')" "$prs" || occ_rc=$?
        if (( occ_rc == 0 )); then
          log "approve $id: 占用 PR 全部停摆超限，stalled-occupier 豁免，继续发卡"
        elif (( occ_rc == 2 )); then
          log "approve $id: ${TTL_FAIL_REASON}——置 rejected，不发卡"
          "$RQ" set "$id" rejected --note "占坑判定 fail-closed：${TTL_FAIL_REASON}（发卡前 TTL 轻复验拦截）" >/dev/null 2>&1 || true
          "$SELF_BIN" event premise-dead --key "premise-dead-$id" \
            --summary "审批项 $id 发卡前占坑取证失败 fail-closed，未推送" >/dev/null 2>&1 || true
          continue
        else
          log "approve $id: premise 死亡（issue #$iss 已被 PR $prs 占坑）——置 rejected，不发卡"
          "$RQ" set "$id" rejected --note "premise 死亡：已被 PR $prs 占坑（发卡前 TTL 轻复验拦截）" >/dev/null 2>&1 || true
          "$SELF_BIN" event premise-dead --key "premise-dead-$id" \
            --summary "审批项 $id 的 issue #$iss 已被 PR $prs 占坑，发卡前拦截未推送" >/dev/null 2>&1 || true
          continue
        fi
      fi
    fi
    # 已成功推过则不重复
    local ok; ok="$(jq -r --arg id "$id" --arg d "$(today)" '.approvals[$d].ok[$id] // false' "$STATE" 2>/dev/null)"
    [[ "$ok" == "true" ]] && continue

    local card="/tmp/contrib-approval-$id.txt"

    if [[ "$interactive" == "true" ]]; then
      # ---- 交互路：人读页 + 随机 slug/短码 + 卡 v2 ----
      local slug="" code="" url="" page="" card_ok=0
      slug="$(gen_slug)" && code="$(gen_code)"
      # 截止时间 = awaiting_epoch（无则当前）+ approval_ttl_hours
      local base_ep deadline
      base_ep="$(jq -r --arg id "$id" '.items[] | select(.id == $id) | .awaiting_epoch // 0' "$QUEUE")"
      [[ "$base_ep" =~ ^[0-9]+$ ]] || base_ep="0"
      (( base_ep > 0 )) || base_ep="$(now_epoch)"
      deadline="$(date -r $(( base_ep + ttl * 3600 )) "+%m-%d %H:%M")"
      # 人读页 = draft 路径 + .page.md 后缀（约定派生文件，不入 rq；机器稿本体零改动）
      if [[ -n "$slug" && -n "$code" ]] \
         && _build_approval_page "$id" "$draft" "$deadline" "$ttl" > "${draft}.page.md"; then
        page="${draft}.page.md"
        # B-1（QA 审查）：再审批轮次先回收旧公开页——.tunnel 即将被新 slug/code 覆写，
        # 旧页面（公开可读含 draft 全文）会孤儿化且失去台账归属；失败不阻断发卡
        local old_slug old_rm
        old_slug="$(jq -r --arg id "$id" '.items[] | select(.id == $id) | .tunnel.slug // ""' "$QUEUE")"
        old_rm="$(jq -r --arg id "$id" '.items[] | select(.id == $id) | .tunnel.removed_at // ""' "$QUEUE")"
        if [[ -n "$old_slug" && -z "$old_rm" && "$DRY_RUN" != "true" ]] && command -v "$TUNNEL_BIN" >/dev/null 2>&1; then
          "$TUNNEL_BIN" rm "$old_slug" >/dev/null 2>&1 || true
          log "approve $id: 再审批轮次回收旧公开页 $old_slug"
        fi
        if [[ "$DRY_RUN" == "true" ]]; then
          # dry-run 登记语义：跳过真实部署，但 slug/code 生成 + rq 登记（合成 url）照常（沙箱链依赖）
          url="https://d.stringzhao.life/${slug}"
        elif command -v "$TUNNEL_BIN" >/dev/null 2>&1; then
          local deploy_out
          deploy_out=$("$TUNNEL_BIN" drops approve "$page" --name "$slug" 2>/dev/null || true)
          url="$(grep -oE 'https?://[^ ]+' <<<"$deploy_out" | tail -1)"
        fi
        if [[ -n "$url" ]]; then
          "$RQ" tunnel-deploy "$id" "$url" "$slug" "$code" >/dev/null
          log "approve $id: 审批页就绪（slug=${slug}，dry-run=${DRY_RUN}）"
          _build_approval_card_v2 "$id" "$url" "$code" "$deadline" "$ttl" > "$card"
          card_ok=1
        fi
      fi
      if (( card_ok == 0 )); then
        log "approve $id: 交互路未成（slug/短码/人读页/部署之一失败），降级旧卡路"
        rm -f "${draft}.page.md"
        _legacy_deploy "$id" "$draft"
        _build_approval_card "$id" > "$card"
      fi
    else
      # ---- 旧路（approval_interactive 非 true）：行为兼容 ----
      _legacy_deploy "$id" "$draft"
      _build_approval_card "$id" > "$card"
    fi

    # 审批推送记账；approvals[date] = {count, ok:{}, fail:{}}
    # 09-07 双修①：审批卡是用户的唯一决策触达通道，单发即败=永久卡死（rq-20260907-104693 实证：
    # iLink 30s cooldown 被同窗口回执挤爆，fail=1 后无人再推）。rc==1 类失败原地退避重试跨过
    # cooldown。rc==3（网关不可达）重试无意义，
    # 保持 osascript 兜底。重试只重发同一张卡，不重新部署 tunnel 页（slug/code 已登记）。
    local rc=0 attempts total backoff
    total="${NOTIFY_CARD_ATTEMPTS:-3}"
    backoff="${NOTIFY_CARD_BACKOFF:-35}"
    attempts=0
    while :; do
      attempts=$((attempts+1))
      rc=0
      _send "$card" "contrib L2 审批 $id" || rc=$?
      (( rc == 0 || rc == 3 )) && break
      (( attempts >= total )) && break
      sleep "$backoff"
    done
    if (( rc == 3 )); then
      _osascript "contrib 审批 $id 就绪（hermes 网关不可达，未推送）——明细 contrib-data/pending/$id.md"
      log "approve $id: 网关不可达，osascript 兜底"
    elif (( rc == 0 )); then
      if [[ "$DRY_RUN" != "true" ]]; then
        jq --arg d "$(today)" --arg id "$id" '
          .approvals[$d].count = ((.approvals[$d].count // 0) + 1)
          | .approvals[$d].ok[$id] = true' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
      fi
      log "approve $id: 审批卡已推送（dry-run=${DRY_RUN}，attempt=${attempts}）"
      dry_pushed=$((dry_pushed+1))
    else
      local fail_prev fail_total
      fail_prev="$(jq -r --arg id "$id" --arg d "$(today)" '.approvals[$d].fail[$id] // 0' "$STATE")"
      fail_total=$((fail_prev + attempts))
      jq --arg d "$(today)" --arg id "$id" --argjson n "$fail_total" '.approvals[$d].fail[$id] = $n' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
      (( fail_total >= 3 )) && _osascript "contrib 审批 $id 推送连续 ${fail_total} 次失败（微信通道异常？）"
      log "approve $id: 推送失败（本次尝试 ${attempts} 次，累计 ${fail_total} 次）"
    fi
    rm -f "$card"
  done
  (( dry_pushed > 0 )) && return 0 || return 0
}

# ---------------- receipt（回执，独立计数） ----------------
cmd_receipt() {
  ensure_state
  local id="${1:-}"; shift || true
  local summary=""
  while [[ $# -gt 0 ]]; do case "$1" in --summary) summary="$2"; shift 2 ;; *) shift ;; esac; done
  local msg="/tmp/contrib-receipt-$id.txt"
  printf '✅【contrib 回执】#%s 已执行\n%s\n（账目: martin/approved.log）\n' "$id" "$summary" > "$msg"
  local rc=0; _send "$msg" "contrib 回执 $id" || rc=$?
  if (( rc == 0 )); then
    state_bump receipts "$(today)"
    log "receipt $id 已发"
  else
    log "receipt $id 发送失败 rc=${rc}（不影响记账，明晨对账补报）"
  fi
  rm -f "$msg"
  return 0
}

# ---------------- resolve（修④ 告警闭环：标记 resolved + ✅ 收尾卡） ----------------
# 定位账本未 resolved 匹配行（--key 精确 / --cluster 簇匹配；两者同给=与语义）→ 原行标记
# resolved=true、resolved_at、resolution=S；命中行存在 pushed==true 时复用 _send 发一条
# 跟进收尾卡（✅ 含 key 与 summary）并置 resolution_sent=true。
# 无匹配行 → 非零退出 + stdout 回显目标 + 账本与推送零副作用（显式失败优于静默幂等：
# 「已闭环」的假回执会让根因继续烧）。
# dry-run 语义同 _send（打印不发送；dry-run 不置 resolution_sent——未真发不算收尾）。
cmd_resolve() {
  ensure_state
  local key="" cluster="" summary=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --key) key="${2:-}"; shift 2 ;;
      --cluster) cluster="${2:-}"; shift 2 ;;
      --summary) summary="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "$key" || -n "$cluster" ]] || { echo "用法: resolve --key K --summary S [--cluster C]" >&2; exit 2; }
  local ident="${key:-$cluster}"
  # 候选行预过滤（key 双格式 / 簇子串），逐行 jq 校验
  local pre
  if [[ -n "$key" ]]; then
    pre="$(grep -nF -e "\"key\":\"$key\"" -e "\"key\": \"$key\"" "$EVENTS" 2>/dev/null || true)"
  else
    pre="$(grep -nF -e "$cluster" -e '"cluster"' "$EVENTS" 2>/dev/null || true)"
  fi
  local matches="/tmp/contrib-resolve-$$.txt" line n raw info lkey lch lcl lres lpushed
  : > "$matches"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    n="${line%%:*}"
    raw="${line#*:}"
    info="$(printf '%s' "$raw" | jq -r --arg sep "$(printf '\037')" '[(.key // ""), (.channel // "contrib"), (.cluster // ""), ((.resolved // false) | tostring), ((.pushed // false) | tostring)] | join($sep)' 2>/dev/null || true)"
    [[ -n "$info" ]] || continue
    IFS=$'\x1f' read -r lkey lch lcl lres lpushed <<<"$info"
    [[ "$lres" == "true" ]] && continue
    [[ -n "$lcl" ]] || lcl="$(cluster_key_of "$lkey")"
    if [[ -n "$key" && -n "$cluster" ]]; then
      [[ "$lkey" == "$key" && "$lcl" == "$cluster" ]] || continue
    elif [[ -n "$key" ]]; then
      [[ "$lkey" == "$key" ]] || continue
    else
      [[ "$lcl" == "$cluster" ]] || continue
    fi
    printf '%s\t%s\t%s\n' "$n" "$lkey" "$lpushed" >> "$matches"
  done <<<"$pre"
  local n_matches; n_matches="$(wc -l < "$matches" | tr -d ' ')"
  if (( n_matches == 0 )); then
    echo "resolve: 未命中未 resolved 告警 ${ident}（账本与推送零动作）"
    rm -f "$matches"
    return 1
  fi
  # 收尾卡：任一命中行已推送过则发一条（未推送过的告警在账本层面闭环即可，无「已推送后解决」可言）
  local pushed_any=0
  while IFS=$'\t' read -r n lkey lpushed; do
    [[ "$lpushed" == "true" ]] && pushed_any=1
  done < "$matches"
  # 路径禁与 matches 同址（曾同名覆盖致标记丢失：/tmp/contrib-resolve-$$.txt 双占）
  local send_rc=0 card="/tmp/contrib-resolve-card-$$.txt" res="${summary:-（已解决）}"
  if (( pushed_any == 1 )); then
    printf '✅【contrib 闭环】%s 已解决：%s\n' "$ident" "$res" > "$card"
    _send "$card" "contrib 闭环 ${ident}" || send_rc=$?
  fi
  rm -f "$card"
  # 行进位标记（line-splice）：resolution_sent 仅当收尾卡真发出
  local rsent="false"
  if (( pushed_any == 1 )) && (( send_rc == 0 )) && [[ "$DRY_RUN" != "true" ]]; then
    rsent="true"
  fi
  local upd="/tmp/contrib-resolve-upd-$$.tsv" args_json
  : > "$upd"
  args_json="$(jq -cn --arg ts "$(ts)" --arg res "$res" --argjson sent "$rsent" \
    '{ts: $ts, resolution: $res, sent: $sent}')"
  while IFS=$'\t' read -r n lkey lpushed; do
    if [[ "$lpushed" == "true" ]]; then
      printf '%s\t%s\t%s\n' "$n" "$args_json" \
        '.resolved = true | .resolved_at = $a.ts | .resolution = $a.resolution | (if $a.sent then .resolution_sent = true else . end)' >> "$upd"
    else
      printf '%s\t%s\t%s\n' "$n" "$args_json" \
        '.resolved = true | .resolved_at = $a.ts | .resolution = $a.resolution' >> "$upd"
    fi
  done < "$matches"
  _events_splice "$upd"
  rm -f "$upd" "$matches"
  log "resolve ~ ${ident}（命中 ${n_matches} 行，pushed=${pushed_any}，send_rc=${send_rc}，resolution_sent=${rsent}）"
  return "$send_rc"
}

# ---------------- fallback ----------------
cmd_fallback() {
  _osascript "${1:-contrib-watch 通知}"
  log "fallback: $1"
}

# ---------------- 入口 ----------------
# source guard：测试套件 source 本文件复用纯函数（cfg/state_* 等）；默认 unset = 完全现状
[[ "${NOTIFY_SOURCE_ONLY:-}" == "1" ]] && { return 0 2>/dev/null || exit 0; }

cmd="${1:-help}"; shift || true
case "$cmd" in
  event)   cmd_event "$@" ;;
  flush)   cmd_flush ;;
  resolve) cmd_resolve "$@" ;;
  approve) cmd_approve "$@" ;;
  receipt) cmd_receipt "$@" ;;
  fallback) cmd_fallback "$@" ;;
  send-digest) cmd_send_digest "$@" ;;
  help|*)  sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
