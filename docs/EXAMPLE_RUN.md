# Example run — a real bring-up session

This is an annotated walk-through of an actual test of the automation against a
live Coralogix tenant, end to end: healthcheck → dry-run → block one metric →
verify in the UI → unblock. Output is lightly trimmed but real.

The whole point of this sequence is that **nothing is blocked until the
`live-one` step**, and even then only a single named metric — so you can prove
the full lifecycle safely before scheduling anything.

---

## 0. One-time setup

```bash
chmod +x detect_over_threshold.sh unblock_midnight.sh lib_common.sh run_test.sh
brew install grpcurl jq flock      # if not already installed
# edit config.env: CX_API_KEY + USAGE_ENDPOINT (your region's gRPC Management host)
# leave BLOCK_ENABLED=false
```

> Gotcha hit during real setup: on macOS, files saved with Windows (CRLF) line
> endings make `./run_test.sh healthcheck` silently exit 2. Fix:
> ```bash
> sed -i '' $'s/\r$//' *.sh config.env
> ```

---

## 1. Healthcheck (read-only)

Verifies the API key, the endpoint, and the auth header against **both** APIs.
Makes no changes.

```text
$ ./run_test.sh healthcheck
Stage: HEALTHCHECK (read-only — calls Usage GetMetricUsages + Optimizer List)
[INFO] Healthcheck: Usage API (api.eu1.coralogix.com:443) ...
[INFO]   Usage API OK (valid JSON response).
[INFO] Healthcheck: Optimizer API (api.eu1.coralogix.com:443) List ...
[INFO]   Optimizer API OK (List returned 0 existing rule(s)).
[INFO] Healthcheck PASSED.
```

What it proved: key works, `api.eu1.coralogix.com:443` is the right host for
both APIs, auth header format is correct, and there were no pre-existing
blocking rules.

> If this fails with `Unauthenticated`, switch `CX_AUTH_HEADER` to the raw form
> `Authorization: ${CX_API_KEY}`. If the Optimizer `List` fails with
> `UNAVAILABLE`/`NOT_FOUND`, try `OPTIMIZER_ENDPOINT=ng-api-grpc.app.coralogix.net:443`.

---

## 2. Dry-run (read-only) + inspect

Runs the real detection against live data but with `BLOCK_ENABLED=false`, so it
stops before blocking. Here we use `THRESHOLD_UNITS=20` to get a workable set of
candidates in this tenant.

```text
$ THRESHOLD_UNITS=20 ./run_test.sh dryrun
Stage: DRY-RUN (read-only — real detection, BLOCK_ENABLED=false)
Settings: BLOCK_ENABLED=false
[INFO] Detecting metrics over 20 (unit_usage) for 2026-06-03 UTC
[INFO] Found 6 metric(s) over threshold.
[INFO] BLOCK_ENABLED=false — report-only, not blocking anything.
[INFO] Done. over=6 newly_blocked=0 already_blocked=0 unconfirmed=0 deferred=0 blocked_by_us_today=0
Metrics over 20 (unit_usage) on 2026-06-03 UTC:
  otelcol_k8s_pod_association                                          51.72
  cx_aggregate_test_metric_counter_reset_rewritten_cx_topk_50          50.80
  cx_aggregate_test_metric_counter_reset_300s:topk_50_by_group_gap...  49.91
  metric_alert_evaluator_task                                          25.38
  cx_catalog_customer_info                                             23.32
  request_handler_duration_seconds_bucket                              22.72
```

What it proved: the detector's numbers match the Coralogix UI's "units" column
exactly (e.g. `otelcol_k8s_pod_association` 51.72 in both). `newly_blocked=0`
confirms dry-run blocks nothing. This is where you pick a **throwaway** metric to
test with.

> Reading the numbers: it's mid-day UTC, so these are partial-day totals — they
> keep climbing until 00:00 UTC. A metric at 25 now may finish the day much
> higher. That's expected.

---

## 3. Block exactly one metric (the first real change)

`live-one <metric>` sets `BLOCK_ENABLED=true`, `MAX_BLOCKS_PER_RUN=1`, and
`BLOCK_ALLOWLIST="<metric>"` all at once, then prompts for confirmation. Even
with 6 metrics over threshold, only the named one can be blocked.

```text
$ ./run_test.sh live-one metric_alert_evaluator_task
Stage: CONTROLLED LIVE BLOCK of a single metric
Settings: BLOCK_ENABLED=true  MAX_BLOCKS_PER_RUN=1  BLOCK_ALLOWLIST="metric_alert_evaluator_task"
This WILL block 'metric_alert_evaluator_task' in Coralogix (stops its ingestion until you unblock).
Proceed? [y/N] y
[INFO] Detecting metrics over 20 (unit_usage) for 2026-06-03 UTC
[INFO] Found 6 metric(s) over threshold.
[INFO] Allowlist active: 1/6 candidate(s) are on the allowlist; the rest are ignored.
[INFO] Blocking 1 new metric(s) in chunks of 50.
[INFO] Newly blocked 1; 0 unconfirmed; 0 chunk failure(s).
[INFO] Done. over=6 newly_blocked=1 already_blocked=0 unconfirmed=0 deferred=0 blocked_by_us_today=1
[INFO] Notified: blocked 1 new metric(s)
Now verify in the Coralogix UI that ONLY 'metric_alert_evaluator_task' is blocked, then:
  ./run_test.sh unblock-now
```

What it proved: `Allowlist active: 1/6` — the safety filter dropped the other 5
candidates. `newly_blocked: 1`, `0 unconfirmed`, `0 chunk failures`. Exactly one
metric blocked.

---

## 4. Verify in the Coralogix UI

In **Metric Data → All metrics**, search the metric name. The blocked one shows a
green **Unblock** action (instead of **Block**), confirming it's currently
blocked. The other five over-threshold metrics still show **Block** — untouched.

The logs prove the API call succeeded; the UI confirms the product-side effect.

---

## 5. Unblock (close the round trip)

```text
$ ./run_test.sh unblock-now
Stage: UNBLOCK NOW (lifts everything this automation blocked, incl. today)
This calls Allow for all rules we own across all date buckets.
Proceed? [y/N] y
[INFO] Bucket 2026-06-03: unblocking 1 rule(s) in chunks of 50.
[INFO] Bucket 2026-06-03: fully unblocked; bucket removed.
[INFO] Total rules unblocked this run: 1.
[INFO] Done. unblocked=1 pending=0
```

What it proved: `unblocked=1 pending=0` — the rule was lifted and state cleared.
Refreshing the UI shows the metric's action flip back from **Unblock** to
**Block** (ingesting normally again). Full lifecycle confirmed:
detect → block → unblock.

---

## 6. The autonomous overnight run (the real proof)

After the manual round-trip, the schedule was installed live (detector every
15 min for the test, `UNBLOCK_UTC_HOUR=0`) and left to run overnight. This is
the actual log, lightly trimmed — block → hold → auto-unblock at the UTC day
boundary → re-block, with **no human involved**:

```text
# --- June 3 UTC: blocked, then held idempotently every ~15 min ---
22:28  detect  over_threshold=37  newly_blocked=1  blocked_by_us_today=1   # blocked it
22:49  detect  over_threshold=37  newly_blocked=0  already_blocked=1       # holds
23:07  detect  ...                newly_blocked=0  already_blocked=1
23:22  detect  ...                already_blocked=1
23:38  detect  ...                already_blocked=1
23:53  detect  over_threshold=38  already_blocked=1

# --- 00:00 UTC rollover: usage resets to a fresh day ---
00:09  detect  over_threshold=3   newly_blocked=0  blocked_by_us_today=0   # count collapsed 38 -> 3
00:24  detect  over_threshold=5   ...
00:40  detect  over_threshold=5   ...

# --- the scheduled unblock fires by itself, during the 00:00 UTC hour ---
00:52  midnight_unblock  unblocked=1  pending=0                            # auto-unblocked!

# --- new UTC day: metric re-crosses threshold, gets re-blocked ---
00:55  detect  over_threshold=5   newly_blocked=0
01:11  detect  over_threshold=6   newly_blocked=1  blocked_by_us_today=1   # re-blocked on new day
01:26  detect  over_threshold=6   already_blocked=1
01:42  detect  over_threshold=6   already_blocked=1
```

What this proves — every moving part, running on its own:

- **Block + idempotent hold:** blocked once at 22:28, then six runs that
  correctly said `already_blocked` instead of re-blocking.
- **The UTC day boundary is real:** `over_threshold` collapsed from **38 to 3**
  at 00:09 — that's Coralogix resetting daily usage at 00:00 UTC. (The UI shows
  usage by *local* day, which is why it can look out of step; the API, and these
  scripts, work in UTC.)
- **Automatic unblock:** at 00:52 the unblock job's hourly wake landed inside the
  `UNBLOCK_UTC_HOUR=0` window, saw yesterday's bucket was now a completed day,
  and lifted it — `unblocked=1 pending=0`. Nobody ran a command.
- **Re-block on the new day:** by 01:11 the metric was back over 5 units, so the
  detector re-blocked it (a brand-new rule ID — the old one was gone). Exactly
  right: new day, still over budget.

Confirming afterward, all three sources agreed: the UI showed the metric blocked
(green **Unblock** action, usage `6.12 U` for the new day), the last log line
showed `already_blocked:1`, and `state.json` held it under the current date with
`owned:true` and the new `rule_id`.

```bash
# the one-line proof the auto-unblock fired:
$ grep midnight_unblock data/optimizer.log
{"ts":"2026-06-04T00:52:24Z","event":"midnight_unblock","utc_day":"2026-06-04","unblocked":1,"pending":0}

# jobs healthy:
$ ./install_launchd.sh status
== detector ==  last exit code = 0  state = active
== reset ==     last exit code = 0  state = active
```

> Note on timing: the unblock fired at 00:52 UTC, not exactly 00:00 — the job
> wakes on its hourly interval and runs the first time a wake lands inside the
> configured UTC hour. Functionally perfect (it unblocked early in the new day);
> if you want it nearer the top of the hour, shorten the reset interval.
>
> Also: the Mac must stay awake for jobs to fire. For unattended overnight runs,
> use a machine that doesn't sleep, or keep it plugged in and awake.

---

## What to change for production

- Set `THRESHOLD_UNITS` to your real value (e.g. `5`) in the **production**
  folder's `config.env`. (Keep prod and test tenants in separate folders, each
  with its own `config.env` and `data/`.)
- Don't jump to "block everything over threshold." Start narrow —
  `BLOCK_ALLOWLIST="<one known-safe metric>"` or `MAX_BLOCKS_PER_RUN=1` — and
  widen over days once you trust it. `MAX_BLOCKS_PER_RUN=0` + empty allowlist
  (block everything) is the destination, not the starting point.
- Schedule it: detector hourly, unblock just after 00:00 UTC. See the
  **Scheduling** section of README.md.
