#!/bin/bash
# pth-shim-patrol.sh — toolchain python .pth shim self-heal (deterministic tick face)
#
# Why: PM runtime staging regeneration (~/.hermes/installs/<key>/environments/<gen>/)
#   wipes the toolchain python's site-packages contents, including the single-line
#   hermes-agent-repo.pth that lets the isolated launcher interpreter import hermes_cli.
#   Two production bites: 2026-09-26 ~20:00 (6 cards / 12 runs crashed, ~4h lost) and
#   2026-09-27 11:32 (redteam worker crash x2 -> gave_up). Spawn chain strips PYTHONPATH
#   by design; the .pth is the only import path left. This patrol re-writes it on its
#   next hourly tick (contrib-flush.sh :02 face) — i.e. worst-case exposure equals the
#   flush cadence (~60 min), NOT 2 minutes (the header here previously claimed "one
#   tick (2 min)"; that was wrong and cost a 24-min wipe window on 2026-09-29 02:16
#   where two worker cards crashed before the 02:40 manual heal).
# Same-face contract as watch-due-patrol: always exit 0, stdout <=1 line (only on
#   state change), details to contrib-data/logs/pth-shim-patrol.log.
# Rollback: remove the 3-line stanza in contrib-flush.sh + delete this file (both the
#   git true-source and the deployed copy under ~/.hermes/scripts/contrib/).
set -uo pipefail

REPO="$HOME/workspace/hermes-agent"
PTH_NAME="hermes-agent-repo.pth"
LOG="$HOME/workspace/martin/contrib-data/logs/pth-shim-patrol.log"

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null || true; }

# repo guard: no repo root -> nothing to point at, never write a wrong path
if [ ! -d "$REPO/hermes_cli" ]; then
  log "skip: repo root missing or moved ($REPO)"
  exit 0
fi

healed=0
for py in "$HOME"/.hermes/tools/python-*/bin/python3; do
  [ -x "$py" ] || continue
  purelib="$("$py" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])' 2>/dev/null)" || continue
  [ -n "$purelib" ] && [ -d "$purelib" ] || continue
  want="$purelib/$PTH_NAME"
  if [ -f "$want" ] && [ "$(cat "$want" 2>/dev/null)" = "$REPO" ]; then
    continue
  fi
  if printf '%s\n' "$REPO" > "$want" 2>/dev/null; then
    healed=$((healed + 1))
    log "healed: $want"
  else
    log "WRITE FAILED: $want"
  fi
done

# acid check: a clean-env child of the first toolchain python must import hermes_cli
py1="$(ls "$HOME"/.hermes/tools/python-*/bin/python3 2>/dev/null | head -1)"
if [ -n "$py1" ] && [ -x "$py1" ]; then
  if ! env -i HOME="$HOME" PATH="/usr/bin:/bin" "$py1" -c 'import hermes_cli' >/dev/null 2>&1; then
    log "WARN: clean-env import still failing (healed=$healed)"
    printf 'pth-shim: WARN import failing after heal=%d\n' "$healed"
    exit 0
  fi
fi

if [ "$healed" -gt 0 ]; then
  printf 'pth-shim: healed %d site(s)\n' "$healed"
fi
exit 0
