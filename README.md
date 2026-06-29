# Coralogix Metrics Throttling Guard

**Stop one runaway metric from throttling your whole Coralogix account.**

When metric ingestion runs over your fair-usage limit, Coralogix throttles and
drops datapoints **account-wide** — every dashboard and alert degrades at once.
This tool watches per-metric daily usage, automatically **blocks** the few
metrics responsible, and **unblocks** them when usage resets at the start of the
next UTC day. A circuit breaker for metric spend: throttle the worst offenders
*deliberately*, instead of letting Coralogix throttle *everything*.

It's two small shell scripts (`bash` + `grpcurl`) — no agent, no service in your
data path. Your metrics keep flowing; the guard only reads usage and manages
blocking rules over the Coralogix gRPC management API.

---

## 📊 Visual overview

Open **[`flow.html`](flow.html)** in a browser for a one-page explainer —
what it does, the daily cycle, the architecture, and the deploy steps. It's the
best thing to share with someone seeing this for the first time.

---

## How it works

```
during the day        usage climbs → detector BLOCKS metrics over your threshold
                      (their ingestion stops, so the account stays under quota → no throttling)
just after 00:00 UTC  Coralogix resets daily usage → unblock job ALLOWS them again
new day               a metric that re-crosses the threshold gets re-blocked
```

| Phase | Script | gRPC call | Schedule |
|-------|--------|-----------|----------|
| Detect over-budget metrics, block them | `detect_over_threshold.sh` | `GetMetricUsages` (read), `Block` (write) | every 15–60 min |
| Unblock everything it blocked | `unblock_midnight.sh` | `List` (read), `Allow` (write) | hourly; acts at 00:00 UTC |

All usage is evaluated **per UTC calendar day** — the same boundary Coralogix
resets on.

## What it measures

Each run reads per-metric usage for the current UTC day and enforces **one**
dimension (your choice via `USAGE_FIELD`):

| `USAGE_FIELD` | Dimension | Drives throttling? |
|---------------|-----------|--------------------|
| `cardinality` | active time series (label combinations) | **yes — top cause** |
| `bytes_volume` | raw bytes ingested | **yes** |
| `unit_usage` *(default)* | Coralogix billing "units" (vs your quota) | yes |
| `sample_count` | datapoints ingested | indirect |

> Cardinality and volume are the two that most directly cause throttling — most
> teams run **two instances**, one guarding each.

---

## Quick start

```bash
# 1. Prerequisites (the runner just needs these CLIs on PATH)
brew install grpcurl jq flock          # macOS  ·  Linux: jq + grpcurl + util-linux's flock

# 2. Configure — edit config.env (the only file you edit)
#    CX_API_KEY      = a Team/Personal API key (DataAnalytics read + manage blocking rules)
#    USAGE_ENDPOINT  = api.<region>.coralogix.com:443   (eu1 eu2 us1 us2 ap1 ap2 ap3)
#    USAGE_FIELD     = cardinality | bytes_volume | unit_usage | sample_count
#    THRESHOLD_UNITS = your limit
#    BLOCK_ENABLED   = false   ← starts in preview (blocks nothing)

# 3. Prove it by hand — read-only, then one real block, then unblock
./run_test.sh healthcheck              # verify key + endpoint + auth (read-only)
./run_test.sh dryrun                   # real detection, blocks NOTHING
./run_test.sh live-one <metric>        # block exactly one metric (asks to confirm)
./run_test.sh unblock-now              # lift it again — full lifecycle proven

# 4. Go live (set BLOCK_ENABLED=true, start narrow), then schedule it (below)
```

Only `live-one` and `unblock-now` change anything; everything else is read-only.

## Scheduling (production)

```cron
# Linux cron — detector every 15 min, unblock hourly (self-gates to 00:00 UTC)
*/15 * * * *  /opt/metrics-guard/detect_over_threshold.sh  >> /var/log/metrics-guard.log 2>&1
5   * * * *  /opt/metrics-guard/unblock_midnight.sh        >> /var/log/metrics-guard.log 2>&1
```

- **Kubernetes:** run the two scripts as two `CronJob`s (config in a `Secret`),
  using an image that has the scripts + `grpcurl` + `jq`.
- **macOS:** use the bundled `install_launchd.sh`.
- Run the host **always-on** — a sleeping machine misses both jobs.

---

## Configure

Everything lives in **`config.env`**. Key settings:

| Setting | Purpose |
|---------|---------|
| `CX_API_KEY` | Team/Personal API key (not a send-your-data ingest key). |
| `USAGE_ENDPOINT` | Your region's gRPC host, `api.<region>.coralogix.com:443`. |
| `USAGE_FIELD` | Which dimension to enforce (see table above). |
| `THRESHOLD_UNITS` | A metric over this (per day) is flagged. |
| `BLOCK_ENABLED` | Master switch. `false` = preview/dry-run. |
| `MAX_BLOCKS_PER_RUN` | Cap new blocks per run. `1` to start; `0` = unlimited. |
| `BLOCK_ALLOWLIST` | If set, **only** these metric names may ever be blocked. |
| `DETECTOR_INTERVAL_SECONDS` / `UNBLOCK_UTC_HOUR` | Schedule (UTC). |
| `NOTIFY_CMD` | Optional Slack/webhook on meaningful events. |

## Safety

- **Dry-run by default** — nothing is blocked until you enable enforcement.
- **Allowlist + per-run cap** — bound which metrics and how many can be blocked.
- **Unblock by rule id only** — never by name; can't touch a rule you made by hand.
- **Skips already-blocked metrics** — never double-blocks or claims another's rule.
- **Crash-safe** — atomic state writes under a shared lock; a failed unblock is
  retried, never lost. Both scripts can't race around the midnight boundary.

---

## What each script does

### `detect_over_threshold.sh` — the detector *(runs on a schedule)*
The workhorse. On each run it:
1. Pages through **every metric**'s usage for the current UTC day (`GetMetricUsages`) and keeps those over `THRESHOLD_UNITS` on your chosen dimension.
2. If `BLOCK_ENABLED=true`: calls `List` to see what's already blocked and **skips it**, applies your `BLOCK_ALLOWLIST` and `MAX_BLOCKS_PER_RUN` cap, then calls `Block` (in chunks) on the rest.
3. Re-checks with `List` and records each newly created rule (**metric name + rule id**) in a date-bucketed `data/state.json`, so the unblock job knows exactly what it owns.
4. Writes `data/over_threshold_latest.json` (the current over-budget list) and appends a one-line JSON summary to `data/optimizer.log`.

With `BLOCK_ENABLED=false` it does steps 1 + 4 only — pure detection, blocks nothing.

### `unblock_midnight.sh` — the unblock job *(runs hourly, acts at 00:00 UTC)*
Wakes every hour and **exits immediately unless** the current UTC hour matches `UNBLOCK_UTC_HOUR` (default 0). When it does act, for every completed (past) day bucket it:
1. Gathers the rule ids it recorded as its own, and reconciles them against the live `List` (drops ids that are already gone).
2. Calls `Allow` **by rule id only** (in chunks), removing each id from state as it succeeds.
3. Deletes a day's bucket only once every rule in it is unblocked; a failed unblock is **kept and retried** next run, never lost.

Pass `--force` / `--include-today` to run it manually outside the scheduled hour.

### `lib_common.sh` — shared library *(not run directly)*
Sourced by both scripts. Loads `config.env` and provides: logging, the cross-process `flock`, atomic state writes (temp-file + rename), the auth header, the `grpcurl` wrappers (with one retry), the Optimizer `List` helpers, and the read-only **healthcheck**.

### `run_test.sh` — safe staged runner *(you run this by hand)*
Encodes the safe bring-up stages as named presets so you can't fat-finger a wide blast radius. Subcommands: `healthcheck`, `dryrun`, `noop`, `live-one <metric>`, `unblock-now`, `status`. It only sets env vars for a child run — it **never edits `config.env`** — and only `live-one` and `unblock-now` change anything.

### `install_launchd.sh` + `*.plist` — macOS scheduling
Renders the two plist templates with this folder's path and your `DETECTOR_INTERVAL_SECONDS`, loads them via `launchctl bootstrap`, and verifies. Commands: `install`, `uninstall`, `run [detect|reset]`, `status`, `doctor`. (On Linux, use cron / CronJobs instead — see above.)

### `run_scheduled.sh` — scheduler entry point
A thin wrapper the scheduler invokes: sets a clean `PATH` and runs the requested job. You don't call it directly.

### `config.env` — all settings *(the only file you edit)*
Every knob lives here (API key, region, threshold, dimension, enforcement, schedule, notifications). Committed as a template with a placeholder key.

---

## File map

| Path | What |
|------|------|
| `detect_over_threshold.sh` | The detector (detect + block). |
| `unblock_midnight.sh` | The unblock job. |
| `lib_common.sh` | Shared helpers (auth, gRPC, lock, atomic state, healthcheck). |
| `run_test.sh` | Safe staged runner: `healthcheck → dryrun → live-one → unblock-now → status`. |
| `config.env` | All settings (the only file you edit) — committed as a template. |
| `install_launchd.sh`, `*.plist` | macOS launchd scheduling. |
| `run_scheduled.sh` | Scheduler entry point. |
| `flow.html` | 📊 Visual one-page overview — share this. |
| `DEMO_GUIDE.md` | Detailed walkthrough + how it was validated end-to-end. |
| `demo/metric-gen.yaml` | Optional: deploy a safe throwaway metric to test the guard against. |
| `docs/REFERENCE.md` | Full reference (every config knob, internals, edge cases). |
| `docs/EXAMPLE_RUN.md` | An annotated real bring-up session. |

## Requirements

`bash` (3.2+), [`grpcurl`](https://github.com/fullstorydev/grpcurl), `jq`,
`flock`, and a Coralogix API key with the **DataAnalytics** read preset plus
permission to manage metric blocking rules.

---

> **Heads up:** `config.env` is committed with a placeholder key. Don't commit it
> once you paste a real key — `git rm --cached config.env` and keep it local.
