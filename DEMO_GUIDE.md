# Coralogix Metrics Throttling Guard

A pair of small shell scripts that **keep a Coralogix account under its metrics
fair-usage limit so it never gets throttled.** When an account's metric
ingestion exceeds its quota, Coralogix applies **fair-usage throttling** and
starts dropping datapoints account-wide — so every dashboard and alert degrades
at once. This tool prevents that by automatically **blocking the few heaviest
metrics** that are blowing the budget, then **unblocking them** when usage resets
at the start of the next UTC day.

> Think of it as a circuit breaker for metric spend: throttle the worst
> offenders deliberately, instead of letting Coralogix throttle *everything*.

---

## 1. What the script measures

Each run pulls **per-metric usage for the current UTC calendar day** from the
Coralogix `UsageService.GetMetricUsages` API. For every metric the API returns
all of these figures:

| Dimension | Config value (`USAGE_FIELD`) | What it is |
|-----------|------------------------------|------------|
| **Units** | `unit_usage` *(default)* | Coralogix's billing "units" — the number shown in the **Metric Data → units** column and the figure your fair-usage quota is expressed in. |
| **Volume** | `bytes_volume` | Raw bytes ingested for that metric. |
| **Cardinality** | `cardinality` | Number of active time series (label combinations). The usual root cause of throttling. |
| **Samples** | `sample_count` | Number of datapoints ingested. |

**Yes — it can measure cardinality *and* volume** (and units, and sample count).
But each run compares **one** dimension at a time against the threshold — you
choose which with `USAGE_FIELD`. Cardinality and volume are the two that most
directly drive throttling, so a common setup is **two instances**: one guarding
cardinality, one guarding volume (separate folders, separate `config.env`,
separate `data/` — see §5).

A metric is flagged when its chosen figure for the day exceeds
`THRESHOLD_UNITS`. The API also returns each metric's *fraction of the daily
account total*, so the heaviest offenders are easy to spot.

### How blocking avoids throttling

There is no API to zero a usage counter mid-day. Coralogix counts usage **per
UTC calendar day** and resets to zero at **00:00 UTC**. So:

```
during the day        usage climbs → detector BLOCKS metrics over the threshold
                      (their ingestion stops, so the account stays under quota → no throttling)
just after 00:00 UTC  new day starts at zero → unblock job ALLOWS them again
new day               a metric that re-crosses the threshold gets re-blocked
```

---

## 2. The scripts

| File | Role |
|------|------|
| `config.env` | The only file you edit. API key, region, threshold, which dimension, enforcement switches. |
| `detect_over_threshold.sh` | Detector. Reads usage, flags metrics over threshold, and (if enabled) **blocks** them via the Optimizer API. Runs on a schedule (hourly by default). |
| `unblock_midnight.sh` | Unblock job. Just after 00:00 UTC it **unblocks** everything this tool blocked. |
| `run_test.sh` | Safe staged runner — `healthcheck → dryrun → live-one → unblock-now → status`. |
| `lib_common.sh` | Shared helpers (auth, gRPC, flock, atomic state, healthcheck). |
| `install_launchd.sh` + `*.plist` | Scheduling on macOS launchd. Linux uses cron / a CronJob (see §5). |

The three gRPC methods it calls on your region's gRPC host (`:443`):
`UsageService.GetMetricUsages` (read), `MetricsBlockingRulesService.List` (read),
`.Block` / `.Allow` (the only state-changing calls).

---

## 3. How to configure it

Everything lives in `config.env`. Each line is `NAME="${NAME:-default}"` — edit
the default after `:-`, or override with an environment variable.

**Required:**

```bash
# Your Coralogix Team or Personal API key (NOT a send-your-data ingest key).
# Needs the DataAnalytics read preset + permission to manage metric blocking rules.
CX_API_KEY="${CX_API_KEY:-<your-api-key>}"

# Your region's gRPC management host (host:443, no https://):
#   eu1 api.eu1.coralogix.com:443   eu2 api.eu2.coralogix.com:443
#   us1 api.coralogix.us:443        us2 api.cx498.coralogix.com:443
#   ap1 api.app.coralogix.in:443    ap2 api.coralogixsg.com:443   ap3 api.ap3.coralogix.com:443
USAGE_ENDPOINT="${USAGE_ENDPOINT:-api.<region>.coralogix.com:443}"
```

**What to measure & when it's "too much":**

```bash
THRESHOLD_UNITS="${THRESHOLD_UNITS:-5}"        # flag metrics over this value
USAGE_FIELD="${USAGE_FIELD:-unit_usage}"       # unit_usage | bytes_volume | cardinality | sample_count
```

**Enforcement (start safe, widen over time):**

```bash
BLOCK_ENABLED="${BLOCK_ENABLED:-false}"        # MASTER SWITCH. false = dry-run (detect + log, block nothing)
MAX_BLOCKS_PER_RUN="${MAX_BLOCKS_PER_RUN:-1}"  # cap new blocks per run. 0 = unlimited (block everything over threshold)
BLOCK_ALLOWLIST="${BLOCK_ALLOWLIST:-}"         # if set, ONLY these metric names may ever be blocked
```

**Schedule (all evaluated in UTC):**

```bash
DETECTOR_INTERVAL_SECONDS="${DETECTOR_INTERVAL_SECONDS:-3600}"  # 3600 hourly · 900 every 15 min
UNBLOCK_UTC_HOUR="${UNBLOCK_UTC_HOUR:-0}"                       # unblock during 00:00 UTC, right after reset
```

**Optional:** `NOTIFY_CMD` (Slack/webhook on meaningful events only),
`HIGH_WATERMARK` (alert when N metrics are over threshold even in dry-run),
`PAGE_SIZE`, `CHUNK_SIZE`, `KEEP_DAYS`.

### Recommended bring-up order (read-only until step 4)

```bash
brew install grpcurl jq flock      # prerequisites (flock not on macOS by default)

./run_test.sh healthcheck          # read-only: verify key + endpoint + auth on both APIs
./run_test.sh dryrun               # read-only: real detection, blocks nothing
./run_test.sh status               # the over-threshold list, current state, recent log

./run_test.sh live-one <metric>    # block exactly one throwaway metric (asks to confirm)
#   ...check the "Blocked Metrics" tab in the UI...
./run_test.sh unblock-now          # lift it again — full lifecycle proven by hand
```

Only `live-one` and `unblock-now` change anything; everything else is read-only.

---

## 4. Built-in safety

- **Dry-run by default** (`BLOCK_ENABLED=false`) — nothing is blocked until you opt in.
- **Allowlist + per-run cap** — limit *which* and *how many* metrics can be blocked.
- **Unblock by rule ID only** — never by name, so it can't touch a rule you created by hand.
- **Skips already-blocked metrics** — checks the current rule list first, never double-blocks or claims ownership of someone else's rule.
- **Atomic state under a shared `flock`** — the two jobs can't race or corrupt state around the 00:00 UTC boundary.
- **State buckets are only removed after a confirmed unblock** — a failed unblock is kept and retried, never silently lost.

---

## 5. Running it at production scale

This tool is built for a **high-scale production account** — it pages through
*every* metric and chunks its Block/Allow calls — but how you run it matters:

- **Run it somewhere always-on**, not a laptop. The detector must fire on schedule
  and the unblock job must catch the 00:00 UTC hour. A sleeping machine misses
  both. Use a Linux host (cron) or a **Kubernetes `CronJob`** (two CronJobs:
  detector every 15–60 min, unblock hourly — the unblock self-gates on `UNBLOCK_UTC_HOUR`).
- **Tighten the detector interval** to react fast as the day's usage climbs —
  `DETECTOR_INTERVAL_SECONDS=900` (every 15 min) is a good production value.
- **Ramp enforcement, don't flip it all at once.** Start with
  `MAX_BLOCKS_PER_RUN=1` or a small `BLOCK_ALLOWLIST`, watch a few days, then move
  to `MAX_BLOCKS_PER_RUN=0` (block everything over threshold) as the steady state.
- **Guard the right dimension(s).** For throttling, run one instance on
  `cardinality` and one on `bytes_volume` (or `unit_usage` against your quota).
  Each instance = its own folder, `config.env`, and `data/` directory.
- **Set the threshold from real numbers.** Run `dryrun` for a day first; the
  `fractionOfDailyUsage` / `fractionOfDailyCardinality` the API returns show which
  metrics dominate the account — set `THRESHOLD_UNITS` just below them.
- **Wire up `NOTIFY_CMD`** to Slack so you're told when a metric gets blocked,
  when a block fails, or when the over-threshold count spikes.
- **One folder per account/region.** Keep staging and production fully separate.

---

## 6. End-to-end validation summary

The full lifecycle was verified against a live Coralogix account, with every
state change confirmed by an **independent read of the server** (not just the
script's own log):

| Step | Script reported | Independent server check | Result |
|------|-----------------|--------------------------|--------|
| Healthcheck | both APIs OK, 0 rules | `List` → empty | ✅ |
| Dry-run detection | over-threshold list | matches the UI "units" column | ✅ |
| Block (allowlisted) | `newly_blocked=1` | `List` → exactly 1 rule for the named metric | ✅ |
| Unblock | `unblocked=1 pending=0` | `List` → 0 rules; state cleared | ✅ |

The block touched **only** the allowlisted metric even though hundreds were over
the (test) threshold — proving the safety guard.

A reproducible test workload is included in `demo/metric-gen.yaml`: a tiny
dependency-free Prometheus exporter plus an OpenTelemetry collector
(`opentelemetry-collector-contrib`) that ships a uniquely-named throwaway metric
into your account, giving the guard something safe to block. Point it at your
account by setting the collector's `domain` and ingest key, then:

```bash
kubectl apply -f demo/metric-gen.yaml
kubectl -n metric-block-test get pods
# ...verify the metric exists, run ./run_test.sh live-one <metric>, then unblock...
kubectl delete ns metric-block-test          # tear down when done
```
