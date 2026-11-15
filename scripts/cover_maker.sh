#!/usr/bin/env bash
# Install Cover Maker on the Kindle (it then shows in the kppmods Apps list).
#
#   bash scripts/cover_maker.sh install    copy k4covers.lua + CoverMaker.sh
#   bash scripts/cover_maker.sh dry-run    install, then render into /tmp only
#   bash scripts/cover_maker.sh run        install, then add covers (writes cc.db)
#
# Needs KOReader at /mnt/us/koreader. See kppmods-ext/cover-maker/README.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/kppmods-ext/cover-maker"
DEV="${KINDLE_DEV:-root@192.168.0.73}"
OPTS=(-i "${KINDLE_KEY:-$HOME/.ssh/kindle_key}" -o BatchMode=yes -o ConnectTimeout=8 -p 2222)

install() {
    ssh "${OPTS[@]}" "$DEV" "mkdir -p /mnt/us/k4covers && cat > /mnt/us/k4covers/k4covers.lua" <"$SRC/k4covers.lua"
    ssh "${OPTS[@]}" "$DEV" "cat > /mnt/us/documents/CoverMaker.sh && chmod 755 /mnt/us/documents/CoverMaker.sh" <"$SRC/CoverMaker.sh"
    echo "installed /mnt/us/k4covers/k4covers.lua and /mnt/us/documents/CoverMaker.sh"
}

case "${1:-install}" in
install) install ;;
dry-run)
    install
    ssh "${OPTS[@]}" "$DEV" "sh /mnt/us/documents/CoverMaker.sh --dry-run; cat /mnt/us/k4covers/last-run.log"
    ;;
run)
    install
    ssh "${OPTS[@]}" "$DEV" "sh /mnt/us/documents/CoverMaker.sh; cat /mnt/us/k4covers/last-run.log"
    ;;
*) echo "usage: $0 {install|dry-run|run}" >&2; exit 2 ;;
esac
