#!/usr/bin/env bash
# fix-snap-print.sh — diagnose & bypass the broken cups-snap proxy backend.
#
# THE PROBLEM
#   On systems with BOTH a classic (deb) CUPS daemon and the OpenPrinting
#   `cups` snap (pulled in automatically by snap browsers like chromium),
#   snap-confined apps print through the snap's own cupsd, which runs in
#   "proxy mode": its queues forward jobs to the system cupsd via the
#   /snap/cups/*/lib/cups/backend/proxy backend.
#
#   That backend can fail persistently with:
#       "Could not create job on the system's CUPS daemon - No such file or directory"
#   while root-owned cups-proxyd talks to the very same socket just fine.
#   Result: you hit Print in chromium, the dialog closes, NOTHING happens,
#   no error is shown, and the job sits invisible in the snap cupsd queue.
#   Restarting the cups snap does NOT fix it (verified 2026-07-28,
#   cups snap 2.4.19-2 rev 1229, Ubuntu 24.04).
#
# THE FIX (workaround)
#   Create a SECOND queue on the SNAP cupsd that talks IPP-Everywhere
#   DIRECTLY to the network printer, skipping the broken proxy hop:
#       chromium(snap) -> snap cupsd -> ipps://PRINTER:631 -> paper
#   cups-proxyd only manages its own mirrored queues (it tags their PPDs),
#   so it leaves the direct queue alone.
#
# USAGE
#   ./fix-snap-print.sh diagnose            # read-only health check
#   ./fix-snap-print.sh fix [URI] [NAME]    # create direct queue (sudo)
#   ./fix-snap-print.sh test [NAME]         # test print via the snap path
#   ./fix-snap-print.sh remove [NAME]       # remove the direct queue (sudo)
#
#   URI  defaults to the first printer found by `driverless`
#   NAME defaults to <printer-host>_DIRECT
set -u

SNAP_SOCK=/var/snap/cups/common/run/cups.sock
SIG_ERROR="Could not create job on the system's CUPS daemon"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
warn()  { printf '\033[33m%s\033[0m\n' "$*"; }

snap_lpstat() { CUPS_SERVER="$SNAP_SOCK" lpstat "$@" 2>&1; }

require_snap_cups() {
  if ! snap list cups >/dev/null 2>&1; then
    red "cups snap not installed — this tool targets the snap-proxy failure mode."
    exit 1
  fi
  if [ ! -S "$SNAP_SOCK" ]; then
    red "snap cupsd socket not found at $SNAP_SOCK"
    exit 1
  fi
}

discover_uri() {
  # First driverless (IPP-Everywhere) printer on the network.
  timeout 15 driverless 2>/dev/null | head -1
}

default_name() {
  # ipps://NPIC2312C.local:631/ipp/print                          -> NPIC2312C_DIRECT
  # ipps://HP%20Color%20LaserJet...(C2312C)._ipps._tcp.local/     -> HP_Color_LaserJet_C2312C_DIRECT-ish
  local host
  host=$(printf '%s' "$1" | sed -E 's#^[a-z]+://([^:/]+).*#\1#')
  host=$(printf '%s' "$host" | sed -E 's/%[0-9A-Fa-f]{2}/_/g; s/\._ipps?\._tcp.*$//; s/\.local$//')
  host=$(printf '%s' "$host" | tr -c 'A-Za-z0-9' '_' | sed -E 's/_+/_/g; s/^_+//; s/_+$//' | cut -c1-32)
  printf '%s_DIRECT' "${host:-PRINTER}"
}

cmd_diagnose() {
  require_snap_cups
  echo "== snap cups =="
  snap list cups | tail -1
  pgrep -a cups-proxyd >/dev/null && green "cups-proxyd running (PROXY MODE: snap forwards to system cupsd)" \
                                  || warn  "cups-proxyd not running (standalone mode)"
  echo
  echo "== system cupsd =="
  if [ -S /run/cups/cups.sock ]; then green "system socket /run/cups/cups.sock present"; else warn "no system cupsd socket"; fi
  echo
  echo "== queues on the SNAP cupsd (what snap apps actually see) =="
  snap_lpstat -v
  echo
  echo "== stuck jobs / signature error =="
  local jobs; jobs=$(snap_lpstat -l -o)
  if [ -z "$jobs" ]; then green "no jobs stuck in the snap queue"; else printf '%s\n' "$jobs" | head -20; fi
  if printf '%s' "$jobs" | grep -q "$SIG_ERROR"; then
    red  ">>> SIGNATURE ERROR PRESENT: the snap proxy backend is broken on this box."
    red  ">>> Run: $0 fix"
  fi
  echo
  echo "== driverless printers discovered on the network =="
  timeout 15 driverless 2>/dev/null || warn "driverless found nothing (printer off / different subnet?)"
}

cmd_fix() {
  require_snap_cups
  local uri="${1:-}" name="${2:-}"
  [ -z "$uri" ] && uri=$(discover_uri)
  if [ -z "$uri" ]; then
    red "No printer URI given and driverless discovery found nothing."
    red "Usage: $0 fix ipps://<printer-host>:631/ipp/print [QUEUE_NAME]"
    exit 1
  fi
  [ -z "$name" ] && name=$(default_name "$uri")
  if [ "$(id -u)" -ne 0 ]; then
    warn "lpadmin on the snap cupsd needs root — re-running with sudo…"
    exec sudo "$0" fix "$uri" "$name"
  fi
  echo "Creating direct queue '$name' -> $uri on the snap cupsd…"
  export CUPS_SERVER="$SNAP_SOCK"
  lpadmin -p "$name" -v "$uri" -m everywhere -o printer-is-shared=false
  cupsenable "$name"
  cupsaccept "$name"
  lpstat -v "$name"
  green "Done. In your snap browser's print dialog pick '$name' ONCE — it will be remembered."
}

cmd_test() {
  require_snap_cups
  local name="${1:-}"
  if [ -z "$name" ]; then
    name=$(snap_lpstat -v | grep -o '^device for [A-Za-z0-9_]*_DIRECT' | head -1 | awk '{print $3}')
  fi
  if [ -z "$name" ]; then red "No *_DIRECT queue found — run '$0 fix' first."; exit 1; fi
  echo "test print via snap socket -> $name — $(date '+%H:%M:%S')" | CUPS_SERVER="$SNAP_SOCK" lp -d "$name" || exit 1
  echo "Waiting for completion…"
  for _ in $(seq 1 12); do
    if [ -z "$(snap_lpstat -o | grep "^$name-")" ]; then green "COMPLETED — check the printer tray."; exit 0; fi
    sleep 5
  done
  red "Job still queued after 60 s:"; snap_lpstat -l -o | head -8; exit 1
}

cmd_remove() {
  require_snap_cups
  local name="${1:-}"
  [ -z "$name" ] && { red "Usage: $0 remove QUEUE_NAME"; exit 1; }
  if [ "$(id -u)" -ne 0 ]; then exec sudo "$0" remove "$name"; fi
  CUPS_SERVER="$SNAP_SOCK" lpadmin -x "$name" && green "Removed '$name'."
}

case "${1:-}" in
  diagnose) cmd_diagnose ;;
  fix)      shift; cmd_fix "$@" ;;
  test)     shift; cmd_test "$@" ;;
  remove)   shift; cmd_remove "$@" ;;
  *) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
