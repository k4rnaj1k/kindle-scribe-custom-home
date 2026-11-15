#!/usr/bin/env bash
# Detect the stock lipc-daemon fork deadlock (see docs/troubleshooting.md).
#
# lipc-daemon (multithreaded) forks a child to run each script-backed property
# (e.g. com.lab126.system usid -> usid.sh). Occasionally the child never reaches
# exec: it stays a "lipc-daemon" process blocked on a futex inherited from the
# parent, and every script property then times out (lipcErrTimedOut), which
# later segfaults cvm when a book opens.
#
# Usage (from WSL):
#   bash scripts/lipcd_check.sh         # read-only; exit 1 if a stuck child is present
#   bash scripts/lipcd_check.sh --fix   # also kill -9 the stuck child(ren)
#
# --fix is verified (2026-10-28): killing only the stuck child restores usid at
# once; no lipcd/framework restart, cvm keeps running. Stuck children are
# detected by age, so a script that is merely running right now is left alone.
set -u
KEY="${KINDLE_KEY:-$HOME/.ssh/kindle_key}"
DEV="${KINDLE_DEV:-root@192.168.0.73}"
FIX=no
[ "${1:-}" = "--fix" ] && FIX=yes
ssh -i "$KEY" -p 2222 -o BatchMode=yes -o ConnectTimeout=8 "$DEV" "FIX=$FIX sh -s" <<'REMOTE'
stuck=0
for p in $(pidof lipc-daemon); do
    pp=$(grep PPid /proc/$p/status | awk '{print $2}')
    age=$(ps -o pid,etime | awk -v p=$p '$1==p {print $2}')
    if [ "$pp" = 1 ]; then
        echo "parent $p (up $age, $(grep Threads /proc/$p/status | awk '{print $2}') threads)"
    else
        # script children normally exec within milliseconds; "0:0x" etime = under 10 s
        case "$age" in 00:0?) echo "child $p of $pp is young ($age), not stuck yet"; continue ;; esac
        stuck=1
        echo "STUCK child $p of $pp (age $age) syscall: $(cut -d' ' -f1-3 /proc/$p/syscall)"
        if [ "$FIX" = yes ]; then
            kill -9 "$p" && echo "  killed $p"
            sleep 2
        fi
    fi
done
if lipc-get-prop com.lab126.system usid >/dev/null 2>&1; then
    echo "usid: OK"
else
    echo "usid: TIMEOUT"
fi
exit $stuck
REMOTE
