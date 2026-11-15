#!/usr/bin/env bash
# Kindle recovery playbook: diagnose and repair the "reading is broken" wedge.
#
# Verified failure signature (2026-10-03, firmware 5.16.6.1):
#   * lipc-get-prop com.lab126.system <anything>  -> lipcErrTimedOut (0xf)
#     while native targets (com.lab126.appmgrd ...) still answer instantly.
#     com.lab126.system props are the *script-backed* ones in
#     /etc/lipc-daemon-props.conf, executed by lipc-daemon itself.
#   * Opening a book then makes cvm segfault in
#     LipcImpl.getStringProperty0 while YJBook.<init> reads the `usid` prop,
#     killing the AGUI event-dispatch thread; the reader can never finish GO.
#   * Afterwards cvm stays crippled until it is restarted.
#
# This script only restarts services and relocates auto-generated crash junk.
# It never mounts/unmounts anything, never edits /app or /var/local, and never
# deletes user content. Run it from WSL:
#   bash scripts/recover_reader.sh                      # diagnose + repair
#   bash scripts/recover_reader.sh --restart-framework  # force a cvm respawn
#                                                      # even if lipc looks fine
set -u
KEY="${KINDLE_KEY:-$HOME/.ssh/kindle_key}"
DEV="${KINDLE_DEV:-root@192.168.0.73}"
FORCE_CVM=no
[ "${1:-}" = "--restart-framework" ] && FORCE_CVM=yes
ssh -i "$KEY" -p 2222 -o BatchMode=yes -o ConnectTimeout=8 "$DEV" "FORCE_CVM=$FORCE_CVM sh -s" <<'REMOTE'
set -u
say() { echo "[recover] $*"; }

say "activeApp   = $(lipc-get-prop com.lab126.appmgrd activeApp 2>&1)"
say "cvm=$(pidof cvm 2>/dev/null) kpp=$(pidof KPPMainAppV2 2>/dev/null) lipcd=$(pidof lipc-daemon 2>/dev/null)"

# 1. Script-backed lipc props (com.lab126.system) are the canary.
#    Remember the verdict: a wedge almost always means cvm already lost its AGUI
#    thread, so it needs restarting even though the process still exists.
WEDGE=0
if lipc-get-prop com.lab126.system usid >/dev/null 2>&1; then
    say "OK: com.lab126.system/usid responds (no lipc wedge)"
else
    WEDGE=1
    say "WEDGE: com.lab126.system props time out -> restarting lipcd"
    restart lipcd
    sleep 8
    if lipc-get-prop com.lab126.system usid >/dev/null 2>&1; then
        say "OK: usid=$(lipc-get-prop com.lab126.system usid)"
    else
        say "still broken after lipcd restart"
    fi
fi

# 2. cvm is the Java/framework host; a dead AGUI thread means no book ever opens,
#    and the process stays alive in that state - so "pid exists" is not health.
#    Docs note: restarting framework leaves kppmainapp stopped -> start it below.
if [ "$FORCE_CVM" = yes ] || [ "$WEDGE" = 1 ] || [ -z "$(pidof cvm 2>/dev/null)" ]; then
    say "restarting framework (cvm respawn; wedge=$WEDGE force=$FORCE_CVM)"
    stop framework
    sleep 5
    start framework
    sleep 25
    say "cvm pid now $(pidof cvm 2>/dev/null)"
else
    say "cvm running (pid $(pidof cvm)) and lipc healthy; leaving it alone"
    say "  (pass --restart-framework to force a respawn)"
fi

# 3. KPP is the Home app; make sure it is up after any framework restart.
if [ -z "$(pidof KPPMainAppV2 2>/dev/null)" ]; then
    say "kppmainapp is down -> starting it"
    start kppmainapp
    sleep 12
fi

# 4. A wedged crash-dump pipeline fills the 64M /var/tmp tmpfs (tmp -> /var/tmp),
#    which then breaks unrelated services. Clear only that staging dir.
df -h /var | tail -1
if [ -d /var/tmp/dmcc.326 ] || df /var | awk 'NR==2{exit !($5+0>=98)}'; then
    say "/var/tmp nearly full; aborting stuck dmcc/dump-stack and clearing staging"
    for p in $(ps -o pid,args 2>/dev/null | grep -E "dump-stack|dmcc\.sh" | grep -v grep | awk '{print $1}'); do
        kill -9 "$p" 2>/dev/null || true
    done
    sleep 2
    rm -rf /var/tmp/dmcc.*
    df -h /var | tail -1
fi

# 5. Crash junk in /mnt/us/documents is indexed into the "recent items" feed.
#    Move (never delete) it into the experiment backup area.
mkdir -p /mnt/us/kindle-home-patch/crashtrash
n=$(ls /mnt/us/documents 2>/dev/null | grep -c '_crash_')
if [ "${n:-0}" -gt 0 ]; then
    say "moving $n crash report(s) out of /mnt/us/documents -> crashtrash"
    mv /mnt/us/documents/*_crash_* /mnt/us/kindle-home-patch/crashtrash/ 2>/dev/null || true
fi

say "final: activeApp=$(lipc-get-prop com.lab126.appmgrd activeApp 2>&1)" \
    "usid=$(lipc-get-prop com.lab126.system usid 2>&1)" \
    "cvm=$(pidof cvm 2>/dev/null) kpp=$(pidof KPPMainAppV2 2>/dev/null)"
say "Try opening a book now; check /var/log/messages for 'ReaderBooklet'."
REMOTE