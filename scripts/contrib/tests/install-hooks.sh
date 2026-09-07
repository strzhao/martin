#!/bin/bash
# install-hooks.sh — 装载 contrib/approval 域入库验收门（本机一次性执行）
#   动作：git config core.hooksPath .githooks + pre-commit 补执行位。幂等。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

if [[ ! -f "$REPO_ROOT/.githooks/pre-commit" ]]; then
  echo "install-hooks: .githooks/pre-commit 缺失（应在仓内）" >&2
  exit 1
fi
chmod +x "$REPO_ROOT/.githooks/pre-commit"
git -C "$REPO_ROOT" config core.hooksPath .githooks
echo "已装载：core.hooksPath=$(git -C "$REPO_ROOT" config core.hooksPath)（pre-commit → scripts/contrib/tests/gate.sh）"
