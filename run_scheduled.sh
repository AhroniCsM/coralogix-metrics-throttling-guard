#!/usr/bin/env bash
# =============================================================================
# run_scheduled.sh — launchd/cron entry point. Keep ALL behavior in config.env;
# this wrapper only fixes up the environment a scheduler doesn't provide (PATH,
# working directory) and then runs the requested script.
# =============================================================================
# Usage (from a plist or cron):
#   run_scheduled.sh detect      -> runs detect_over_threshold.sh
#   run_scheduled.sh unblock     -> runs unblock_midnight.sh
#
# launchd/cron start with a near-empty PATH, so grpcurl/jq/flock (typically in
# Homebrew dirs) wouldn't be found. We prepend the common locations. If your
# tools live elsewhere, add the dir here — this is the ONE place PATH is set.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Make Homebrew + system tools findable regardless of how we were invoked.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

case "${1:-}" in
  detect)  exec "$DIR/detect_over_threshold.sh" ;;
  unblock) exec "$DIR/unblock_midnight.sh" ;;
  *) echo "usage: run_scheduled.sh {detect|unblock}" >&2; exit 2 ;;
esac
