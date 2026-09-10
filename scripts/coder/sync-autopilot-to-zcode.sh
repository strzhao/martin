#!/bin/bash
if [ -z "${BASH_VERSION:-}" ]; then
  printf 'ERROR: 必须用 bash 运行本脚本（检测到非 bash 解释器: BASH_VERSION 为空）\n' >&2
  exit 2
fi
#
# sync-autopilot-to-zcode.sh — 把 string-claude-code-plugin 仓的 autopilot 插件同步进 zcode CLI 插件缓存。
# 自动化 zcode 使用文档 §4.2 的手动四件套：
#   1) 实体目录  $ZCODE_CLI_HOME/plugins/cache/autopilot/autopilot/<version>/
#   2) manifest  $ZCODE_CLI_HOME/plugins/marketplaces/autopilot/marketplace.json
#   3) 注册表    $ZCODE_CLI_HOME/plugins/known_marketplaces.json
#   4) 注册表    $ZCODE_CLI_HOME/plugins/installed_plugins.json
#
# 用法:
#   sync-autopilot-to-zcode.sh [--check] [--help]
#
# 环境变量:
#   ZCODE_CLI_HOME      目标 zcode CLI 主目录（默认 ~/.zcode/cli）
#   PLUGIN_SOURCE_REPO  插件源仓（默认 $HOME/workspace/string-claude-code-plugin）
#
# 固定常量: PLUGIN_NAME=autopilot / MARKETPLACE_NAME=autopilot / PLUGIN_ID=autopilot@autopilot
#
# 退出码: 0 = --check 五查全过，或同步成功（SYNCED / UP_TO_DATE）
#         1 = --check 检出差异（含目标 not-installed；仅此场景使用）
#         2 = 一切错误（SOURCE_MISSING / TARGET_JSON_CORRUPT / POST_SYNC_VERIFY_FAILED / USAGE_ERROR / 目标不可写）
#
# stdout: SOURCE_VERSION / TARGET_VERSION / STATUS 必现行；差异行 DIFF: <项>: <详情>；同步动作行 SYNC: <动作>
# stderr: ERROR: <详情>（错误时无 STATUS 行）
# 约束: 一切写入仅落在 $ZCODE_CLI_HOME 派生路径；对 $PLUGIN_SOURCE_REPO 零写入。
#        文件比较一律 cmp -s（本机 zsh diff 函数遮蔽会产生假结果）。
set -u

PLUGIN_NAME="autopilot"
MARKETPLACE_NAME="autopilot"
PLUGIN_ID="autopilot@autopilot"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

usage() {
  cat <<'USAGE'
sync-autopilot-to-zcode.sh — 把 string-claude-code-plugin 仓的 autopilot 插件同步进 zcode CLI 插件缓存

用法:
  sync-autopilot-to-zcode.sh [--check] [--help]

选项:
  --check    仅一致性五查，零写入: 全过 exit 0 (STATUS: IN_SYNC) / 有差异 exit 1 (STATUS: OUT_OF_SYNC)
  --help     显示本帮助

环境变量:
  ZCODE_CLI_HOME       目标 zcode CLI 主目录 (默认 ~/.zcode/cli)
  PLUGIN_SOURCE_REPO   插件源仓 (默认 $HOME/workspace/string-claude-code-plugin)

固定常量: PLUGIN_NAME=autopilot  MARKETPLACE_NAME=autopilot  PLUGIN_ID=autopilot@autopilot

一致性五查（全过=IN_SYNC，任一不过=OUT_OF_SYNC）:
  1. installed 条目 version == 源 plugin.json version（字符串相等）
  2. 实体目录 cache/autopilot/autopilot/<源ver>/ 存在
  3. marketplaces/autopilot/marketplace.json 与源仓 marketplace.json 逐字节一致（cmp -s）
  4. known_marketplaces.json 有 id=autopilot 条目，source.source=directory 且 source.path==源仓
  5. installed 条目 installPath == cache/autopilot/autopilot/<源ver>

stdout: SOURCE_VERSION / TARGET_VERSION / STATUS 必现行; 差异行 DIFF: <项>: <详情>; 同步动作行 SYNC: <动作>
stderr: ERROR: <详情>（此时无 STATUS 行）
退出码: 0 成功 / 1 仅 --check 检出差异 / 2 一切错误
USAGE
}

norm_path() {
  # 去掉结尾连续的 '/'（根目录 '/' 保留），用于路径归一化比较
  local p
  p="$1"
  while [[ "$p" != "/" && "$p" == */ ]]; do
    p="${p%/}"
  done
  printf '%s\n' "$p"
}

add_diff() {
  CHECK_ALL_PASS=0
  CHECK_DIFFS="${CHECK_DIFFS}DIFF: ${1}"$'\n'
}

print_diffs() {
  if [[ -n "$CHECK_DIFFS" ]]; then
    printf '%s' "$CHECK_DIFFS"
  fi
}

py_read_source_version() {
  python3 - "$SRC_PLUGIN_JSON" <<'PYEOF'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception as exc:
    sys.stderr.write("ERROR: SOURCE_MISSING: %s 不可读或非法 JSON: %s\n" % (path, exc))
    sys.exit(2)
ver = data.get("version") if isinstance(data, dict) else None
if not isinstance(ver, str) or ver == "":
    sys.stderr.write("ERROR: SOURCE_MISSING: %s 缺合法 version 字符串字段\n" % path)
    sys.exit(2)
sys.stdout.write(ver + "\n")
PYEOF
}

py_read_plugin_count() {
  python3 - "$SRC_MANIFEST" <<'PYEOF'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception as exc:
    sys.stderr.write("ERROR: SOURCE_MISSING: %s 不可读或非法 JSON: %s\n" % (path, exc))
    sys.exit(2)
plugins = data.get("plugins") if isinstance(data, dict) else None
if not isinstance(plugins, list):
    sys.stderr.write("ERROR: SOURCE_MISSING: %s 缺 plugins 数组\n" % path)
    sys.exit(2)
sys.stdout.write(str(len(plugins)) + "\n")
PYEOF
}

py_probe_installed() {
  # stdout: "not-installed" 或 "entry\t<version>\t<installPath>"；corrupt 时 stderr ERROR + exit 2
  python3 - "$TARGET_INSTALLED" "$PLUGIN_ID" <<'PYEOF'
import json
import sys

path, plugin_id = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except FileNotFoundError:
    sys.stdout.write("not-installed\n")
    sys.exit(0)
except Exception as exc:
    sys.stderr.write("ERROR: TARGET_JSON_CORRUPT: %s: %s\n" % (path, exc))
    sys.exit(2)
plugins = data.get("plugins") if isinstance(data, dict) else None
if not isinstance(plugins, list):
    sys.stderr.write("ERROR: TARGET_JSON_CORRUPT: %s: 缺 plugins 数组\n" % path)
    sys.exit(2)
for item in plugins:
    if isinstance(item, dict) and item.get("id") == plugin_id:
        ver = item.get("version")
        ipath = item.get("installPath")
        ver_s = ver if isinstance(ver, str) else ""
        ip_s = ipath if isinstance(ipath, str) else ""
        sys.stdout.write("entry\t%s\t%s\n" % (ver_s, ip_s))
        sys.exit(0)
sys.stdout.write("not-installed\n")
PYEOF
}

py_probe_known() {
  # stdout: "no-entry" 或 "entry\t<source.source>\t<source.path>"；corrupt 时 stderr ERROR + exit 2
  python3 - "$TARGET_KNOWN" "$MARKETPLACE_NAME" <<'PYEOF'
import json
import sys

path, mkt_id = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except FileNotFoundError:
    sys.stdout.write("no-entry\n")
    sys.exit(0)
except Exception as exc:
    sys.stderr.write("ERROR: TARGET_JSON_CORRUPT: %s: %s\n" % (path, exc))
    sys.exit(2)
marketplaces = data.get("marketplaces") if isinstance(data, dict) else None
if not isinstance(marketplaces, list):
    sys.stderr.write("ERROR: TARGET_JSON_CORRUPT: %s: 缺 marketplaces 数组\n" % path)
    sys.exit(2)
for item in marketplaces:
    if isinstance(item, dict) and item.get("id") == mkt_id:
        source = item.get("source")
        source = source if isinstance(source, dict) else {}
        ss = source.get("source")
        sp = source.get("path")
        ss_s = ss if isinstance(ss, str) else ""
        sp_s = sp if isinstance(sp, str) else ""
        sys.stdout.write("entry\t%s\t%s\n" % (ss_s, sp_s))
        sys.exit(0)
sys.stdout.write("no-entry\n")
PYEOF
}

py_upsert_known() {
  # known_marketplaces.json upsert：缺失则骨架引导；已有条目仅更新
  # source/pluginCount/lastUpdated，保留 name/description/addedAt
  python3 - "$TARGET_KNOWN" "$REPO_NORM" "$PLUGIN_COUNT" "$MARKETPLACE_NAME" <<'PYEOF'
import datetime
import json
import sys

path, repo, count, mkt_id = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except FileNotFoundError:
    data = {"version": 1, "marketplaces": []}
except Exception as exc:
    sys.stderr.write("ERROR: TARGET_JSON_CORRUPT: %s: %s\n" % (path, exc))
    sys.exit(2)
if not isinstance(data, dict) or not isinstance(data.get("marketplaces"), list):
    sys.stderr.write("ERROR: TARGET_JSON_CORRUPT: %s: 缺 marketplaces 数组\n" % path)
    sys.exit(2)
entry = None
for item in data["marketplaces"]:
    if isinstance(item, dict) and item.get("id") == mkt_id:
        entry = item
        break
if entry is None:
    entry = {
        "id": mkt_id,
        "name": mkt_id,
        "source": {"source": "directory", "path": repo},
        "description": "local marketplace",
        "addedAt": now,
        "pluginCount": count,
        "lastUpdated": now,
    }
    data["marketplaces"].append(entry)
    action = "created"
else:
    entry["source"] = {"source": "directory", "path": repo}
    entry["pluginCount"] = count
    entry["lastUpdated"] = now
    action = "updated"
try:
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
except Exception as exc:
    sys.stderr.write("ERROR: TARGET_NOT_WRITABLE: %s: %s\n" % (path, exc))
    sys.exit(2)
sys.stdout.write(action + "\n")
PYEOF
}

py_upsert_installed() {
  # installed_plugins.json upsert：缺失则骨架引导；已有条目仅更新
  # version/installPath（installedAt 仅版本变化时刷新），保留 name/marketplace/scope
  python3 - "$TARGET_INSTALLED" "$PLUGIN_ID" "$PLUGIN_NAME" "$MARKETPLACE_NAME" "$SOURCE_VERSION" "$EXPECTED_ENTITY_DIR" <<'PYEOF'
import datetime
import json
import sys

path, plugin_id, name, marketplace, version, install_path = sys.argv[1:7]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except FileNotFoundError:
    data = {"plugins": []}
except Exception as exc:
    sys.stderr.write("ERROR: TARGET_JSON_CORRUPT: %s: %s\n" % (path, exc))
    sys.exit(2)
if not isinstance(data, dict) or not isinstance(data.get("plugins"), list):
    sys.stderr.write("ERROR: TARGET_JSON_CORRUPT: %s: 缺 plugins 数组\n" % path)
    sys.exit(2)
entry = None
for item in data["plugins"]:
    if isinstance(item, dict) and item.get("id") == plugin_id:
        entry = item
        break
if entry is None:
    entry = {
        "id": plugin_id,
        "name": name,
        "marketplace": marketplace,
        "version": version,
        "installPath": install_path,
        "installedAt": now,
        "scope": "user",
    }
    data["plugins"].append(entry)
    action = "created"
else:
    old_version = entry.get("version")
    entry["version"] = version
    entry["installPath"] = install_path
    if old_version != version:
        entry["installedAt"] = now
    action = "updated"
try:
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
except Exception as exc:
    sys.stderr.write("ERROR: TARGET_NOT_WRITABLE: %s: %s\n" % (path, exc))
    sys.exit(2)
sys.stdout.write(action + "\n")
PYEOF
}

collect_checks() {
  # 一致性五查。前置: SOURCE_VERSION / REPO_NORM / EXPECTED_ENTITY_DIR / TARGET_* 已就绪。
  # 产出: TARGET_VERSION_DISPLAY / INSTALLED_PRESENT / CHECK_ALL_PASS / CHECK_DIFFS
  CHECK_ALL_PASS=1
  CHECK_DIFFS=""
  INSTALLED_PRESENT=0
  TARGET_VERSION_DISPLAY="not-installed"
  local probe tver tip kprobe kss kpath expected_norm kpath_norm tip_norm
  probe="$(py_probe_installed)" || exit 2
  tver=""
  tip=""
  if [[ "$probe" == "entry"* ]]; then
    INSTALLED_PRESENT=1
    IFS=$'\t' read -r _kind tver tip <<< "$probe"
    TARGET_VERSION_DISPLAY="$tver"
  fi
  # 查 1: installed 条目 version == 源 version（字符串相等判定，不做 semver 序比较）
  if [[ "$INSTALLED_PRESENT" -eq 0 ]]; then
    add_diff "version: not-installed (source='$SOURCE_VERSION')"
  elif [[ "$tver" != "$SOURCE_VERSION" ]]; then
    add_diff "version: installed='$tver' source='$SOURCE_VERSION'"
  fi
  # 查 2: 实体目录 cache/autopilot/autopilot/<源ver>/ 存在
  if [[ ! -d "$EXPECTED_ENTITY_DIR" ]]; then
    add_diff "entity-dir: missing path='$EXPECTED_ENTITY_DIR'"
  fi
  # 查 3: manifest 逐字节一致（必须 cmp -s，禁裸 diff）
  if [[ ! -f "$TARGET_MANIFEST" ]]; then
    add_diff "marketplace-manifest: missing path='$TARGET_MANIFEST'"
  elif ! cmp -s "$TARGET_MANIFEST" "$SRC_MANIFEST"; then
    add_diff "marketplace-manifest: differs target='$TARGET_MANIFEST' source='$SRC_MANIFEST'"
  fi
  # 查 4: known_marketplaces 有 id 条目且 source.source=directory 且 source.path 归一化后 == 源仓
  kprobe="$(py_probe_known)" || exit 2
  if [[ "$kprobe" == "no-entry" ]]; then
    add_diff "known-marketplaces: no entry id='$MARKETPLACE_NAME'"
  else
    IFS=$'\t' read -r _kind kss kpath <<< "$kprobe"
    if [[ "$kss" != "directory" ]]; then
      add_diff "known-marketplaces: source.source='$kss' expected='directory'"
    fi
    kpath_norm="$(norm_path "$kpath")"
    if [[ "$kpath_norm" != "$REPO_NORM" ]]; then
      add_diff "known-marketplaces: source.path='$kpath' expected='$REPO_NORM'"
    fi
  fi
  # 查 5: installed 条目 installPath（归一化后）== 实体目录
  expected_norm="$(norm_path "$EXPECTED_ENTITY_DIR")"
  if [[ "$INSTALLED_PRESENT" -eq 0 ]]; then
    add_diff "install-path: not-installed (expected='$expected_norm')"
  else
    tip_norm="$(norm_path "$tip")"
    if [[ "$tip_norm" != "$expected_norm" ]]; then
      add_diff "install-path: installed='$tip' expected='$expected_norm'"
    fi
  fi
}

# ---- 参数解析 ----
MODE_CHECK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      MODE_CHECK=1
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      die "USAGE_ERROR: 未知参数 '$1'（仅支持 --check / --help）"
      ;;
  esac
  shift
done

command -v python3 >/dev/null 2>&1 ||
  die "PYTHON3_MISSING: 需要 python3 (stdlib json) 做 JSON 读写"

# ---- 环境与路径（归一化去尾斜杠） ----
ZCODE_CLI_HOME="${ZCODE_CLI_HOME:-$HOME/.zcode/cli}"
PLUGIN_SOURCE_REPO="${PLUGIN_SOURCE_REPO:-$HOME/workspace/string-claude-code-plugin}"
ZCODE_CLI_HOME="$(norm_path "$ZCODE_CLI_HOME")"
PLUGIN_SOURCE_REPO="$(norm_path "$PLUGIN_SOURCE_REPO")"
REPO_NORM="$PLUGIN_SOURCE_REPO"

SOURCE_PLUGIN_DIR="$PLUGIN_SOURCE_REPO/plugins/$PLUGIN_NAME"
SRC_PLUGIN_JSON="$SOURCE_PLUGIN_DIR/.claude-plugin/plugin.json"
SRC_MANIFEST="$PLUGIN_SOURCE_REPO/.claude-plugin/marketplace.json"
TARGET_PLUGINS="$ZCODE_CLI_HOME/plugins"
TARGET_CACHE_PARENT="$TARGET_PLUGINS/cache/$MARKETPLACE_NAME/$PLUGIN_NAME"
TARGET_MANIFEST="$TARGET_PLUGINS/marketplaces/$MARKETPLACE_NAME/marketplace.json"
TARGET_KNOWN="$TARGET_PLUGINS/known_marketplaces.json"
TARGET_INSTALLED="$TARGET_PLUGINS/installed_plugins.json"

# ---- 源探测 ----
SOURCE_VERSION="$(py_read_source_version)" || exit 2
printf 'SOURCE_VERSION: %s\n' "$SOURCE_VERSION"
EXPECTED_ENTITY_DIR="$TARGET_CACHE_PARENT/$SOURCE_VERSION"
PLUGIN_COUNT="$(py_read_plugin_count)" || exit 2

# ---- 一致性五查（首轮） ----
collect_checks
printf 'TARGET_VERSION: %s\n' "$TARGET_VERSION_DISPLAY"

if [[ "$MODE_CHECK" -eq 1 ]]; then
  if [[ "$CHECK_ALL_PASS" -eq 1 ]]; then
    printf 'STATUS: %s\n' "IN_SYNC"
    exit 0
  fi
  print_diffs
  printf 'STATUS: %s\n' "OUT_OF_SYNC"
  exit 1
fi

# ---- 默认同步模式：五查全过即幂等锚点（零写入） ----
if [[ "$CHECK_ALL_PASS" -eq 1 ]]; then
  printf 'STATUS: %s\n' "UP_TO_DATE"
  exit 0
fi

print_diffs

# a. 实体目录: mkdir -p 后 ditto 拷入（缺失时兜底 cp -R）；旧版本实体目录一律保留
if ! mkdir -p "$EXPECTED_ENTITY_DIR"; then
  die "TARGET_NOT_WRITABLE: mkdir -p '$EXPECTED_ENTITY_DIR' 失败"
fi
if command -v ditto >/dev/null 2>&1; then
  if ! ditto "$SOURCE_PLUGIN_DIR" "$EXPECTED_ENTITY_DIR"; then
    die "ENTITY_COPY_FAILED: ditto '$SOURCE_PLUGIN_DIR' '$EXPECTED_ENTITY_DIR' 失败"
  fi
  printf "SYNC: entity: ditto '%s' -> '%s'\n" "$SOURCE_PLUGIN_DIR" "$EXPECTED_ENTITY_DIR"
else
  if ! cp -R "$SOURCE_PLUGIN_DIR/." "$EXPECTED_ENTITY_DIR"; then
    die "ENTITY_COPY_FAILED: cp -R '$SOURCE_PLUGIN_DIR/.' '$EXPECTED_ENTITY_DIR' 失败"
  fi
  printf "SYNC: entity: cp -R '%s/.' -> '%s'\n" "$SOURCE_PLUGIN_DIR" "$EXPECTED_ENTITY_DIR"
fi

# b. manifest: cmp -s 有差异才 cp 覆盖（无差异跳过，避免无谓 mtime 变化）
if [[ ! -f "$TARGET_MANIFEST" ]] || ! cmp -s "$SRC_MANIFEST" "$TARGET_MANIFEST"; then
  if ! mkdir -p "$(dirname "$TARGET_MANIFEST")"; then
    die "TARGET_NOT_WRITABLE: mkdir -p '$(dirname "$TARGET_MANIFEST")' 失败"
  fi
  if ! cp "$SRC_MANIFEST" "$TARGET_MANIFEST"; then
    die "TARGET_NOT_WRITABLE: cp '$SRC_MANIFEST' '$TARGET_MANIFEST' 失败"
  fi
  printf "SYNC: manifest: cp '%s' -> '%s'\n" "$SRC_MANIFEST" "$TARGET_MANIFEST"
fi

if ! mkdir -p "$TARGET_PLUGINS"; then
  die "TARGET_NOT_WRITABLE: mkdir -p '$TARGET_PLUGINS' 失败"
fi

# c. known_marketplaces.json upsert（python3 stdlib json，indent=2 / ensure_ascii=False）
known_action="$(py_upsert_known)" || exit 2
printf "SYNC: known_marketplaces: %s entry id='%s'\n" "$known_action" "$MARKETPLACE_NAME"

# d. installed_plugins.json upsert
installed_action="$(py_upsert_installed)" || exit 2
printf "SYNC: installed_plugins: %s entry id='%s'\n" "$installed_action" "$PLUGIN_ID"

# f. 同步后自检：重跑五查，不过即 POST_SYNC_VERIFY_FAILED
collect_checks
if [[ "$CHECK_ALL_PASS" -eq 1 ]]; then
  printf 'STATUS: %s\n' "SYNCED"
  exit 0
fi
print_diffs
die "POST_SYNC_VERIFY_FAILED: 同步后五查未全过"
