#!/usr/bin/env bash
# =============================================================================
# statusline-sage.sh — Sage 色彩体系 · Claude Code 状态栏
# -----------------------------------------------------------------------------
# 功能模块：
#   1. 路径压缩  — 项目名 + worktree 优先（martin ⎇ feature-x），不再裸露长路径
#   2. git 状态  — 分支 / dirty 计数 / ahead-behind / worktree 自动识别
#   3. GLM 限额  — 双窗口 token limit（5h + weekly）+ 高峰期倍率提示（14-18点 ×3，
#                  仅 glm-5.2/5-turbo），带 60s 缓存 + 后台刷新防阻塞
#   4. 上下文    — context window 使用百分比（多版本字段兼容）
#   5. 模型      — 当前模型名
# 色彩体系：https://stringzhao.life/colors（苔绿 Sage 为主色，truecolor 24-bit）
# 兼容：macOS bash 3.2（不使用 mapfile / 关联数组）
# =============================================================================

# ---------- 可调配置 ----------
CACHE_TTL_OK=60            # API 成功时缓存有效期（秒）
CACHE_TTL_FAIL=15          # API 失败时缓存有效期（秒，更短以便重试）
REFRESH_DEBOUNCE=30        # 后台刷新防抖窗口（秒），避免每次渲染都 fork curl
GLM_API_TIMEOUT=3          # 后台刷新 curl 超时（秒）
GLM_FIRST_TIMEOUT=2        # 冷启动首次同步获取 curl 超时（秒，仅一次性阻塞）
GLM_HIGH=85                # 用量阈值：≥ 此值用朱红 vermillion
GLM_MID=60                 # 用量阈值：≥ 此值用琥 amber
PATH_TTY_SAFE=1            # 始终输出 ANSI（Claude Code 终端支持 truecolor）

# ---------- 高峰期倍率（GLM Coding Plan 计费规则，写死）----------
# quota API（/api/monitor/usage/quota/limit）只返回用量百分比，不返回倍率；
# 倍率属于计费策略，源自官方文档：docs.bigmodel.cn/cn/coding-plan/faq
#   GLM-5.2 / GLM-5-Turbo（高阶，对标 Opus）：高峰期 3 倍、非高峰期 2 倍
#   GLM-4.7（对标 Sonnet）：1 倍，无高峰加成（故非高阶模型不显示倍率）
# 限时福利（至 9 月底）：GLM-5.2/5-Turbo 非高峰期降为 1 倍（高峰期不变，仍 3 倍）
PEAK_START=14              # 高峰期起始小时（UTC+8，含）
PEAK_END=18                # 高峰期结束小时（UTC+8，不含，即 [14,18)）
PEAK_RATE=3                # 高峰期高阶模型消耗倍率
# 受高峰倍率影响的高阶模型 display_name 模式（ERE，大小写不敏感）
# 匹配 glm-5.2 / glm-5-turbo（历史模型自动切 glm-5.2）；glm-4.x 不含 5 系，自动排除
PEAK_MODELS='glm-5\.2|glm-5-turbo'

CACHE_FILE="${HOME}/.claude/.statusline-sage-quota.json"
REFRESH_FLAG="${HOME}/.claude/.statusline-sage-refreshing"

# ---------- Sage 色彩（truecolor 24-bit）----------
# hex → RGB 对照见仓库 COLORS / README
c_reset=$'\033[0m'
_sage()        { printf '\033[38;2;58;125;104m'; }   # #3A7D68 苔绿   品牌主色 / clean
_sage_light()  { printf '\033[38;2;82;166;136m'; }   # #52A688 苔浅   路径 / 活跃
_amber()       { printf '\033[38;2;212;146;10m'; }   # #D4920A 琥     warning / 中用量
_vermillion()  { printf '\033[38;2;217;79;61m'; }    # #D94F3D 朱     error / 高用量
_sky()         { printf '\033[38;2;59;135;204m'; }   # #3B87CC 天     模型 / info
_smoke()       { printf '\033[38;2;143;143;141m'; }  # #8F8F8D 烟     分隔符 / 辅助

# 按百分比选色：高→朱，中→琥，低→苔绿
# $1 = 百分比（允许小数 / 空）
_level_color() {
  local p="${1%.*}"
  case "$p" in
    ''|*[!0-9]*) _sage; return ;;
  esac
  if   [ "$p" -ge "$GLM_HIGH" ]; then _vermillion
  elif [ "$p" -ge "$GLM_MID"  ]; then _amber
  else                                _sage
  fi
}

# 高峰期倍率提示 —— GLM Coding Plan 计费规则（写死，见上方 PEAK_* 配置）
# 独立于 quota 用量：反映"当前时段的计费倍率"，而非"已用多少"——即便 quota 接口挂了，
# 高峰期 glm-5.2 仍按 3 倍消耗，故此提示独立于 _render_glm_cache 的成败。
# 仅当 本地时区(强制 UTC+8) 小时 ∈ [PEAK_START, PEAK_END) 且 当前模型为高阶模型 时输出
# 返回带朱红着色的 " ×N"（N=PEAK_RATE），否则输出空。$model 在调用点已赋值。
_glm_peak() {
  local h m_lc
  h="$(TZ='Asia/Shanghai' date +%H 2>/dev/null)"
  # 高峰判定：小时落在 [PEAK_START, PEAK_END)（如 14..17 ∈ [14,18)）；date 失败则保守不显示
  [ -n "$h" ] && [ "$h" -ge "$PEAK_START" ] 2>/dev/null && [ "$h" -lt "$PEAK_END" ] 2>/dev/null || return
  # 仅高阶模型受倍率影响（glm-4.x 为 1 倍，不显示）；大小写不敏感匹配 display_name
  m_lc="$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')"
  printf '%s' "$m_lc" | grep -qE "$PEAK_MODELS" 2>/dev/null || return
  printf ' %s×%s%s' "$(_vermillion)" "$PEAK_RATE" "$c_reset"
}

# ---------- 读取 stdin（一次 jq，兼容 bash 3.2 用 while+process substitution）----------
_raw_input="$(cat 2>/dev/null)"
[ -z "$_raw_input" ] && _raw_input='{}'

# 一次性提取所有字段，避免多次 jq 调用
_fields=()
while IFS= read -r _line; do _fields+=("$_line"); done < <(
  printf '%s' "$_raw_input" | jq -r '
    .model.display_name // "",
    .workspace.current_dir // "",
    .workspace.project_dir // "",
    .output_style.name // "default",
    ((.context_window.used_percentage // "") | tostring),
    ((.context_window.remaining_percentage // "") | tostring)
  ' 2>/dev/null
)
model="${_fields[0]:-}"
cur_dir="${_fields[1]:-}"
proj_dir="${_fields[2]:-}"
out_style="${_fields[3]:-default}"
ctx_used="${_fields[4]:-}"
ctx_remain="${_fields[5]:-}"
[ -z "$cur_dir" ] && cur_dir="$PWD"

# ---------- git + worktree（合并 git 调用以降低延迟）----------
_git_part=""
_proj_name=""
# 一次 rev-parse 取多个值（is-inside-work-tree / git-dir / common-dir / toplevel / branch / short hash）
_git_parse=()
while IFS= read -r _l; do _git_parse+=("$_l"); done < <(
  git -C "$cur_dir" rev-parse --is-inside-work-tree --absolute-git-dir \
    --git-common-dir --show-toplevel --abbrev-ref HEAD --short HEAD 2>/dev/null
)
if [ "${_git_parse[0]:-}" = "true" ]; then
  _git_dir="${_git_parse[1]:-}"
  _common_rel="${_git_parse[2]:-}"
  _toplevel="${_git_parse[3]:-}"
  _abbrev="${_git_parse[4]:-}"
  _shorthash="${_git_parse[5]:-}"
  # 分支名：正常用 abbrev，detached（HEAD）用 short hash
  if [ "$_abbrev" = "HEAD" ] && [ -n "$_shorthash" ]; then
    _branch="$_shorthash"
  else
    _branch="${_abbrev:-detached}"
  fi

  # worktree 判定：absolute-git-dir 与 common-dir（解析为绝对）不同 → 处于 worktree
  _common_abs=""
  [ -n "$_common_rel" ] && _common_abs="$(cd "$cur_dir" && cd "$_common_rel" 2>/dev/null && pwd)"
  _main_root=""; [ -n "$_common_abs" ] && _main_root="$(dirname "$_common_abs")"
  # 项目名取主仓库根（worktree 场景也指向主仓库名，如 martin）
  [ -n "$_main_root" ] && _proj_name="$(basename "$_main_root")"

  _in_wt=0
  [ -n "$_git_dir" ] && [ -n "$_common_abs" ] && [ "$_git_dir" != "$_common_abs" ] && _in_wt=1

  # dirty 文件计数
  _dirty="$(git -C "$cur_dir" status --porcelain 2>/dev/null | grep -c . )"

  # ahead / behind upstream（无 upstream 时 rev-list 失败 → _ab 留空，省一次判定调用）
  _ab=""
  _counts="$(git -C "$cur_dir" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null)" || _counts=""
  if [ -n "$_counts" ]; then
    _behind="$(printf '%s' "$_counts" | cut -f1)"
    _ahead="$(printf '%s' "$_counts" | cut -f2)"
    [ -n "$_ahead" ] && [ "$_ahead" -gt 0 ] 2>/dev/null && _ab="${_ab}↑${_ahead}"
    [ -n "$_behind" ] && [ "$_behind" -gt 0 ] 2>/dev/null && _ab="${_ab}↓${_behind}"
  fi

  # 组装 git 区
  if [ "$_in_wt" = "1" ]; then
    _wt_name="$(basename "$_toplevel")"
    _git_part="$(_amber)⎇${c_reset}$(_sage_light)${_branch}${c_reset} $(_smoke)⌥${_wt_name}${c_reset}"
  else
    _git_part="$(_sage)⎇${c_reset}$(_sage_light)${_branch}${c_reset}"
  fi
  [ -n "$_dirty" ] && [ "$_dirty" -gt 0 ] 2>/dev/null && _git_part="${_git_part} $(_vermillion)●${_dirty}${c_reset}"
  [ -n "$_ab" ] && _git_part="${_git_part} $(_smoke)${_ab}${c_reset}"
fi

# ---------- 路径区（项目名 + worktree 优先）----------
# 主仓库：显示项目名；worktree 的具体名已在 git 区用 ⌥ 标注
_path_part=""
if [ -n "$_proj_name" ]; then
  _path_part="$(_smoke)·${c_reset}$(_sage_light)${_proj_name}${c_reset}"
elif [ -n "$cur_dir" ]; then
  # 非 git 目录兜底：显示当前目录 basename
  _path_part="$(_smoke)·${c_reset}$(_sage_light)$(basename "$cur_dir")${c_reset}"
fi

# ---------- GLM token limit（双窗口 + 缓存 + 后台刷新）----------
_now="$(date +%s)"

# 从 ~/.claude/settings.json 读取 base url / token（环境变量优先）
_read_glm_env() {
  local sf="${HOME}/.claude/settings.json"
  [ -z "$ANTHROPIC_BASE_URL" ]   && ANTHROPIC_BASE_URL="$(jq -r '.env.ANTHROPIC_BASE_URL // empty' "$sf" 2>/dev/null)"
  [ -z "$ANTHROPIC_AUTH_TOKEN" ] && ANTHROPIC_AUTH_TOKEN="$(jq -r '.env.ANTHROPIC_AUTH_TOKEN // empty' "$sf" 2>/dev/null)"
}

# 同步抓取 quota 并原子写入缓存
_fetch_quota_sync() {
  local _timeout="${1:-$GLM_API_TIMEOUT}"
  _read_glm_env
  local domain base="${ANTHROPIC_BASE_URL:-}"
  domain="$(printf '%s' "$base" | sed -E 's#(https?://[^/]+).*#\1#')"
  [ -z "$domain" ] || [ -z "$ANTHROPIC_AUTH_TOKEN" ] && return 1

  local resp
  resp="$(curl -s --max-time "$_timeout" \
    "${domain}/api/monitor/usage/quota/limit" \
    -H "Authorization: ${ANTHROPIC_AUTH_TOKEN}" \
    -H 'Accept-Language: en-US,en' 2>/dev/null)" || return 1
  [ -z "$resp" ] && return 1

  # 用 jq 直接构造缓存 JSON（避免 shell 拼接引号 / 转义出错）
  # sort_by(.r)：reset 时间升序 → 第一个为短周期窗口(5h)，最后一个为长周期窗口(weekly)
  local ts; ts="$(date +%s)"
  printf '%s' "$resp" | jq -c --arg ts "$ts" '
    { ts:   ($ts|tonumber),
      ok:   1,
      level: (.data.level // null),
      tokens: ( [ (.data.limits[]? | select(.type=="TOKENS_LIMIT")
                   | { p: (.percentage|floor), r: .nextResetTime }) ]
                | sort_by(.r) ) }
  ' > "${CACHE_FILE}.tmp" 2>/dev/null && mv -f "${CACHE_FILE}.tmp" "$CACHE_FILE" 2>/dev/null
}

# 后台刷新（带防抖，避免每次渲染都 fork）
_refresh_bg() {
  if [ -f "$REFRESH_FLAG" ]; then
    local ft; ft="$(cat "$REFRESH_FLAG" 2>/dev/null)"
    if [ -n "$ft" ] && [ "$((_now - ft))" -lt "$REFRESH_DEBOUNCE" ]; then
      return 0
    fi
  fi
  printf '%s' "$_now" > "$REFRESH_FLAG" 2>/dev/null
  # 子 shell 后台抓取，完成后清标记；与 statusline 渲染解耦，绝不阻塞
  ( _fetch_quota_sync >/dev/null 2>&1; rm -f "$REFRESH_FLAG" 2>/dev/null ) &
  disown 2>/dev/null || true
}

# 从缓存文件渲染 GLM 区到 _glm_part（无可显示数据时返回非 0）
_render_glm_cache() {
  # 单次 jq 提取 level / token 数 / 短窗口百分比 / 长窗口百分比
  local _parsed _level _n _short_p _long_p
  _parsed="$(jq -r '
    [ (.level // ""),
      ((.tokens // []) | length),
      ((.tokens // [{}])[0].p // ""),
      ((.tokens // [{}])[-1].p // "") ] | @tsv
  ' "$CACHE_FILE" 2>/dev/null)"
  [ -z "$_parsed" ] && return 1
  IFS=$'\t' read -r _level _n _short_p _long_p <<< "$_parsed"
  [ -z "$_short_p" ] && return 1
  if [ "${_n:-0}" -ge 2 ] 2>/dev/null; then
    _glm_part="$(_smoke)GLM${c_reset} $(_level_color "$_short_p")5h:${_short_p}%${c_reset} $(_level_color "$_long_p")wk:${_long_p}%${c_reset}"
  else
    _glm_part="$(_smoke)GLM${c_reset} $(_level_color "$_short_p")${_short_p}%${c_reset}"
  fi
  return 0
}

# 渲染 GLM 区
_glm_part=""
if [ -f "$CACHE_FILE" ]; then
  _c_ts="$(jq -r '.ts // 0' "$CACHE_FILE" 2>/dev/null)"
  _c_ok="$(jq -r '.ok // 0' "$CACHE_FILE" 2>/dev/null)"
  _ttl="$CACHE_TTL_OK"; [ "$_c_ok" = "0" ] && _ttl="$CACHE_TTL_FAIL"
  _age="$(($_now - ${_c_ts:-0}))"
  # 过期：仍输出旧缓存，同时后台刷新（不阻塞）
  [ "$_age" -ge "$_ttl" ] && _refresh_bg
  _render_glm_cache || { _glm_part="$(_smoke)GLM …${c_reset}"; _refresh_bg; }
else
  # 冷启动：无缓存，同步获取一次（一次性阻塞 ≤ GLM_FIRST_TIMEOUT），之后靠缓存 / 后台刷新
  _fetch_quota_sync "$GLM_FIRST_TIMEOUT"
  _render_glm_cache || { _glm_part="$(_smoke)GLM …${c_reset}"; _refresh_bg; }
fi

# 高峰期倍率提示追加到 GLM 区尾部（独立于 quota 数据成败）
_glm_part="${_glm_part}$(_glm_peak)"

# ---------- context window ----------
_ctx_part=""
_ctx_val=""
if [ -n "$ctx_used" ] && [ "$ctx_used" != "null" ] && [ "$ctx_used" != "null" ]; then
  _ctx_val="${ctx_used%.*}"
elif [ -n "$ctx_remain" ] && [ "$ctx_remain" != "null" ]; then
  _ctx_val="$((100 - ${ctx_remain%.*}))"
fi
if [ -n "$_ctx_val" ]; then
  _ctx_part="$(_level_color "$_ctx_val")ctx ${_ctx_val}%${c_reset}"
fi

# ---------- 模型 ----------
_model_part=""
if [ -n "$model" ] && [ "$model" != "null" ]; then
  _model_part="$(_sky)${model}${c_reset}"
fi

# ---------- 组装单行输出 ----------
_sep="$(_smoke)│${c_reset}"
_parts=()
[ -n "$_git_part" ]   && _parts+=("$_git_part")
[ -n "$_path_part" ]  && _parts+=("$_path_part")
[ -n "$_glm_part" ]   && _parts+=("$_glm_part")
[ -n "$_model_part" ] && _parts+=("$_model_part")
[ -n "$_ctx_part" ]   && _parts+=("$_ctx_part")
if [ -n "$out_style" ] && [ "$out_style" != "default" ] && [ "$out_style" != "null" ]; then
  _parts+=("$(_amber)${out_style}${c_reset}")
fi

_out=""
_i=0
for _p in "${_parts[@]}"; do
  if [ "$_i" -eq 0 ]; then _out="$_p"; else _out="${_out} ${_sep} ${_p}"; fi
  _i=$((_i + 1))
done

printf '%s' "$_out"
