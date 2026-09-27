#!/bin/bash
# =============================================================================
# statusline-plan-cluster.acceptance.test.sh — statusline 套餐展示 红队验收套件
#
# 依据（设计级 SSOT，实现代码零读取）：
#   - state.md `## 验收场景` 场景 1-15（冻结谓词，逐条对应硬断言）
#   - state.md `## 契约规约` 1-4（stdout 单行/fail-open 硬要求；DB 只读；token 保密；fixture 契约）
#   - state.md `## 验证方案`（fixture e2e / 只读辅助锚 / 性能门禁 artifact / cmp 纪律）
#   - context.md 测试形态（HOME fixture + stdin JSON + stdout/exit 断言）
#
# 覆盖映射（mutation-kill，与 state.md 覆盖说明同源）：
#   no-op                          → 场景 1/2（套餐名不上屏即红）
#   按 base_url 而非 token 匹配    → 场景 3
#   只读 is_current 捷径           → 场景 4.P1/P2
#   去掉 app_type='claude' 过滤    → 场景 4.P3（hermes 条目 si=5 干扰）
#   跳过 MODEL 消歧 / 缓存键缺 model 维度 → 场景 5（同 token 双连跑反转用例）
#   跳过 is_current tie-break      → 场景 6（is_current 胜者 si 故意更大）
#   跳过 sort_index / 取首行       → 场景 7（插入序冻结：期望胜者非首行）
#   缓存跨 token 变化命中旧值      → 场景 8
#   token 落盘/上屏                → 场景 9 + 终局扫尾
#   fail-open 闭集                 → 场景 10-13、15（缓存命中绕过 fail-open → 11.P3 两版各验）
#   无缓存                         → 场景 14.P1
#   顺序颠倒 / 多行                → 1.P3 / 2.P3 / 1.P4 / 2.P4
#
# 红队纪律：黑盒；每断言硬失败；无 skip 通道；磁盘字节对照一律 /usr/bin/cmp
# （历史知识：本机 PATH 上 diff 被 OpenHarmony toolchain 遮蔽，裸 diff 判据恒真假绿）。
# 颜色语义（mjs plan=P.sage / model 迁移 P.sky）ANSI 剥离测不出 → VISUAL_RESIDUE: 留 QA 真机判定。
# =============================================================================
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=rt-lib.sh
source "$SELF_DIR/rt-lib.sh"

rt_env_gate
t_init "statusline-plan-cluster.acceptance.test.sh"

# ---- 套件级登记与随机物 ----
RT_REG_HOMES="$RT_TMPDIR/rt-sl-homes.txt"
RT_REG_SIDS="$RT_TMPDIR/rt-sl-sids.txt"
RT_DRIVE_TMPS=""
: > "$RT_REG_HOMES"; : > "$RT_REG_SIDS"
rm -f /tmp/cc-sl-rt-s*.plan /tmp/cc-sl-rt-s*.git \
      "$RT_TMPDIR"/cc-sl-rt-s*.plan "$RT_TMPDIR"/cc-sl-rt-s*.git 2>/dev/null || :   # 预清本套件确定性 sid 缓存（真实 CC session_id 为 UUID 不撞 rt- 前缀）

T_SHARED="$(gen_hex 16)"; T_ECHO="$(gen_hex 16)"; T_KIMI="$(gen_hex 16)"
T_DS="$(gen_hex 16)";     T_NONE="$(gen_hex 16)"
if [ "$(printf '%s\n%s\n%s\n%s\n%s\n' "$T_SHARED" "$T_ECHO" "$T_KIMI" "$T_DS" "$T_NONE" \
       | LC_ALL=C sort -u | wc -l | tr -d ' ')" != "5" ]; then
  rt_harness_die "假 token 两两碰撞（重跑即可，概率事件）"
fi
FP_ECHO="$(fp8 "$T_ECHO")"

# 契约 3：token 值永不入 artifact——此处只登记指纹与绑定字面
{
  printf 'MODEL_STR=%s\nBASE_FIX=%s\nM_FLASH=%s\nM_LAST=%s\nM_ECHO=%s\n' \
    "$MODEL_STR" "$BASE_FIX" "$M_FLASH" "$M_LAST" "$M_ECHO"
  printf 'FP(T_shared)=%s\nFP(T_echo)=%s\nFP(T_kimi)=%s\nFP(T_ds)=%s\nFP(T_none)=%s\n' \
    "$(fp8 "$T_SHARED")" "$FP_ECHO" "$(fp8 "$T_KIMI")" "$(fp8 "$T_DS")" "$(fp8 "$T_NONE")"
  printf 'fake_token_len=%s（token 值依契约 3 不入任何 artifact）\n' "${#T_ECHO}"
  printf 'SAGE_SH=%s\nMJS=%s\n' "$SAGE_SH" "$MJS"
} > "$ARTIFACTS/env-facts.txt"

rt_cleanup() {
  local hf sid p
  while IFS= read -r hf; do [ -n "$hf" ] && rm -rf "$hf" 2>/dev/null; done < "$RT_REG_HOMES"
  while IFS= read -r sid; do
    [ -n "$sid" ] || continue
    while IFS= read -r p; do [ -n "$p" ] && rm -f "$p" 2>/dev/null; done < <(node_cache_paths "$sid")
  done < "$RT_REG_SIDS"
  # 本套件假 sid（rt- 前缀，真实 CC session_id 为 UUID 不撞）的 node 侧车（quota 缓存 .git 等）
  rm -f "$RT_TMPDIR"/cc-sl-rt-s*.plan "$RT_TMPDIR"/cc-sl-rt-s*.git \
        /tmp/cc-sl-rt-s*.plan /tmp/cc-sl-rt-s*.git 2>/dev/null
  rmdir "$RT_HOME_ROOT" 2>/dev/null
  [ -n "$RT_DRIVE_TMPS" ] && rm -f $RT_DRIVE_TMPS 2>/dev/null
  return 0
}
trap rt_cleanup EXIT

# 通用断言：整行 fail-open 下四个套餐名全部缺席（设计：套餐段隐藏）
assert_no_plan_names() { # <clean> <label>
  local c="$1" lbl="$2" n
  for n in "glm flash lastest" "glm flash echo" "kimi" "deepseek-flash"; do
    assert_not_contains "$c" "$n" "$lbl 套餐名缺席 [$n]"
  done
}

# token 泄漏单文件扫描（S9/终局共用；副作用写 RT_LEAK）
rt_scan_leak() { # <file>
  local f="$1" t
  for t in "$T_SHARED" "$T_ECHO" "$T_KIMI" "$T_DS"; do
    if grep -qFa -- "$t" "$f" 2>/dev/null; then RT_LEAK="${RT_LEAK}${t} @ ${f}\n"; fi
  done
}

# =============================================================================
t_case "场景1 bash 渲染「套餐 · 模型」身份簇（Happy Path）"
new_home s01; db_set_a; write_settings full "$T_ECHO" ""
drive_bash "$(json_bash_model_only)"
art_save s01p1; art_save s01p2; art_save s01p3; art_save s01p4   # 同一次驱动的观察，逐谓词各落 artifact
C1="$(cleaned_out)"
assert_exit 0 "$R_RC" "1.P1 exit==0"
assert_contains "$C1" "glm flash echo · $MODEL_STR" "1.P1 渲染 glm flash echo · <模型绑定串>"
RS1="$(rstrip "$C1")"
case "$RS1" in
  *"$MODEL_STR") _pass "1.P2 身份簇位于行尾（rstrip 后以模型绑定串结尾）" ;;
  *) _fail "1.P2 身份簇位于行尾" "rstrip 后不以 [$MODEL_STR] 结尾：[$RS1]" ;;
esac
assert_not_contains "$C1" "$MODEL_STR · glm flash echo" "1.P3 无反序簇 <模型> · 套餐"
assert_eq "$(line_count "$C1")" "1" "1.P4 stdout 单行"

# =============================================================================
t_case "场景2 node 渲染「模型 · 套餐」身份簇（Happy Path）"
new_home s02; db_set_a; write_settings full "$T_ECHO" ""
drive_node "$(json_node_full rt-s02)" "rt-s02"
art_save s02p1; art_save s02p2; art_save s02p3; art_save s02p4   # 同一次驱动的观察，逐谓词各落 artifact
C2="$(cleaned_out)"
assert_exit 0 "$R_RC" "2.P1 exit==0"
assert_contains "$C2" "$MODEL_STR · glm flash echo" "2.P1 渲染 <模型绑定串> · glm flash echo"
assert_contains "$(firstline "$C2")" "$MODEL_STR · glm flash echo" "2.P2 身份簇位于行首"
assert_not_contains "$C2" "glm flash echo · $MODEL_STR" "2.P3 无反序簇 套餐 · <模型>"
assert_eq "$(line_count "$C2")" "1" "2.P4 正常宽度下 stdout 单行"

# =============================================================================
t_case "场景3 同 base_url 异 key 由指纹唯一区分（机制核心）"
new_home s03; db_set_a; write_settings full "$T_ECHO" ""
SNAP3="$RT_TMPDIR/rt-sl-db-s03.snap"; db_snapshot "$SNAP3"
drive_bash "$(json_bash_model_only)"
art_save s03p1
assert_contains "$(cleaned_out)" "glm flash echo · $MODEL_STR" "3.P1 T_echo → glm flash echo"
write_settings full "$T_SHARED" ""
drive_bash "$(json_bash_model_only)"
art_save s03p2
C3B="$(cleaned_out)"
assert_contains "$C3B" "glm flash lastest · $MODEL_STR" "3.P2 T_shared → glm flash lastest"
assert_not_contains "$C3B" "glm flash echo ·" "3.P2 不再显示 glm flash echo"
drive_node "$(json_node_full rt-s03)" "rt-s03"
art_save s03p3
assert_contains "$(cleaned_out)" "$MODEL_STR · glm flash lastest" "3.P3 node T_shared → glm flash lastest"
db_assert_unwritten "$SNAP3" "3.锚 fixture DB 三次驱动后逐字节不变（契约 2 只读辅助锚）"

# =============================================================================
t_case "场景4 显示跟随 token 指纹而非 DB is_current"
new_home s04
KIMI_CURRENT=1; db_set_a; KIMI_CURRENT=0
write_settings full "$T_ECHO" ""
drive_bash "$(json_bash_model_only)"
art_save s04p1
C4="$(cleaned_out)"
assert_contains "$C4" "glm flash echo · $MODEL_STR" "4.P1 is_current=1 是 kimi 仍显示 glm flash echo"
assert_not_contains "$C4" "kimi" "4.P1 不显示 is_current 条目 kimi"
drive_node "$(json_node_full rt-s04)" "rt-s04"
art_save s04p2
C4N="$(cleaned_out)"
assert_contains "$C4N" "$MODEL_STR · glm flash echo" "4.P2 node 同语义"
assert_not_contains "$C4N" "kimi" "4.P2 node 不显示 kimi"
write_settings full "$T_SHARED" ""
drive_bash "$(json_bash_model_only)"
art_save s04p3
C4P3="$(cleaned_out)"
assert_contains "$C4P3" "glm flash lastest" "4.P3 bash T_shared 命中 claude 条目 glm flash lastest"
assert_not_contains "$C4P3" "hermes-glm-flash-lastest" "4.P3 bash 不渲染 hermes 条目（app_type=claude 过滤，杀变异）"
drive_node "$(json_node_full rt-s04b)" "rt-s04b"
art_save s04p3-node
C4P3N="$(cleaned_out)"
assert_contains "$C4P3N" "glm flash lastest" "4.P3 node T_shared 命中 glm flash lastest"
assert_not_contains "$C4P3N" "hermes-glm-flash-lastest" "4.P3 node 不渲染 hermes 条目"

# =============================================================================
t_case "场景5 指纹撞车 L1——env.ANTHROPIC_MODEL 精确相等消歧"
new_home s05; db_set_b 0 20 0 10
write_settings full "$T_SHARED" "$M_FLASH"
drive_bash "$(json_bash_model_only)"
art_save s05p1
C5A="$(cleaned_out)"
assert_contains "$C5A" "glm flash lastest · $MODEL_STR" "5.P1 MODEL=M_flash → glm flash lastest"
assert_not_contains "$C5A" "glm lastest ·" "5.P1 不显示 glm lastest"
write_settings full "$T_SHARED" "$M_LAST"
drive_bash "$(json_bash_model_only)"
art_save s05p2
C5B="$(cleaned_out)"
assert_contains "$C5B" "glm lastest · $MODEL_STR" "5.P2 MODEL=M_last 反转显示 glm lastest（同 token 双连跑，杀缓存键缺 model 维度）"
assert_not_contains "$C5B" "glm flash lastest ·" "5.P2 不再显示 glm flash lastest"
write_settings full "$T_SHARED" "$M_FLASH"
drive_node "$(json_node_full rt-s05)" "rt-s05"
art_save s05p3
C5N="$(cleaned_out)"
assert_contains "$C5N" "$MODEL_STR · glm flash lastest" "5.P3 node 按 MODEL 消歧"
assert_not_contains "$C5N" " · glm lastest" "5.P3 node 不显示 glm lastest"

# =============================================================================
t_case "场景6 指纹撞车 L2——is_current=1 优先"
new_home s06; db_set_b 1 20 0 10   # is_current 胜者 si=20 故意大于败者 si=10（杀跳过 is_current 取 si 最小）
write_settings full "$T_SHARED" ""
drive_bash "$(json_bash_model_only)"
art_save s06p1
C6="$(cleaned_out)"
assert_contains "$C6" "glm flash lastest · $MODEL_STR" "6.P1 is_current=1 条目 glm flash lastest 胜出"
assert_not_contains "$C6" "glm lastest ·" "6.P1 不显示 glm lastest"
drive_node "$(json_node_full rt-s06)" "rt-s06"
art_save s06p2
C6N="$(cleaned_out)"
assert_contains "$C6N" "$MODEL_STR · glm flash lastest" "6.P2 node 同语义"
assert_not_contains "$C6N" " · glm lastest" "6.P2 node 不显示 glm lastest"

# =============================================================================
t_case "场景7 指纹撞车 L3——sort_index 最小兜底"
new_home s07; db_set_b 0 20 0 10   # 插入序冻结：glm flash lastest(id1,si20) 先、glm lastest(id2,si10) 后——期望胜者非首行
write_settings full "$T_SHARED" ""
drive_bash "$(json_bash_model_only)"
art_save s07p1
C7="$(cleaned_out)"
assert_contains "$C7" "glm lastest · $MODEL_STR" "7.P1 sort_index 最小的 glm lastest 兜底胜出"
assert_not_contains "$C7" "glm flash lastest ·" "7.P1 不显示 glm flash lastest"
drive_node "$(json_node_full rt-s07)" "rt-s07"
art_save s07p2
C7N="$(cleaned_out)"
assert_contains "$C7N" "$MODEL_STR · glm lastest" "7.P2 node 同语义"
assert_not_contains "$C7N" " · glm flash lastest" "7.P2 node 不显示 glm flash lastest"

# =============================================================================
t_case "场景8 切换套餐后下一次渲染即反映新套餐（缓存正确性）"
new_home s08; db_set_a; write_settings full "$T_ECHO" ""
drive_bash "$(json_bash_model_only)"
art_save s08run1
C8P="$(cleaned_out)"
assert_contains "$C8P" "glm flash echo · $MODEL_STR" "8.前置 run1 基线显示 glm flash echo（缓存已建立前提，硬断言）"
write_settings full "$T_KIMI" ""                                   # 模拟 cc-switch 切换：settings token 换
sqlite3 "$(db_file)" "UPDATE providers SET is_current=1 WHERE name='kimi';"
SNAP8="$RT_TMPDIR/rt-sl-db-s08.snap"; db_snapshot "$SNAP8"          # 锚窗口：切换落库后 → 两次驱动
drive_bash "$(json_bash_model_only)"
art_save s08p1
C8="$(cleaned_out)"
assert_contains "$C8" "kimi · $MODEL_STR" "8.P1 token T_echo→T_kimi 后立即显示 kimi（缓存键随指纹失效）"
assert_not_contains "$C8" "glm flash echo" "8.P1 不再显示 glm flash echo"
drive_node "$(json_node_full rt-s08)" "rt-s08"
art_save s08p2
C8N="$(cleaned_out)"
assert_contains "$C8N" "$MODEL_STR · kimi" "8.P2 node 同语义"
assert_not_contains "$C8N" "glm flash echo" "8.P2 node 不再显示 glm flash echo"
db_assert_unwritten "$SNAP8" "8.锚 切换落库后两次驱动 DB 逐字节不变"

# =============================================================================
t_case "场景9 token 保密硬约束——零 stdout/零落盘"
RT_LEAK=""
MISSING9=""
for F9 in s01p1 s01p2 s01p3 s01p4 s02p1 s02p2 s02p3 s02p4 s03p1 s03p2 s03p3 \
          s04p1 s04p2 s04p3 s04p3-node s05p1 s05p2 s05p3 s06p1 s06p2 \
          s07p1 s07p2 s08p1 s08p2 s08run1; do
  [ -f "$ARTIFACTS/$F9.out" ] || MISSING9="$MISSING9 $F9"
done
[ -z "$MISSING9" ] || _fail "9.P1 前置 artifact 齐备" "场景 1-8 artifact 缺失: ${MISSING9} （前置未满足，fail-closed）"
FILES9="$(LC_ALL=C find "$ARTIFACTS" -type f \( -name '*.out' -o -name '*.err' \) 2>/dev/null | LC_ALL=C sort)"
while IFS= read -r f; do [ -n "$f" ] && rt_scan_leak "$f"; done <<EOF9
$FILES9
EOF9
{
  printf '扫描范围（场景1-8 全部 .out/.err artifact）：\n%s\n' "$FILES9"
  printf '泄漏清单（应为空）：\n%b' "$RT_LEAK"
} > "$ARTIFACTS/s09p1.out"
if [ -z "$RT_LEAK" ] && [ -z "$MISSING9" ]; then
  _pass "9.P1 场景1-8 全部 stdout/stderr artifact 零 token 本体"
else
  _fail "9.P1 stdout/stderr 零 token" "泄漏或前置缺失，见 s09p1.out"
fi

# P2：脚本运行期间新建/修改的文件（各场景 HOME 树 + 本套件 node plan 缓存），
# 显式排除 fixture 预置输入 settings.json 与 cc-switch.db（含 sidecar）
RT_SCAN_BAD=""; RT_SCAN_FP=0; RT_SCAN_LIST=""; RT_SCAN_FP_LIST=""
rt_scan_p2_file() { # <file>
  local f="$1" t
  case "$f" in
    */.claude/settings.json|*/.cc-switch/cc-switch.db|*/.cc-switch/cc-switch.db-*) return 0 ;;
  esac
  RT_SCAN_LIST="${RT_SCAN_LIST}${f}
"
  for t in "$T_SHARED" "$T_ECHO" "$T_KIMI" "$T_DS"; do
    if grep -qFa -- "$t" "$f" 2>/dev/null; then RT_SCAN_BAD="${RT_SCAN_BAD}${t} @ ${f}
"; fi
  done
  if grep -qFa -- "$FP_ECHO" "$f" 2>/dev/null; then
    RT_SCAN_FP=1; RT_SCAN_FP_LIST="${RT_SCAN_FP_LIST}${f}
"
  fi
}
while IFS= read -r hf; do
  [ -n "$hf" ] || continue
  while IFS= read -r f; do [ -n "$f" ] && rt_scan_p2_file "$f"; done < <(LC_ALL=C find "$hf" -type f 2>/dev/null)
done < "$RT_REG_HOMES"
while IFS= read -r sid; do
  [ -n "$sid" ] || continue
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -f "$p" ] && rt_scan_p2_file "$p"
  done < <(node_cache_paths "$sid")
done < "$RT_REG_SIDS"
{
  printf 'P2 扫描范围（HOME 树 + node plan 缓存；已排除 fixture 预置输入及其 sidecar）：\n%s\n' "$RT_SCAN_LIST"
  printf '含 FP(T_echo)=%s 的文件（至少 1 个）：\n%s\n' "$FP_ECHO" "$RT_SCAN_FP_LIST"
  printf 'token 违例（应为空）：\n%s\n' "$RT_SCAN_BAD"
} > "$ARTIFACTS/s09p2.out"
if [ -z "$RT_SCAN_BAD" ] && [ "$RT_SCAN_FP" = "1" ]; then
  _pass "9.P2 运行期落盘文件零 token 本体且至少一文件含 FP(T_echo)"
else
  _fail "9.P2 缓存零 token 且含指纹" "违例=[${RT_SCAN_BAD:-无}] FP命中=${RT_SCAN_FP}，见 s09p2.out"
fi

# =============================================================================
t_case "场景10 fail-open——无生效 token"
new_home s10a; db_set_a; write_settings notoken "" ""
drive_bash "$(json_bash_model_only)"
art_save s10p1
C10A="$(cleaned_out)"
assert_exit 0 "$R_RC" "10.P1 exit==0"
assert_contains "$C10A" "$MODEL_STR" "10.P1 整行照常渲染（模型名在）"
assert_no_plan_names "$C10A" "10.P1"
new_home s10b; db_set_a; write_settings noenv "" ""
drive_bash "$(json_bash_model_only)"
art_save s10p2
C10B="$(cleaned_out)"
assert_exit 0 "$R_RC" "10.P2 exit==0"
assert_contains "$C10B" "$MODEL_STR" "10.P2 无 env 块整行照常渲染"
assert_no_plan_names "$C10B" "10.P2"
new_home s10c; db_set_a; write_settings notoken "" ""
drive_node "$(json_node_full rt-s10c)" "rt-s10c"
art_save s10p3
C10N="$(cleaned_out)"
assert_exit 0 "$R_RC" "10.P3 exit==0"
assert_contains "$C10N" "$MODEL_STR" "10.P3 node 整行照常渲染"
assert_no_plan_names "$C10N" "10.P3"

# =============================================================================
t_case "场景11 fail-open——DB 缺失（含热缓存后删除，两版各验）"
new_home s11a; write_settings full "$T_ECHO" ""   # .cc-switch 目录在、DB 文件不存在（冷）
drive_bash "$(json_bash_model_only)"
art_save s11p1
C11A="$(cleaned_out)"
assert_exit 0 "$R_RC" "11.P1 exit==0"
assert_contains "$C11A" "$MODEL_STR" "11.P1 整行照常渲染"
assert_no_plan_names "$C11A" "11.P1"
new_home s11b; write_settings full "$T_ECHO" ""
drive_node "$(json_node_full rt-s11b)" "rt-s11b"
art_save s11p2
C11B="$(cleaned_out)"
assert_exit 0 "$R_RC" "11.P2 exit==0"
assert_contains "$C11B" "$MODEL_STR" "11.P2 node 整行照常渲染"
assert_no_plan_names "$C11B" "11.P2"
# 11.P3 bash：先成功解析一次（缓存建立）→ 删 DB → 下一次渲染仍隐藏
new_home s11c; db_set_a; write_settings full "$T_ECHO" ""
drive_bash "$(json_bash_model_only)"
art_save s11c-pre
assert_contains "$(cleaned_out)" "glm flash echo · $MODEL_STR" "11.P3 前置 首次解析成功显示 echo（硬断言，缓存确实已建立）"
rm -f "$(db_file)"
drive_bash "$(json_bash_model_only)"
art_save s11p3
C11P3="$(cleaned_out)"
assert_exit 0 "$R_RC" "11.P3 bash exit==0"
assert_contains "$C11P3" "$MODEL_STR" "11.P3 bash 整行照常渲染"
assert_no_plan_names "$C11P3" "11.P3 bash（fail-open 优先于缓存命中）"
# 11.P3 node：同一 session_id 两次跑（/tmp 会话缓存新鲜），删 DB 后仍隐藏
new_home s11d; db_set_a; write_settings full "$T_ECHO" ""
drive_node "$(json_node_full rt-s11d)" "rt-s11d"
art_save s11d-pre
assert_contains "$(cleaned_out)" "$MODEL_STR · glm flash echo" "11.P3 前置 node 首次解析成功（硬断言）"
rm -f "$(db_file)"
drive_node "$(json_node_full rt-s11d)" "rt-s11d"   # 同 sid：缓存路径 /tmp/cc-sl-rt-s11d.plan 仍新鲜
art_save s11p3-node
C11P3N="$(cleaned_out)"
assert_exit 0 "$R_RC" "11.P3 node exit==0"
assert_contains "$C11P3N" "$MODEL_STR" "11.P3 node 整行照常渲染"
assert_no_plan_names "$C11P3N" "11.P3 node（fail-open 优先于缓存命中）"

# =============================================================================
t_case "场景12 fail-open——schema 变更与数据损坏"
new_home s12a; db_no_settings_col; write_settings full "$T_ECHO" ""
drive_bash "$(json_bash_model_only)"
art_save s12p1
C12="$(cleaned_out)"
assert_exit 0 "$R_RC" "12.P1 缺 settings_config 列 exit==0"
assert_contains "$C12" "$MODEL_STR" "12.P1 整行照常渲染"
assert_no_plan_names "$C12" "12.P1"
new_home s12b; db_other_table; write_settings full "$T_ECHO" ""
drive_bash "$(json_bash_model_only)"
art_save s12p2
C12="$(cleaned_out)"
assert_exit 0 "$R_RC" "12.P2 无 providers 表 exit==0"
assert_contains "$C12" "$MODEL_STR" "12.P2 整行照常渲染"
assert_no_plan_names "$C12" "12.P2"
new_home s12c; db_garbage; write_settings full "$T_ECHO" ""
drive_bash "$(json_bash_model_only)"
art_save s12p3
C12="$(cleaned_out)"
assert_exit 0 "$R_RC" "12.P3 非 SQLite 垃圾字节 exit==0（不崩溃不挂起）"
assert_contains "$C12" "$MODEL_STR" "12.P3 整行照常渲染"
assert_no_plan_names "$C12" "12.P3"
new_home s12d; db_set_a; db_break_echo_json; write_settings full "$T_ECHO" ""
drive_bash "$(json_bash_model_only)"
art_save s12p4
C12="$(cleaned_out)"
assert_exit 0 "$R_RC" "12.P4 命中条目 settings_config 非法 JSON bash exit==0"
assert_contains "$C12" "$MODEL_STR" "12.P4 整行照常渲染"
assert_no_plan_names "$C12" "12.P4"
drive_node "$(json_node_full rt-s12d)" "rt-s12d"
art_save s12p5
C12="$(cleaned_out)"
assert_exit 0 "$R_RC" "12.P5 node 同场景 exit==0"
assert_contains "$C12" "$MODEL_STR" "12.P5 node 整行照常渲染"
assert_no_plan_names "$C12" "12.P5"

# =============================================================================
t_case "场景13 fail-open——指纹无匹配条目"
new_home s13a; db_set_a; write_settings full "$T_NONE" ""
drive_bash "$(json_bash_model_only)"
art_save s13p1
C13="$(cleaned_out)"
assert_exit 0 "$R_RC" "13.P1 exit==0"
assert_contains "$C13" "$MODEL_STR" "13.P1 整行照常渲染"
assert_no_plan_names "$C13" "13.P1"
drive_node "$(json_node_full rt-s13a)" "rt-s13a"
art_save s13p2
C13="$(cleaned_out)"
assert_exit 0 "$R_RC" "13.P2 node exit==0"
assert_contains "$C13" "$MODEL_STR" "13.P2 node 整行照常渲染"
assert_no_plan_names "$C13" "13.P2"
new_home s13b; db_empty_providers; write_settings full "$T_ECHO" ""
drive_bash "$(json_bash_model_only)"
art_save s13p3
C13="$(cleaned_out)"
assert_exit 0 "$R_RC" "13.P3 空表 exit==0"
assert_contains "$C13" "$MODEL_STR" "13.P3 整行照常渲染"
assert_no_plan_names "$C13" "13.P3"

# =============================================================================
t_case "场景14 解析缓存产物存在且连续渲染稳定"
new_home s14; db_set_a; write_settings full "$T_ECHO" ""
drive_bash "$(json_bash_model_only)"
art_save s14run1
C14A="$(cleaned_out)"
assert_contains "$C14A" "glm flash echo · $MODEL_STR" "14.前置 首次解析成功渲染 echo（硬断言）"
# 14.P1 缓存文件存在且含 FP(T_echo)——扫描 HOME_F 树 + 本套件 node plan 缓存，排除 fixture 预置输入
RT_SCAN_FP=0; RT_SCAN_LIST=""; RT_SCAN_FP_LIST=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in */.claude/settings.json|*/.cc-switch/cc-switch.db|*/.cc-switch/cc-switch.db-*) continue ;; esac
  RT_SCAN_LIST="${RT_SCAN_LIST}${f}
"
  if grep -qFa -- "$FP_ECHO" "$f" 2>/dev/null; then
    RT_SCAN_FP=1; RT_SCAN_FP_LIST="${RT_SCAN_FP_LIST}${f}
"
  fi
done < <(LC_ALL=C find "$HOME_F" -type f 2>/dev/null)
while IFS= read -r sid; do
  [ -n "$sid" ] || continue
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -f "$p" ] || continue
    RT_SCAN_LIST="${RT_SCAN_LIST}${p}
"
    if grep -qFa -- "$FP_ECHO" "$p" 2>/dev/null; then
      RT_SCAN_FP=1; RT_SCAN_FP_LIST="${RT_SCAN_FP_LIST}${p}
"
    fi
  done < <(node_cache_paths "$sid")
done < "$RT_REG_SIDS"
{
  printf '14.P1 扫描范围（排除 fixture 预置输入）：\n%s\n含 FP(T_echo)=%s 的文件：\n%s\n' \
    "$RT_SCAN_LIST" "$FP_ECHO" "$RT_SCAN_FP_LIST"
} > "$ARTIFACTS/s14p1.out"
if [ "$RT_SCAN_FP" = "1" ]; then
  _pass "14.P1 缓存文件存在且含 8 位指纹 FP(T_echo)"
else
  _fail "14.P1 缓存存在且含指纹" "扫描范围（s14p1.out）内无文件含 FP=$FP_ECHO"
fi
# 14.P2 同 token <2s 连续两次渲染，套餐段逐字节一致（/usr/bin/cmp）
drive_bash "$(json_bash_model_only)"
art_save s14p2
C14B="$(cleaned_out)"
assert_contains "$C14A" "glm flash echo · $MODEL_STR" "14.P2 run1 含身份簇"
assert_contains "$C14B" "glm flash echo · $MODEL_STR" "14.P2 run2 含身份簇"
PRE14="${C14A%%"glm flash echo"*}"; SEG1="${C14A#"$PRE14"}"; SEG1="${SEG1%%"$MODEL_STR"*}$MODEL_STR"
PRE14="${C14B%%"glm flash echo"*}"; SEG2="${C14B#"$PRE14"}"; SEG2="${SEG2%%"$MODEL_STR"*}$MODEL_STR"
SEG1F="$RT_TMPDIR/rt-sl-s14-seg1"; SEG2F="$RT_TMPDIR/rt-sl-s14-seg2"
printf '%s' "$SEG1" > "$SEG1F"; printf '%s' "$SEG2" > "$SEG2F"
if /usr/bin/cmp -s "$SEG1F" "$SEG2F"; then
  _pass "14.P2 套餐段两次渲染逐字节一致（cmp）"
else
  _fail "14.P2 套餐段逐字节一致" "run1=[$SEG1] run2=[$SEG2]"
fi
# 性能门禁 artifact：热缓存连续渲染耗时（<50ms 增量门禁由 QA 以改动前基线 A/B 实测判定；
# 本件记录两版热路径单次总量供对照 + 反挂起粗闸）
TIMEFORMAT='%R'
PB="$( { time ( i=0; while [ $i -lt 5 ]; do drive_bash "$(json_bash_model_only)"; i=$((i+1)); done ) ; } 2>&1 )"
PN="$( { time ( i=0; while [ $i -lt 5 ]; do drive_node "$(json_node_full rt-s14-perf)" "rt-s14-perf"; i=$((i+1)); done ) ; } 2>&1 )"
PB="${PB##*$'\n'}"; PN="${PN##*$'\n'}"   # 取末行（time 计时行），防杂散 stderr 混入
{
  printf '性能门禁 artifact（热缓存，各 5 次连续渲染，单位秒）\n'
  printf '口径说明：设计门禁 = 热缓存单次渲染增量 <50ms（brainstorm 验收⑤）；增量需改动前基线 A/B，\n'
  printf '本 artifact 记录热路径单次总耗时供 QA 对照（bash 总时/5、node 总时/5）。\n'
  printf 'bash_total=%s\nnode_total=%s\n' "$PB" "$PN"
} > "$ARTIFACTS/perf-hot.txt"
MEANB="$(awk -v t="$PB" -v n=5 'BEGIN{printf "%.3f", t/n}' 2>/dev/null)"
MEANN="$(awk -v t="$PN" -v n=5 'BEGIN{printf "%.3f", t/n}' 2>/dev/null)"
case "$MEANB" in ''|*[!0-9.]*) MEANB="999" ;; esac
case "$MEANN" in ''|*[!0-9.]*) MEANN="999" ;; esac
if awk -v m="$MEANB" 'BEGIN{exit !(m < 5)}'; then _pass "14.性能 bash 热路径均值 ${MEANB}s < 5s（反挂起粗闸）"
else _fail "14.性能 bash 热路径" "均值 ${MEANB}s ≥ 5s（疑似挂起），详见 perf-hot.txt"; fi
if awk -v m="$MEANN" 'BEGIN{exit !(m < 5)}'; then _pass "14.性能 node 热路径均值 ${MEANN}s < 5s（反挂起粗闸）"
else _fail "14.性能 node 热路径" "均值 ${MEANN}s ≥ 5s（疑似挂起），详见 perf-hot.txt"; fi

# =============================================================================
t_case "场景15 stdin 缺模型字段不致崩溃"
new_home s15; db_set_a; write_settings full "$T_ECHO" ""
drive_bash '{}'
art_save s15p1
C15="$(cleaned_out)"
assert_exit 0 "$R_RC" "15.P1 exit==0"
assert_no_plan_names "$C15" "15.P1"
drive_node "$(printf '{"session_id":"rt-s15"}')" "rt-s15"
art_save s15p2
C15="$(cleaned_out)"
assert_exit 0 "$R_RC" "15.P2 node exit==0"
assert_no_plan_names "$C15" "15.P2"

# =============================================================================
t_case "终局扫尾：全场景（1-15）token 零泄漏扩展复核（9.P1 扩展）"
RT_LEAK=""
FILESZ="$(LC_ALL=C find "$ARTIFACTS" -type f \( -name '*.out' -o -name '*.err' \) 2>/dev/null | LC_ALL=C sort)"
while IFS= read -r f; do [ -n "$f" ] && rt_scan_leak "$f"; done <<EOFZ
$FILESZ
EOFZ
if [ -z "$RT_LEAK" ]; then
  _pass "终扫 场景1-15 全部 stdout/stderr artifact 零 token 本体（契约 3）"
else
  _fail "终扫 token 零泄漏" "泄漏清单见运行日志"
fi

t_finish
