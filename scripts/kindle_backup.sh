#!/usr/bin/env bash
# Pull a snapshot of the data k4 Home and its extras read or write to the PC.
#
# Usage:  bash scripts/kindle_backup.sh
# Output: backups/kindle-<timestamp>/{kindle.tar.gz,SHA256SUMS,CONTENTS.txt}
#
# Read-only on the device apart from a temporary copy of the databases in
# /var/tmp (removed afterwards). Contents:
#   - cc.db (Library: collections, covers; sqlite .backup) and
#     ksdk.content.db (notebook list; raw copy, see k4sync/README.md)
#   - kppmods state (/mnt/us/.eink-sdk/var/lib/kppmods: options.json, enabled set)
#   - k4sync config and state, Cover Maker's cc.db backups, the KOReader shortcut
# Notebook ink (/mnt/us/.notebooks) is not included: copy it over USB if needed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY="${KINDLE_KEY:-$HOME/.ssh/kindle_key}"
DEV="${KINDLE_DEV:-root@192.168.0.73}"
SSH=(ssh -i "$KEY" -p 2222 -o BatchMode=yes -o ConnectTimeout=8 "$DEV")
OUT="$ROOT/backups/kindle-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

"${SSH[@]}" 'sh -s' > "$OUT/kindle.tar.gz" <<'REMOTE'
set -e
S=/var/tmp/kindle-backup.$$
mkdir -p $S
trap 'rm -rf $S' EXIT
sqlite3 /var/local/cc.db ".timeout 5000" ".backup $S/cc.db"
cp /var/local/ksdk.content.db $S/ksdk.content.db 2>/dev/null || true
cat /etc/prettyversion.txt > $S/device.txt 2>/dev/null || true
cd /
set --
for p in mnt/us/.eink-sdk/var/lib/kppmods mnt/us/k4sync/k4sync.conf mnt/us/k4sync/state \
         mnt/us/k4covers/backup mnt/us/documents/KOReader.sh; do
    [ -e "$p" ] && set -- "$@" "$p"
done
# busybox tar applies -C to every path, so archive the staging dir by its path too
tar czf - "$@" "${S#/}"
REMOTE

cd "$OUT"
sha256sum kindle.tar.gz > SHA256SUMS
tar tzf kindle.tar.gz > CONTENTS.txt
echo "Backup: $OUT ($(du -h kindle.tar.gz | cut -f1), $(wc -l < CONTENTS.txt) entries)"
