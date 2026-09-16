#!/usr/bin/python3
"""snap-print-guard — keep printing from snap apps working with no human in the loop.

WHY (diagnosed 2026-09-16 from source + a live A/B on /dev/null queues)
  Snap apps (chromium, ...) never talk to the system cupsd. They print into the
  cups SNAP's own cupsd, which forwards each job to the system cupsd through the
  `proxy` backend. That backend copies the target queue name into
  `char resource[32]` (OpenPrinting/cups-snap, cups-proxyd/proxy.c:53), so a
  system queue name longer than 30 characters is silently truncated, the lookup
  fails, and the job is held and retried forever with the misleading
      "Could not create job on the system's CUPS daemon - No such file or directory".
  cups-browsed names network printers after their DNS-SD name, which is easily
  longer than that (HP_Color_LaserJet_MFP_M283fdw_C2312C = 36 characters).

  The durable fix is a PERMANENT queue with a SHORT name on the SYSTEM cupsd.
  cups-proxyd mirrors every system queue into the snap on each start, so the
  mirror survives snap refreshes and reboots. A queue created only inside the
  snap does not: cups-proxyd deletes it on its next start ("Queue X disappeared
  on the system, removing it from proxy", cups-proxyd.c:1003 — it happened to
  HP_M283_DIRECT at the 2026-07-31 22:53:43 refresh).

WHAT EACH RUN DOES (idempotent; silent unless it acts)
  ensure  the short system queue exists, is enabled and accepts jobs.
  rescue  a job that sits pending/held in the SNAP cupsd for longer than
          STUCK_AFTER never reached the system (a successful forward completes
          the snap-side job within seconds). Move it onto the short queue and
          release it. Classified by job STATE, not by error text, so it also
          covers failure modes other than the name truncation.
  watch   a job that waits on the working queue itself (printer off, no paper)
          produces a desktop notification instead of a silent wait.
"""

import argparse
import json
import os
import subprocess
import sys
import time
import traceback

import cups

SNAP_SOCK = "/var/snap/cups/common/run/cups.sock"
SYSTEM_SOCK = "/run/cups/cups.sock"
DEFAULT_QUEUE = "HP_M283_DIRECT"
DEFAULT_URI = "ipps://NPIC2312C.local:631/ipp/print"
DEFAULT_TOKEN = "C2312C"   # see same_printer()
QUEUE_INFO = "HP M283fdw (works from every app, incl. snap)"

# proxy.c: char resource[32] holds "/" + name + NUL -> at most 30 name chars survive.
PROXY_NAME_LIMIT = 30

STUCK_AFTER = 45               # s in the snap layer before a job counts as not forwarded
WAIT_NOTIFY_AFTER = 180        # s pending/held on the working system queue -> notify
PROCESSING_NOTIFY_AFTER = 600  # s still processing on the working system queue -> notify
NOTIFY_TTL = 3600              # s before the same condition is announced again
STATE_KEEP = 7 * 86400         # s to remember announced conditions
MIRROR_NUDGE_EVERY = 300       # s between nudges of cups-proxyd for a missing mirror

JOB_PENDING, JOB_HELD, JOB_PROCESSING = 3, 4, 5
PRINTER_STOPPED = 5

JOB_ATTRS = [
    "job-id", "job-state", "job-state-reasons", "time-at-creation", "job-printer-uri",
    "job-originating-user-name", "job-name", "job-printer-state-message",
    "job-hold-until",
]


def log(msg):
    print(msg, flush=True)


# ---------------------------------------------------------------- state / notify

def state_file():
    base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return os.path.join(base, "snap-print-guard", "state.json")


def load_state():
    try:
        with open(state_file()) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    # A hand-edited or half-written file must not crash every future run.
    return {k: v for k, v in data.items() if isinstance(v, (int, float))}


def save_state(state, now):
    state = {k: v for k, v in state.items() if now - v < STATE_KEEP}
    path = state_file()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"  # a manual run may race the timer
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, path)


def first_time(state, key, now):
    """True if `key` was not announced within NOTIFY_TTL; records it."""
    last = state.get(key)
    if last is not None and now - last < NOTIFY_TTL:
        return False
    state[key] = now
    return True


def notify(title, body, dry):
    log(f"notify: {title} | {body}")
    if dry:
        return
    env = dict(os.environ)
    env.setdefault("DBUS_SESSION_BUS_ADDRESS", f"unix:path=/run/user/{os.getuid()}/bus")
    try:
        subprocess.run(
            ["notify-send", "-a", "Drukarka", "-i", "printer", title, body],
            env=env, timeout=10, check=False,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        log(f"notify-send failed: {exc}")


# ---------------------------------------------------------------- helpers

def same_printer(name, attrs, token):
    """Is system queue `name` the physical printer this guard owns?

    HP embeds the last six hex digits of the printer's MAC in both its hostname
    (NPIC2312C) and its DNS-SD service name ("HP Color LaserJet MFP M283fdw
    (C2312C)"), and cups-browsed builds the queue name and printer-info from
    that service name. The token therefore identifies the device no matter how
    cups-browsed decorates the queue name (e.g. a "-2" collision suffix)."""
    token = token.lower()
    info = str((attrs or {}).get("printer-info", "")).lower()
    return token in name.lower() or token in info


def reasons_of(obj, key):
    value = obj.get(key, [])
    return [value] if isinstance(value, str) else list(value)


def held_by_cups_not_by_a_person(job):
    """A job CUPS itself parks after a failed backend run keeps job-hold-until
    'no-hold' (measured: retry-held snap job 11 -> 'no-hold', reasons
    'resources-are-not-ready'). A person's hold sets a keyword or a time
    ('indefinite', 'night', '23:00', ...), and must be left alone."""
    return job.get("job-hold-until", "no-hold") == "no-hold"


def label_of(job):
    # job-name is a private value the cupsd hides over the local socket even
    # for the owner (measured), so fall back to when the job was sent.
    name = job.get("job-name")
    if name:
        return f"„{name}”"
    try:
        return "wydruk z " + time.strftime("%H:%M", time.localtime(int(job["time-at-creation"])))
    except (KeyError, TypeError, ValueError):
        return "wydruk"


def queue_of(job):
    return str(job.get("job-printer-uri", "")).rstrip("/").rsplit("/", 1)[-1]


def age_of(job, now):
    try:
        return now - int(job.get("time-at-creation", now))
    except (TypeError, ValueError):
        return 0


def minutes(seconds):
    return max(1, round(seconds / 60))


# ---------------------------------------------------------------- steps

def ensure(sysc, queue, uri, dry, state, now):
    printer = sysc.getPrinters().get(queue)
    if printer is None:
        log(f"ensure: system queue {queue} missing -> creating it for {uri}")
        if dry:
            return
        cmd = [
            "lpadmin", "-h", SYSTEM_SOCK, "-p", queue, "-E", "-v", uri,
            "-m", "everywhere",
            "-o", "printer-error-policy=retry-job",
            "-o", "printer-is-shared=false",
            "-D", QUEUE_INFO,
        ]
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        if res.returncode != 0:
            err = (res.stderr or res.stdout).strip()[:200]
            log(f"ensure: lpadmin failed rc={res.returncode}: {err}")
            if first_time(state, "ensure-failed", now):
                notify("Drukarka: nie mogę założyć kolejki",
                       f"{queue}: {err or 'brak odpowiedzi'} — czy drukarka jest włączona?", dry)
            return
        state.pop("ensure-failed", None)
        default = sysc.getDefault()
        if not default or len(default) > PROXY_NAME_LIMIT:
            sysc.setDefault(queue)
            log(f"ensure: default printer {default!r} -> {queue}")
        log(f"ensure: created {queue}")
        notify("Drukarka: kolejka odtworzona", f"{queue} znów jest dostępna we wszystkich aplikacjach.", dry)
        return

    if printer.get("printer-state") == PRINTER_STOPPED:
        why = printer.get("printer-state-message", "")
        log(f"ensure: {queue} is stopped ({why!r}) -> enabling")
        if not dry:
            sysc.enablePrinter(queue)
        if first_time(state, f"stopped:{queue}", now):
            notify("Drukarka była zatrzymana", f"{queue} włączona ponownie. Powód: {why or 'brak'}", dry)
    # getPrinters() carries no printer-is-accepting-jobs; the REJECTING bit of
    # printer-type is the same fact (verified 2026-09-16).
    if int(printer.get("printer-type", 0)) & cups.CUPS_PRINTER_REJECTING:
        log(f"ensure: {queue} rejects jobs -> accepting")
        if not dry:
            sysc.acceptJobs(queue)


def mirror(sysc, snapc, queue, dry, state, now):
    """cups-proxyd clones a new system queue on the printer-added event, but that
    clone can lose a race with PPD generation (measured 13:06:31: "Unable to load
    PPD ... Bad Request") and is not retried until some other event arrives.
    A harmless modify of the system queue is such an event."""
    if queue not in sysc.getPrinters():
        return  # ensure() could not create it; nothing to mirror
    printer = snapc.getPrinters().get(queue)
    uri = str(printer.get("device-uri", "")) if printer else ""
    if uri.startswith("proxy:"):
        return
    last = state.get("mirror-nudge")
    if last is not None and now - last < MIRROR_NUDGE_EVERY:
        return
    state["mirror-nudge"] = now
    log(f"mirror: snap cupsd has {queue} as {uri or 'nothing'} -> nudging cups-proxyd to re-clone it")
    if dry:
        return
    subprocess.run(["lpadmin", "-h", SYSTEM_SOCK, "-p", queue, "-D", QUEUE_INFO],
                   capture_output=True, text=True, timeout=60)


def stuck_in_snap(job, now):
    """Pending or CUPS-held in the snap layer for longer than a forward takes."""
    state_value = job.get("job-state")
    if age_of(job, now) < STUCK_AFTER:
        return False
    if state_value == JOB_PENDING:
        return "job-incoming" not in reasons_of(job, "job-state-reasons")  # still uploading
    return state_value == JOB_HELD and held_by_cups_not_by_a_person(job)


def rescue(sysc, snapc, queue, token, dry, state, now):
    if queue not in snapc.getPrinters():
        log(f"rescue: {queue} not mirrored into the snap cupsd yet -> skipping this run")
        return
    target = f"ipp://localhost/printers/{queue}"
    system_printers = sysc.getPrinters()
    jobs = snapc.getJobs(which_jobs="not-completed", requested_attributes=JOB_ATTRS)
    moved = []
    for jid in sorted(jobs):
        job = jobs[jid]
        if not stuck_in_snap(job, now):
            continue
        src = queue_of(job)
        label = label_of(job)
        age = age_of(job, now)
        msg = job.get("job-printer-state-message", "")
        if src == queue:
            # The short queue itself does not forward: nothing safe to do automatically.
            if first_time(state, f"snap-stuck:{jid}", now):
                notify("Drukarka: wydruk utknął",
                       f"{label} czeka {minutes(age)} min w warstwie snap ({queue}): {msg or 'brak komunikatu'}", dry)
            continue
        if not same_printer(src, system_printers.get(src), token):
            # Another printer: moving it onto this one would print on the wrong device.
            if first_time(state, f"foreign-stuck:{jid}", now):
                why = (f"nazwa kolejki ma {len(src)} znaków, a aplikacje snap obsługują najwyżej {PROXY_NAME_LIMIT}"
                       if len(src) > PROXY_NAME_LIMIT else (msg or "brak komunikatu"))
                notify("Drukarka: wydruk utknął",
                       f"{label} na {src} nie dotarł do drukarki: {why}. To inna drukarka niż {queue}, więc go nie przenoszę.",
                       dry)
            continue
        log(f"rescue: snap job {jid} on {src} state={job.get('job-state')} age={age}s msg={msg!r} -> {queue}")
        if dry:
            moved.append(label)
            continue
        try:
            # Re-read right before acting: the snap cupsd's own retry may have
            # picked the job up since getJobs(), and moving a job that is being
            # forwarded could leave a partial copy on the system side.
            fresh = snapc.getJobAttributes(jid, requested_attributes=JOB_ATTRS)
            if not stuck_in_snap(fresh, int(time.time())) or queue_of(fresh) != src:
                log(f"rescue: job {jid} changed state before the move -> leaving it")
                continue
            snapc.moveJob(job_id=jid, job_printer_uri=target)
        except cups.IPPError as exc:
            log(f"rescue: job {jid} could not be moved: {exc}")
            if first_time(state, f"rescue-failed:{jid}", now):
                notify("Drukarka: nie mogę przekierować wydruku", f"{label} ({src}): {exc}", dry)
            continue
        moved.append(label)
        if fresh.get("job-state") == JOB_HELD:
            try:
                # Without this the moved job still waits out the snap cupsd's 300 s
                # retry hold (measured: moved job 8 printed only when it expired).
                # pycups has no releaseJob; job-hold-until=no-hold is the release.
                snapc.setJobHoldUntil(jid, "no-hold")
            except cups.IPPError as exc:
                log(f"rescue: job {jid} moved but not released (prints when the hold expires): {exc}")
    if moved:
        notify("Drukarka: wydruk przekierowany",
               f"Wybrana drukarka nie działa z aplikacji snap. Wysłane na {queue}: " + ", ".join(moved)[:200], dry)


def watch(sysc, queue, dry, state, now):
    printer = sysc.getPrinters().get(queue, {})
    jobs = sysc.getJobs(which_jobs="not-completed", requested_attributes=JOB_ATTRS)
    for jid in sorted(jobs):
        job = jobs[jid]
        if queue_of(job) != queue or not held_by_cups_not_by_a_person(job):
            continue
        state_value = job.get("job-state")
        age = age_of(job, now)
        limit = PROCESSING_NOTIFY_AFTER if state_value == JOB_PROCESSING else WAIT_NOTIFY_AFTER
        if age < limit or not first_time(state, f"sys-wait:{jid}", now):
            continue
        reasons = ", ".join(r for r in reasons_of(printer, "printer-state-reasons") if r != "none")
        detail = (printer.get("printer-state-message") or job.get("job-printer-state-message")
                  or reasons or "brak komunikatu")
        notify("Drukarka nie drukuje", f"{label_of(job)} czeka {minutes(age)} min. Drukarka: {detail}", dry)


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--queue", default=DEFAULT_QUEUE)
    ap.add_argument("--uri", default=DEFAULT_URI)
    ap.add_argument("--token", default=DEFAULT_TOKEN,
                    help="substring identifying this printer's other queues (see same_printer)")
    ap.add_argument("--dry-run", action="store_true", help="report, change nothing")
    ap.add_argument("--only", action="append", choices=["ensure", "mirror", "rescue", "watch"])
    args = ap.parse_args()

    if len(args.queue) > PROXY_NAME_LIMIT:
        log(f"refusing: queue name {args.queue!r} has {len(args.queue)} chars; "
            f"the snap proxy backend keeps only {PROXY_NAME_LIMIT}")
        return 2

    steps = args.only or ["ensure", "mirror", "rescue", "watch"]
    now = int(time.time())
    state = load_state()
    rc = 0

    try:
        sysc = cups.Connection(host=SYSTEM_SOCK)
    except RuntimeError as exc:
        log(f"cannot reach system cupsd at {SYSTEM_SOCK}: {exc}")
        return 1

    for step in steps:
        try:
            if step == "ensure":
                ensure(sysc, args.queue, args.uri, args.dry_run, state, now)
            elif step == "watch":
                watch(sysc, args.queue, args.dry_run, state, now)
            elif step in ("mirror", "rescue"):
                if not os.path.exists(SNAP_SOCK):
                    continue  # no cups snap -> nothing to mirror or rescue
                snapc = cups.Connection(host=SNAP_SOCK)
                if step == "mirror":
                    mirror(sysc, snapc, args.queue, args.dry_run, state, now)
                else:
                    rescue(sysc, snapc, args.queue, args.token, args.dry_run, state, now)
        except Exception:  # one broken step must not skip the others or kill the timer run
            log(f"{step}: failed:\n{traceback.format_exc()}")
            rc = 1

    if not args.dry_run:
        save_state(state, now)
    return rc


if __name__ == "__main__":
    sys.exit(main())
