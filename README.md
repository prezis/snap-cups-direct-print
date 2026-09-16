# snap-cups-direct-print

**Fix silent print failures from snap browsers (chromium, firefox) on Ubuntu — and keep them fixed across snap refreshes, with no human in the loop.**

## The symptom

You hit **Print** in chromium (snap). The dialog closes. **Nothing prints. No error.**
A plain `lp file.pdf` from the terminal prints fine.

The job is not lost. It sits, invisibly, inside the **cups snap's own cupsd**:

```
$ lpstat -h /var/snap/cups/common/run/cups.sock -l -o
HP_Color_LaserJet_MFP_M283fdw_C2312C-5  user  102400  Wed 16 Sep 2026 12:30:53
    Status: Could not create job on the system's CUPS daemon - No such file or directory
```

## Root cause

Snap apps never talk to the system cupsd. They print into the `cups` snap's cupsd,
which runs in proxy mode and forwards each job through its `proxy` backend:

```
chromium(snap) ──> snap cupsd ──> [proxy backend] ──> system cupsd ──> printer
```

The backend reads the target queue name into a **32-byte buffer**
([`cups-snap/cups-proxyd/proxy.c:53`](https://github.com/OpenPrinting/cups-snap/blob/master/cups-proxyd/proxy.c),
`char ... resource[32]`, holding `"/" + name + NUL`). **Any system queue name longer
than 30 characters is silently truncated.** `cupsCreateJob()` then looks up a queue
that does not exist and fails. The "No such file or directory" text is a stale
`errno` left behind by that failed lookup, not a missing socket (that was a red
herring in the first version of this repo).

cups-browsed names network printers after their DNS-SD service name, which is easily
over 30 characters. For example, `HP_Color_LaserJet_MFP_M283fdw_C2312C` is 36, so the
backend asks for `HP_Color_LaserJet_MFP_M283fdw_`.

**Proof (2026-09-16, cups snap 2.4.19-2 rev 1238):** two system queues, identical
except for name length, both `file:///dev/null`, jobs sent through the snap socket:

| system queue | length | name the backend used | result |
|---|---|---|---|
| `ZZ_PROXYTEST_SHORT` | 18 | `ZZ_PROXYTEST_SHORT` | forwarded, completed |
| `ZZ_PROXYTEST_LONG_NAME_OVER_30_CHARS` | 36 | `ZZ_PROXYTEST_LONG_NAME_OVER_30` | held, same error as above |

The buffer is still 32 bytes on `master`, so a snap refresh will not fix it.

## The fix

1. **A permanent queue with a short name on the SYSTEM cupsd.** cups-proxyd mirrors
   every system queue into the snap every time it starts, so the mirror survives snap
   refreshes and reboots. Verified with `snap restart cups`: the mirror was back
   within 2 s.
2. **`snap-print-guard`**, a `systemd --user` timer that runs every 60 s. No root is
   needed.
   - **ensure**: recreates the system queue if it disappears, and re-enables it if it
     is stopped or rejecting jobs.
   - **mirror**: re-triggers cups-proxyd when the snap has no working mirror. Its first
     clone can lose a race with PPD generation.
   - **rescue**: a job pending or held by CUPS inside the snap for more than 45 s never
     reached the system, so the guard moves it onto the short queue and releases it.
     It only does this for queues of the **same physical printer** (matched by a
     token, see `same_printer()`). A job for another printer only raises a
     notification, so it can never print on the wrong device. Jobs a person held on
     purpose (`job-hold-until` ≠ `no-hold`) are left alone.
   - **watch**: shows a desktop notification when a job waits on the working queue
     (printer off, no paper), instead of failing silently.

### Why not a queue inside the snap (the v1 approach)

v1 created the direct queue on the snap cupsd. **cups-proxyd deletes, on start, every
snap queue that does not exist on the system** (`cups-proxyd.c:993-1007`). Measured:
`HP_M283_DIRECT` was removed at 2026-07-31 22:53:43, the same second the cups snap
refreshed 1229 → 1238, and printing silently broke again until 2026-09-16.

## Usage

```bash
./fix-snap-print.sh diagnose          # read-only: flags every snap queue the proxy cannot reach
./fix-snap-print.sh fix               # discover printer, create short system queue, install guard
./fix-snap-print.sh fix ipps://NPIC2312C.local:631/ipp/print HP_M283_DIRECT
./fix-snap-print.sh install-guard     # guard only
./fix-snap-print.sh test              # prints a real page through the snap path
```

In the browser's print dialog, pick the short queue **once**. Chromium remembers it.
If you pick the long one later anyway, the guard moves the job within about 1–2 min
and tells you.

For another printer: `./fix-snap-print.sh fix <URI> <NAME≤30> <TOKEN>`, where TOKEN is a substring unique to
`DEFAULT_URI` and `DEFAULT_TOKEN` in `snap-print-guard.py`, or pass
`--queue/--uri/--token` in the unit's `ExecStart`.

Logs: `journalctl --user -u snap-print-guard`. The guard is silent unless it acts.

## Requirements

- the `cups` snap (the broken layer) plus a system cupsd
- your user in the `lpadmin` group (default for the first Ubuntu user)
- `python3-cups` (pycups), `notify-send`
- a network printer with IPP Everywhere / driverless support

## Upstream

The real fix belongs in `proxy.c`: size `resource` like `HTTP_MAX_URI`, as
`cups-proxyd.c` already does for its own copy.

## License

MIT
