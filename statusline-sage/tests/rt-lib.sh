#!/bin/bash
# =============================================================================
# rt-lib.sh — statusline 套餐展示 红队验收测试共享库
#
# 依据（均为设计级输入，实现代码零读取）：
#   - state.md `## 验收场景`（冻结版谓词 SSOT）/ `## 契约规约` 1-4 / `## 验证方案`
#   - context.md（fixture e2e 形态 + 历史知识：fixture DB schema 必须与真实
#     cc-switch.db 一致；env -i 剥离进程 ANTHROPIC_*）
# 风格参照 scripts/contrib/tests/lib/assert.sh（t_init/_pass/_fail/##SUMMARY 协议，
# bash 3.2 兼容，零外部测试框架）。
#
# 铁律：本库只表达设计意图；对被测脚本仅黑盒执行（stdin 管道驱动 + stdout 断言），
#       绝不读取 statusline-sage.sh / statusline.mjs 源码。
# =============================================================================
set -u

RT_ORIG_PATH="$PATH"
RT_TMPDIR="${TMPDIR:-/tmp}"

# 被测脚本（编排器绑定；只执行不读）
SAGE_SH="${RT_SAGE_SH:-/Users/stringzhao/workspace/martin/statusline-sage/statusline-sage.sh}"
MJS="${RT_MJS:-/Users/stringzhao/.claude/statusline.mjs}"

# artifact 落点（编排器绑定 = $TASK_DIR/artifacts/）
ARTIFACTS="${RT_ARTIFACTS:-/Users/stringzhao/workspace/martin/.autopilot/runtime/requirements/20260927-开始实现/artifacts}"
mkdir -p "$ARTIFACTS" 2>/dev/null || { printf 'rt-lib: artifacts 目录不可建: %s\n' "$ARTIFACTS" >&2; exit 1; }

# ---- 冻结常量（state.md 验收场景绑定约定）----
BASE_FIX="http://127.0.0.1:1"      # fixture 域名冻结：连接立即拒绝，零真实 API 零 DNS
MODEL_STR="GLM-5.3-Test"           # <模型绑定串>（QA 真机绑定值）
M_FLASH="flash-model-x1"           # 条目集 B/A 的 settings_config ANTHROPIC_MODEL 字面（QA 绑定）
M_LAST="last-model-x2"
M_ECHO="echo-model-x3"

# ---- 断言协议状态 ----
DIM="${DIM:-redteam-acceptance}"
T_FILE="${T_FILE:-suite}"
T_TOTAL=0; T_PASSED=0; T_FAILED=0
T_CURRENT=""
RT_HARNESS_DEAD=0

_pass() {
  T_TOTAL=$((T_TOTAL + 1)); T_PASSED=$((T_PASSED + 1))
  printf 'PASS %s %s%s\n' "$T_FILE" "$T_CURRENT" "${1:+ [$1]}"
}
_fail() {
  T_TOTAL=$((T_TOTAL + 1)); T_FAILED=$((T_FAILED + 1))
  printf 'FAIL %s %s%s :: %s\n' "$T_FILE" "$T_CURRENT" "${1:+ [$1]}" "$2"
}

t_init()  { T_FILE="${1:-$T_FILE}"; T_TOTAL=0; T_PASSED=0; T_FAILED=0; T_CURRENT=""; }
t_case()  { T_CURRENT="${1:-}"; }
t_finish() {
  printf '##SUMMARY {"dim":"%s","file":"%s","total":%d,"passed":%d,"failed":%d,"skipped":0}\n' \
    "$DIM" "$T_FILE" "$T_TOTAL" "$T_PASSED" "$T_FAILED"
  if [ "$T_FAILED" -ne 0 ]; then exit 1; fi
  exit 0
}

assert_eq()           { if [ "$1" = "$2" ]; then _pass "${3:-}"; else _fail "${3:-}" "actual=[$1] expected=[$2]"; fi; }
assert_contains()     { case "$1" in *"$2"*) _pass "${3:-}" ;; *) _fail "${3:-}" "未找到 [$2]，实际前 240 字节=[${1:0:240}]" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) _fail "${3:-}" "不应出现却出现 [$2]" ;; *) _pass "${3:-}" ;; esac; }
assert_exit()         { assert_eq "$2" "$1" "${3:-exit=$1}"; }

# ---- 基础工具 ----
rt_harness_die() { printf 'HARNESS-FAIL: %s\n' "$1" >&2; exit 1; }

gen_hex() { # <字节数×2> → 随机十六进制（假 token 用，契约 3：fixture 一律假 token）
  local n="$1" out=""
  if command -v openssl >/dev/null 2>&1; then
    out="$(openssl rand -hex "$n" 2>/dev/null)"
  fi
  if [ -z "$out" ]; then
    out="$(head -c 64 /dev/urandom | LC_ALL=C tr -dc 'a-f0-9' | head -c "$((n * 2))")"
  fi
  [ "${#out}" -eq "$((n * 2))" ] || rt_harness_die "随机 token 生成失败（len=${#out}）"
  printf '%s' "$out"
}

fp8() { # FP(x) = sha256(x) 前 8 位十六进制（设计冻结）
  printf '%s' "$1" | shasum -a 256 | cut -c1-8
}

strip_ansi() { # stdin→stdout；剥离 ANSI 转义序列（冻结口径：ESC[…m）
  local esc; esc="$(printf '\033')"
  LC_ALL=C sed "s/${esc}\[[0-9;]*m//g"
}

rstrip() { printf '%s' "$1" | LC_ALL=C sed -e 's/[[:space:]]*$//'; }

firstline() {
  local s="$1"
  printf '%s' "${s%%$'\n'*}"
}

line_count() { # <text> → 行数（无尾随换行口径）
  printf '%s\n' "$1" | LC_ALL=C awk 'END{printf "%d", NR}'
}

# ---- fixture 构造（契约 4：临时 HOME 隔离；schema 与真实 cc-switch.db 一致）----
RT_HOME_ROOT="$RT_TMPDIR/rt-sl-fixtures"

new_home() { # <场景短名> → 设 HOME_F（确定性命名，防随机段污染 not-contains 断言）
  local name="$1" hf
  hf="$RT_HOME_ROOT/$name"
  rm -rf "$hf"
  mkdir -p "$hf/.claude" "$hf/.cc-switch" "$hf/proj" || rt_harness_die "fixture 目录不可建: $hf"
  HOME_F="$hf"
  printf '%s\n' "$hf" >> "${RT_REG_HOMES:?}"
}

write_settings() { # <full|notoken|noenv> <token> <model>  —— $HOME_F/.claude/settings.json
  local mode="$1" tok="$2" mdl="$3" f="$HOME_F/.claude/settings.json"
  case "$mode" in
    full)
      if [ -n "$mdl" ]; then
        printf '{"env":{"ANTHROPIC_AUTH_TOKEN":"%s","ANTHROPIC_BASE_URL":"%s","ANTHROPIC_MODEL":"%s"}}' \
          "$tok" "$BASE_FIX" "$mdl" > "$f"
      else
        printf '{"env":{"ANTHROPIC_AUTH_TOKEN":"%s","ANTHROPIC_BASE_URL":"%s"}}' \
          "$tok" "$BASE_FIX" > "$f"
      fi
      ;;
    notoken) printf '{"env":{"ANTHROPIC_BASE_URL":"%s"}}' "$BASE_FIX" > "$f" ;;
    noenv)   printf '{}\n' > "$f" ;;
    *) rt_harness_die "write_settings 未知 mode: $mode" ;;
  esac
  [ -s "$f" ] || rt_harness_die "settings.json 写入为空: $f"
}

db_file() { printf '%s/.cc-switch/cc-switch.db' "$HOME_F"; }

db_set_a() { # 默认条目集 A（含 hermes 干扰条目 si=5）；KIMI_CURRENT=1 时 kimi 置 is_current=1
  sqlite3 "$(db_file)" <<SQL
CREATE TABLE providers(id INTEGER PRIMARY KEY, app_type TEXT, name TEXT, is_current INTEGER, sort_index INTEGER, settings_config TEXT);
INSERT INTO providers VALUES(1,'claude','glm flash lastest',0,10,'{"env":{"ANTHROPIC_AUTH_TOKEN":"$T_SHARED","ANTHROPIC_BASE_URL":"$BASE_FIX","ANTHROPIC_MODEL":"$M_FLASH"}}');
INSERT INTO providers VALUES(2,'claude','glm flash echo',0,20,'{"env":{"ANTHROPIC_AUTH_TOKEN":"$T_ECHO","ANTHROPIC_BASE_URL":"$BASE_FIX","ANTHROPIC_MODEL":"$M_ECHO"}}');
INSERT INTO providers VALUES(3,'claude','kimi',0,30,'{"env":{"ANTHROPIC_AUTH_TOKEN":"$T_KIMI","ANTHROPIC_BASE_URL":"$BASE_FIX"}}');
INSERT INTO providers VALUES(4,'claude','deepseek-flash',0,40,'{"env":{"ANTHROPIC_AUTH_TOKEN":"$T_DS","ANTHROPIC_BASE_URL":"$BASE_FIX"}}');
INSERT INTO providers VALUES(5,'hermes','hermes-glm-flash-lastest',0,5,'{"env":{"ANTHROPIC_AUTH_TOKEN":"$T_SHARED","ANTHROPIC_BASE_URL":"$BASE_FIX","ANTHROPIC_MODEL":"$M_FLASH"}}');
SQL
  if [ "${KIMI_CURRENT:-0}" = "1" ]; then
    sqlite3 "$(db_file)" "UPDATE providers SET is_current=1 WHERE name='kimi';"
  fi
  [ "$(sqlite3 "$(db_file)" 'SELECT count(*) FROM providers;')" = "5" ] || rt_harness_die "条目集 A 构建计数异常"
}

db_set_b() { # 撞车条目集 B：同 token T_SHARED；插入序冻结 glm flash lastest 先、glm lastest 后
  # $1=cur_flash $2=si_flash $3=cur_last $4=si_last
  sqlite3 "$(db_file)" <<SQL
CREATE TABLE providers(id INTEGER PRIMARY KEY, app_type TEXT, name TEXT, is_current INTEGER, sort_index INTEGER, settings_config TEXT);
INSERT INTO providers VALUES(1,'claude','glm flash lastest',$1,$2,'{"env":{"ANTHROPIC_AUTH_TOKEN":"$T_SHARED","ANTHROPIC_BASE_URL":"$BASE_FIX","ANTHROPIC_MODEL":"$M_FLASH"}}');
INSERT INTO providers VALUES(2,'claude','glm lastest',$3,$4,'{"env":{"ANTHROPIC_AUTH_TOKEN":"$T_SHARED","ANTHROPIC_BASE_URL":"$BASE_FIX","ANTHROPIC_MODEL":"$M_LAST"}}');
SQL
  [ "$(sqlite3 "$(db_file)" 'SELECT count(*) FROM providers;')" = "2" ] || rt_harness_die "条目集 B 构建计数异常"
}

db_empty_providers() { # 场景 13b：providers 表存在但零行
  sqlite3 "$(db_file)" <<'SQL'
CREATE TABLE providers(id INTEGER PRIMARY KEY, app_type TEXT, name TEXT, is_current INTEGER, sort_index INTEGER, settings_config TEXT);
SQL
}

db_no_settings_col() { # 场景 12a：providers 表缺 settings_config 列
  sqlite3 "$(db_file)" <<'SQL'
CREATE TABLE providers(id INTEGER PRIMARY KEY, app_type TEXT, name TEXT, is_current INTEGER, sort_index INTEGER);
INSERT INTO providers VALUES(1,'claude','glm flash echo',0,20);
SQL
}

db_other_table() { # 场景 12b：无 providers 表
  sqlite3 "$(db_file)" <<'SQL'
CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT);
INSERT INTO meta VALUES('x','y');
SQL
}

db_garbage() { # 场景 12c：非 SQLite 垃圾字节
  {
    printf 'this file is definitely not a sqlite database at all. '
    printf 'padding padding padding padding padding padding padding. '
    printf 'more garbage bytes to defeat any header sniffing heuristics.\n'
  } > "$(db_file)"
}

db_break_echo_json() { # 场景 12d：命中条目 settings_config 为非法 JSON
  sqlite3 "$(db_file)" "UPDATE providers SET settings_config='NOT-JSON{{{{' WHERE name='glm flash echo';"
}

# ---- stdin JSON 构造（接口绑定：bash 读 .model.display_name；node 读
#      .model.display_name || .model.id 与 .workspace.*、session_id）----
json_bash_model_only() { # 场景 1 冻结：仅含模型显示名的最小 JSON（无 ctx/out_style/workspace）
  printf '{"model":{"display_name":"%s"}}' "$MODEL_STR"
}
json_node_full() { # <sid>：node 驱动（独立 session_id 防跨场景缓存污染）
  printf '{"session_id":"%s","model":{"display_name":"%s"},"workspace":{"current_dir":"%s/proj"}}' \
    "$1" "$MODEL_STR" "$HOME_F"
}

# ---- 驱动（冻结驱动方式：env -i 剥离进程 ANTHROPIC_*）----
R_OUT=""; R_ERR=""; R_RC=""; R_OUT_F=""; R_ERR_F=""

_drive() { # <bash|node> <script> <stdin-json> [sid]
  local interp="$1" script="$2" sin="$3" sid="${4:-}"
  local outf errf
  outf="$(mktemp "$RT_TMPDIR/rt-drive.XXXXXX")" || rt_harness_die "mktemp 失败"
  errf="$(mktemp "$RT_TMPDIR/rt-drive.XXXXXX")" || rt_harness_die "mktemp 失败"
  RT_DRIVE_TMPS="$RT_DRIVE_TMPS $outf $errf"
  if [ "$interp" = "bash" ]; then
    printf '%s' "$sin" | env -i HOME="$HOME_F" PATH="$RT_ORIG_PATH" TMPDIR="$RT_TMPDIR" bash "$script" >"$outf" 2>"$errf"
  else
    printf '%s' "$sin" | env -i HOME="$HOME_F" PATH="$RT_ORIG_PATH" TMPDIR="$RT_TMPDIR" node "$script" >"$outf" 2>"$errf"
    printf '%s\n' "$sid" >> "${RT_REG_SIDS:?}"
  fi
  R_RC=$?
  R_OUT="$(cat "$outf")"
  R_ERR="$(cat "$errf")"
  R_OUT_F="$outf"; R_ERR_F="$errf"
}
drive_bash() { _drive bash "$SAGE_SH" "$1"; }
drive_node() { _drive node "$MJS" "$1" "$2"; }

cleaned_out() { printf '%s' "$R_OUT" | strip_ansi; }

art_save() { # <名> —— 把当前 drive 的 stdout/stderr 快照进 artifacts（冻结 artifact 名）
  cp -f "$R_OUT_F" "$ARTIFACTS/$1.out" 2>/dev/null || printf '(capture failed)\n' > "$ARTIFACTS/$1.out"
  cp -f "$R_ERR_F" "$ARTIFACTS/$1.err" 2>/dev/null || : > "$ARTIFACTS/$1.err"
}
art_text() { # <名(不含扩展名可选)> <文本>
  printf '%s' "$2" > "$ARTIFACTS/$1"
}

node_cache_paths() { # <sid> → 打印该 sid 的 node plan 缓存候选路径（mjs 走 os.tmpdir()，
  # env -i TMPDIR 覆盖时落 $RT_TMPDIR 而非 /tmp；两处都扫，防扫描/清理面漏检）
  printf '%s/cc-sl-%s.plan\n' "$RT_TMPDIR" "$1"
  printf '/tmp/cc-sl-%s.plan\n' "$1"
}

db_snapshot() { # fixture DB 字节快照 → <dest>（验证方案「只读辅助锚」：cmp 字节对照）
  cp -f "$(db_file)" "$1" 2>/dev/null || rt_harness_die "DB 快照失败: $(db_file)"
}
db_assert_unwritten() { # <快照> <label> —— 被测脚本驱动后 DB 逐字节不变（契约 2 只读）
  if /usr/bin/cmp -s "$1" "$(db_file)"; then
    _pass "$2"
  else
    _fail "$2" "fixture cc-switch.db 在驱动后被写入（违反契约 2 只读）；快照=$1"
  fi
}

# ---- 环境闸门（fail-closed）----
rt_env_gate() {
  local miss=""
  for c in jq sqlite3 shasum node awk sed; do
    command -v "$c" >/dev/null 2>&1 || miss="$miss $c"
  done
  [ -x /usr/bin/cmp ] || miss="$miss /usr/bin/cmp"
  [ -z "$miss" ] || rt_harness_die "缺依赖:$miss"
  [ -f "$SAGE_SH" ] || rt_harness_die "被测 bash 脚本不存在: $SAGE_SH"
  [ -f "$MJS" ] || rt_harness_die "被测 node 脚本不存在: $MJS"
  # diff 遮蔽防御（历史知识）：本套件一律 cmp/shasum，不使用裸 diff；此处仅登记
  return 0
}
