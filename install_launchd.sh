#!/usr/bin/env bash
# =============================================================================
# install_launchd.sh — manage the two launchd jobs on macOS (modern launchctl).
# =============================================================================
# Commands:
#   ./install_launchd.sh install            # render plists w/ this folder + bootstrap + enable + verify
#   ./install_launchd.sh install --dry-run  # same, but plists force BLOCK_ENABLED=false (safe test)
#   ./install_launchd.sh uninstall          # bootout + remove plists
#   ./install_launchd.sh run [detect|reset] # kickstart a job NOW (bypasses throttle) + tail log
#   ./install_launchd.sh status             # launchctl print for both services
#   ./install_launchd.sh doctor             # full diagnostics (paths, perms, launchd state, logs)
#
# Why modern launchctl: legacy `load`/`unload`/`start` return 0 even when the
# job is broken, so they give false confidence. We use bootstrap/bootout/enable/
# kickstart and then VERIFY the service really exists.
#
# Keep this folder OUTSIDE ~/Desktop, ~/Documents, ~/Downloads — macOS TCC blocks
# launchd from running scripts there ("Operation not permitted").
#
# All runtime behavior stays in config.env; this only manages the schedule.

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS="$HOME/Library/LaunchAgents"
UID_NUM="$(id -u)"
DOMAIN="gui/$UID_NUM"
DET="com.coralogix.metricoptimizer.detector"
RES="com.coralogix.metricoptimizer.reset"

red()   { printf '\033[31m%s\033[0m\n' "$1"; }
grn()   { printf '\033[32m%s\033[0m\n' "$1"; }
bold()  { printf '\033[1m%s\033[0m\n'  "$1"; }

warn_if_protected() {
  case "$DIR" in
    "$HOME/Desktop"/*|"$HOME/Documents"/*|"$HOME/Downloads"/*|"$HOME/Desktop"|"$HOME/Documents"|"$HOME/Downloads")
      red "WARNING: '$DIR' is under a macOS-protected folder (Desktop/Documents/Downloads)."
      red "         launchd will be blocked with 'Operation not permitted'."
      red "         Move this folder to e.g. ~/coralogix-metric-optimizer and re-run."
      echo ;;
  esac
}

require_plists() {
  for p in "$DET" "$RES"; do
    [[ -f "$DIR/$p.plist" ]] || { red "Missing $DIR/$p.plist"; exit 1; }
  done
}

# Read DETECTOR_INTERVAL_SECONDS from config.env (default 3600 if unset/missing).
# We grep rather than source, to avoid running config.env side-effects here.
detector_interval() {
  local v
  v="$(grep -E '^[[:space:]]*DETECTOR_INTERVAL_SECONDS=' "$DIR/config.env" 2>/dev/null \
        | tail -n1 | sed -E 's/.*DETECTOR_INTERVAL_SECONDS=//; s/^"//; s/".*//; s/[^0-9].*//')"
  [[ "$v" =~ ^[0-9]+$ ]] && printf '%s' "$v" || printf '3600'
}

# Render a plist: replace __DIR__ with the folder path and __INTERVAL__ with the
# detector interval from config.
render_plist() {
  local interval; interval="$(detector_interval)"
  sed -e "s|__DIR__|$DIR|g" -e "s|__INTERVAL__|$interval|g" "$1" > "$2"
}

bootout_one() {
  # Remove from domain whether referenced by label or by path; ignore errors.
  launchctl bootout "$DOMAIN/$1" 2>/dev/null || true
  launchctl bootout "$DOMAIN" "$AGENTS/$1.plist" 2>/dev/null || true
}

verify_one() {
  local label="$1"; local plist="$AGENTS/$label.plist"; local ok=0
  # 1) Path VALUES (inside <string> tags) must not be stale or an unrendered
  #    placeholder. We only inspect <string> lines containing a path, so the
  #    explanatory comment (which mentions Desktop/__DIR__) doesn't false-trigger.
  if grep -E '<string>' "$plist" 2>/dev/null | grep -qE '__DIR__|/Desktop/|/metric blocking/'; then
    red "  ✗ $label: installed plist has a stale/placeholder path:"
    grep -nE '<string>' "$plist" | grep -E '__DIR__|/Desktop/|/metric blocking/' | sed 's/^/      /'
    ok=1
  fi
  # Unrendered numeric placeholder (e.g. __INTERVAL__) would make plutil fail too,
  # but flag it explicitly for a clearer message.
  if grep -q '__INTERVAL__' "$plist" 2>/dev/null; then
    red "  ✗ $label: installed plist still contains __INTERVAL__ (not substituted)"; ok=1
  fi
  # 2) plist must be valid (skip gracefully if plutil unavailable)
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$plist" >/dev/null 2>&1 || { red "  ✗ $label: plist failed plutil -lint"; ok=1; }
  fi
  # 3) launchd must actually know the service
  if launchctl print "$DOMAIN/$label" >/dev/null 2>&1; then
    grn "  ✓ $label: loaded in $DOMAIN"
  else
    red "  ✗ $label: NOT present in $DOMAIN (bootstrap failed)"; ok=1
  fi
  return "$ok"
}

cmd="${1:-}"; arg="${2:-}"
case "$cmd" in
  install)
    require_plists
    warn_if_protected
    mkdir -p "$AGENTS" "$DIR/data"
    chmod +x "$DIR"/*.sh 2>/dev/null || true
    # Clear quarantine so launchd won't refuse downloaded files.
    xattr -dr com.apple.quarantine "$DIR" 2>/dev/null || true

    DRYRUN_NOTE=""
    [[ "$arg" == "--dry-run" ]] && DRYRUN_NOTE=" (forcing BLOCK_ENABLED=false)"

    for p in "$DET" "$RES"; do
      render_plist "$DIR/$p.plist" "$AGENTS/$p.plist"
      # For a safe scheduler test, inject a dry-run env override into the plist.
      if [[ "$arg" == "--dry-run" ]]; then
        # Insert an EnvironmentVariables dict right after the opening <dict>.
        /usr/bin/python3 - "$AGENTS/$p.plist" <<'PY'
import plistlib,sys
f=sys.argv[1]
d=plistlib.load(open(f,'rb'))
ev=d.get('EnvironmentVariables',{}); ev['BLOCK_ENABLED']='false'
d['EnvironmentVariables']=ev
plistlib.dump(d,open(f,'wb'))
PY
      fi
      chmod 644 "$AGENTS/$p.plist"
      bootout_one "$p"
      launchctl bootstrap "$DOMAIN" "$AGENTS/$p.plist" 2>/dev/null || {
        red "bootstrap failed for $p — see: ./install_launchd.sh doctor"; }
      launchctl enable "$DOMAIN/$p" 2>/dev/null || true
      echo "installed: $p  ->  $DIR$DRYRUN_NOTE"
    done

    echo; bold "Verifying..."
    rc=0; verify_one "$DET" || rc=1; verify_one "$RES" || rc=1
    echo
    if [[ "$rc" -eq 0 ]]; then
      grn "All good. Force one detector run now:  ./install_launchd.sh run detect"
    else
      red "Problems found above. Run:  ./install_launchd.sh doctor"
    fi
    ;;

  uninstall)
    for p in "$DET" "$RES"; do
      bootout_one "$p"
      rm -f "$AGENTS/$p.plist"
      echo "removed: $p"
    done
    ;;

  run)
    label="$DET"; [[ "$arg" == "reset" ]] && label="$RES"
    bold "Kickstarting $label (bypasses throttle)..."
    launchctl kickstart -kp "$DOMAIN/$label" || {
      red "kickstart failed — service may not be loaded. Try: ./install_launchd.sh install"; exit 1; }
    sleep 5
    echo; bold "--- last 8 lines of optimizer.log ---"
    tail -n 8 "$DIR/data/optimizer.log" 2>/dev/null || echo "(no optimizer.log yet)"
    echo; bold "--- launchd stderr for this job ---"
    cat "$DIR/data/launchd.$( [[ $label == $RES ]] && echo reset || echo detector).err" 2>/dev/null || echo "(none)"
    ;;

  status)
    for p in "$DET" "$RES"; do
      bold "== $p =="
      launchctl print "$DOMAIN/$p" 2>/dev/null | grep -E 'state =|last exit code =|program =|path =' || echo "  not loaded in $DOMAIN"
      echo
    done
    ;;

  doctor)
    bold "1) This folder"; echo "   $DIR"; warn_if_protected
    bold "2) Installed plist path VALUES (want your real folder, not Desktop/__DIR__)"
    for p in "$DET" "$RES"; do
      echo "   $p:"
      grep -E '<string>' "$AGENTS/$p.plist" 2>/dev/null | grep -E '/|__DIR__' | sed 's/^/      /' || echo "      (not installed)"
    done
    echo
    bold "3) plist validity + perms (must be user-owned, not world-writable)"
    for p in "$DET" "$RES"; do
      plutil -lint "$AGENTS/$p.plist" 2>/dev/null | sed 's/^/   /' || echo "   $p: missing"
      ls -l "$AGENTS/$p.plist" 2>/dev/null | sed 's/^/   /' || true
    done
    echo
    bold "4) launchd service state"
    for p in "$DET" "$RES"; do
      if launchctl print "$DOMAIN/$p" >/dev/null 2>&1; then
        echo "   $p:"; launchctl print "$DOMAIN/$p" | grep -E 'state =|last exit code =|program =|arguments|path =' | sed 's/^/      /'
      else
        echo "   $p: NOT in $DOMAIN"
      fi
    done
    echo
    bold "5) quarantine attrs on this folder (want none)"
    xattr -lr "$DIR" 2>/dev/null | grep -i quarantine | sed 's/^/   /' || echo "   none"
    echo
    bold "6) data/ contents + logs"
    ls -la "$DIR/data" 2>/dev/null | sed 's/^/   /' || echo "   no data/ dir"
    echo "   --- launchd.detector.err ---"; cat "$DIR/data/launchd.detector.err" 2>/dev/null | sed 's/^/   /' || echo "   (none)"
    echo "   --- optimizer.log (tail) ---"; tail -n 5 "$DIR/data/optimizer.log" 2>/dev/null | sed 's/^/   /' || echo "   (none)"
    echo
    bold "7) recent launchd unified logs (last 5m)"
    log show --last 5m --style compact --predicate 'process == "launchd"' 2>/dev/null | grep -i metricoptimizer | sed 's/^/   /' || echo "   (none / not available)"
    ;;

  *)
    echo "usage: ./install_launchd.sh {install [--dry-run]|uninstall|run [detect|reset]|status|doctor}" >&2
    exit 2
    ;;
esac
