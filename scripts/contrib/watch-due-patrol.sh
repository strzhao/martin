#!/bin/bash
# watch-due-patrol.sh — deterministic due-date wake-up for [watch] cards (card t_cc4c9fcd)
#
# WHY THIS EXISTS
#   `scheduled` and `blocked` cards never wake by themselves: the kernel documents
#   schedule_task as parked "until unblock_task re-gates it" (hermes_cli/kanban_db.py:3767-3770)
#   and the dispatcher only enumerates the ready lane
#   (hermes_cli/kanban_db_dispatch.py `_lane_rows(conn,"ready")`). The only wake actor used to be
#   the clamp inside scripts/contrib/heartbeat.sh; that script and its cron host were retired on
#   2026-09-13 (commit 753409c), so the 10 materialised due-dated [watch] cards had no actor at
#   all (task_events kind='unblocked' = 0 ever came from the clamp). This restores the actor on
#   the *existing* deterministic surface: the per-tick harness ~/.hermes/scripts/contrib-flush.sh
#   (cron job 3e5c6e23e260) calls this script, so no new job, no new plist, no new job field.
#
# CONTRACT (keep in sync with card t_cc4c9fcd + deploy/contrib-operator/SKILL.md 4.1)
#   1. Board DB is read-only and always via `?immutable=1`. Never `?mode=ro`: on this WAL board
#      that read fails rc=14 "unable to open database file" whenever -wal/-shm are absent, and
#      the retired clamp's `2>/dev/null || true` swallowed exactly that, silently.
#   2. Scan domain = task_comments only (machine lines are a comment contract). Card bodies are
#      NOT scanned: they carry the operating rule and prose that mentions the token, which only
#      adds false windows.
#   3. Candidates = status in ('scheduled','blocked'). Cards already re-gated (ready/running/
#      done/archived) are excluded by the read itself, so a wake can never repeat for one card.
#   4. Due date per card = MAX over that card's comment windows that pass the YYYY-MM-DD shape
#      guard. A revision note raises the date (t_03bc12f0 carries 2026-09-16 and 2026-09-18);
#      min/first-match would wake it two days early and burn a worker run. Window = the 10 chars
#      after the token's single trailing space, first occurrence per comment - the same parse the
#      retired clamp used. A window failing the guard is logged as SKIP and never judged (naive
#      widening once woke the non-due card t_8bc51715 on the same day).
#   5. Wake = `hermes kanban --board contrib unblock <id> --reason ...`; never a direct SQLite
#      write (write-path discipline).
#   6. Always exit 0. stdout <= 1 line: the harness injects stdout into the shift agent's prompt;
#      details go to $CONTRIB/logs/watch-due-patrol.log (registered in
#      tests/lib/production-writers.tsv, single-line records, timestamp-first alphabet).
#   7. Log states are greppable: no line = zero cards read | `patrol read FAILED` = read broken |
#      `patrol parse SKIP` = token present but window malformed | `patrol woke` |
#      `patrol unblock FAILED`.
#
# DEPLOYMENT: truth = scripts/contrib/watch-due-patrol.sh; deployed copy =
#   ~/.hermes/scripts/watch-due-patrol.sh (cp + diff, byte-identical both ways).
# ROLLBACK: drop the two patrol lines from scripts/contrib/contrib-flush.sh and remove the
#   deployed copy (see that file's header).
# SEAMS (tests only; defaults = production): MARTIN_DIR, CONTRIB_DATA_DIR, HERMES_BIN.
set -uo pipefail

MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"
CONTRIB="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"
BOARD="contrib"
DB="$HOME/.hermes/kanban/boards/$BOARD/kanban.db"
LOG="$CONTRIB/logs/watch-due-patrol.log"

# PATH: cron/launchd hand out a minimal PATH (nvm-installed CLIs resolve to rc=127 there).
# Append-only, never prepend: prepending /usr/bin ahead of an already-shadowed PATH turns the
# test suite's shadow stubs (date/hermes) into no-ops, i.e. it escapes the sandbox by design.
for d in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin; do
  case ":$PATH:" in
    *":$d:"*) : ;;
    *) [ -d "$d" ] && PATH="$PATH:$d" ;;
  esac
done
node_bin="$(ls -td "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | head -1 || true)"
if [ -n "$node_bin" ] && [ -x "$node_bin/node" ]; then
  case ":$PATH:" in
    *":$node_bin:"*) : ;;
    *) PATH="$PATH:$node_bin" ;;   # hermes/tunnel are npm wrappers: the node binary must be reachable
  esac
fi
export PATH

# hermes binary: seam > PATH > nvm glob (same three-step resolution as the flush harness).
KANBAN="${HERMES_BIN:-}"
if [ -z "$KANBAN" ]; then
  KANBAN="$(command -v hermes 2>/dev/null || true)"
fi
if [ -z "$KANBAN" ]; then
  KANBAN="$(ls -t "$HOME"/.nvm/versions/node/*/bin/hermes 2>/dev/null | head -1 || true)"
fi
KANBAN="${KANBAN:-hermes}"

TODAY="$(date +%F)"
# Inline (no LOGDIR-style variable): a `$LOG`-prefixed variable name makes the write-attribution
# source guard derive a phantom write point (`<log>_PARENT`), since its substitution is
# prefix-blind. Keep the log path itself as the only $CONTRIB-derived literal here.
[ -d "${LOG%/*}" ] || mkdir -p "${LOG%/*}" 2>/dev/null || true

log_line() { # <detail> — always one physical line (the log has a single-line alphabet)
  local detail
  detail="$(printf '%s' "$1" | tr '\n' ' ')"
  printf '[%s] patrol %s\n' "$(date '+%F %T')" "${detail:0:200}" >>"$LOG" 2>/dev/null || true
}

# One row per candidate card: `<id>|<max valid window>` or `<id>|X|len=.. first=0x..` when the
# card only carries windows that fail the shape guard (no verdict for those: SKIP + log).
READ_SQL="
with w as (
  select t.id as id,
         substr(trim(replace(c.body,char(13),'')), instr(trim(replace(c.body,char(13),'')),'watch-due:')+11, 10) as due
  from tasks t join task_comments c on c.task_id = t.id
  where t.status in ('scheduled','blocked') and c.body like '%watch-due:%'
),
v as (
  select id, due from w where due glob '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
)
select id || '|' || max(due) from v group by id
union all
select r.id || '|X|len=' || length(min(r.due)) || ' first=0x' || hex(substr(min(r.due),1,1))
  from w r where not exists (select 1 from v where v.id = r.id)
 group by r.id"

raw="$(sqlite3 "file:$DB?immutable=1" "$READ_SQL" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  log_line "read FAILED rc=$rc: $raw"
  printf 'watch-due patrol: read FAILED rc=%s（DB=%s；详见 logs/watch-due-patrol.log）\n' "$rc" "$DB"
  exit 0
fi

woken=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  id="${line%%|*}"
  rest="${line#*|}"
  case "$id" in
    # defensive shape guard on the id read from the board (never trust the row verbatim); the
    # write path stays CLI-only, so a malformed id must never reach argv.
    t_[A-Za-z0-9]*) : ;;
    *) continue ;;
  esac
  case "$rest" in
    X\|*)
      log_line "parse SKIP $id win=[${rest#X|}]"
      continue
      ;;
  esac
  [ "$rest" \> "$TODAY" ] && continue
  if "$KANBAN" kanban --board "$BOARD" unblock "$id" --reason "watch-due 到期唤醒（确定性巡检器）" >/dev/null 2>&1; then
    log_line "woke $id due=$rest today=$TODAY"
    woken="$woken $id"
  else
    log_line "unblock FAILED $id"
  fi
done <<<"$raw"

if [ -n "$woken" ]; then
  printf 'watch-due patrol: 本 tick 唤醒 %s（今天 %s；判据=max(合法到期日) <= 今天）\n' "${woken# }" "$TODAY"
fi
exit 0
