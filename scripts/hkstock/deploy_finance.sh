#!/bin/bash
# Deploy only generated finance executables and skill sources; never touches hkstock-data.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROFILE_DIR="${HKSTOCK_PROFILE_DIR:-$HOME/.hermes/profiles/hkstock}"
USER_BIN="${ZCODE_FINANCE_BIN:-$HOME/.local/bin/zcode-finance}"
NODE_BIN="${NODE_BIN:-node}"
BRIDGE_SRC="$REPO_ROOT/scripts/finance/zcode-mcp-bridge.mjs"
GUARD_SRC="$REPO_ROOT/scripts/hkstock/research_guard.py"
THESIS_STORE_SRC="$REPO_ROOT/scripts/hkstock/thesis_store.py"
WECHAT_EXACT_SRC="$REPO_ROOT/scripts/hkstock/wechat_exact.py"
SKILL_SRC="$REPO_ROOT/deploy/hkstock/morning-brief"
SKILL_DEST="$PROFILE_DIR/skills/morning-brief"

for source in "$BRIDGE_SRC" "$GUARD_SRC" "$THESIS_STORE_SRC" "$WECHAT_EXACT_SRC" "$SKILL_SRC/SKILL.md"; do
  [[ -f "$source" ]] || { printf 'DEPLOY_ERROR missing source: %s\n' "$source" >&2; exit 2; }
done
"$NODE_BIN" -e 'const major=Number(process.versions.node.split(".")[0]); if(major<22) process.exit(1)' \
  || { printf 'DEPLOY_ERROR Node.js 22+ is required\n' >&2; exit 2; }
"$NODE_BIN" --check "$BRIDGE_SRC"
python3 -m py_compile "$GUARD_SRC" "$THESIS_STORE_SRC" "$WECHAT_EXACT_SRC"

install_cmp() {
  local source="$1" destination="$2" mode="$3" temp
  mkdir -p "$(dirname "$destination")"
  temp="${destination}.tmp.$$"
  cp "$source" "$temp"
  chmod "$mode" "$temp"
  mv "$temp" "$destination"
  cmp -s "$source" "$destination" || { printf 'DEPLOY_ERROR cmp failed: %s\n' "$destination" >&2; exit 1; }
  printf 'CMP_OK %s\n' "$destination"
}

install_cmp "$BRIDGE_SRC" "$PROFILE_DIR/bin/zcode-finance" 755
install_cmp "$BRIDGE_SRC" "$USER_BIN" 755
install_cmp "$GUARD_SRC" "$PROFILE_DIR/bin/research_guard.py" 755
install_cmp "$THESIS_STORE_SRC" "$PROFILE_DIR/bin/thesis_store.py" 755
install_cmp "$WECHAT_EXACT_SRC" "$PROFILE_DIR/bin/wechat_exact.py" 755
install_cmp "$SKILL_SRC/SKILL.md" "$SKILL_DEST/SKILL.md" 644

mkdir -p "$SKILL_DEST/references"
for source in "$SKILL_SRC"/references/*.md; do
  install_cmp "$source" "$SKILL_DEST/references/$(basename "$source")" 644
done

printf 'DEPLOY_OK profile=%s user_bin=%s\n' "$PROFILE_DIR" "$USER_BIN"
