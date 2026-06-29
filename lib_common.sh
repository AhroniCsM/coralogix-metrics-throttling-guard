#!/usr/bin/env bash
# =============================================================================
# lib_common.sh — shared helpers for the Coralogix metrics-optimizer scripts.
# Sourced by detect_over_threshold.sh and unblock_midnight.sh.
# =============================================================================
# Requires: bash 4+, grpcurl, jq, flock (util-linux).

set -euo pipefail

# --- locate & load config -----------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/config.env"

# Fallback defaults so the scripts stay robust under `set -u` even if a user
# comments out an optional knob in config.env. (Required values like CX_API_KEY
# are validated separately in check_prereqs.)
: "${THRESHOLD_UNITS:=5}"
: "${USAGE_FIELD:=unit_usage}"
: "${PAGE_SIZE:=200}"
: "${BLOCK_ENABLED:=false}"
: "${CHUNK_SIZE:=50}"
: "${MAX_BLOCKS_PER_RUN:=0}"
: "${BLOCK_ALLOWLIST:=}"
: "${KEEP_DAYS:=7}"
# The UTC hour (0-23) at which the unblock job actually does its work. The
# reset job wakes hourly (launchd StartInterval) and exits immediately unless
# the current UTC hour matches this — so the schedule is driven entirely by
# this config value, in UTC, with no local-time/DST math anywhere.
#   0 = unblock at 00:00 UTC (the production setting: right after usage resets).
#   9 = unblock during the 09:00 UTC hour (handy for watching it in daytime).
: "${UNBLOCK_UTC_HOUR:=0}"
# How often the DETECTOR runs, in seconds. The installer reads this value and
# writes it into the detector launchd plist (StartInterval). 3600 = hourly
# (production). 900 = every 15 min (handy for testing / faster reaction).
: "${DETECTOR_INTERVAL_SECONDS:=3600}"
# Sort controls for the Usage query. OPTIONAL and omitted by default, because
# the enum value names (e.g. BYTES_VOLUME) differ between tenant/proto versions
# and the detector filters all metrics itself — sort order doesn't affect which
# metrics are over threshold. Set USAGE_ORDER_BY only if you know your tenant's
# valid enum value (check: grpcurl <endpoint> describe com.coralogix.metrics.common.OrderBy).
: "${USAGE_ORDER_BY:=}"
: "${USAGE_ORDERING:=}"
: "${NOTIFY_CMD:=}"
: "${HIGH_WATERMARK:=0}"
: "${OPTIMIZER_ENDPOINT:=${USAGE_ENDPOINT:-}}"

# Fully-qualified RPC method names (shared by both scripts).
USAGE_METHOD="com.coralogix.metrics.metric_usages.UsageService.GetMetricUsages"
BLOCK_METHOD="com.coralogix.metrics.metrics_blocking_rules.MetricsBlockingRulesService.Block"
LIST_METHOD="com.coralogix.metrics.metrics_blocking_rules.MetricsBlockingRulesService.List"
ALLOW_METHOD="com.coralogix.metrics.metrics_blocking_rules.MetricsBlockingRulesService.Allow"

# --- logging ------------------------------------------------------------------
log() { printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${1:-INFO}" "${2:-}" >&2; }
die() { log "ERROR" "$1"; exit 1; }

# --- notifications ------------------------------------------------------------
# notify <message>  — runs $NOTIFY_CMD if set, passing the message on stdin and
# as $1. No-op when NOTIFY_CMD is empty. Failures are logged, never fatal, so a
# broken webhook can't take down the run.
notify() {
  local msg="$1"
  [[ -z "${NOTIFY_CMD:-}" ]] && return 0
  if ! printf '%s' "$msg" | bash -c "$NOTIFY_CMD" "$NOTIFY_CMD" "$msg" >/dev/null 2>&1; then
    log "WARN" "NOTIFY_CMD failed (continuing)."
  fi
}

# --- preflight checks ---------------------------------------------------------
check_prereqs() {
  command -v grpcurl >/dev/null 2>&1 || die "grpcurl not found on PATH. Install: https://github.com/fullstorydev/grpcurl"
  command -v jq      >/dev/null 2>&1 || die "jq not found on PATH. Install: https://stedolan.github.io/jq/"
  command -v flock   >/dev/null 2>&1 || die "flock not found on PATH (util-linux). On macOS: 'brew install flock'."
  if [[ -z "${CX_API_KEY:-}" || "$CX_API_KEY" == "PASTE_YOUR_API_KEY_HERE" ]]; then
    die "CX_API_KEY is not set. Edit config.env or export CX_API_KEY."
  fi
  mkdir -p "$DATA_DIR"
}

# --- cross-process lock -------------------------------------------------------
# Acquire an exclusive flock for the lifetime of the script. Both the detector
# and the midnight job take the SAME lock, so they can never race on the state
# file (critical right around 00:00 UTC). Waits up to 120s, then bails.
acquire_lock() {
  exec 9>"$LOCK_FILE" || die "Cannot open lock file $LOCK_FILE"
  if ! flock -w 120 9; then
    die "Could not acquire lock $LOCK_FILE within 120s (another run in progress?)."
  fi
}

# --- atomic state write -------------------------------------------------------
# write_atomic <target_path>  (content on stdin)
# Writes to a temp file in the same dir, then mv (atomic on the same fs) so a
# crash or overlap never leaves a half-written / corrupt state file.
write_atomic() {
  local target="$1" tmp
  tmp="$(mktemp "${target}.XXXXXX")"
  cat > "$tmp"
  mv -f "$tmp" "$target"
}

# --- auth header --------------------------------------------------------------
auth_header() { printf '%s' "$CX_AUTH_HEADER"; }

# --- today's UTC date as the Usage API's {year,month,day} object ---------------
utc_date_json() {
  local y m d
  y="$(date -u +%Y)"; m="$(date -u +%-m)"; d="$(date -u +%-d)"
  printf '{"year":%s,"month":%s,"day":%s}' "$y" "$m" "$d"
}

# --- generic grpcurl wrapper with one retry -----------------------------------
# grpc_call <endpoint> <method> <json-payload>  -> echoes JSON response.
# NOTE: grpcurl emits proto fields in lowerCamelCase (dailyUsages, metricUsages,
# unitUsage, ruleId, ruleExpression, byMetricName). All jq filters in these
# scripts use those camelCase names to match the API exactly.
# Dies on repeated failure. Use grpc_try for calls where you want to inspect
# the error instead of dying (e.g. tolerate a failed Block/Allow chunk).
grpc_call() {
  local endpoint="$1" method="$2" payload="$3" out rc
  for attempt in 1 2; do
    if out="$(grpcurl -H "$(auth_header)" -d "$payload" "$endpoint" "$method" 2>&1)"; then
      printf '%s' "$out"; return 0
    fi
    rc=$?
    log "WARN" "grpc $method failed (attempt $attempt/2, rc=$rc): $(printf '%s' "$out" | head -c 300)"
    sleep $(( attempt * 3 ))
  done
  die "grpc call to $method failed after retries."
}

# grpc_try <endpoint> <method> <payload>
# Echoes response (or error text) on stdout; returns grpcurl's exit code without
# dying, so the caller can decide how to handle failures (e.g. partial batches).
grpc_try() {
  local endpoint="$1" method="$2" payload="$3"
  grpcurl -H "$(auth_header)" -d "$payload" "$endpoint" "$method" 2>&1
}

# --- Optimizer: List all current blocking rules -------------------------------
# grpcurl returns camelCase, so the rule shape is
# {"rules":[{ruleId, ruleExpression:{byMetricName:{name}}}]}.
optimizer_list() { grpc_call "$OPTIMIZER_ENDPOINT" "$LIST_METHOD" '{}'; }

# Given a List response on stdin, emit TSV of  name<TAB>ruleId  for byMetricName rules.
list_name_to_id_tsv() {
  jq -r '.rules[]? | select(.ruleExpression.byMetricName.name != null)
         | [.ruleExpression.byMetricName.name, .ruleId] | @tsv'
}

# Given a List response on stdin, emit one ruleId per line (all rule types).
list_rule_ids() { jq -r '.rules[]?.ruleId // empty'; }

# --- healthcheck --------------------------------------------------------------
# Verifies connectivity + auth to BOTH APIs WITHOUT making any change:
#   * Usage API: a tiny GetMetricUsages for today (length:1).
#   * Optimizer API: a List call (read-only).
# Exits 0 if both succeed, non-zero otherwise. Never blocks/unblocks anything.
healthcheck() {
  check_prereqs
  local ok=0 today_json resp ids
  today_json="$(utc_date_json)"

  log "INFO" "Healthcheck: Usage API (${USAGE_ENDPOINT}) ..."
  if resp="$(grpc_try "$USAGE_ENDPOINT" "$USAGE_METHOD" \
        "$(printf '{"common":{"start_date":%s,"end_date":%s,"start_offset":0,"length":1}}' "$today_json" "$today_json")")"; then
    if printf '%s' "$resp" | jq -e . >/dev/null 2>&1; then
      log "INFO" "  Usage API OK (valid JSON response)."
    else
      log "ERROR" "  Usage API returned non-JSON: $(printf '%s' "$resp" | head -c 200)"; ok=1
    fi
  else
    log "ERROR" "  Usage API call failed: $(printf '%s' "$resp" | head -c 200)"; ok=1
  fi

  log "INFO" "Healthcheck: Optimizer API (${OPTIMIZER_ENDPOINT}) List ..."
  if resp="$(grpc_try "$OPTIMIZER_ENDPOINT" "$LIST_METHOD" '{}')"; then
    if printf '%s' "$resp" | jq -e . >/dev/null 2>&1; then
      ids="$(printf '%s' "$resp" | list_rule_ids | wc -l | tr -d ' ')"
      log "INFO" "  Optimizer API OK (List returned ${ids} existing rule(s))."
    else
      log "ERROR" "  Optimizer List returned non-JSON: $(printf '%s' "$resp" | head -c 200)"; ok=1
    fi
  else
    log "ERROR" "  Optimizer List failed: $(printf '%s' "$resp" | head -c 200)"
    log "ERROR" "  -> Check OPTIMIZER_ENDPOINT (try the global gateway) and CX_AUTH_HEADER format."
    ok=1
  fi

  if [[ "$ok" -eq 0 ]]; then log "INFO" "Healthcheck PASSED."; else log "ERROR" "Healthcheck FAILED."; fi
  return "$ok"
}
