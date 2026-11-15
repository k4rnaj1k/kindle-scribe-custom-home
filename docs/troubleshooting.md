# Troubleshooting — "reading books is broken"

Kindle Scribe, firmware **5.16.6.1**. This is a **stock firmware failure mode**
that k4 Home cannot cause or fix by itself, but every KPP restart (each
`kppmod reload`, `kppmods-start` or deploy) makes it more likely, so it is worth
knowing. First seen 2026-10-03, root cause found 2026-10-28.

## Symptom

- Tapping a book tile on Home (or in Library) does nothing useful: the screen
  flashes back to Home, sometimes after ~30 s, sometimes immediately.
- `/var/log/messages` shows the reader app timing out in `GO`.
- Afterwards, other lipc-backed things feel sluggish or dead.

## Root cause chain (verified from logs)

```text
lipc-daemon's script-backed property executor is wedged
  → lipc-get-prop com.lab126.system usid  ->  lipcErrTimedOut (0xf), 10 s
  → cvm (booklet host) opens a book: YJBook.<init> → aID() → FrameworkUtil.ae()
    → KindleIdentityService reads com.lab126.system:usid
    → LipcException (ErrCode=15) thrown out of native LipcImpl.getStringProperty0
    → SIGSEGV in cvm on the AGUI event-dispatch thread  ← process is crippled
  → appmgrd: "Timed out waiting for app to finish GO", reverts app id to
    com.lab126.KPPMainApp; "Ignore library open due to concurrent open"
  → cvm can never open a book again until it is restarted
```

Exact log excerpt (device clock 23:03, `/var/log/messages`):

```
cvm: E lipc:pto:timeout=10000, property=usid, publisher=com.lab126.system:
      Timed out waiting for sync prop access to complete
cvm: E KindleIdentityService:PropertyReadFailed: ... Unable to read device serial number
cvm: com.amazon.kindle.util.lipc.LipcException: Failed to get String property.  ErrCode=15
      at com.lab126.linux.arm.LipcImpl.getStringProperty0(Native Method)
      ...
      at com.amazon.ebook.booklet.yjreader.impl.YJBook.aID(YJBook.java:123)
      at com.amazon.ebook.booklet.reader.impl.ReaderSDKImpl.ah(ReaderSDKImpl.java:1011)
      ...
      at java.awt.AGUIEventDispatchThread.run(Unknown Source)
stackdumpd: I def:::Process PID: 16656 received Segmentation fault
system: I dump-stack:dumpstack:Creating Native Crash Report file for process:cvm pid:16656
```

`/var/local/crash/crash_java-16656.part` confirms `Signal: 11` with
`ActiveApp: com.lab126.KPPMainApp`.

### Why `com.lab126.system` is the canary

Its properties are **not** served by an app. They are the script-backed entries
in `/etc/lipc-daemon-props.conf`, executed by `lipc-daemon` itself:

```sh
usid  r  /usr/bin/lipcd-scripts/lipc-props/usid.sh     # cat /proc/usid | xargs echo -n
boardid r /usr/bin/lipcd-scripts/lipc-props/boardid.sh
```

Each of those scripts runs in **milliseconds** when executed by hand. So a
timeout on `com.lab126.system` is never a slow script — it means lipc-daemon's
script executor is stuck. Native targets (`com.lab126.appmgrd`,
`com.lab126.powerd`, …) keep answering during the wedge, which is why the UI
otherwise looks alive.

### What exactly is stuck (diagnosed 2026-10-28)

`lipc-daemon` (5 threads) runs each script property by `fork()` + `exec`. The
wedge is a **child that never reached `exec`**:

- an extra `lipc-daemon` process whose parent is the real daemon, with the same
  cmdline, one thread, and the parent's inherited pipe/sockets;
- it sleeps in a futex wait (`/proc/<pid>/syscall` = `0 0xb650046c 0x80 …`) on
  an address in an anonymous per-thread region of the parent's address space —
  the classic "fork in a multithreaded process while another thread holds a
  lock" deadlock. Nothing in the child can ever release it.

Observed three times, all at the **same futex address**: one child had been
stuck for 25 days (device uptime 98 days), one appeared ~20 s after a
`restart lipcd`, during the recovery script's framework restart, and one was
forked ~2 s before a normal book open (20:03:11 vs `ReaderBooklet start`
20:03:13; that open still succeeded). It is **intermittent**: 30 sequential `usid` reads, 5×6 parallel `usid` reads, 8 rounds
of all 13 readable script props in parallel, and a second framework restart all
completed without a stuck child. Framework startup traffic (props plus `-e`
event scripts) is the only trigger seen so far; restarting KPP is one way to
cause that traffic.

Check for it (read-only, exit 1 when stuck):

```bash
bash scripts/lipcd_check.sh
```

## Recovery (verified)

**Preferred, lightest (verified 2026-10-28):** kill only the stuck child.

```bash
# from WSL
bash scripts/lipcd_check.sh --fix
```

`usid`/`boardid` answered immediately afterwards; lipcd, the framework and cvm
kept running. If cvm has **already** segfaulted (a book open failed), the AGUI
thread is dead and a framework restart is still needed:

```bash
bash scripts/recover_reader.sh
bash scripts/lipcd_check.sh --fix   # the framework restart itself can re-wedge it
```

or by hand:

```sh
restart lipcd          # clears the wedged script executor; usid answers again
stop framework; start framework   # cvm respawns, dead AGUI thread is gone
start kppmainapp        # a framework restart leaves it stopped
```

After that, `lipc-get-prop com.lab126.system usid` answers at once and
`lipc-get-prop com.lab126.appmgrd activeApp` is `com.lab126.KPPMainApp`.
No reboot is needed.

## Secondary problem: the crash-dump pipeline fills `/var/tmp`

`/tmp` is a symlink to `/var/tmp`, a **64 MiB tmpfs**. When `dump-stack`/`dmcc.sh`
post-process a crash they stage the archive in `/var/tmp/dmcc.<pid>` (25 MB for
this device). After the `cvm` segfault that filled the tmpfs to 100 %, and then:

- `cp` into `/tmp` fails with `No space left on device`;
- cvm's `-XX:OnError` handler cannot write `/var/tmp/hs_err_pid*.log`;
- `dmcc.sh` spins forever, leaving `dump-stack` → `dmcc.sh` → (killed core) alive.

Clearing it is safe and is part of the recovery script:

```sh
kill -9 $(ps -o pid,args | grep -E 'dump-stack|dmcc\.sh' | grep -v grep | awk '{print $1}')
rm -rf /var/tmp/dmcc.*
```

Also note `/mnt/us` sat at 94 % full with several 200–430 MB `*.core` dumps in
`/mnt/us`. Nothing needs those; they are safe to remove (keep the `.txt`
crash summaries if you want the record).

## Crash reports in the Library

Every KPP restart (`stop kppmainapp`, `kppmod reload`, `kppmods-start`) makes the
old process segfault on shutdown, and the firmware writes a ~4 MB
`KPPMainAppV2_*_crash_*` report into `/mnt/us/documents`, where it shows up in
the Library. They are safe to delete. `scripts/kppmod_reload_device.sh` deletes
the one its own reload produced; `scripts/recover_reader.sh` moves them to
`/mnt/us/kindle-home-patch/crashtrash/`.

## Device connectivity

The Kindle does not answer ICMP — test with SSH, not `ping`:

```sh
ssh -i ~/.ssh/kindle_key -p 2222 -o BatchMode=yes -o ConnectTimeout=8 root@<kindle-ip> 'uptime'
```

If the SSH port is closed and the ARP entry is gone, the device needs a physical
power cycle. After a reboot, start KPP Mods again (see install.md).