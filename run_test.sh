#!/usr/bin/env bash
# =============================================================================
# run_test.sh — safe, staged test runner for the metrics-optimizer scripts.
# =============================================================================
# Encodes the recommended bring-up stages as named presets so you never have to
# hand-assemble BLOCK_ENABLED / MAX_BLOCKS_PER_RUN / BLOCK_ALLOWLIST env vars
# (a typo there is the one thing that could widen the blast radius).
#
# Each subcommand prints the exact settings it will use, then runs. The only
# subcommands that can change anything in Coralogix are `live-one` and
# `unblock-now`; both make it explicit and `live-one` requires a metric name.
#
# Usage:
#   ./run_test.sh healthcheck            # read-only: verify endpoints + auth
#   ./run_test.sh dryrun                 # read-only: real detection, no blocking
#   ./run_test.sh noop                   # enforcement path, threshold so high nothing matches
#   ./run_test.sh live-one <metric>      # BLOCK exactly one allowlisted metric (asks to confirm)
#   ./run_test.sh unblock-now            # unblock everything we blocked, incl. today (asks to confirm)
#   ./run_test.sh status                 # show over-threshold list, state, last log lines
#
# This wrapper NEVER edits config.env. It only sets env vars for the child run,
# so your config.env defaults (BLOCK_ENABLED=false, etc.) are left untouched.
# =============================================================================

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT="$DIR/detect_over_threshold.sh"
UNBLOCK="$DIR/unblock_midnight.sh"

# Pull DATA_DIR (and friends) the same way the scripts do, for `status`.
# shellcheck source=/dev/null
source "$DIR/config.env" 2>/dev/null || true
: "${DATA_DIR:=$DIR/data}"
: "${OVER_THRESHOLD_FILE:=$DATA_DIR/over_threshold_latest.json}"
: "${STATE_FILE:=$DATA_DIR/state.json}"
: "${LOG_FILE:=$DATA_DIR/optimizer.log}"

c_red()   { printf '\033[31m%s\033[0m\n' "$1"; }
c_green() { printf '\033[32m%s\033[0m\n' "$1"; }
c_bold()  { printf '\033[1m%s\033[0m\n'  "$1"; }

confirm() {
  # confirm <prompt> — require an explicit y/yes (unless ASSUME_YES=1, for tests).
  [[ "${ASSUME_YES:-0}" == "1" ]] && return 0
  local ans
  read -r -p "$1 [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" || "$ans" == "yes" ]]
}

usage() { sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

cmd="${1:-}"; shift || true

case "$cmd" in
  healthcheck)
    c_bold "Stage: HEALTHCHECK (read-only — calls Usage GetMetricUsages + Optimizer List)"
    exec "$DETECT" --healthcheck
    ;;

  dryrun)
    c_bold "Stage: DRY-RUN (read-only — real detection, BLOCK_ENABLED=false)"
    echo "Settings: BLOCK_ENABLED=false"
    BLOCK_ENABLED=false "$DETECT"
    echo; c_green "Done. Inspect: ./run_test.sh status"
    ;;

  noop)
    c_bold "Stage: NO-OP ENFORCEMENT (enforcement path on, threshold impossibly high)"
    echo "Settings: BLOCK_ENABLED=true THRESHOLD_UNITS=999999999 MAX_BLOCKS_PER_RUN=1"
    echo "Expected: over_threshold=0, newly_blocked=0 (proves enabled mode is sane; blocks nothing)."
    BLOCK_ENABLED=true THRESHOLD_UNITS=999999999 MAX_BLOCKS_PER_RUN=1 "$DETECT"
    ;;

  live-one)
    metric="${1:-}"
    if [[ -z "$metric" ]]; then
      c_red "live-one needs a metric name: ./run_test.sh live-one <metric_name>"
      echo "Pick one from: $OVER_THRESHOLD_FILE (run './run_test.sh dryrun' first)."
      exit 2
    fi
    c_bold "Stage: CONTROLLED LIVE BLOCK of a single metric"
    echo "Settings: BLOCK_ENABLED=true  MAX_BLOCKS_PER_RUN=1  BLOCK_ALLOWLIST=\"$metric\""
    c_red "This WILL block '$metric' in Coralogix (stops its ingestion until you unblock)."
    if ! confirm "Proceed?"; then echo "Aborted."; exit 1; fi
    BLOCK_ENABLED=true MAX_BLOCKS_PER_RUN=1 BLOCK_ALLOWLIST="$metric" "$DETECT"
    echo; c_green "Now verify in the Coralogix UI that ONLY '$metric' is blocked, then:"
    echo "  ./run_test.sh unblock-now"
    ;;

  unblock-now)
    c_bold "Stage: UNBLOCK NOW (lifts everything this automation blocked, incl. today)"
    c_red "This calls Allow for all rules we own across all date buckets."
    if ! confirm "Proceed?"; then echo "Aborted."; exit 1; fi
    "$UNBLOCK" --include-today
    echo; c_green "Done. Confirm 'pending: 0' in the log and that the metric is unblocked in the UI."
    ;;

  status)
    c_bold "=== over-threshold (latest detector run) ==="
    if [[ -f "$OVER_THRESHOLD_FILE" ]]; then
      jq '{checked_at, utc_day, threshold, usage_field, count}' "$OVER_THRESHOLD_FILE"
      echo "metric names:"; jq -r '.metrics[]?.name | "  " + .' "$OVER_THRESHOLD_FILE"
    else echo "(no over_threshold_latest.json yet — run './run_test.sh dryrun')"; fi
    echo; c_bold "=== blocked state (by this automation) ==="
    if [[ -f "$STATE_FILE" ]]; then jq '.blocked_by_date' "$STATE_FILE"; else echo "(no state file yet)"; fi
    echo; c_bold "=== last 5 log lines ==="
    [[ -f "$LOG_FILE" ]] && tail -n 5 "$LOG_FILE" | jq . 2>/dev/null || echo "(no log yet)"
    ;;

  ""|-h|--help|help) usage 0 ;;
  *) c_red "Unknown command: $cmd"; echo; usage 2 ;;
esac
