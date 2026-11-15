#!/usr/bin/env bash
# Build k4 Home and install it (and its extras) on a Kindle that runs kppmods.
#
#   bash scripts/k4home_ext.sh setup              one-time: kppmods build tools, Node check, Pillow venv
#   bash scripts/k4home_ext.sh install-host       build + install the kppmods UI host with the 5.16 Home hook
#   bash scripts/k4home_ext.sh deploy-device      build + install k4 Home (also after every change)
#   bash scripts/k4home_ext.sh install-koreader   Store cart -> KOReader button (needs kppmods-koreader)
#   bash scripts/k4home_ext.sh install-k4sync     "Send to Obsidian" files (+ k4sync.conf template)
#   bash scripts/k4home_ext.sh build              build only -> $K4_OUT/k4home
#   bash scripts/k4home_ext.sh build-host         build only -> $K4_OUT/host.js
#   bash scripts/k4home_ext.sh deploy-emu         emulator (127.0.0.1:2222), see emulator/README.md
#
# With K4_PREBUILT=DIR (an unpacked release, holding main.js, manifest.json and
# assets/), deploy-device installs that instead of building: no Node needed.
#
# Environment (defaults in brackets):
#   KINDLE_DEV   [root@192.168.0.73]      the Kindle, root over SSH on port 2222
#   KINDLE_KEY   [~/.ssh/kindle_key]      SSH key for it
#   KPPMODS_DIR  [~/emu/kppmods]          kppmods checkout (build tools)
#   NODE_DIR     [~/emu/node]             Node >= 22.18; falls back to `node` on PATH
#   VENV         [~/emu/venv]             Python venv with Pillow
#   K4_OUT       [~/emu/kppmods-out]      build output
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/kppmods-ext/k4home"
KPPMODS_DIR="${KPPMODS_DIR:-$HOME/emu/kppmods}"
KPPMODS_REPO=https://github.com/katadelos/kppmods.git
KPPMODS_REF=172e9a9          # tested version (kppmods 2.0.0+git.r32.172e9a9)
NODE_DIR="${NODE_DIR:-$HOME/emu/node}"
VENV="${VENV:-$HOME/emu/venv}"
K4_OUT="${K4_OUT:-$HOME/emu/kppmods-out}"
OUT="$K4_OUT/k4home"
EXTENSIONS=/mnt/us/.eink-sdk/usr/lib/kppmods/extensions
EXT=$EXTENSIONS/k4home
DEV="${KINDLE_DEV:-root@192.168.0.73}"
KEY="${KINDLE_KEY:-$HOME/.ssh/kindle_key}"
OPTS=(-i "$KEY" -o BatchMode=yes -o ConnectTimeout=8)
[ -x "$NODE_DIR/bin/node" ] && export PATH="$NODE_DIR/bin:$PATH"

on_kindle() { ssh "${OPTS[@]}" -p 2222 "$DEV" "$@"; }
# Copy local files into a device folder (tar over ssh: works without SFTP).
put() {
    local dest=$1 dir=$2; shift 2
    tar -C "$dir" -cf - "$@" | on_kindle "mkdir -p '$dest' && tar -C '$dest' -xf -"
}
check_node() {
    command -v node >/dev/null || { echo "Node.js not found (need >= 22.18; set NODE_DIR)" >&2; exit 1; }
    node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>22||(a==22&&b>=18)?0:1)' ||
        { echo "Node $(node -v) is too old (need >= 22.18; set NODE_DIR)" >&2; exit 1; }
}
check_kindle() {
    on_kindle ". /mnt/us/.eink-sdk/control/env && kppmod status >/dev/null" ||
        { echo "kppmods is not running on $DEV (see docs/install.md step 2)" >&2; exit 1; }
}

setup() {
    check_node
    if [ ! -d "$KPPMODS_DIR/.git" ]; then
        git clone "$KPPMODS_REPO" "$KPPMODS_DIR"
        git -C "$KPPMODS_DIR" checkout -q "$KPPMODS_REF"
    elif [ "$(git -C "$KPPMODS_DIR" rev-parse --short=7 HEAD)" != "$KPPMODS_REF" ]; then
        echo "note: $KPPMODS_DIR is not at the tested commit $KPPMODS_REF" >&2
    fi
    git -C "$KPPMODS_DIR" submodule update --init --depth 1 vendor/react-kindle
    [ -d "$KPPMODS_DIR/node_modules" ] || (cd "$KPPMODS_DIR" && npm ci)
    if [ ! -x "$VENV/bin/python" ]; then
        python3 -m venv "$VENV"
        "$VENV/bin/pip" install -q pillow
    fi
    echo "setup done: kppmods in $KPPMODS_DIR, venv in $VENV"
}

build() {
    check_node
    rm -rf "$OUT" && mkdir -p "$OUT"
    (cd "$KPPMODS_DIR" && node tools/build/build-extension.cjs "$SRC/main.jsx" k4home "$OUT/main.js" "$SRC")
    cp "$SRC/manifest.json" "$OUT/"
    cp -r "$SRC/assets" "$OUT/"
    # KPP's image views are only known to decode PNG/JPEG/SVG: ship WebP sources as PNG.
    for webp in "$OUT"/assets/*.webp; do
        [ -e "$webp" ] || continue
        "$VENV/bin/python" -c 'import sys; from PIL import Image; Image.open(sys.argv[1]).convert("L").save(sys.argv[2])' \
            "$webp" "${webp%.webp}.png"
        rm "$webp"
    done
    echo "built $OUT"
}

build_host() {
    check_node
    # kppmods' own Home hook needs renderHomeFeed, which 5.16 lacks; this adapter adds the 5.16 path.
    cp "$ROOT/emulator/kppmods-home-5.16.js" "$KPPMODS_DIR/ui/adapters/home.js"
    mkdir -p "$K4_OUT"
    (cd "$KPPMODS_DIR" && node tools/build/build-host.cjs "$K4_OUT/host.js")
    echo "built $K4_OUT/host.js"
}

case "${1:-build}" in
setup) setup ;;
build) build ;;
build-host) build_host ;;
install-host)
    build_host
    check_kindle
    # Keep the packaged host once (skip if the installed one already has the 5.16 hook).
    on_kindle "H=$EXTENSIONS/ui-host/host.js; grep -q stockPager \$H || [ -e /mnt/us/ui-host.stock.js ] || cp \$H /mnt/us/ui-host.stock.js"
    put "$EXTENSIONS/ui-host" "$K4_OUT" host.js
    bash "$(dirname "$0")/kppmod_reload_device.sh"
    ;;
deploy-device)
    # A full reload picks up manifest/option changes; it restarts KPP, which can
    # freeze a lipc-daemon child, so the reload helper clears that afterwards.
    if [ -n "${K4_PREBUILT:-}" ]; then
        OUT="$(cd "$K4_PREBUILT" && pwd)"
        [ -f "$OUT/main.js" ] && [ -f "$OUT/manifest.json" ] ||
            { echo "K4_PREBUILT=$K4_PREBUILT has no main.js/manifest.json" >&2; exit 1; }
    else
        build
    fi
    check_kindle
    on_kindle "rm -rf $EXT/assets"
    put "$EXT" "$OUT" main.js manifest.json assets
    bash "$(dirname "$0")/kppmod_reload_device.sh"
    ;;
install-koreader)
    check_kindle
    on_kindle ". /mnt/us/.eink-sdk/control/env; opkg list-installed | grep -q '^kppmods-koreader '" ||
        { echo "install it first on the Kindle: opkg install kppmods-koreader" >&2; exit 1; }
    put /mnt/us/documents "$ROOT/kppmods-ext/koreader-shortcut" KOReader.sh
    on_kindle "chmod 755 /mnt/us/documents/KOReader.sh"
    # Rescan packages (the shortcut is unavailable until the script exists), then enable it.
    KPPMOD_CMD="kppmod reload && kppmod enable koreader" bash "$(dirname "$0")/kppmod_reload_device.sh"
    ;;
install-k4sync)
    S="$ROOT/kppmods-ext/k4sync"
    put /mnt/us/k4sync "$S" k4ion.lua k4pdf.lua k4pdfedit.lua k4strokes.lua k4sync.lua k4sync-dump.lua k4sync.sh
    put /mnt/us/documents "$S" SendToObsidian.sh
    on_kindle "chmod 755 /mnt/us/k4sync/k4sync.sh /mnt/us/documents/SendToObsidian.sh"
    if on_kindle "[ -e /mnt/us/k4sync/k4sync.conf ]"; then
        echo "kept the existing /mnt/us/k4sync/k4sync.conf"
    else
        put /mnt/us/k4sync "$S" k4sync.conf.example
        on_kindle "mv /mnt/us/k4sync/k4sync.conf.example /mnt/us/k4sync/k4sync.conf"
        echo "now edit /mnt/us/k4sync/k4sync.conf (WEBDAV_URL, WEBDAV_USER, WEBDAV_PASS)"
    fi
    ;;
deploy-emu)
    build
    KEY="$HOME/emu/eink-emulator/build/ssh/id_ed25519"
    EOPTS=(-i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
    ssh "${EOPTS[@]}" -p 2222 root@127.0.0.1 "mkdir -p $EXT/assets"
    # The guest's dropbear has no SFTP subsystem: use the legacy scp protocol.
    scp -O "${EOPTS[@]}" -P 2222 "$OUT/main.js" "$OUT/manifest.json" "root@127.0.0.1:$EXT/"
    scp -O "${EOPTS[@]}" -P 2222 "$OUT"/assets/* "root@127.0.0.1:$EXT/assets/"
    ssh "${EOPTS[@]}" -p 2222 root@127.0.0.1 ". /mnt/us/.eink-sdk/control/env; kppmod reload k4home"
    ;;
*) sed -n '2,/^set -euo/{/^set -euo/d;p;}' "$0" >&2; exit 2 ;;
esac
