#!/usr/bin/env bash
# Behavior tests for bin/fm-no-mistakes-ci-recover.sh - the guided recovery
# helper for the no-mistakes ci-step gh-checks-cwd bug
# (github.com/schmidt-software/firstmate/issues/3).
#
# Every case runs the real script against a fake `no-mistakes` and `gh` (never
# a real daemon or real GitHub call), and a real throwaway git worktree so the
# branch-name lookup behaves like a live task worktree. Coverage:
#   (a) refuses when the stuck condition is not confirmed: no active ci step,
#       wrong step status, log text not matching the known warning, the
#       second sample showing recovery, or too little active_for
#   (b) refuses to restart without --force even when fully confirmed
#   (c) refuses when GitHub itself does not already show the check green
#       (non-zero exit, or a reported failing check)
#   (d) a fully confirmed --force run restarts the daemon, requires
#       `no-mistakes doctor` to report it healthy again, prints the exact
#       fm-send.sh command to unblock the worker, and --notify-worker actually
#       runs that command (both its success and failure paths)
#   (e) usage/environment errors: missing meta, non-ship kind, torn-down
#       worktree, missing PR, non-GitHub PR provider, bad flags
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECOVER="$ROOT/bin/fm-no-mistakes-ci-recover.sh"
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-ci-recover)
fm_git_identity fmtest fmtest@example.invalid

KNOWN_WARNING='could not check CI: gh pr checks: exit status 1'

new_case() {  # <name> -> echoes case dir with state/home/fakebin/wt scaffolding
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state" "$d/home" "$d/fakebin"
  mkdir -p "$d/wt"
  git -C "$d/wt" init -q
  git -C "$d/wt" commit -q --allow-empty -m init
  git -C "$d/wt" checkout -q -b fm/test-task
  printf '%s\n' "$d"
}

write_meta() {  # <case-dir> <id> [pr-url] [kind]
  local d=$1 id=$2 pr=${3-https://github.com/o/r/pull/7} kind=${4:-ship}
  if [ -n "$pr" ]; then
    fm_write_meta "$d/state/$id.meta" "worktree=$d/wt" "kind=$kind" "pr=$pr"
  else
    fm_write_meta "$d/state/$id.meta" "worktree=$d/wt" "kind=$kind"
  fi
}

# active_steps[1]{...} TOON block with one "ci" row. Pass status "" to omit
# the active_steps table entirely (no active step at all).
active_run_out() {  # <status> <active_for> <last_activity> [pr]
  local status=$1 active_for=$2 last=$3 pr=${4-https://github.com/o/r/pull/7}
  if [ -z "$status" ]; then
    cat <<EOF
run:
  id: "01RUN"
  branch: fm/test-task
  status: running
  head: "abc1234"
  pr: "$pr"
EOF
    return
  fi
  cat <<EOF
run:
  id: "01RUN"
  branch: fm/test-task
  status: running
  head: "abc1234"
  pr: "$pr"
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,$status,$active_for,"$last","",starting
EOF
}

# Fakebin: `no-mistakes` (axi status alternates FM_FAKE_AXI_1/FM_FAKE_AXI_2
# across successive calls via a per-case counter file; runs/daemon/doctor
# each serve one fixed canned response) and `gh` (pr checks only).
make_fakebin() {  # <case-dir>
  local d=$1
  cat > "$d/fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
set -u
COUNT_FILE="$d/.nm-call-count"
case "\${1:-}" in
  axi)
    shift
    case "\${1:-}" in
      status)
        n=0
        [ -f "\$COUNT_FILE" ] && n=\$(cat "\$COUNT_FILE")
        n=\$((n + 1))
        printf '%s\n' "\$n" > "\$COUNT_FILE"
        if [ "\$n" -le 1 ]; then
          printf '%s\n' "\${FM_FAKE_AXI_1:-}"
        else
          printf '%s\n' "\${FM_FAKE_AXI_2:-\${FM_FAKE_AXI_1:-}}"
        fi
        ;;
    esac
    ;;
  runs)
    printf '%s\n' "\${FM_FAKE_RUNS_LIST:-}"
    exit "\${FM_FAKE_RUNS_RC:-0}"
    ;;
  daemon)
    shift
    if [ "\${1:-}" = restart ] && [ "\${2:-}" = --force ]; then
      printf '%s\n' "\${FM_FAKE_RESTART_OUT:-daemon restarted}"
      exit "\${FM_FAKE_RESTART_RC:-0}"
    fi
    ;;
  doctor)
    printf '%s\n' "\${FM_FAKE_DOCTOR_OUT:-  - daemon          running}"
    ;;
esac
exit 0
SH
  chmod +x "$d/fakebin/no-mistakes"
  cat > "$d/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = pr ] && [ "${2:-}" = checks ]; then
  printf '%s\n' "${FM_FAKE_GH_OUT:-build  pass  1s  https://example.invalid/run/1}"
  exit "${FM_FAKE_GH_RC:-0}"
fi
exit 1
SH
  chmod +x "$d/fakebin/gh"
}

reset_fakes() {
  FM_FAKE_AXI_1=""
  FM_FAKE_AXI_2=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_RUNS_RC=0
  FM_FAKE_RESTART_OUT=""
  FM_FAKE_RESTART_RC=0
  FM_FAKE_DOCTOR_OUT=""
  FM_FAKE_GH_OUT=""
  FM_FAKE_GH_RC=0
  FM_FAKE_SEND_OUT=""
  FM_FAKE_SEND_RC=0
  export FM_FAKE_AXI_1 FM_FAKE_AXI_2 FM_FAKE_RUNS_LIST FM_FAKE_RUNS_RC FM_FAKE_RESTART_OUT
  export FM_FAKE_RESTART_RC FM_FAKE_DOCTOR_OUT FM_FAKE_GH_OUT FM_FAKE_GH_RC
  export FM_FAKE_SEND_OUT FM_FAKE_SEND_RC
}

# A confirmed-stuck pair of samples: both show ci running with the known
# warning and an active_for comfortably above the default 60s floor. Cases
# that need to diverge just overwrite FM_FAKE_AXI_2 (or FM_FAKE_GH_*) after
# calling this.
arm_confirmed_stuck() {
  FM_FAKE_AXI_1=$(active_run_out running 1m35s "3s ago: log: warning: $KNOWN_WARNING")
  FM_FAKE_AXI_2=$(active_run_out running 1m40s "1s ago: log: warning: $KNOWN_WARNING")
}

run_recover() {  # <case-dir> <id> [args...]
  local d=$1 id=$2
  shift 2
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" FM_HOME="$d/home" \
    FM_ROOT_OVERRIDE="$ROOT" FM_NMCR_SAMPLE_INTERVAL_SECS=0 \
    "$RECOVER" "$id" "$@" 2>&1
}

# A copy of the script under test alongside a fake fm-send.sh, so
# --notify-worker's `"$SCRIPT_DIR/fm-send.sh"` call (SCRIPT_DIR resolves from
# the running script's own location) hits the fake instead of the real
# bin/fm-send.sh. Records the fake's argv to $d/send-call.args for assertion.
make_scriptdir_with_fake_send() {  # <case-dir>
  local d=$1
  mkdir -p "$d/scriptdir"
  cp "$ROOT/bin/fm-no-mistakes-ci-recover.sh" "$ROOT/bin/fm-nm-run-lib.sh" \
    "$ROOT/bin/fm-pr-lib.sh" "$d/scriptdir/"
  cat > "$d/scriptdir/fm-send.sh" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$@" > "$d/send-call.args"
printf '%s\n' "\${FM_FAKE_SEND_OUT:-}"
exit "\${FM_FAKE_SEND_RC:-0}"
SH
  chmod +x "$d/scriptdir/fm-no-mistakes-ci-recover.sh" "$d/scriptdir/fm-send.sh"
}

run_recover_with_fake_send() {  # <case-dir> <id> [args...]
  local d=$1 id=$2
  shift 2
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" FM_HOME="$d/home" \
    FM_ROOT_OVERRIDE="$ROOT" FM_NMCR_SAMPLE_INTERVAL_SECS=0 \
    "$d/scriptdir/fm-no-mistakes-ci-recover.sh" "$id" "$@" 2>&1
}

# --- (a) stuck condition not confirmed --------------------------------------

test_refuses_no_active_step() {
  reset_fakes
  local d; d=$(new_case no-active-step)
  make_fakebin "$d"
  write_meta "$d" t1
  FM_FAKE_AXI_1=$(active_run_out "" "" "")
  local out rc; out=$(run_recover "$d" t1); rc=$?
  expect_code 1 "$rc" "no active ci step must refuse"
  assert_contains "$out" "REFUSED:" "refusal is labeled"
  assert_contains "$out" "no active 'ci' step" "names the missing active step"
  pass "refuses when no active ci step is reported"
}

test_refuses_wrong_step_status() {
  reset_fakes
  local d; d=$(new_case wrong-status)
  make_fakebin "$d"
  write_meta "$d" t1
  FM_FAKE_AXI_1=$(active_run_out fixing 1m35s "1s ago: log: warning: $KNOWN_WARNING")
  local out rc; out=$(run_recover "$d" t1); rc=$?
  expect_code 1 "$rc" "non-running ci step must refuse"
  assert_contains "$out" "REFUSED:" "refusal is labeled"
  assert_contains "$out" "not running" "names the wrong status"
  pass "refuses when the ci step is not running"
}

test_refuses_log_text_mismatch() {
  reset_fakes
  local d; d=$(new_case log-mismatch)
  make_fakebin "$d"
  write_meta "$d" t1
  FM_FAKE_AXI_1=$(active_run_out running 1m35s "1s ago: log: warning: some unrelated transient network blip")
  local out rc; out=$(run_recover "$d" t1); rc=$?
  expect_code 1 "$rc" "unrelated warning text must refuse"
  assert_contains "$out" "REFUSED:" "refusal is labeled"
  assert_contains "$out" "does not match the known warning" "names the mismatch"
  pass "refuses when the log text does not match the known bug's warning"
}

test_refuses_second_sample_recovered_no_row() {
  reset_fakes
  local d; d=$(new_case recovered-no-row)
  make_fakebin "$d"
  write_meta "$d" t1
  FM_FAKE_AXI_1=$(active_run_out running 1m35s "3s ago: log: warning: $KNOWN_WARNING")
  FM_FAKE_AXI_2=$(active_run_out "" "" "")
  local out rc; out=$(run_recover "$d" t1); rc=$?
  expect_code 1 "$rc" "recovered ci step on second sample must refuse"
  assert_contains "$out" "REFUSED:" "refusal is labeled"
  assert_contains "$out" "no longer active on the second sample" "names the recovery"
  pass "refuses when the ci step is no longer active on the second sample"
}

test_refuses_second_sample_advanced_past_warning() {
  reset_fakes
  local d; d=$(new_case advanced-past)
  make_fakebin "$d"
  write_meta "$d" t1
  FM_FAKE_AXI_1=$(active_run_out running 1m35s "3s ago: log: warning: $KNOWN_WARNING")
  FM_FAKE_AXI_2=$(active_run_out running 1m40s "1s ago: log: CI checks running, waiting for results...")
  local out rc; out=$(run_recover "$d" t1); rc=$?
  expect_code 1 "$rc" "second sample past the warning must refuse"
  assert_contains "$out" "REFUSED:" "refusal is labeled"
  assert_contains "$out" "log advanced past the known warning" "names the advance"
  pass "refuses when the second sample's log advanced past the known warning"
}

test_refuses_too_brief_active_for() {
  reset_fakes
  local d; d=$(new_case too-brief)
  make_fakebin "$d"
  write_meta "$d" t1
  FM_FAKE_AXI_1=$(active_run_out running 5s "3s ago: log: warning: $KNOWN_WARNING")
  FM_FAKE_AXI_2=$(active_run_out running 10s "1s ago: log: warning: $KNOWN_WARNING")
  local out rc; out=$(run_recover "$d" t1); rc=$?
  expect_code 1 "$rc" "too-brief active_for must refuse"
  assert_contains "$out" "REFUSED:" "refusal is labeled"
  assert_contains "$out" "too brief to rule out a transient hiccup" "names the brevity refusal"
  pass "refuses when the confirmed active_for is too brief to rule out a transient hiccup"
}

test_refuses_subsecond_active_for_not_misread_as_minutes() {
  reset_fakes
  local d; d=$(new_case subsecond-active-for)
  make_fakebin "$d"
  write_meta "$d" t1
  FM_FAKE_AXI_1=$(active_run_out running 1m35s "3s ago: log: warning: $KNOWN_WARNING")
  FM_FAKE_AXI_2=$(active_run_out running 500ms "1s ago: log: warning: $KNOWN_WARNING")
  local out rc; out=$(run_recover "$d" t1); rc=$?
  expect_code 1 "$rc" "sub-second active_for must refuse, not be misread as 500 minutes"
  assert_contains "$out" "REFUSED:" "refusal is labeled"
  assert_contains "$out" "too brief to rule out a transient hiccup" "names the brevity refusal"
  pass "refuses a sub-second Go duration active_for instead of misparsing its 'm' as minutes"
}

test_fractional_second_active_for_keeps_whole_seconds() {
  reset_fakes
  local d; d=$(new_case fractional-active-for)
  make_fakebin "$d"
  write_meta "$d" t1
  FM_FAKE_AXI_1=$(active_run_out running 1m30s "3s ago: log: warning: $KNOWN_WARNING")
  FM_FAKE_AXI_2=$(active_run_out running 1m35.243573921s "1s ago: log: warning: $KNOWN_WARNING")
  FM_FAKE_RUNS_LIST="  running    fm/other-crew aaaaaaa  2026-08-17 10:00"
  local out rc
  out=$(FM_NMCR_MIN_ACTIVE_SECS=90 run_recover "$d" t1); rc=$?
  expect_code 1 "$rc" "confirmed bug without --force must refuse for the missing flag, not for brevity"
  assert_not_contains "$out" "too brief" "fractional seconds must not be truncated away, undercounting active_for below the floor"
  assert_contains "$out" "GitHub reports PR" "GitHub verification ran, proving active_for cleared the 90s floor"
  assert_contains "$out" "but --force was not given" "names the missing --force"
  pass "keeps whole seconds from a fractional-second active_for instead of zeroing them"
}

test_ignores_sibling_table_decoy_ci_row() {
  reset_fakes
  local d; d=$(new_case sibling-decoy)
  make_fakebin "$d"
  write_meta "$d" t1
  # active_steps[1] has no "ci," row (its one step is "lint"); a sibling
  # completed_steps[1] table nested at the exact same indent level as
  # active_steps carries its own "ci,running,..." row shaped exactly like the
  # confirmed-stuck bug. nm_active_ci_row() must stop scanning at the sibling
  # table's header (same indent as active_steps' own header), never fall
  # through into it and return this lookalike row.
  FM_FAKE_AXI_1=$(cat <<EOF
run:
  id: "01RUN"
  branch: fm/test-task
  status: running
  head: "abc1234"
  pr: "https://github.com/o/r/pull/7"
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    lint,running,1m35s,"3s ago: log: nothing interesting","",starting
  completed_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,1m40s,"1s ago: log: warning: $KNOWN_WARNING","",done
EOF
)
  local out rc; out=$(run_recover "$d" t1); rc=$?
  expect_code 1 "$rc" "a decoy ci row in a sibling table must not be treated as an active ci step"
  assert_contains "$out" "REFUSED:" "refusal is labeled"
  assert_contains "$out" "no active 'ci' step" "names the missing active step, not the decoy row"
  pass "never matches a lookalike ci row from a sibling table nested at active_steps' own indent level"
}

# --- (b) confirmed but no --force -------------------------------------------

test_refuses_without_force_when_confirmed() {
  reset_fakes
  local d; d=$(new_case no-force)
  make_fakebin "$d"
  write_meta "$d" t1
  arm_confirmed_stuck
  FM_FAKE_RUNS_LIST="  running    fm/other-crew aaaaaaa  2026-08-17 10:00"
  local out rc; out=$(run_recover "$d" t1); rc=$?
  expect_code 1 "$rc" "confirmed bug without --force must refuse"
  assert_contains "$out" "GitHub reports PR" "GitHub verification ran and passed"
  assert_contains "$out" "fm/other-crew" "other active runs were surfaced before refusing"
  assert_contains "$out" "REFUSED:" "refusal is labeled"
  assert_contains "$out" "but --force was not given" "names the missing --force"
  assert_not_contains "$out" "RECOVERED" "must not report success without --force"
  pass "refuses to restart without --force even when fully confirmed"
}

test_runs_listing_failure_is_not_reported_as_empty() {
  reset_fakes
  local d; d=$(new_case runs-listing-fails)
  make_fakebin "$d"
  write_meta "$d" t1
  arm_confirmed_stuck
  FM_FAKE_RUNS_RC=1
  FM_FAKE_RUNS_LIST=""
  local out rc; out=$(run_recover "$d" t1); rc=$?
  expect_code 1 "$rc" "confirmed bug without --force must still refuse"
  assert_contains "$out" "could not query other active runs" "a failed runs listing is surfaced as a warning"
  assert_not_contains "$out" "(no runs reported)" "a failed listing must not be reported as a genuinely empty one"
  pass "reports a failed/timed-out runs listing distinctly from a genuinely empty one"
}

# --- (c) GitHub disagrees ----------------------------------------------------

test_refuses_when_github_checks_nonzero() {
  reset_fakes
  local d; d=$(new_case gh-nonzero)
  make_fakebin "$d"
  write_meta "$d" t1
  arm_confirmed_stuck
  FM_FAKE_GH_RC=1
  FM_FAKE_GH_OUT="build  pending  -  https://example.invalid/run/1"
  local out rc; out=$(run_recover "$d" t1 --force); rc=$?
  expect_code 1 "$rc" "gh reporting pending/nonzero must refuse"
  assert_contains "$out" "REFUSED:" "refusal is labeled"
  assert_contains "$out" "does not (yet) show this PR green" "names GitHub's disagreement"
  assert_not_contains "$out" "restarting the no-mistakes daemon" "must never reach the restart step"
  pass "refuses when GitHub itself does not already show the check green"
}

test_refuses_when_github_reports_failing_check() {
  reset_fakes
  local d; d=$(new_case gh-failing)
  make_fakebin "$d"
  write_meta "$d" t1
  arm_confirmed_stuck
  FM_FAKE_GH_RC=0
  FM_FAKE_GH_OUT="build  fail  26s  https://example.invalid/run/1"
  local out rc; out=$(run_recover "$d" t1 --force); rc=$?
  expect_code 1 "$rc" "a reported failing check must refuse"
  assert_contains "$out" "REFUSED:" "refusal is labeled"
  assert_contains "$out" "reports a failing check" "names the failing check"
  assert_not_contains "$out" "restarting the no-mistakes daemon" "must never reach the restart step"
  pass "refuses when GitHub reports a failing check even though gh exited 0"
}

# --- (d) confirmed + --force succeeds ---------------------------------------

test_force_restart_succeeds() {
  reset_fakes
  local d; d=$(new_case force-succeeds)
  make_fakebin "$d"
  write_meta "$d" t1
  arm_confirmed_stuck
  FM_FAKE_RESTART_OUT="restarting; affected: fm/other-crew, fm/test-task"
  FM_FAKE_DOCTOR_OUT="  - daemon          running"
  local out rc; out=$(run_recover "$d" t1 --force); rc=$?
  expect_code 0 "$rc" "a fully confirmed --force run must succeed"
  assert_contains "$out" "restarting; affected: fm/other-crew, fm/test-task" "daemon restart output is shown"
  assert_contains "$out" "confirmed: no-mistakes daemon is healthy again" "doctor health is confirmed"
  assert_contains "$out" "fm-send.sh" "the next-step notify command is printed"
  assert_contains "$out" "t1" "the printed command names the task"
  assert_contains "$out" "--resolve-key default" "the printed command uses the default resolve key"
  assert_contains "$out" "RECOVERED:" "final outcome is reported"
  pass "a fully confirmed --force run restarts the daemon and reports recovery"
}

test_force_restart_custom_resolve_key() {
  reset_fakes
  local d; d=$(new_case force-custom-key)
  make_fakebin "$d"
  write_meta "$d" t1
  arm_confirmed_stuck
  local out rc; out=$(run_recover "$d" t1 --force --resolve-key blocker-1); rc=$?
  expect_code 0 "$rc" "a custom --resolve-key must still succeed"
  assert_contains "$out" "--resolve-key blocker-1" "the printed command uses the custom resolve key"
  pass "a custom --resolve-key is threaded into the printed notify command"
}

test_force_restart_daemon_failure() {
  reset_fakes
  local d; d=$(new_case force-daemon-fails)
  make_fakebin "$d"
  write_meta "$d" t1
  arm_confirmed_stuck
  FM_FAKE_RESTART_RC=1
  FM_FAKE_RESTART_OUT="could not reach daemon socket"
  local out rc; out=$(run_recover "$d" t1 --force); rc=$?
  expect_code 1 "$rc" "a failed daemon restart must not report success"
  assert_contains "$out" "could not reach daemon socket" "restart failure output is shown"
  assert_contains "$out" "error: no-mistakes daemon restart --force exited" "the restart failure is reported"
  assert_not_contains "$out" "RECOVERED" "must not report recovery on a failed restart"
  pass "reports a failed daemon restart instead of claiming recovery"
}

test_force_restart_doctor_unhealthy() {
  reset_fakes
  local d; d=$(new_case force-doctor-unhealthy)
  make_fakebin "$d"
  write_meta "$d" t1
  arm_confirmed_stuck
  FM_FAKE_DOCTOR_OUT="  x daemon          not running"
  local out rc; out=$(run_recover "$d" t1 --force); rc=$?
  expect_code 1 "$rc" "an unhealthy post-restart doctor must not report success"
  assert_contains "$out" "does not report the daemon healthy" "the doctor failure is reported"
  assert_not_contains "$out" "RECOVERED" "must not report recovery when doctor is unhealthy"
  pass "reports when doctor does not confirm daemon health after a restart"
}

# --- (d, cont.) --notify-worker actually runs fm-send.sh -------------------

test_notify_worker_succeeds() {
  reset_fakes
  local d; d=$(new_case notify-worker-succeeds)
  make_fakebin "$d"
  make_scriptdir_with_fake_send "$d"
  write_meta "$d" t1
  arm_confirmed_stuck
  FM_FAKE_SEND_RC=0
  FM_FAKE_SEND_OUT="steer submitted"
  local out rc; out=$(run_recover_with_fake_send "$d" t1 --force --notify-worker); rc=$?
  expect_code 0 "$rc" "a successful fm-send.sh must not fail the run"
  assert_contains "$out" "notifying task t1" "notify attempt is announced"
  assert_contains "$out" "steer submitted" "fm-send.sh output is shown"
  assert_contains "$out" "notified: task t1" "success is reported"
  assert_contains "$out" "RECOVERED:" "overall recovery is still reported"
  [ -f "$d/send-call.args" ] || fail "fm-send.sh must actually be invoked"
  local call; call=$(cat "$d/send-call.args")
  assert_contains "$call" "t1" "fm-send.sh is called with the task id"
  assert_contains "$call" "--resolve-key" "fm-send.sh is called with --resolve-key"
  assert_contains "$call" "default" "fm-send.sh is called with the default resolve key"
  pass "--notify-worker invokes fm-send.sh and reports success on the happy path"
}

test_notify_worker_failure() {
  reset_fakes
  local d; d=$(new_case notify-worker-fails)
  make_fakebin "$d"
  make_scriptdir_with_fake_send "$d"
  write_meta "$d" t1
  arm_confirmed_stuck
  FM_FAKE_SEND_RC=1
  FM_FAKE_SEND_OUT="could not reach backend"
  local out rc; out=$(run_recover_with_fake_send "$d" t1 --force --notify-worker); rc=$?
  expect_code 1 "$rc" "a failed fm-send.sh must fail the run"
  assert_contains "$out" "could not reach backend" "fm-send.sh failure output is shown"
  assert_contains "$out" "error: fm-send.sh failed to notify task t1" "the failure is reported"
  assert_contains "$out" "run the command above manually" "the manual fallback is pointed to"
  assert_not_contains "$out" "RECOVERED" "must not report recovery when notify fails"
  [ -f "$d/send-call.args" ] || fail "fm-send.sh must actually be invoked"
  pass "--notify-worker reports failure and points to the manual fallback when fm-send.sh fails"
}

# --- (e) usage and environment errors ---------------------------------------

test_missing_meta() {
  local d; d=$(new_case missing-meta)
  make_fakebin "$d"
  local out rc; out=$(run_recover "$d" ghost); rc=$?
  expect_code 1 "$rc" "a missing task must error"
  assert_contains "$out" "no metadata for task ghost" "names the missing metadata"
  pass "errors when the task has no metadata"
}

test_non_ship_kind() {
  reset_fakes
  local d; d=$(new_case non-ship)
  make_fakebin "$d"
  write_meta "$d" t1 "https://github.com/o/r/pull/7" scout
  local out rc; out=$(run_recover "$d" t1); rc=$?
  expect_code 1 "$rc" "a non-ship task must error"
  assert_contains "$out" "not a ship task" "names the wrong kind"
  pass "errors when the task is not a ship task"
}

test_torn_down_worktree() {
  reset_fakes
  local d; d=$(new_case torn-down)
  make_fakebin "$d"
  write_meta "$d" t1
  rm -rf "$d/wt"
  local out rc; out=$(run_recover "$d" t1); rc=$?
  expect_code 1 "$rc" "a torn-down worktree must error"
  assert_contains "$out" "worktree for task t1 is missing" "names the missing worktree"
  pass "errors when the task's worktree is gone"
}

test_missing_pr() {
  reset_fakes
  local d; d=$(new_case missing-pr)
  make_fakebin "$d"
  write_meta "$d" t1 ""
  FM_FAKE_AXI_1=$(active_run_out running 1m35s "3s ago: log: warning: $KNOWN_WARNING" "")
  FM_FAKE_AXI_2=$(active_run_out running 1m40s "1s ago: log: warning: $KNOWN_WARNING" "")
  local out rc; out=$(run_recover "$d" t1); rc=$?
  expect_code 1 "$rc" "a task with no recorded PR must refuse"
  assert_contains "$out" "REFUSED:" "refusal is labeled"
  assert_contains "$out" "no PR URL recorded" "names the missing PR"
  pass "refuses when no PR URL is recorded anywhere"
}

test_non_github_provider() {
  reset_fakes
  local d; d=$(new_case non-github)
  make_fakebin "$d"
  write_meta "$d" t1 "https://gitlab.example.invalid/group/project/-/merge_requests/9"
  FM_FAKE_AXI_1=$(active_run_out running 1m35s "3s ago: log: warning: $KNOWN_WARNING")
  FM_FAKE_AXI_2=$(active_run_out running 1m40s "1s ago: log: warning: $KNOWN_WARNING")
  local out rc; out=$(run_recover "$d" t1); rc=$?
  expect_code 1 "$rc" "a non-GitHub PR provider must refuse"
  assert_contains "$out" "REFUSED:" "refusal is labeled"
  assert_contains "$out" "not github" "names the unsupported provider"
  pass "refuses for a non-GitHub PR provider (the bug is gh-specific)"
}

test_usage_error_no_id() {
  reset_fakes
  local d; d=$(new_case usage-no-id)
  make_fakebin "$d"
  local out rc; out=$(run_recover "$d" ""); rc=$?
  expect_code 2 "$rc" "a missing task id is a usage error"
  pass "usage error when no task id is given"
}

test_help() {
  reset_fakes
  local d; d=$(new_case help)
  make_fakebin "$d"
  local out rc; out=$(run_recover "$d" --help); rc=$?
  expect_code 0 "$rc" "--help must succeed"
  assert_contains "$out" "Usage:" "help includes usage"
  pass "--help prints usage and exits 0"
}

test_unrecognized_flag() {
  reset_fakes
  local d; d=$(new_case bad-flag)
  make_fakebin "$d"
  write_meta "$d" t1
  local out rc; out=$(run_recover "$d" t1 --nonsense); rc=$?
  expect_code 2 "$rc" "an unrecognized flag is a usage error"
  assert_contains "$out" "unrecognized argument" "names the bad flag"
  pass "usage error on an unrecognized flag"
}

test_resolve_key_missing_value() {
  reset_fakes
  local d; d=$(new_case resolve-key-missing-value)
  make_fakebin "$d"
  write_meta "$d" t1
  local out rc; out=$(run_recover "$d" t1 --resolve-key); rc=$?
  expect_code 2 "$rc" "a valueless --resolve-key is a usage error"
  pass "usage error when --resolve-key has no value"
}

test_refuses_no_active_step
test_refuses_wrong_step_status
test_refuses_log_text_mismatch
test_refuses_second_sample_recovered_no_row
test_refuses_second_sample_advanced_past_warning
test_refuses_too_brief_active_for
test_refuses_subsecond_active_for_not_misread_as_minutes
test_fractional_second_active_for_keeps_whole_seconds
test_ignores_sibling_table_decoy_ci_row
test_refuses_without_force_when_confirmed
test_runs_listing_failure_is_not_reported_as_empty
test_refuses_when_github_checks_nonzero
test_refuses_when_github_reports_failing_check
test_force_restart_succeeds
test_force_restart_custom_resolve_key
test_force_restart_daemon_failure
test_force_restart_doctor_unhealthy
test_notify_worker_succeeds
test_notify_worker_failure
test_missing_meta
test_non_ship_kind
test_torn_down_worktree
test_missing_pr
test_non_github_provider
test_usage_error_no_id
test_help
test_unrecognized_flag
test_resolve_key_missing_value

echo "all fm-no-mistakes-ci-recover tests passed"
