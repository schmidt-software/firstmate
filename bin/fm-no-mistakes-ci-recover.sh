#!/usr/bin/env bash
# fm-no-mistakes-ci-recover.sh - guided recovery for the no-mistakes ci-step
# gh-checks-cwd bug: https://github.com/schmidt-software/firstmate/issues/3
#
# The no-mistakes daemon's `ci` pipeline step can get stuck retrying
# `gh pr checks: exit status 1` forever, even after GitHub's own checks are
# already green, because some other step handler leaves the daemon's working
# directory pointed away from the target repo before the ci step's own `gh`
# call runs. Root cause, evidence, and the no-mistakes-side suggested fix are
# owned by that issue; firstmate has no source access to no-mistakes itself,
# so this script only automates the manual recovery dance around it instead
# of re-deriving it by hand every time it recurs.
#
# Usage:
#   fm-no-mistakes-ci-recover.sh <task-id> [--force] [--notify-worker]
#                                 [--resolve-key <key>]
#   fm-no-mistakes-ci-recover.sh --help
#
# Without --force, this only diagnoses: it confirms the task's no-mistakes
# run is genuinely stuck in this exact way, independently confirms GitHub
# itself already reports the check green, and lists every other no-mistakes
# run a daemon restart would affect - then refuses to restart anything. It
# never restarts the shared daemon on its own; --force is required every
# time, matching the project-management skill's standing rule that firstmate
# never restarts the shared daemon from a project operation - here, a
# deliberate, explicitly-stated decision each time, never an automated
# default.
#
# Detection never assumes: it samples `no-mistakes axi status` twice
# (FM_NMCR_SAMPLE_INTERVAL_SECS apart, default 5s) and requires BOTH samples
# to show the `ci` step `running` with the exact known warning text, plus the
# second sample's active_for at least FM_NMCR_MIN_ACTIVE_SECS (default 60s) -
# so a single transient hiccup is never misread as this bug. It then
# independently re-checks the PR's actual state with `gh pr checks --repo
# <owner>/<repo>` run from the task's own worktree (never an arbitrary
# directory - that is the exact mistake this script is recovering from). Only
# when both agree is the daemon treated as safe to force-restart.
#
# The "other active runs" list comes from the read-only `no-mistakes runs`
# listing, never from probing `daemon restart` without --force: this script
# does not rely on any assumption about what an unforced `daemon restart`
# would do if nothing else were active, so it never invokes that subcommand
# at all except in the single --force branch, once the operator has already
# committed to restarting. A failed or timed-out `runs` query is reported as
# such, distinct from a genuinely empty listing, instead of being silently
# treated as "nothing else is active".
#
# After a --force restart, `no-mistakes doctor` must report the daemon
# healthy again before this script reports success. It then prints the exact
# `bin/fm-send.sh <id> --resolve-key <key> ...` command that closes the
# worker's open decision/blocker and tells it it is safe to resume (see
# AGENTS.md section 7's no-mistakes worker contract for what the worker does
# next - sync then rerun - unchanged by this script); pass --notify-worker to
# run that command directly instead of only printing it. --resolve-key
# defaults to "default", the usual unkeyed status-log decision.
#
# This script never touches the worker's own worktree or no-mistakes run (no
# sync/rerun/respond here - that stays the worker's job per its brief) and
# never restarts the daemon without --force.
#
# Tunables (env, all optional):
#   FM_NMCR_NM_TIMEOUT            bounded seconds per `axi status` probe (10)
#   FM_NMCR_SAMPLE_INTERVAL_SECS  seconds between the two confirmation samples (5)
#   FM_NMCR_MIN_ACTIVE_SECS       minimum confirmed active_for to proceed (60)
#   FM_NMCR_RUNS_LIMIT            rows requested from `no-mistakes runs --limit` (50)
#   FM_NMCR_RESTART_TIMEOUT       bounded seconds for `daemon restart --force` (30)
#   FM_NMCR_DOCTOR_TIMEOUT        bounded seconds for the post-restart `doctor` (15)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

STUCK_MARKER='could not check CI: gh pr checks: exit status 1'

refuse() {  # <message...>
  printf 'REFUSED: %s\n' "$*" >&2
  exit 1
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

ID=${1:-}
if [ -z "$ID" ]; then
  usage >&2
  exit 2
fi
shift

FORCE=0
NOTIFY_WORKER=0
RESOLVE_KEY=default
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    --notify-worker)
      NOTIFY_WORKER=1
      shift
      ;;
    --resolve-key)
      [ "$#" -ge 2 ] || { echo "error: --resolve-key requires a value" >&2; exit 2; }
      RESOLVE_KEY=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unrecognized argument '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no metadata for task $ID at $META" >&2; exit 1; }

meta_value() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

WT=$(meta_value worktree)
KIND=$(meta_value kind)
[ -n "$KIND" ] || KIND=ship
if [ "$KIND" != ship ]; then
  echo "error: task $ID is kind=$KIND, not a ship task; this recovery only applies to a no-mistakes ship validation" >&2
  exit 1
fi
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  echo "error: worktree for task $ID is missing (torn down?): '$WT'" >&2
  exit 1
fi

command -v no-mistakes >/dev/null 2>&1 || { echo "error: no-mistakes not found on PATH" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "error: gh not found on PATH" >&2; exit 1; }

NM_TIMEOUT=${FM_NMCR_NM_TIMEOUT:-10}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=10 ;; esac
SAMPLE_INTERVAL=${FM_NMCR_SAMPLE_INTERVAL_SECS:-5}
case "$SAMPLE_INTERVAL" in ''|*[!0-9]*) SAMPLE_INTERVAL=5 ;; esac
MIN_ACTIVE_SECS=${FM_NMCR_MIN_ACTIVE_SECS:-60}
case "$MIN_ACTIVE_SECS" in ''|*[!0-9]*) MIN_ACTIVE_SECS=60 ;; esac
RUNS_LIMIT=${FM_NMCR_RUNS_LIMIT:-50}
case "$RUNS_LIMIT" in ''|*[!0-9]*) RUNS_LIMIT=50 ;; esac
RESTART_TIMEOUT=${FM_NMCR_RESTART_TIMEOUT:-30}
case "$RESTART_TIMEOUT" in ''|*[!0-9]*) RESTART_TIMEOUT=30 ;; esac
DOCTOR_TIMEOUT=${FM_NMCR_DOCTOR_TIMEOUT:-15}
case "$DOCTOR_TIMEOUT" in ''|*[!0-9]*) DOCTOR_TIMEOUT=15 ;; esac

nm_status() {
  fm_nm_run "$WT" "$NM_TIMEOUT" axi status
}

# First "ci," row inside the active_steps[...] table only - never a sibling
# table (e.g. the separate completed-steps summary table), which uses
# different columns and can also carry a "ci,running,..." row with no bearing
# on this bug. The boundary is any later line indented no deeper than the
# active_steps[...] header line itself, not specifically column 0, since a
# sibling table nested at the same level as active_steps (not just a
# top-level run:/branch_sync: key) must never be scanned into either.
nm_active_ci_row() {  # <run-out>
  printf '%s\n' "$1" | awk '
    /^[[:space:]]*active_steps\[/ {
      match($0, /^[[:space:]]*/)
      indent = RLENGTH
      active = 1
      next
    }
    active {
      match($0, /^[[:space:]]*/)
      if (RLENGTH <= indent) { active = 0 }
    }
    active && /^[[:space:]]*ci,/ { print; exit }
  '
}

# Tab-separated status, active_for, last_activity, agent_pid, round from one
# active_steps row "ci,<status>,<active_for>,<last_activity>,<agent_pid>,<round>".
# Splits on commas that fall outside a quoted field, per this repo's TOON
# quoting convention (bin/fm-bearings-snapshot.sh), so a comma embedded inside
# the quoted last_activity free-text column (e.g. a retry-count log line) is
# never mistaken for a column delimiter.
nm_active_ci_fields() {  # <row>
  printf '%s' "$1" | awk '
    {
      n = 0
      field = ""
      inquotes = 0
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "\"") { inquotes = !inquotes; continue }
        if (c == "," && !inquotes) { fields[n++] = field; field = ""; continue }
        field = field c
      }
      fields[n++] = field
      for (i = 0; i <= 5; i++) { gsub(/^[ \t]+|[ \t]+$/, "", fields[i]) }
      printf "%s\t%s\t%s\t%s\t%s", fields[1], fields[2], fields[3], fields[4], fields[5]
    }
  '
}

# Go-style duration string ("13m35s", "45s", "1h2m3s", "2h") to whole seconds.
# Sub-second Go units (ms, µs/us, ns) are recognized before the h/m/s parsing
# below so the literal "m" in "ms" is never misread as the minutes separator;
# duration_to_secs only needs whole-second precision, so any sub-second value
# safely floors to 0. A fractional seconds component (e.g. "1m35.243s") is
# truncated to whole seconds rather than rejected as non-numeric, so it still
# counts toward active_for instead of undercounting to just the minutes/hours.
duration_to_secs() {  # <duration>
  local rest=$1 h=0 m=0 sec=0
  case "$rest" in *ms|*[uµ]s|*ns) printf '%s' 0; return ;; esac
  case "$rest" in *h*) h=${rest%%h*}; rest=${rest#*h} ;; esac
  case "$rest" in *m*) m=${rest%%m*}; rest=${rest#*m} ;; esac
  case "$rest" in *s) sec=${rest%s} ;; esac
  case "$sec" in *.*) sec=${sec%%.*} ;; esac
  case "$h" in ''|*[!0-9]*) h=0 ;; esac
  case "$m" in ''|*[!0-9]*) m=0 ;; esac
  case "$sec" in ''|*[!0-9]*) sec=0 ;; esac
  printf '%s' "$((h * 3600 + m * 60 + sec))"
}

echo "diagnosing task $ID (worktree: $WT)"

RUN_OUT_1=$(nm_status)
ROW_1=$(nm_active_ci_row "$RUN_OUT_1")
[ -n "$ROW_1" ] || refuse "no active 'ci' step found in this task's no-mistakes run; not confirmed as the known stuck-ci bug"
FIELDS_1=$(nm_active_ci_fields "$ROW_1")
STATUS_1=$(printf '%s' "$FIELDS_1" | cut -f1)
LAST_1=$(printf '%s' "$FIELDS_1" | cut -f3)
[ "$STATUS_1" = running ] || refuse "ci step is '$STATUS_1', not running; not confirmed as the known stuck-ci bug"
printf '%s' "$LAST_1" | grep -qF "$STUCK_MARKER" \
  || refuse "ci step's latest log line does not match the known warning ('$STUCK_MARKER'); not confirmed as this bug (saw: $LAST_1)"

echo "first sample: ci step running, log: $LAST_1"
echo "waiting ${SAMPLE_INTERVAL}s for a second sample..."
sleep "$SAMPLE_INTERVAL"

RUN_OUT_2=$(nm_status)
ROW_2=$(nm_active_ci_row "$RUN_OUT_2")
[ -n "$ROW_2" ] || refuse "ci step is no longer active on the second sample; it may already have recovered on its own"
FIELDS_2=$(nm_active_ci_fields "$ROW_2")
STATUS_2=$(printf '%s' "$FIELDS_2" | cut -f1)
ACTIVE_FOR_2=$(printf '%s' "$FIELDS_2" | cut -f2)
LAST_2=$(printf '%s' "$FIELDS_2" | cut -f3)
[ "$STATUS_2" = running ] || refuse "ci step is '$STATUS_2' on the second sample; it may already have recovered on its own"
printf '%s' "$LAST_2" | grep -qF "$STUCK_MARKER" \
  || refuse "ci step's log advanced past the known warning on the second sample; it may already have recovered on its own (saw: $LAST_2)"

ACTIVE_SECS=$(duration_to_secs "$ACTIVE_FOR_2")
[ "$ACTIVE_SECS" -ge "$MIN_ACTIVE_SECS" ] \
  || refuse "ci step has only been active $ACTIVE_FOR_2 (< ${MIN_ACTIVE_SECS}s); too brief to rule out a transient hiccup rather than this bug"

RUN_ID=$(fm_nm_strip_quotes "$(fm_nm_field "$RUN_OUT_2" id)")
echo "confirmed: ci step (run $RUN_ID) stuck running for $ACTIVE_FOR_2, repeating: $LAST_2"

PR_URL=$(meta_value pr)
[ -n "$PR_URL" ] || PR_URL=$(fm_nm_strip_quotes "$(fm_nm_field "$RUN_OUT_2" pr)")
[ -n "$PR_URL" ] || refuse "no PR URL recorded for task $ID (state/$ID.meta pr= and the run's own pr: field are both empty); run bin/fm-pr-check.sh <id> <pr-url> first"

fm_pr_url_parse "$PR_URL" || refuse "PR URL '$PR_URL' could not be parsed"
[ "$FM_PR_PROVIDER" = github ] \
  || refuse "PR provider is '$FM_PR_PROVIDER', not github; the known stuck-ci bug is specific to no-mistakes' gh-based CI check"

OWNER_REPO=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

echo
echo "independently checking GitHub: gh pr checks $NUMBER --repo $OWNER_REPO (run from $WT)"
GH_OUT=$(cd "$WT" && gh pr checks "$NUMBER" --repo "$OWNER_REPO" 2>&1)
GH_RC=$?
printf '%s\n' "$GH_OUT"
[ "$GH_RC" -eq 0 ] \
  || refuse "gh pr checks $NUMBER --repo $OWNER_REPO exited $GH_RC from the actual worktree; GitHub does not (yet) show this PR green, so this is NOT confirmed as the known daemon bug - do not restart"

echo "confirmed: GitHub reports PR $PR_URL green while no-mistakes' ci step is stuck retrying a false failure"

BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
echo
echo "other no-mistakes runs a daemon restart would affect (this task's own branch is '$BRANCH'):"
RUNS_LIST=$(fm_nm_run_bounded "$WT" "$NM_TIMEOUT" runs --limit "$RUNS_LIMIT" 2>&1)
RUNS_RC=$?
if [ "$RUNS_RC" -ne 0 ]; then
  echo "(could not query other active runs - no-mistakes runs failed or timed out; assume other work may be affected before deciding)"
elif [ -n "$RUNS_LIST" ]; then
  printf '%s\n' "$RUNS_LIST"
else
  echo "(no runs reported)"
fi

if [ "$FORCE" -ne 1 ]; then
  refuse "diagnosis complete and matches the known bug (issue #3), but --force was not given; rerun with --force to actually restart the shared no-mistakes daemon. This affects every active run listed above, not just task $ID."
fi

echo
echo "restarting the no-mistakes daemon (--force)..."
RESTART_OUT=$(fm_nm_run_bounded "$WT" "$RESTART_TIMEOUT" daemon restart --force 2>&1)
RESTART_RC=$?
printf '%s\n' "$RESTART_OUT"
if [ "$RESTART_RC" -ne 0 ]; then
  echo "error: no-mistakes daemon restart --force exited $RESTART_RC" >&2
  exit 1
fi

echo
echo "confirming daemon health..."
DOCTOR_OUT=$(fm_nm_run_bounded "$WT" "$DOCTOR_TIMEOUT" doctor 2>&1)
printf '%s\n' "$DOCTOR_OUT"
DAEMON_LINE=$(printf '%s\n' "$DOCTOR_OUT" | grep -i 'daemon' | head -1)
if [ -z "$DAEMON_LINE" ] || printf '%s' "$DAEMON_LINE" | grep -qi 'not running' \
  || ! printf '%s' "$DAEMON_LINE" | grep -qi 'running'; then
  echo "error: no-mistakes doctor does not report the daemon healthy after restart (see output above)" >&2
  exit 1
fi
echo "confirmed: no-mistakes daemon is healthy again"

SEND_MSG="no-mistakes daemon restarted: task $ID's ci step was stuck retrying a false CI failure (known bug, github.com/schmidt-software/firstmate/issues/3) even though GitHub already showed PR $PR_URL green; safe to resume - continue with sync/rerun per your brief."

echo
echo "next: tell the worker it is safe to resume and close its open decision:"
printf '  FM_HOME=%q %q %q --resolve-key %q %q\n' "$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$ID" "$RESOLVE_KEY" "$SEND_MSG"

if [ "$NOTIFY_WORKER" -eq 1 ]; then
  echo "notifying task $ID..."
  if FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$ID" --resolve-key "$RESOLVE_KEY" "$SEND_MSG"; then
    echo "notified: task $ID"
  else
    echo "error: fm-send.sh failed to notify task $ID; run the command above manually" >&2
    exit 1
  fi
fi

echo
echo "RECOVERED: daemon restarted and confirmed healthy for task $ID"
exit 0
