#!/usr/bin/env bash
# Full `kppmod reload` on the real Kindle (rescans packages, restarts KPP), then
# the clean-up every KPP restart needs: unfreeze a lipc-daemon child, and delete
# the crash report the old KPPMainAppV2 leaves when it segfaults on shutdown
# (the firmware's dump-stack writes ~4 MB into /mnt/us/documents). Only the
# report this reload produced is removed.
#
#   bash scripts/kppmod_reload_device.sh
#   KPPMOD_CMD="kppmod enable koreader" bash scripts/kppmod_reload_device.sh   # another reloading command
set -euo pipefail
DEV="${KINDLE_DEV:-root@192.168.0.73}"
OPTS=(-i "${KINDLE_KEY:-$HOME/.ssh/kindle_key}" -o BatchMode=yes -o ConnectTimeout=8 -p 2222)
CRASH_GLOB='/mnt/us/documents/KPPMainAppV2_*_crash_*'

before=$(ssh "${OPTS[@]}" "$DEV" "ls -d $CRASH_GLOB 2>/dev/null" || true)
ssh "${OPTS[@]}" "$DEV" ". /mnt/us/.eink-sdk/control/env; ${KPPMOD_CMD:-kppmod reload}"
sleep 30
bash "$(dirname "$0")/lipcd_check.sh" --fix
# dump-stack can start well after the reload: wait (up to 4 min) until a new
# report (.tgz) exists and dump-stack has finished, then delete that report.
new=""
for _ in $(seq 1 24); do
    after=$(ssh "${OPTS[@]}" "$DEV" "ps | grep -q '[d]ump-stack' && echo BUSY; ls -d $CRASH_GLOB 2>/dev/null" || true)
    new=$(comm -13 <(echo "$before" | sort) <(echo "$after" | grep -v '^BUSY$' | sort) |
        grep -E '/KPPMainAppV2_[0-9]+_.*_crash_[^/]*\.(tgz|txt|sdr)$' || true)
    if ! echo "$after" | grep -q '^BUSY$' && echo "$new" | grep -q '\.tgz$'; then break; fi
    sleep 10
done
if [ -n "$new" ]; then
    echo "removing crash report from this reload:"
    echo "$new" | sed 's/^/  /'
    ssh "${OPTS[@]}" "$DEV" "rm -rf $(echo "$new" | sed "s/.*/'&'/" | tr '\n' ' ')"
fi
