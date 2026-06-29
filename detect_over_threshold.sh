#!/usr/bin/env bash
# =============================================================================
# detect_over_threshold.sh  —  runs on a schedule (DETECTOR_INTERVAL_SECONDS in
#                              config.env; default hourly). Detects over-threshold
#                              metrics and blocks them.
# =============================================================================
# 1. Pulls per-metric usage for the CURRENT UTC day (UsageService.GetMetricUsages),
#    paging through every metric.
# 2. Finds metric names whose usage (USAGE_FIELD) exceeds THRESHOLD_UNITS.
# 3. If BLOCK_ENABLED=true: snapshots current Optimizer rules (List), Blocks only
#    the over-threshold metrics not already blocked, in chunks. Then re-Lists and
#    records ONLY metrics that (a) were absent before, (b) are present after, and
#    (c) have a concrete rule ID — marking those owned:true with their ID.
#    Anything that can't be confirmed is NOT recorded and is retried next run.
# 4. Writes the current over-threshold list and appends a summary log line.
#
# State model (date buckets) — the detector ONLY ever ADDS to today's bucket.
# It never deletes any bucket. Only unblock_midnight.sh removes a bucket, and
# only after it has successfully unblocked it. This prevents losing yesterday's
# block list if the detector happens to run at/just after 00:00 UTC.
#
#   {
#     "blocked_by_date": {
#       "2025-09-11": [ {"name":"m1","rule_id":"3","owned":true}, ... ]
#     }
#   }
#
# Every recorded entry is guaranteed to have a non-empty rule_id (see step 3),
# so the midnight job can unblock purely by ID and never has to guess by name.
#
# Usage resets to zero on its own at 00:00 UTC, so each new day starts clean.
# =============================================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_common.sh"

# Read-only connectivity/auth check for both APIs; makes no changes.
if [[ "${1:-}" == "--healthcheck" ]]; then healthcheck; exit $?; fi

check_prereqs
acquire_lock   # shared with the midnight job; released on exit

TODAY="$(date -u +%Y-%m-%d)"
DATE_JSON="$(utc_date_json)"

# -----------------------------------------------------------------------------
# Step 1+2: page through all metrics for today; collect those over threshold.
# -----------------------------------------------------------------------------
log "INFO" "Detecting metrics over ${THRESHOLD_UNITS} (${USAGE_FIELD}) for ${TODAY} UTC"

# Field paths use grpcurl's camelCase JSON (unitUsage, bytesVolume, sampleCount).
# USAGE_FIELD stays snake_case as a user-facing config name; we map it here.
case "$USAGE_FIELD" in
  unit_usage)   VALUE_EXPR='(.usage.unitUsage // 0)' ;;
  bytes_volume) VALUE_EXPR='((.usage.bytesVolume // "0")|tonumber)' ;;
  cardinality)  VALUE_EXPR='((.usage.cardinality // "0")|tonumber)' ;;
  sample_count) VALUE_EXPR='((.sampleCount // "0")|tonumber)' ;;
  *) die "Unknown USAGE_FIELD '$USAGE_FIELD' (use unit_usage|bytes_volume|cardinality|sample_count)" ;;
esac

offset=0
over_threshold_json='[]'
while : ; do
  # Build the request. order_by/ordering are added ONLY if configured, because
  # the OrderBy enum value names vary by tenant/proto version and the sort doesn't
  # affect which metrics are over threshold (we filter all of them ourselves).
  payload="$(jq -c -n \
      --argjson sd "$DATE_JSON" --argjson ed "$DATE_JSON" \
      --argjson off "$offset" --argjson len "$PAGE_SIZE" \
      --arg ob "${USAGE_ORDER_BY:-}" --arg ord "${USAGE_ORDERING:-}" \
      '{common: ({start_date:$sd, end_date:$ed, start_offset:$off, length:$len}
                 + (if $ob  != "" then {order_by:$ob}   else {} end)
                 + (if $ord != "" then {ordering:$ord}  else {} end))}')"
  resp="$(grpc_call "$USAGE_ENDPOINT" "$USAGE_METHOD" "$payload")"

  page="$(printf '%s' "$resp" | jq -c '[.dailyUsages[]?.metricUsages[]?]')"
  count="$(printf '%s' "$page" | jq 'length')"
  [[ "$count" -eq 0 ]] && break

  page_over="$(printf '%s' "$page" | jq -c --argjson t "$THRESHOLD_UNITS" \
      "[.[] | {name: .name, value: ${VALUE_EXPR}} | select(.value > \$t)]")"
  over_threshold_json="$(jq -c -n --argjson a "$over_threshold_json" --argjson b "$page_over" '$a + $b')"

  offset=$(( offset + PAGE_SIZE ))
  [[ "$count" -lt "$PAGE_SIZE" ]] && break
done

over_threshold_json="$(printf '%s' "$over_threshold_json" | jq -c 'unique_by(.name) | sort_by(-.value)')"
over_names="$(printf '%s' "$over_threshold_json" | jq -r '.[].name')"
over_count="$(printf '%s' "$over_threshold_json" | jq 'length')"
log "INFO" "Found ${over_count} metric(s) over threshold."

# Always write the latest over-threshold list (report-only artifact).
jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg day "$TODAY" \
   --argjson threshold "$THRESHOLD_UNITS" --arg field "$USAGE_FIELD" \
   --argjson items "$over_threshold_json" \
   '{checked_at:$ts, utc_day:$day, usage_field:$field, threshold:$threshold, count:($items|length), metrics:$items}' \
   | write_atomic "$OVER_THRESHOLD_FILE"

# -----------------------------------------------------------------------------
# Load state (date buckets). NEVER delete buckets here.
# -----------------------------------------------------------------------------
if [[ -f "$STATE_FILE" ]]; then
  state="$(cat "$STATE_FILE")"
  state="$(printf '%s' "$state" | jq -c 'if type=="object" and has("blocked_by_date") then . else {blocked_by_date:{}} end')"
else
  state='{"blocked_by_date":{}}'
fi
state="$(printf '%s' "$state" | jq -c --arg d "$TODAY" '.blocked_by_date[$d] //= []')"

# Names already recorded as blocked by US today (these always have a rule_id).
ours_today="$(printf '%s' "$state" | jq -r --arg d "$TODAY" '.blocked_by_date[$d][].name')"

# -----------------------------------------------------------------------------
# Step 3: block — only if enabled, and only metrics not already blocked anywhere.
# Record ownership ONLY for confirmed new rules (absent before -> present after,
# with a concrete rule ID).
# -----------------------------------------------------------------------------
# Counters surfaced in the summary log + notifications.
newly_blocked=0; already_blocked=0; unconfirmed=0; block_failures=0; deferred=0
if [[ "$BLOCK_ENABLED" != "true" ]]; then
  log "INFO" "BLOCK_ENABLED=false — report-only, not blocking anything."
elif [[ "$over_count" -eq 0 ]]; then
  log "INFO" "Nothing over threshold; nothing to block."
else
  # --- BEFORE snapshot: name -> ruleId for everything currently blocked. ------
  before_list="$(optimizer_list)"
  # Set of names already blocked (by us or manually) BEFORE we do anything.
  before_names="$(printf '%s' "$before_list" | list_name_to_id_tsv | cut -f1 | sort -u | sed '/^$/d')"

  # Candidates = over-threshold names, minus anything already blocked anywhere,
  # minus anything we already recorded today.
  to_block="$(comm -23 \
      <(printf '%s\n' "$over_names"   | sort -u | sed '/^$/d') \
      <(printf '%s\n' "$before_names" | sort -u | sed '/^$/d') )"
  to_block="$(comm -23 \
      <(printf '%s\n' "$to_block"    | sort -u | sed '/^$/d') \
      <(printf '%s\n' "$ours_today"  | sort -u | sed '/^$/d') )"

  skipped_external="$(comm -12 \
      <(printf '%s\n' "$over_names"   | sort -u | sed '/^$/d') \
      <(printf '%s\n' "$before_names" | sort -u | sed '/^$/d') )"
  already_blocked="$(printf '%s\n' "$skipped_external" | sed '/^$/d' | grep -c . || true)"
  if [[ "$already_blocked" -gt 0 ]]; then
    log "INFO" "Skipping ${already_blocked} metric(s) already blocked (won't touch them)."
  fi

  # --- SAFETY GUARD 1: allowlist ----------------------------------------------
  # If BLOCK_ALLOWLIST is set, intersect candidates with it so ONLY named metrics
  # can ever be blocked. Great for a first live test against one throwaway metric.
  if [[ -n "${BLOCK_ALLOWLIST// }" ]]; then
    allow_norm="$(printf '%s' "$BLOCK_ALLOWLIST" | tr ', ' '\n\n' | sed '/^$/d' | sort -u)"
    n_before_allow="$(printf '%s\n' "$to_block" | sed '/^$/d' | grep -c . || true)"
    to_block="$(comm -12 \
        <(printf '%s\n' "$to_block"   | sort -u | sed '/^$/d') \
        <(printf '%s\n' "$allow_norm" | sort -u | sed '/^$/d') )"
    n_after_allow="$(printf '%s\n' "$to_block" | sed '/^$/d' | grep -c . || true)"
    log "INFO" "Allowlist active: ${n_after_allow}/${n_before_allow} candidate(s) are on the allowlist; the rest are ignored."
  fi

  # --- SAFETY GUARD 2: per-run cap --------------------------------------------
  # Block at most MAX_BLOCKS_PER_RUN new metrics this run (0 = unlimited).
  # Anything over the cap is DEFERRED to a later run (still reported in logs).
  if [[ "${MAX_BLOCKS_PER_RUN:-0}" -gt 0 ]]; then
    n_candidates="$(printf '%s\n' "$to_block" | sed '/^$/d' | grep -c . || true)"
    if [[ "$n_candidates" -gt "$MAX_BLOCKS_PER_RUN" ]]; then
      deferred=$(( n_candidates - MAX_BLOCKS_PER_RUN ))
      to_block="$(printf '%s\n' "$to_block" | sed '/^$/d' | head -n "$MAX_BLOCKS_PER_RUN")"
      log "WARN" "Per-run cap: blocking ${MAX_BLOCKS_PER_RUN} now, deferring ${deferred} to later run(s)."
    fi
  fi

  if [[ -z "${to_block// }" ]]; then
    log "INFO" "Nothing new to block."
  else
    n_to_block="$(printf '%s\n' "$to_block" | sed '/^$/d' | wc -l | tr -d ' ')"
    log "INFO" "Blocking ${n_to_block} new metric(s) in chunks of ${CHUNK_SIZE}."

    # Read candidate names into an array (bash 3.2-compatible; `mapfile` is bash 4+).
    _names=()
    while IFS= read -r _line; do [[ -n "$_line" ]] && _names+=("$_line"); done \
      < <(printf '%s\n' "$to_block" | sed '/^$/d')

    # Block in chunks, tolerating partial failures (e.g. a 409 race).
    flush_block() {
      local names_json="$1" n re payload out
      n="$(printf '%s' "$names_json" | jq 'length')"; [[ "$n" -eq 0 ]] && return 0
      re="$(printf '%s' "$names_json" | jq -c '[.[] | {byMetricName:{name:.}}]')"
      payload="$(jq -c -n --argjson re "$re" '{ruleExpressions:$re}')"
      if ! out="$(grpc_try "$OPTIMIZER_ENDPOINT" "$BLOCK_METHOD" "$payload")"; then
        log "WARN" "Block chunk returned error (continuing): $(printf '%s' "$out" | head -c 200)"
        block_failures=$(( block_failures + 1 ))
      fi
    }
    buf='[]'
    for nm in "${_names[@]}"; do
      buf="$(jq -c -n --argjson a "$buf" --arg n "$nm" '$a + [$n]')"
      if [[ "$(printf '%s' "$buf" | jq 'length')" -ge "$CHUNK_SIZE" ]]; then flush_block "$buf"; buf='[]'; fi
    done
    flush_block "$buf"

    # --- AFTER snapshot: confirm which candidates are now actually blocked. ---
    # (No associative arrays — bash 3.2 on macOS lacks them. We look names up
    #  with jq against the fresh List, and check 'before' membership with grep.)
    after_list="$(optimizer_list)"

    for nm in "${_names[@]}"; do
      [[ -z "$nm" ]] && continue
      # rule ID for this name in the AFTER list (empty if not present).
      rid="$(printf '%s' "$after_list" \
          | jq -r --arg n "$nm" '.rules[]? | select(.ruleExpression.byMetricName.name==$n) | .ruleId' \
          | head -n1)"
      # was this name already blocked BEFORE we ran?
      if printf '%s\n' "$before_names" | grep -qxF "$nm"; then
        was_before="yes"; else was_before="no"; fi
      # Record as OWNED only if: not present before, present (with ID) after.
      if [[ "$was_before" == "no" && -n "$rid" && "$rid" != "null" ]]; then
        state="$(printf '%s' "$state" | jq -c --arg d "$TODAY" --arg n "$nm" --arg id "$rid" \
            '.blocked_by_date[$d] += [{name:$n, rule_id:$id, owned:true}]
             | .blocked_by_date[$d] |= unique_by(.name)')"
        newly_blocked=$(( newly_blocked + 1 ))
      else
        # Either it was already present before (someone else owns it), or no ID
        # appeared (block not confirmed). Don't claim ownership; retry next run.
        unconfirmed=$(( unconfirmed + 1 ))
        log "WARN" "Did not confirm new ownership of '$nm' (no fresh rule ID); will retry next run."
      fi
    done
    log "INFO" "Newly blocked ${newly_blocked}; ${unconfirmed} unconfirmed; ${block_failures} chunk failure(s)."
  fi
fi

# Persist state atomically (only additions; no buckets removed here).
printf '%s\n' "$state" | jq -c '.' | write_atomic "$STATE_FILE"

# -----------------------------------------------------------------------------
# Step 4: summary log line (richer counters for debugging/dashboards).
# -----------------------------------------------------------------------------
blocked_today="$(printf '%s' "$state" | jq --arg d "$TODAY" '.blocked_by_date[$d] | length')"
summary="$(jq -c -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg day "$TODAY" \
   --argjson over "$over_count" --argjson blocked_today "$blocked_today" \
   --argjson newly_blocked "$newly_blocked" --argjson already_blocked "$already_blocked" \
   --argjson unconfirmed "$unconfirmed" --argjson block_failures "$block_failures" \
   --argjson deferred "$deferred" --arg block_enabled "$BLOCK_ENABLED" \
   '{ts:$ts, event:"detect", utc_day:$day, over_threshold:$over,
     newly_blocked:$newly_blocked, already_blocked:$already_blocked,
     unconfirmed_blocks:$unconfirmed, block_failures:$block_failures,
     deferred_by_cap:$deferred, blocked_by_us_today:$blocked_today, block_enabled:$block_enabled}')"
printf '%s\n' "$summary" >> "$LOG_FILE"

log "INFO" "Done. over=${over_count} newly_blocked=${newly_blocked} already_blocked=${already_blocked} unconfirmed=${unconfirmed} deferred=${deferred} blocked_by_us_today=${blocked_today}"

# --- Notify only on meaningful events (never on a quiet, no-change tick) ------
notify_reasons=()
[[ "$newly_blocked"   -gt 0 ]] && notify_reasons+=("blocked ${newly_blocked} new metric(s)")
[[ "$block_failures"  -gt 0 ]] && notify_reasons+=("${block_failures} block chunk failure(s)")
[[ "$unconfirmed"     -gt 0 ]] && notify_reasons+=("${unconfirmed} unconfirmed block(s)")
[[ "$deferred"        -gt 0 ]] && notify_reasons+=("${deferred} metric(s) deferred by per-run cap")
if [[ "$HIGH_WATERMARK" -gt 0 && "$over_count" -ge "$HIGH_WATERMARK" ]]; then
  notify_reasons+=("over-threshold count ${over_count} >= watermark ${HIGH_WATERMARK}")
fi
if [[ "${#notify_reasons[@]}" -gt 0 ]]; then
  reason_str="$(IFS='; '; echo "${notify_reasons[*]}")"
  notify "$(jq -c -n --argjson s "$summary" --arg r "$reason_str" \
            '$s + {alert:$r, source:"detect_over_threshold"}')"
  log "INFO" "Notified: ${reason_str}"
fi

if [[ "$over_count" -gt 0 ]]; then
  echo "Metrics over ${THRESHOLD_UNITS} (${USAGE_FIELD}) on ${TODAY} UTC:"
  printf '%s' "$over_threshold_json" | jq -r '.[] | "  \(.name)\t\(.value)"'
fi
