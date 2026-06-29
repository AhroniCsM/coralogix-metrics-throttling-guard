#!/usr/bin/env bash
# =============================================================================
# unblock_midnight.sh  —  wakes hourly; does its work only during the UTC hour
#                         set by UNBLOCK_UTC_HOUR in config.env (default 0 =
#                         00:00 UTC, just after Coralogix resets daily usage).
# =============================================================================
# Coralogix usage rolls to a fresh UTC day at 00:00 UTC. This script lifts the
# blocks THIS AUTOMATION created during previous day(s) so every metric starts
# the new day ingesting normally ("restart"). Pass --force (or --include-today)
# to bypass the hour gate for a manual run.
#
# It processes every date bucket STRICTLY BEFORE today (completed days), plus a
# "--include-today" override. For each bucket it:
#   1. collects the rule IDs we recorded (owned:true, each has a concrete ID),
#   2. unblocks them via Optimizer Allow, in chunks, tolerating partial failures,
#   3. removes that bucket from state — ONLY if every Allow chunk succeeded.
#
# Safety properties:
#   * Unblocks BY RULE ID ONLY. The detector guarantees every recorded entry has
#     a real rule_id, so we never resolve by name and never risk unblocking a
#     manually-created rule that merely shares a metric name.
#   * Only entries with owned:true are ever touched.
#   * A bucket with a failed Allow chunk is KEPT and retried next run.
#   * Pruning removes ONLY empty buckets (already fully unblocked). A non-empty
#     pending bucket is never pruned, regardless of age — we can't lose the
#     record of rules we still owe an unblock.
#
# Scheduling note: launchd runs this hourly; the UTC-hour gate (below) decides
# when it actually acts, so the timing lives entirely in UNBLOCK_UTC_HOUR. The
# shared flock makes any overlap with the detector safe regardless.
# =============================================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_common.sh"

# Read-only connectivity/auth check for both APIs; makes no changes.
if [[ "${1:-}" == "--healthcheck" ]]; then healthcheck; exit $?; fi

# Parse flags (order-independent).
INCLUDE_TODAY="false"; FORCE="false"
for a in "$@"; do
  case "$a" in
    --include-today) INCLUDE_TODAY="true"; FORCE="true" ;;  # manual: also bypass the hour gate
    --force)         FORCE="true" ;;
  esac
done

check_prereqs

# --- UTC-hour gate -----------------------------------------------------------
# launchd wakes this job hourly; it should only DO anything during the
# configured UTC hour. This keeps all scheduling logic in UTC (matching the
# backend) with zero local-time/DST math. Manual runs pass --force to skip it.
NOW_UTC_HOUR="$(date -u +%-H)"   # 0-23, no leading zero
if [[ "$FORCE" != "true" && "$NOW_UTC_HOUR" -ne "$UNBLOCK_UTC_HOUR" ]]; then
  log "INFO" "Unblock gate: current UTC hour ${NOW_UTC_HOUR} != UNBLOCK_UTC_HOUR ${UNBLOCK_UTC_HOUR}; nothing to do."
  exit 0
fi

acquire_lock   # shared with the detector

TODAY="$(date -u +%Y-%m-%d)"

if [[ ! -f "$STATE_FILE" ]]; then
  log "INFO" "No state file — nothing to unblock. Initialising empty state."
  printf '%s\n' '{"blocked_by_date":{}}' | write_atomic "$STATE_FILE"
  exit 0
fi

state="$(cat "$STATE_FILE")"
state="$(printf '%s' "$state" | jq -c 'if type=="object" and has("blocked_by_date") then . else {blocked_by_date:{}} end')"

# Which date buckets to process: everything < today (and optionally today).
if [[ "$INCLUDE_TODAY" == "true" ]]; then
  dates="$(printf '%s' "$state" | jq -r '.blocked_by_date | keys[]' | sort)"
else
  dates="$(printf '%s' "$state" | jq -r --arg t "$TODAY" '.blocked_by_date | keys[] | select(. < $t)' | sort)"
fi

total_unblocked=0
if [[ -z "${dates// }" ]]; then
  log "INFO" "No completed-day buckets to unblock."
else
  # Snapshot the set of rule IDs that currently EXIST in the Optimizer once.
  # Any recorded ID not in this set has already been removed (e.g. a prior
  # partial success, or a manual delete) and must NOT be re-sent to Allow —
  # re-sending already-deleted IDs is what would otherwise poison retries.
  # Snapshot existing rule IDs as a newline-delimited string (no associative
  # arrays — bash 3.2 on macOS lacks them; membership is tested with grep -qxF).
  list_resp="$(optimizer_list)"
  exists_ids="$(printf '%s' "$list_resp" | list_rule_ids | sed '/^$/d')"

  while IFS= read -r day; do
    [[ -z "$day" ]] && continue

    # Owned rule IDs recorded for this bucket (bash 3.2-compatible; mapfile is bash 4+).
    recorded=()
    while IFS= read -r _rid; do [[ -n "$_rid" ]] && recorded+=("$_rid"); done < <(printf '%s' "$state" | jq -r --arg d "$day" \
        '.blocked_by_date[$d][] | select(.owned==true and (.rule_id // "") != "") | .rule_id' | sort -u | sed '/^$/d')

    # Reconcile against reality: drop IDs that no longer exist (already gone).
    to_try=(); already_gone=0
    for rid in "${recorded[@]:-}"; do
      [[ -z "$rid" ]] && continue
      if printf '%s\n' "$exists_ids" | grep -qxF "$rid"; then to_try+=("$rid"); else already_gone=$(( already_gone + 1 )); fi
    done
    if [[ "$already_gone" -gt 0 ]]; then
      log "INFO" "Bucket ${day}: ${already_gone} recorded rule(s) already removed; clearing from state."
      # Remove already-gone IDs from this bucket immediately.
      gone_json="$(for rid in "${recorded[@]:-}"; do [[ -n "$rid" ]] && ! printf '%s\n' "$exists_ids" | grep -qxF "$rid" && printf '%s\n' "$rid"; done | jq -R . | jq -s -c '.')"
      state="$(printf '%s' "$state" | jq -c --arg d "$day" --argjson gone "$gone_json" \
          '.blocked_by_date[$d] |= map(select((.rule_id // "") as $r | ($gone | index($r)) | not))')"
    fi

    n_try="${#to_try[@]}"
    if [[ "$n_try" -eq 0 ]]; then
      remaining="$(printf '%s' "$state" | jq --arg d "$day" '.blocked_by_date[$d] | length')"
      if [[ "$remaining" -eq 0 ]]; then
        state="$(printf '%s' "$state" | jq -c --arg d "$day" 'del(.blocked_by_date[$d])')"
        log "INFO" "Bucket ${day}: nothing left to unblock; bucket removed."
      else
        log "WARN" "Bucket ${day}: ${remaining} entr(y/ies) without resolvable rule IDs; KEEPING for inspection."
      fi
      printf '%s\n' "$state" | jq -c '.' | write_atomic "$STATE_FILE"
      continue
    fi

    log "INFO" "Bucket ${day}: unblocking ${n_try} rule(s) in chunks of ${CHUNK_SIZE}."
    # Process chunk-by-chunk. On SUCCESS, remove those IDs from the bucket in
    # state immediately and persist — so a later chunk failure (or a crash)
    # never causes already-unblocked IDs to be retried. On FAILURE, leave those
    # IDs in the bucket for the next run.
    buf=()
    flush_ids() {
      [[ "${#buf[@]}" -eq 0 ]] && return 0
      local ids_json payload out
      ids_json="$(printf '%s\n' "${buf[@]}" | jq -R . | jq -s -c '.')"
      payload="$(jq -c -n --argjson ids "$ids_json" '{ruleIds:$ids}')"
      if out="$(grpc_try "$OPTIMIZER_ENDPOINT" "$ALLOW_METHOD" "$payload")"; then
        # Success: drop these IDs from the bucket now and persist.
        state="$(printf '%s' "$state" | jq -c --arg d "$day" --argjson done "$ids_json" \
            '.blocked_by_date[$d] |= map(select((.rule_id // "") as $r | ($done | index($r)) | not))')"
        printf '%s\n' "$state" | jq -c '.' | write_atomic "$STATE_FILE"
        total_unblocked=$(( total_unblocked + ${#buf[@]} ))
      else
        log "WARN" "Allow chunk failed (these IDs kept for retry): $(printf '%s' "$out" | head -c 200)"
      fi
      buf=()
    }
    for id in "${to_try[@]}"; do
      buf+=("$id")
      [[ "${#buf[@]}" -ge "$CHUNK_SIZE" ]] && flush_ids
    done
    flush_ids

    # Delete the bucket only if it is now empty (all chunks succeeded).
    remaining="$(printf '%s' "$state" | jq --arg d "$day" '.blocked_by_date[$d] | length')"
    if [[ "$remaining" -eq 0 ]]; then
      state="$(printf '%s' "$state" | jq -c --arg d "$day" 'del(.blocked_by_date[$d])')"
      log "INFO" "Bucket ${day}: fully unblocked; bucket removed."
    else
      log "WARN" "Bucket ${day}: ${remaining} rule(s) still pending after failures — KEEPING for retry."
    fi
    printf '%s\n' "$state" | jq -c '.' | write_atomic "$STATE_FILE"
  done <<< "$dates"

  log "INFO" "Total rules unblocked this run: ${total_unblocked}."
fi

# -----------------------------------------------------------------------------
# Pruning: remove ONLY empty buckets older than KEEP_DAYS. Never prune a bucket
# that still has entries (it's pending an unblock we owe). This guarantees we
# cannot silently lose the record of rules we still need to unblock, even if
# unblocking has been failing for longer than KEEP_DAYS.
# -----------------------------------------------------------------------------
cutoff="$(date -u -d "${KEEP_DAYS} days ago" +%Y-%m-%d 2>/dev/null || date -u -v-"${KEEP_DAYS}"d +%Y-%m-%d 2>/dev/null || echo "")"
if [[ -n "$cutoff" ]]; then
  state="$(printf '%s' "$state" | jq -c --arg c "$cutoff" \
      '.blocked_by_date |= with_entries(select((.value | length) > 0 or (.key >= $c)))')"
fi

printf '%s\n' "$state" | jq -c '.' | write_atomic "$STATE_FILE"

# How many rules are still pending (across all completed-day buckets we tried)?
pending="$(printf '%s' "$state" | jq -r --arg t "$TODAY" \
   '[.blocked_by_date | to_entries[] | select(.key < $t) | .value[]] | length')"

summary="$(jq -c -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg day "$TODAY" \
   --argjson unblocked "$total_unblocked" --argjson pending "$pending" \
   '{ts:$ts, event:"midnight_unblock", utc_day:$day, unblocked:$unblocked, pending:$pending}')"
printf '%s\n' "$summary" >> "$LOG_FILE"

# Notify only if something needs attention: rules left pending after retries.
if [[ "$pending" -gt 0 ]]; then
  notify "$(jq -c -n --argjson s "$summary" \
            '$s + {alert:("unblock left " + ($s.pending|tostring) + " rule(s) pending after retries"), source:"unblock_midnight"}')"
  log "WARN" "Unblock left ${pending} rule(s) pending; notified."
fi

log "INFO" "Done. unblocked=${total_unblocked} pending=${pending}"
