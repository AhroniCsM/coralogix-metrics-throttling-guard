# Coralogix Metrics Cost-Optimizer Automation

Two small scripts that, together, keep your Coralogix metric spend in check:

- **`detect_over_threshold.sh`** (runs hourly) — finds metrics whose usage for
  the current UTC day is over a threshold and **blocks** them (stops further
  ingestion for the rest of the day).
- **`unblock_midnight.sh`** (runs daily, just after 00:00 UTC) — **unblocks**
  everything this automation blocked, because Coralogix resets daily usage at
  00:00 UTC and every metric should start the new day clean.

Everything is driven by **one file, `config.env`** — you never edit the scripts
or the schedule files. The default config is **dry-run**: it detects and logs
but blocks nothing until you deliberately turn enforcement on.

---

## TL;DR — what you actually do

```bash
# 1. Put all files in one folder OUTSIDE ~/Desktop, ~/Documents, ~/Downloads
#    (macOS blocks scheduled jobs from running in those). e.g.:
mkdir -p ~/coralogix-metric-optimizer && cd ~/coralogix-metric-optimizer
#    ...copy the files here...

# 2. Install prerequisites
brew install grpcurl jq flock

# 3. Make scripts executable
chmod +x *.sh

# 4. Edit config.env: set CX_API_KEY and USAGE_ENDPOINT (your region).
#    Leave BLOCK_ENABLED=false for now (the default).

# 5. Verify connectivity + auth (read-only, changes nothing)
./run_test.sh healthcheck          # want: "Healthcheck PASSED."

# 6. See what WOULD be blocked (read-only, still blocks nothing)
./run_test.sh dryrun
./run_test.sh status

# 7. Prove one real block/unblock on a throwaway metric (asks to confirm)
./run_test.sh live-one <a_safe_metric_from_the_status_list>
#    ...check the Coralogix UI: only that metric shows "Unblock"...
./run_test.sh unblock-now

# 8. When confident, turn on enforcement + schedule it (see "Going live")
```

Each step is explained below. There's also a full annotated walk-through of a
real run in **EXAMPLE_RUN.md**.

---

## Step-by-step

### Step 1 — Folder location (macOS)

Put the files in a normal folder like `~/coralogix-metric-optimizer`. **Do not**
use `~/Desktop`, `~/Documents`, or `~/Downloads` — macOS privacy protection
(TCC) stops `launchd` from running scripts in those, and you'll get
"Operation not permitted" when scheduling.

### Step 2 — Prerequisites

- `bash` — works on stock macOS bash 3.2 and Linux bash 4/5 (no special version needed).
- [`grpcurl`](https://github.com/fullstorydev/grpcurl) — `brew install grpcurl`
- [`jq`](https://stedolan.github.io/jq/) — `brew install jq`
- `flock` — Linux has it; macOS: `brew install flock`.

> **macOS line-endings gotcha:** if you ever edit a file and a command silently
> exits with code 2, it likely got saved with Windows (CRLF) line endings. Fix:
> `sed -i '' $'s/\r$//' *.sh config.env`

### Step 3 — Make scripts executable

```bash
chmod +x *.sh
```

### Step 4 — Configure (`config.env`)

Open `config.env`. Every setting is `NAME="${NAME:-default}"`; change the
default after `:-`. You **must** set two things:

- **`CX_API_KEY`** — a Coralogix API key with the *DataAnalytics* preset (to
  read usage) **and** permission to manage metric blocking rules.
- **`USAGE_ENDPOINT`** — your region's gRPC host (table is in the file;
  e.g. EU1 = `api.eu1.coralogix.com:443`).

Leave `BLOCK_ENABLED` at `false` for now. Review `THRESHOLD_UNITS` (default 5).

### Step 5 — Healthcheck (read-only)

```bash
./run_test.sh healthcheck
```

This calls the Usage API and the Optimizer `List` — both read-only — and prints
`Healthcheck PASSED.` if your key + endpoint + auth are all good.

- Auth error (`Unauthenticated` / 16)? Change `CX_AUTH_HEADER` in config to the
  raw form `Authorization: ${CX_API_KEY}`.
- Optimizer `UNAVAILABLE` (14) / `NOT_FOUND`? Set `OPTIMIZER_ENDPOINT` to
  `ng-api-grpc.app.coralogix.net:443`.

Don't proceed until this passes.

### Step 6 — Dry run (read-only)

```bash
./run_test.sh dryrun     # real detection against your data; blocks NOTHING
./run_test.sh status     # shows the over-threshold list, current state, recent log
```

Review the metric list. Is the threshold sensible? Pick one **throwaway /
non-critical** metric for the next step. (Tip: it's normal for the count to be
low early in the UTC day and grow through the day, since usage accumulates per
UTC calendar day.)

### Step 7 — One controlled live block (the first real change)

```bash
./run_test.sh live-one <your_safe_metric>
```

This sets `BLOCK_ENABLED=true`, `MAX_BLOCKS_PER_RUN=1`, and an allowlist of just
that metric, then asks you to confirm. It blocks **exactly** that one metric.
Then **check the Coralogix UI** — search the metric; it should show the green
**Unblock** action (= currently blocked). The other over-threshold metrics
should be untouched.

Then lift it:

```bash
./run_test.sh unblock-now
```

You want `unblocked=1 pending=0`, and the UI flips back to **Block**. That's the
full lifecycle proven by hand.

### Step 8 — Going live (autonomous, scheduled)

See the next section.

---

## Going live: autonomous scheduling (macOS / launchd)

Once the manual round-trip works, turn on enforcement and let it run on a
schedule. **All behaviour stays in `config.env`** — the `.plist` files only
schedule, and the installer fills in paths/intervals from config.

1. **Decide your enforcement scope in `config.env`** and set `BLOCK_ENABLED="true"`.
   Start narrow so the first scheduled runs can't over-block:
   - `BLOCK_ALLOWLIST="one_known_metric"` (only that metric can be blocked), or
   - `MAX_BLOCKS_PER_RUN=1` (at most one new block per run; the rest defer).
   Widen over days. `MAX_BLOCKS_PER_RUN=0` + empty allowlist = block everything
   over threshold — the eventual steady state, not the starting point.

2. **Confirm the schedule values** in `config.env`:
   - `DETECTOR_INTERVAL_SECONDS=3600` (hourly) — or `900` for every 15 min.
   - `UNBLOCK_UTC_HOUR=0` (unblock at 00:00 UTC, right after usage resets).

3. **Install:**
   ```bash
   ./install_launchd.sh install
   ```
   It renders the plists with this folder's path + your interval, loads them
   with modern `launchctl bootstrap`, and **verifies** (prints ✓ per job). If
   anything's wrong it tells you to run `./install_launchd.sh doctor`.

4. **Force one run now** to confirm it works end-to-end (instead of waiting an hour):
   ```bash
   ./install_launchd.sh run detect
   ```

5. **Watch it:**
   ```bash
   tail -f data/optimizer.log
   ./install_launchd.sh status      # both jobs loaded, last exit code = 0
   ```

To change anything later: edit `config.env`, then `./install_launchd.sh install`
again (re-run install only matters for the *interval*; the scripts read the rest
of config fresh on each run). To stop everything: `./install_launchd.sh uninstall`
(then optionally `./unblock_midnight.sh --force` to leave metrics unblocked).

> **The Mac must be awake** for jobs to fire. If it sleeps, launchd defers jobs
> to the next wake — and because the unblock job only acts during its
> configured UTC hour, a Mac asleep through that hour will unblock on the next
> day it's awake during that hour. For always-on operation, run this on a server
> or a Mac that doesn't sleep (or a Linux box via cron — see below).

### Installer commands

```
./install_launchd.sh install [--dry-run]   # render + load + verify (--dry-run forces BLOCK_ENABLED=false)
./install_launchd.sh uninstall             # unload + remove
./install_launchd.sh run [detect|reset]    # force a job to run NOW + tail its log
./install_launchd.sh status                # show both services' state + last exit
./install_launchd.sh doctor                # full diagnostics if something's off
```

### Linux / cron alternative

```cron
# Detector — hourly
5 * * * * /full/path/detect_over_threshold.sh >> /full/path/data/cron.out 2>&1
# Unblock — wakes hourly; gates on UNBLOCK_UTC_HOUR (UTC) internally
1 * * * * /full/path/unblock_midnight.sh >> /full/path/data/cron.out 2>&1
```

(cron uses local time, but the scripts decide everything in UTC, so the exact
local minute doesn't matter — the unblock only acts during `UNBLOCK_UTC_HOUR`.)

---

## How it works (and why it's safe)

**The day boundary.** There's no API to zero a usage counter mid-day. Coralogix
reports usage per **UTC calendar day**; at 00:00 UTC it rolls to a fresh day
that starts at zero. "Restart at midnight" = a new UTC day begins. The Optimizer
API is a blocking-rules service (`Block`, `List`, `Allow`).

```
during the day:      usage climbs → detector Blocks over-threshold metrics
just after 00:00 UTC: new day starts near zero → unblock job Allows them again
new day:             a metric that re-crosses the threshold gets re-blocked
```

**State** lives in `data/state.json`, in per-UTC-date buckets, each entry being
`{name, rule_id, owned:true}`. Safety properties:

1. The detector only **adds** to today's bucket; it never deletes a bucket.
2. Only the unblock job removes a bucket, and only after its `Allow` calls
   succeed. A failed unblock keeps the bucket and retries.
3. Every recorded entry has a concrete `rule_id` — the detector snapshots rules
   before/after blocking and records ownership only for a metric that was absent
   before, present after, with a real ID. Unconfirmed blocks aren't recorded.
4. **Unblock is by rule ID only**, so it can never touch a manually-created rule
   that happens to share a metric name.
5. Unblocking is **ID-level idempotent**: it drops already-gone IDs and removes
   each succeeded chunk from state immediately, so a partial failure never
   re-sends an already-removed ID (which would 404 and wedge the bucket).
6. Pruning removes only **empty** old buckets; a non-empty bucket still owed an
   unblock is never pruned.
7. Both scripts share a `flock` and write state atomically (temp file + `mv`).
8. The detector calls `List` before blocking, so it **skips** metrics already
   blocked manually or by something else, and never claims ownership of those.

**Field names.** grpcurl returns Coralogix fields in camelCase (`dailyUsages`,
`unitUsage`, `ruleId`); the scripts read those directly. `USAGE_FIELD` stays as
the human-readable snake_case config name and is mapped internally.

**Sorting.** The Usage query omits `order_by`/`ordering` by default (their enum
value names vary by tenant, and the detector filters everything itself anyway).
Set `USAGE_ORDER_BY`/`USAGE_ORDERING` only if you know your tenant's valid values.

---

## Files

```
config.env                              # ALL settings (the only file you edit)
lib_common.sh                           # shared helpers: logging, flock, atomic writes, grpc, healthcheck
detect_over_threshold.sh                # the hourly detect+block job
unblock_midnight.sh                     # the daily unblock job (gated on UNBLOCK_UTC_HOUR)
run_test.sh                             # staged, safe manual test runner
run_scheduled.sh                        # launchd entry point (sets PATH, runs a job)
install_launchd.sh                      # install/uninstall/run/status/doctor for the schedule
com.coralogix.metricoptimizer.detector.plist   # detector schedule (templated)
com.coralogix.metricoptimizer.reset.plist      # unblock schedule (templated)
EXAMPLE_RUN.md                          # annotated real test session
data/                                   # created on first run
  ├── state.json                            # date-bucketed block state (shared)
  ├── optimizer.lock                        # flock target (shared)
  ├── over_threshold_latest.json            # latest over-threshold list (overwritten)
  └── optimizer.log                         # one JSON line per run (append-only)
```

## Logging & counters

Each detector run appends one JSON line to `data/optimizer.log`:

```json
{"ts":"…","event":"detect","utc_day":"2026-06-04","over_threshold":7,
 "newly_blocked":1,"already_blocked":0,"unconfirmed_blocks":0,
 "block_failures":0,"deferred_by_cap":0,"blocked_by_us_today":1,"block_enabled":"true"}
```

The unblock job logs `{"event":"midnight_unblock","unblocked":N,"pending":M}`.
`pending > 0` means some rules couldn't be unblocked and will be retried.

## Notifications (optional, off by default)

Set `NOTIFY_CMD` in `config.env` to be pinged only on meaningful events (new
blocks, failures, deferrals, pending unblocks, a high-watermark spike) — never
on a quiet tick. The JSON summary (plus an `alert` field) arrives on stdin and
as `$1`. A failing command is logged but never aborts a run. See `config.env`
for file-append and Slack-webhook examples.

## Reusing across accounts / regions

Everything environment-specific is in `config.env`. Copy the folder, change
`config.env` (key, endpoint, `DATA_DIR`), and schedule independently. This is
exactly how you keep a staging tenant and production separate — one folder each.
