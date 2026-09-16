# snap-cups-direct-print

**Fix silent print failures from snap-packaged browsers (chromium, firefox) on Ubuntu — bypass the broken cups-snap proxy backend with a direct IPP-Everywhere queue.**

## The symptom

You hit **Print** in chromium (snap). The dialog closes. **Nothing prints. No error.**
Meanwhile a plain `lp file.pdf` from the terminal prints fine.

The job is not lost — it is stuck, invisibly, inside the **cups snap's own cupsd**:

```
$ CUPS_SERVER=/var/snap/cups/common/run/cups.sock lpstat -l -o
HP_Color_LaserJet_MFP_M283fdw_C2312C-1  user  48128  Tue 28 Jul 2026 07:27:45
    Status: Could not create job on the system's CUPS daemon - No such file or directory
    Alerts: resources-are-not-ready
```

## Why it happens

On Ubuntu, snap browsers don't talk to your system CUPS directly. The `cups` snap
(installed automatically as a dependency) runs its **own cupsd in "proxy mode"**:

```
chromium(snap) ──> snap cupsd ──> [proxy backend] ──> system cupsd ──> printer
                                       ^^^
                                  breaks here
```

The `proxy` backend (`/snap/cups/*/lib/cups/backend/proxy`) can persistently fail to
create jobs on the system daemon (`ENOENT`), even though:

- the system socket `/run/cups/cups.sock` exists, is world-writable, and **is visible
  inside the snap's mount namespace** (verified with `nsenter -m stat`),
- root-owned `cups-proxyd` in the *same* snap talks to the *same* socket just fine,
- AppArmor explicitly allows `/run/cups/** rwk` for the snap profile.

Restarting the snap (`sudo snap restart cups`) rebuilds the mirrored queue but does
**not** fix job forwarding. Observed on cups snap `2.4.19-2` (rev 1229), Ubuntu 24.04,
2026-07-28, with no newer stable revision available.

## The fix

Don't fight the proxy — go around it. Create a **second queue on the snap cupsd**
that speaks IPP Everywhere **directly to the network printer**:

```
chromium(snap) ──> snap cupsd ──> ipps://PRINTER:631/ipp/print ──> paper
```

The queue persists across reboots like any CUPS queue — **but NOT across a refresh of
the `cups` snap.** Measured on this box: the queue created 2026-07-28 08:05 was
`deleted by "root"` on 2026-07-31 22:53:43, the same second `/var/snap/cups/current`
flipped from rev 1229 to 1238. From then on the browser silently fell back to the
broken mirrored queue and Print went dead again (noticed 2026-09-16). After every
cups snap refresh, run `./fix-snap-print.sh diagnose` and re-run `fix` if the
`*_DIRECT` queue is missing. The queue is visible from the host with:

```bash
lpstat -h /var/snap/cups/common/run/cups.sock -v
```

## Usage

```bash
./fix-snap-print.sh diagnose      # read-only: confirm you have this exact failure
./fix-snap-print.sh fix           # auto-discover printer, create <HOST>_DIRECT queue (sudo)
./fix-snap-print.sh test          # push a test page through the snap path
```

Then in the browser's print dialog pick the `*_DIRECT` printer **once** —
chromium remembers the last-used destination, so from now on Print just works.

Explicit URI / name:

```bash
./fix-snap-print.sh fix ipps://NPIC2312C.local:631/ipp/print HP_M283_DIRECT
./fix-snap-print.sh remove HP_M283_DIRECT   # undo
```

## Requirements

- `cups` snap present (that's the broken layer this bypasses)
- a network printer supporting IPP Everywhere / driverless (any AirPrint-era device;
  discovery via `driverless`, part of `cups-filters`)

## Caveats

- The old mirrored queue stays in the printer list (the proxy daemon would recreate
  it anyway) — just don't pick it.
- If your printer is USB-only, driverless discovery won't find it; this workaround
  targets network printers.
- Rescuing a job already stuck in the snap queue: no need to dig in the spool — move
  it onto the direct queue and release the hold (as root):
  ```bash
  export CUPS_SERVER=/var/snap/cups/common/run/cups.sock
  lpmove HP_Color_LaserJet_MFP_M283fdw_C2312C-6 HP_M283_DIRECT
  lp -i 6 -H resume
  ```
  (verified 2026-09-16: the moved job went straight to the printer).

## License

MIT
