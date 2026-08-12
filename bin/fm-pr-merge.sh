#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to the provider's CLI as separate
# arguments: gh-axi for GitHub, tea for Gitea. GitLab merge request URLs are
# still refused here; bin/fm-pr-lib.sh parses them so the watcher can follow
# them, but merging one stays a deliberate manual step until merge parity
# extends that far.
#
# Merge method defaults to a squash when the caller passes none of GitHub's
# --squash/--merge/--rebase/--method or Gitea's --style after the optional --
# separator. Extra args must not override the repository or login, because
# both come only from the URL and its registered Gitea login.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra provider merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || { [ "$FM_PR_PROVIDER" != github ] && [ "$FM_PR_PROVIDER" != gitea ]; }; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
PROVIDER=$FM_PR_PROVIDER
URL=$FM_PR_URL
PR_HOST=$FM_PR_HOST
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*|--style|--style=*|-s|-s?*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-r|-r?*|-R|-R?*|--remote|--remote=*|--login|--login=*|-l|-l?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

merge_args=()
if ! caller_has_merge_method "$@"; then
  case "$PROVIDER" in
    github) merge_args=(--squash) ;;
    gitea) merge_args=(--style squash) ;;
  esac
fi

if [ "$PROVIDER" = github ]; then
  gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
else
  # tea addresses a Gitea instance by a stored login name rather than a bare
  # host, so the login registered for this exact host is looked up fresh
  # rather than assumed to equal the host string (the same lookup
  # bin/fm-pr-poll.sh uses).
  login=$(tea login list -o csv 2>/dev/null | awk -F, -v h="https://$PR_HOST" 'NR>1 && $2==h {print $1; exit}') || login=
  [ -n "$login" ] || {
    echo "error: no tea login is registered for $PR_HOST" >&2
    exit 1
  }
  tea pulls merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" --login "$login" "${merge_args[@]+"${merge_args[@]}"}" "$@"
fi
