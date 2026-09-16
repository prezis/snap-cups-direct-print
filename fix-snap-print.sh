#!/usr/bin/env bash
# fix-snap-print.sh — make printing from snap browsers work, and keep it working.
#
# ROOT CAUSE (diagnosed 2026-09-16 from source + a live A/B on /dev/null queues)
#   Snap apps (chromium, firefox) print into the `cups` SNAP's own cupsd, which
#   forwards each job to the system cupsd through its `proxy` backend. That
#   backend stores the target queue name in `char resource[32]`
#   (OpenPrinting/cups-snap, cups-proxyd/proxy.c:53): names longer than 30
#   characters are silently truncated, the queue is not found, and the job is
#   held and retried forever with the misleading
#       "Could not create job on the system's CUPS daemon - No such file or directory".
#   cups-browsed names network printers after their DNS-SD name, which is often
#   longer (HP_Color_LaserJet_MFP_M283fdw_C2312C = 36). Nothing is shown to you.
#
# THE FIX
#   1. A PERMANENT queue with a SHORT name (<= 30 chars) on the SYSTEM cupsd.
#      cups-proxyd mirrors every system queue into the snap on each start, so
#      this survives snap refreshes and reboots.
#      (The previous version of this tool created the queue inside the snap
#      cupsd instead; cups-proxyd deletes such queues on its next start, which
#      silently broke printing again after the 2026-07-31 snap refresh.)
#   2. snap-print-guard, a systemd --user timer (every 60 s): recreates the
#      queue if it disappears, moves jobs stuck on a broken queue of the SAME
#      printer onto the short one, and shows a desktop notification whenever it
#      acts or a job cannot print. No root needed.
#
# USAGE
#   ./fix-snap-print.sh diagnose                 # read-only health check
#   ./fix-snap-print.sh fix [URI] [NAME] [TOKEN] # system queue + guard
#   ./fix-snap-print.sh install-guard            # (re)install the guard only
#   ./fix-snap-print.sh uninstall-guard
#   ./fix-snap-print.sh test [NAME]              # PRINTS A PAGE through the snap path
#   ./fix-snap-print.sh remove NAME              # delete the system queue
#
#   URI  defaults to the first printer found by `driverless`
#   NAME defaults to HP_M283_DIRECT; must be <= 30 characters
#   TOKEN substring unique to this printer (e.g. serial), used so the guard only
#         moves jobs between queues of the SAME device; default C2312C
#   The choice is saved to ~/.config/snap-print-guard.env for the guard.
set -u

SNAP_SOCK=/var/snap/cups/common/run/cups.sock
SYS_SOCK=/run/cups/cups.sock
DEFAULT_NAME=HP_M283_DIRECT
DEFAULT_TOKEN=C2312C   # serial suffix HP puts in both its hostname and DNS-SD name
NAME_LIMIT=30
GUARD_ENV="$HOME/.config/snap-print-guard.env"
HERE=$(cd "$(dirname "$0")" && pwd)
UNIT_DIR="$HOME/.config/systemd/user"
GUARD_BIN="$HOME/.local/bin/snap-print-guard"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
warn()  { printf '\033[33m%s\033[0m\n' "$*"; }

sys_lp()  { CUPS_SERVER="$SYS_SOCK" "$@"; }
snap_lp() { CUPS_SERVER="$SNAP_SOCK" "$@"; }

cmd_diagnose() {
  echo "== cups snap =="
  if snap list cups >/dev/null 2>&1; then
    snap list cups | tail -1
    pgrep -x cups-proxyd >/dev/null && green "cups-proxyd running (snap apps print through the proxy)" \
                                    || warn  "cups-proxyd not running"
  else
    green "no cups snap — this failure mode does not apply"; return 0
  fi
  echo
  echo "== queues snap apps see, and whether the proxy can reach them =="
  local queues
  if ! queues=$(snap_lp lpstat -v 2>/dev/null); then
    red "  cannot read the snap cupsd ($SNAP_SOCK) — is the cups snap running?"
  fi
  printf '%s\n' "$queues" | grep '^device for ' | while read -r _ _ q uri; do
    q=${q%:}; target=${uri##*/}
    case "$uri" in
      proxy://*) if [ "${#target}" -gt "$NAME_LIMIT" ]; then
                   red   "  BROKEN  $q  (system name has ${#target} chars > $NAME_LIMIT)"
                 else
                   green "  ok      $q"
                 fi ;;
      *)         warn  "  local   $q -> $uri (deleted by cups-proxyd on its next start)" ;;
    esac
  done
  echo
  echo "== jobs waiting inside the snap cupsd (should be empty) =="
  local jobs
  if ! jobs=$(snap_lp lpstat -l -o 2>/dev/null); then
    red "cannot list jobs on the snap cupsd"
  elif [ -z "$jobs" ]; then
    green "none"
  else
    printf '%s\n' "$jobs" | head -20
  fi
  echo
  echo "== guard =="
  systemctl --user is-active snap-print-guard.timer >/dev/null 2>&1 \
    && green "snap-print-guard.timer active" || red "snap-print-guard.timer NOT active — run: $0 install-guard"
  journalctl --user -u snap-print-guard -n 5 --no-pager 2>/dev/null | tail -5
  echo
  echo "== driverless printers on the network =="
  timeout 15 driverless 2>/dev/null || warn "driverless found nothing (printer off / different subnet?)"
}

refuse_root() {
  # The guard is a per-user service: under sudo it would land in /root and never run.
  if [ "$(id -u)" -eq 0 ]; then
    red "Run this as your normal desktop user, not root/sudo (it needs your lpadmin group and your session)."; exit 1
  fi
}

cmd_install_guard() {
  refuse_root
  if ! /usr/bin/python3 -c 'import cups' 2>/dev/null; then
    red "python3-cups (pycups) is missing: sudo apt install python3-cups"; exit 1
  fi
  install -Dm755 "$HERE/snap-print-guard.py" "$GUARD_BIN" \
    && install -Dm644 "$HERE/systemd/snap-print-guard.service" "$UNIT_DIR/snap-print-guard.service" \
    && install -Dm644 "$HERE/systemd/snap-print-guard.timer"   "$UNIT_DIR/snap-print-guard.timer" \
    && systemctl --user daemon-reload \
    && systemctl --user enable --now snap-print-guard.timer \
    && systemctl --user start snap-print-guard.service \
    || { red "Guard installation failed (see the error above)."; exit 1; }
  systemctl --user --no-pager status snap-print-guard.timer | head -4
  green "Guard installed. Logs: journalctl --user -u snap-print-guard"
}

cmd_uninstall_guard() {
  systemctl --user disable --now snap-print-guard.timer 2>/dev/null
  rm -f "$UNIT_DIR/snap-print-guard.service" "$UNIT_DIR/snap-print-guard.timer" "$GUARD_BIN"
  systemctl --user daemon-reload
  green "Guard removed."
}

cmd_fix() {
  refuse_root
  local uri="${1:-}" name="${2:-$DEFAULT_NAME}" token="${3:-}"
  if [ -z "$token" ]; then
    if [ "$name" = "$DEFAULT_NAME" ]; then
      token=$DEFAULT_TOKEN
    else
      token=$name
      warn "No TOKEN given: stuck jobs are only moved from queues whose name contains '$token'."
      warn "Pass a substring unique to this printer (e.g. its serial) as the 3rd argument to cover its auto-created queue."
    fi
  fi
  if [ "${#name}" -gt "$NAME_LIMIT" ]; then
    red "Queue name '$name' has ${#name} chars; the snap proxy keeps only $NAME_LIMIT."; exit 1
  fi
  [ -z "$uri" ] && uri=$(timeout 15 driverless 2>/dev/null | head -1)
  if [ -z "$uri" ]; then
    red "No printer URI given and driverless discovery found nothing."
    red "Usage: $0 fix ipps://<printer-host>:631/ipp/print [NAME]"; exit 1
  fi
  echo "Creating SYSTEM queue '$name' -> $uri"
  if ! sys_lp lpadmin -p "$name" -E -v "$uri" -m everywhere \
        -o printer-error-policy=retry-job -o printer-is-shared=false; then
    red "lpadmin failed. Your user must be in the lpadmin group: sudo usermod -aG lpadmin \$USER, then log in again."; exit 1
  fi
  sys_lp lpadmin -d "$name" || warn "could not make '$name' the default printer"
  mkdir -p "$(dirname "$GUARD_ENV")"
  printf 'SPG_QUEUE=%s\nSPG_URI=%s\nSPG_TOKEN=%s\n' "$name" "$uri" "$token" > "$GUARD_ENV"
  echo "Guard settings -> $GUARD_ENV"
  echo "Waiting for cups-proxyd to mirror it into the snap…"
  for _ in $(seq 1 30); do
    snap_lp lpstat -v 2>/dev/null | grep -q "^device for $name: proxy://" && break
    sleep 1
  done
  snap_lp lpstat -v "$name" 2>&1
  cmd_install_guard
  green "Done. In the browser's print dialog choose '$name' once — it is remembered."
}

cmd_test() {
  local name="${1:-$DEFAULT_NAME}"
  warn "This prints a real page on '$name' through the snap path."
  echo "snap-print test -> $name — $(date '+%H:%M:%S')" | snap_lp lp -d "$name" || exit 1
  for _ in $(seq 1 12); do
    if [ -z "$(snap_lp lpstat -o 2>/dev/null | grep "^$name-")" ]; then
      green "Left the snap layer — check the printer tray."; exit 0
    fi
    sleep 5
  done
  red "Still inside the snap cupsd after 60 s:"; snap_lp lpstat -l -o | head -8; exit 1
}

cmd_remove() {
  local name="${1:-}"
  [ -z "$name" ] && { red "Usage: $0 remove NAME"; exit 1; }
  local guarded=$DEFAULT_NAME
  [ -f "$GUARD_ENV" ] && guarded=$(sed -n 's/^SPG_QUEUE=//p' "$GUARD_ENV")
  if [ "$name" = "${guarded:-$DEFAULT_NAME}" ] && [ -f "$UNIT_DIR/snap-print-guard.timer" ]; then
    warn "'$name' is the queue the guard maintains; removing the guard first, or it would recreate the queue within a minute."
    cmd_uninstall_guard
  fi
  sys_lp lpadmin -x "$name" && green "Removed system queue '$name' (cups-proxyd drops the mirror)."
}

case "${1:-}" in
  diagnose)        cmd_diagnose ;;
  fix)             shift; cmd_fix "$@" ;;
  install-guard)   cmd_install_guard ;;
  uninstall-guard) cmd_uninstall_guard ;;
  test)            shift; cmd_test "$@" ;;
  remove)          shift; cmd_remove "$@" ;;
  *) sed -n '2,/^set -u/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
