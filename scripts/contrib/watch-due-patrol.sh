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
#   1. Board DBs are read-only. Read path per board = `?mode=ro` FIRST (WAL-aware = current state
#      while the dispatcher keeps -wal/-shm sidecars alive), `?immutable=1` ONLY as fallback for
#      the parked state (sidecars absent -> mode=ro fails rc=14; main db is then current, no
#      pending WAL).
#      2026-10-24 incident: the old unconditional immutable=1 read took a stale main-db snapshot
#      during an active window and mass-woke 94 not-yet-due watch cards off pre-revision windows
#      (the 00:4x-02:2x revision wave's new windows all lived only in the -wal sidecar).
#   2. Scan domain = WATCH_BOARDS (default "contrib default"). 2026-11-01 ([fix] t_756e0fc9):
#      due-wake went cross-board. `default` resolves to the repo-root $HOME/.hermes/kanban.db
#      (boards/default/*.db are 0-byte stubs — never point a reader there). A watch-due machine
#      line on ANY scanned board is the wake contract; boards without watch authority
#      (life/kanban/scratch-note) are deliberately not scanned. Per-board read failure logs and
#      continues — one blind board must not blind the others.
#   3. Scan surface = task_comments only (machine lines are a comment contract). Card bodies are
#      NOT scanned: they carry the operating rule and prose that mentions the token, which only
#      adds false windows.
#   4. Candidates = status in ('scheduled','blocked'). Cards already re-gated (ready/running/
#      done/archived) are excluded by the read itself, so a wake can never repeat for one card.
#   5. Due date per card = MAX over that card's comment windows that pass the YYYY-MM-DD shape
#      guard. A revision note raises the date (t_03bc12f0 carries 2026-09-16 and 2026-09-18);
#      min/first-match would wake it two days early and burn a worker run. Window = the 10 chars
#      after the token's single trailing space, first occurrence per comment - the same parse the
#      retired clamp used. A window failing the guard is logged as SKIP and never judged (naive
#      widening once woke the non-due card t_8bc51715 on the same day).
#   6. Wake = `hermes kanban --board <board> unblock <id> --reason ...`; never a direct SQLite
#      write (write-path discipline).
#   7. Always exit 0. stdout <= 1 line: the harness injects stdout into the shift agent's prompt;
#      details go to $CONTRIB/logs/watch-due-patrol.log (registered in
#      tests/lib/production-writers.tsv, single-line records, timestamp-first alphabet).
#   8. Log states are greppable: no line = zero cards read | `patrol read FAILED` = read broken |
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
# Board scan set (2026-11-01, [fix] t_756e0fc9): due-wake is not contrib-only. The default
# board lives at the repo-root $HOME/.hermes/kanban.db (NOT boards/default/*.db — those are
# all 0-byte stubs) and carries cross-board fixtures: own-PR execution cards, digest/gate
# cards, and operator-spawned watch/[fix] cards. The single-board patrol was structurally
# blind to it (t_375c3290 sat overdue 1 day because no actor scanned default). A real
# watch-due machine line on ANY scanned board is the wake contract by definition (§4.1),
# board-agnostic; boards without watch authority (life/kanban/scratch-note) stay out of the
# default set — waking them would spend another domain's worker budget.
WATCH_BOARDS="${WATCH_BOARDS:-contrib default}"
# Board slug -> db path: `default` = repo-root kanban.db (single-home CLI resolution);
# every other board = boards/<slug>/kanban.db.
board_db() {
  case "$1" in
    default) printf '%s/.hermes/kanban.db\n' "$HOME" ;;
    *)       printf '%s/.hermes/kanban/boards/%s/kanban.db\n' "$HOME" "$1" ;;
  esac
}
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

# Per-board row format: `<board>|<id>|<max valid window>` (or `...|X|len=.. first=0x..` when the
# card only carries windows that fail the shape guard). A read failure on ONE board logs and
# continues — a blind default board must not also blind contrib (the [fix] card's loss was a
# whole board invisible; a joined failure would be two). Sets the globals SCAN_ROWS (this
# board's annotated rows) and FAIL_BOARDS; called WITHOUT command substitution so those
# assignments survive (scan_board runs in the current shell, not a subshell).
scan_board() { # <board>
  local board="$1" db raw rc
  SCAN_ROWS=""
  db="$(board_db "$board")"
  raw="$(sqlite3 "file:$db?mode=ro" "$READ_SQL" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    # Parked board (no -wal/-shm sidecars): mode=ro fails rc=14, but then the main db IS current
    # (nothing pending in WAL) -> fall back to the immutable snapshot. Anything else stays FAILED.
    log_line "read fallback board=$board mode=ro rc=$rc -> immutable (board parked or transient)"
    raw="$(sqlite3 "file:$db?immutable=1" "$READ_SQL" 2>&1)"; rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    log_line "read FAILED board=$board rc=$rc: $raw"
    FAIL_BOARDS="$FAIL_BOARDS $board"
    return 0
  fi
  # Annotate each row with its board so the wake loop can pin `--board` correctly.
  [ -n "$raw" ] && SCAN_ROWS="$(printf '%s\n' "$raw" | awk -v b="$board" 'NF { print b "|" $0 }')"
}

FAIL_BOARDS=""
board_rows=""
for b in $WATCH_BOARDS; do
  scan_board "$b"
  board_rows="$board_rows$SCAN_ROWS"$'\n'
done
raw="$board_rows"

woken=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  board="${line%%|*}"
  line="${line#*|}"
  id="${line%%|*}"
  rest="${line#*|}"
  allowed=0
  for wb in $WATCH_BOARDS; do [ "$wb" = "$board" ] && allowed=1; done
  [ "$allowed" = 1 ] || continue
  case "$id" in
    # defensive shape guard on the id read from the board (never trust the row verbatim); the
    # write path stays CLI-only, so a malformed id must never reach argv.
    t_[A-Za-z0-9]*) : ;;
    *) continue ;;
  esac
  case "$rest" in
    X\|*)
      log_line "parse SKIP board=$board $id win=[${rest#X|}]"
      continue
      ;;
  esac
  [ "$rest" \> "$TODAY" ] && continue
  if "$KANBAN" kanban --board "$board" unblock "$id" --reason "watch-due 到期唤醒（确定性巡检器）" >/dev/null 2>&1; then
    log_line "woke board=$board $id due=$rest today=$TODAY"
    woken="$woken $id"
  else
    log_line "unblock FAILED board=$board $id"
  fi
done <<<"$raw"

if [ -n "$woken" ]; then
  printf 'watch-due patrol: 本 tick 唤醒 %s（今天 %s；判据=max(合法到期日) <= 今天）\n' "${woken# }" "$TODAY"
fi
# stdout carries wakes, or a total-blinding failure (every scanned board failed). A single
# board failing is logged for the shift agent to find — it must not pollute the stdout
# contract on a day when the other board woke nothing.
if [ -z "$woken" ] && [ -n "$FAIL_BOARDS" ]; then
  all_failed=1
  for wb in $WATCH_BOARDS; do
    case " $FAIL_BOARDS " in *" $wb "*) : ;; *) all_failed=0 ;; esac
  done
  if [ "$all_failed" = 1 ]; then
    printf 'watch-due patrol: read FAILED boards:%s（详见 logs/watch-due-patrol.log）\n' "$FAIL_BOARDS"
  fi
fi
exit 0
