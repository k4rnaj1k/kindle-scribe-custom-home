#!/bin/sh
# k4sync: send Send-to-Kindle PDF articles (with any handwriting as ink
# annotations) and handwritten notebooks to a WebDAV inbox (the Pi's
# vault-inbox stack → Obsidian LiveSync).
#
#   sh k4sync.sh send     send what changed since the last send (what the
#                         "Send to Obsidian" button runs)
#   sh k4sync.sh send --dry-run
#                         write the PDFs to /mnt/us/k4sync/dry-run/ instead,
#                         without marking anything as sent
#   sh k4sync.sh send-item ITEM...
#                         send just these (KFX path or notebook uuid), even
#                         if unchanged: what the k4 Home row buttons run
#   sh k4sync.sh status   last log lines
#
# Sent: every member of the COLLECTION collection (whole article, with or
# without handwriting), any other Send-to-Kindle PDF that has handwriting,
# and every notebook. A document is re-sent when its KFX or handwriting store
# changes. Stores are copied once the reader has committed (see snapshot),
# rendered by k4sync.lua and uploaded as <name>.pdf.partial, then MOVEd to
# <name>.pdf. Settings: /mnt/us/k4sync/k4sync.conf.
APP=/mnt/us/k4sync
NOTEBOOKS=/mnt/us/.notebooks
DOCS=/mnt/us/documents
DB=/var/local/cc.db
KSDK=/var/local/ksdk.content.db
WORK=/var/tmp/k4sync
LOG=$APP/k4sync.log

KOREADER=/mnt/us/koreader
COLLECTION=articles
WEBDAV_URL=
WEBDAV_USER=kindle
WEBDAV_PASS=
# CRs stripped: a config edited on Windows (or appended to through a
# PowerShell pipe) would otherwise end every value in \r.
[ -f "$APP/k4sync.conf" ] && eval "$(tr -d '\r' <"$APP/k4sync.conf")"

log() { echo "$(date '+%F %T') $*" >>"$LOG"; }

status() {
    echo "$1"
    # One line of on-screen feedback; the next screen refresh clears it.
    # --quiet (k4 Home) skips it: Home shows its own status per row.
    [ -n "$QUIET" ] || eips 1 2 "Obsidian: $1                    " >/dev/null 2>&1
}

# One send at a time: they share $WORK. A lock left by a killed run is
# taken over when its pid is gone.
lock() {
    local waited=0
    while ! mkdir "$WORK/lock" 2>/dev/null; do
        if ! kill -0 "$(cat "$WORK/lock/pid" 2>/dev/null)" 2>/dev/null; then
            rm -rf "$WORK/lock"
            continue
        fi
        waited=$((waited + 1))
        [ "$waited" -gt 600 ] && { status "busy: another send is still running"; exit 1; }
        sleep 1
    done
    echo $$ >"$WORK/lock/pid"
    trap 'rm -rf "$WORK/lock"' EXIT
}

rotate_log() {
    [ -f "$LOG" ] && [ "$(wc -c <"$LOG")" -gt 262144 ] && mv "$LOG" "$LOG.1"
}

urlencode() {
    printf %s "$1" | lua -e 'io.write((io.read("*a"):gsub("[^%w%-%._~]", function(c) return ("%%%02X"):format(c:byte()) end)))'
}

dav() { # dav METHOD PATH [curl args...]
    local method=$1 path=$2
    shift 2
    curl -fsS --connect-timeout 10 --max-time 300 -u "$WEBDAV_USER:$WEBDAV_PASS" -X "$method" "$@" "$WEBDAV_URL/$path"
}

upload() { # upload LOCAL FOLDER NAME
    local folder name
    if [ -n "$DRY" ]; then
        mkdir -p "$APP/dry-run/$2" && cp "$1" "$APP/dry-run/$2/$3"
        return
    fi
    folder=$(urlencode "$2")
    name=$(urlencode "$3")
    dav MKCOL "$folder/" >/dev/null 2>&1 # 405 when it exists
    dav PUT "$folder/$name.partial" -T "$1" >/dev/null &&
        dav MOVE "$folder/$name.partial" -H "Destination: $WEBDAV_URL/$folder/$name" -H "Overwrite: T" >/dev/null
}

remember() { # remember KEY STAMP — what was last sent (not in a dry run)
    [ -n "$DRY" ] || echo "$2" >"$APP/state/$1"
}

safe_name() { # file names: drop characters WebDAV/Obsidian dislike
    printf %s "$1" | tr -d '\000-\037' | tr '/\\:*?"<>|' '_________'
}

# render_and_upload FOLDER NAME STATE_KEY STAMP COMMAND... → 0 sent, 1 failed, 2 nothing to send
render_and_upload() {
    local folder=$1 name=$2 key=$3 stamp=$4 out=$WORK/out.pdf rc
    shift 4
    rm -f "$out"
    "$@" >"$WORK/render.out" 2>&1
    rc=$?
    rm -f "$WORK/snap.nbk"
    if [ "$rc" = 3 ] || [ "$rc" = 4 ]; then # nothing to send / not a PDF document
        [ "$rc" = 4 ] && log "skipped $folder/$name: not a PDF (web article or book)"
        remember "$key" "$stamp"
        return 2
    fi
    if [ "$rc" != 0 ] || [ ! -s "$out" ]; then
        log "render failed ($rc): $folder/$name: $(grep -v -e '^ffi\.' -e '^lib_' -e '^has monol' "$WORK/render.out" | tail -n 2 | tr '\n' ' ')"
        return 1
    fi
    if upload "$out" "$folder" "$name" 2>"$WORK/upload.err"; then
        log "${DRY:+dry run: }sent $folder/$name ($(wc -c <"$out") bytes; $(tail -n 1 "$WORK/render.out" | sed 's/^wrote [^(]*//')"
        remember "$key" "$stamp"
        rm -f "$out"
        return 0
    fi
    log "upload failed: $folder/$name: $(tail -n 1 "$WORK/upload.err")"
    rm -f "$out"
    return 1
}

# snapshot NBK → prints the snapshot path ("-" when there is no store).
# A raw copy, not `sqlite3 .backup`: the stock sqlite3 does not know the KDF
# fingerprint records and its backup truncates the file by 1 KiB per record.
# The store uses a rollback journal, so a copy taken while the journal is
# empty and the store's mtime/size do not change is a committed state.
snapshot() {
    local f=$1 j="$1-journal" try before after
    [ -f "$f" ] || { echo "-"; return 0; }
    for try in 1 2 3 4 5; do
        before="$(stat -c %Y:%s "$f")"
        if [ ! -s "$j" ] && cp "$f" "$WORK/snap.nbk" && [ ! -s "$j" ]; then
            after="$(stat -c %Y:%s "$f")"
            if [ "$before" = "$after" ]; then
                echo "$WORK/snap.nbk"
                return 0
            fi
        fi
        sleep 1
    done
    return 1
}

run_render() { # run_render ARGS... — KOReader's luajit when present (ink on PDFs, compression), else stock lua
    if [ -x "$KOREADER/luajit" ]; then
        (cd "$KOREADER" && ./luajit "$APP/k4sync.lua" render "$@")
    else
        lua "$APP/k4sync.lua" render "$@"
    fi
}

# send_article KFX IN_COLLECTION — the whole PDF; outside the collection
# only when it has handwriting.
send_article() {
    local kfx=$1 base key store stamp title snap yjr only_with_ink=--require-strokes
    [ -n "$2" ] && only_with_ink=
    base=$(basename "$kfx" .kfx)
    key=${base##*_}
    store="$NOTEBOOKS/$key!!PDOC!!notebook/nbk"
    stamp=$(stat -c %Y "$kfx")
    [ -f "$store" ] && stamp="$stamp-$(stat -c %Y "$store")"
    [ -z "$FORCE" ] && [ "$(cat "$APP/state/$key" 2>/dev/null)" = "$stamp" ] && return 3
    title=${base%_"$key"}
    title=${title%.pdf}
    snap=$(snapshot "$store") || { log "snapshot failed: $store"; return 1; }
    # The reader's sidecar maps each handwriting section to its page.
    yjr=$(ls "$(dirname "$kfx")/$base.sdr"/*.yjr 2>/dev/null | head -n 1)
    render_and_upload Articles "$(safe_name "$title").pdf" "$key" "$stamp" \
        run_render "$snap" "$WORK/out.pdf" --kfx "$kfx" --yjr "$yjr" $only_with_ink
}

# send_pdf PDF — a sideloaded PDF as it is (its handwriting is not added yet:
# only Send-to-Kindle KFX articles are mapped to pages).
send_pdf() {
    local pdf=$1 title
    [ -f "$pdf" ] || { log "not found: $pdf"; return 1; }
    title=$(basename "$pdf" .pdf)
    cp "$pdf" "$WORK/out.pdf" || return 1
    if upload "$WORK/out.pdf" Articles "$(safe_name "$title").pdf" 2>"$WORK/upload.err"; then
        log "sent Articles/$(safe_name "$title").pdf ($(wc -c <"$WORK/out.pdf") bytes; sideloaded PDF as is)"
        rm -f "$WORK/out.pdf"
        return 0
    fi
    log "upload failed: Articles/$title.pdf: $(tail -n 1 "$WORK/upload.err")"
    rm -f "$WORK/out.pdf"
    return 1
}

# Notebook titles live in ksdk.content.db (Nodes, STANDALONE_NOTEBOOK), not
# cc.db. Lists "uuid|title" for notebooks that are not deleted.
list_notebooks() {
    sqlite3 -readonly -cmd ".timeout 10000" -separator '|' "$KSDK" \
        "select uuid, title_collation from Nodes where node_type = 'STANDALONE_NOTEBOOK'
           and ifnull(additional_data, '') not like '%\"delete_state\":1%';" 2>/dev/null
}

send_notebook() { # send_notebook STORE_ID
    local id=$1 stamp title name snap
    [ -f "$NOTEBOOKS/$id/nbk" ] || { log "no notebook store for $id"; return 1; }
    stamp=$(stat -c %Y "$NOTEBOOKS/$id/nbk")
    [ -z "$FORCE" ] && [ "$(cat "$APP/state/$id" 2>/dev/null)" = "$stamp" ] && return 3
    title=$(grep "^$id|" "$WORK/notebooks.list" | head -n 1 | cut -d '|' -f 2-)
    if [ -z "$title" ]; then
        remember "$id" "$stamp" # deleted, or not a library notebook
        return 2
    fi
    name=$(safe_name "$title")
    # Two notebooks with the same title would overwrite each other in the vault.
    [ "$(cut -d '|' -f 2- "$WORK/notebooks.list" | grep -cxF "$title")" -gt 1 ] && name="$name (${id%%-*})"
    snap=$(snapshot "$NOTEBOOKS/$id/nbk") || { log "snapshot failed (store busy): $title"; return 1; }
    render_and_upload Notebooks "$name.pdf" "$id" "$stamp" \
        run_render "$snap" "$WORK/out.pdf" --title "$title"
}

count() { # count RETURN_CODE
    case $1 in
        0) sent=$((sent + 1)); status "sent $sent..." ;;
        1) failed=$((failed + 1)) ;;
    esac
}

send() {
    sent=0
    failed=0
    : >"$WORK/collection.list"
    case "$COLLECTION" in
        *"'"*) log "COLLECTION must not contain quotes" ;;
        ?*) sqlite3 -readonly -cmd ".timeout 10000" "$DB" \
            "select e.p_location from Collections c
               join Entries col on col.p_uuid = c.i_collection_uuid
               join Entries e on e.p_uuid = c.i_member_uuid
             where col.p_type = 'Collection' and lower(col.p_titles_0_nominal) = lower('$COLLECTION')
               and e.p_location like '%.kfx';" >"$WORK/collection.list" ||
            log "cannot read the '$COLLECTION' collection from cc.db" ;;
    esac
    while IFS= read -r kfx; do
        [ -f "$kfx" ] || continue
        send_article "$kfx" 1
        count $?
    done <"$WORK/collection.list"
    list_notebooks >"$WORK/notebooks.list"

    for nbk in "$NOTEBOOKS"/*/nbk; do
        [ -f "$nbk" ] || continue
        d=${nbk%/nbk}
        id=${d##*/}
        case "$id" in
            *'!!PDOC!!notebook')
                key=${id%%!!*}
                kfx=$(find "$DOCS" -name "*_$key.kfx" 2>/dev/null | head -n 1)
                [ -n "$kfx" ] || continue # handwriting on a document that is not a KFX PDF
                grep -qxF "$kfx" "$WORK/collection.list" && continue
                send_article "$kfx" ""
                count $? ;;
            *-*-*-*-*)
                send_notebook "$id"
                count $? ;;
        esac
    done
    summary
}

# send_items ITEM... — the chosen items, sent even if unchanged. An item is
# an article's KFX path or a notebook's uuid.
send_items() {
    sent=0
    failed=0
    FORCE=1
    list_notebooks >"$WORK/notebooks.list"
    for item in "$@"; do
        case "$item" in
            *.kfx) if [ -f "$item" ]; then send_article "$item" 1; else log "not found: $item"; false; fi ;;
            *.pdf) send_pdf "$item" ;;
            *) send_notebook "$item" ;;
        esac
        count $?
    done
    summary
}

summary() {
    if [ "$failed" -gt 0 ]; then
        status "$sent sent, $failed failed (see k4sync.log)"
    elif [ "$sent" -gt 0 ]; then
        status "$sent sent"
    else
        status "nothing new to send"
    fi
    [ "$failed" = 0 ]
}

mkdir -p "$APP/state" "$WORK"
[ -n "$K4SYNC_LIB" ] && return 0 # sourced by tests: functions only
cmd=${1:-send}
[ $# -gt 0 ] && shift
while :; do
    case "$1" in
        --dry-run) DRY=1; shift ;;
        --quiet) QUIET=1; shift ;;
        *) break ;;
    esac
done
case "$cmd" in
    send|send-item)
        if [ -z "$DRY" ] && { [ -z "$WEBDAV_URL" ] || [ -z "$WEBDAV_PASS" ]; }; then
            status "set WEBDAV_URL and WEBDAV_PASS in $APP/k4sync.conf"
            exit 1
        fi
        lock
        rotate_log
        status "sending..."
        if [ "$cmd" = send ]; then send; else send_items "$@"; fi ;;
    status) tail -n 10 "$LOG" 2>/dev/null ;;
    *) echo "usage: $0 send [--dry-run] [--quiet] | send-item [--dry-run] [--quiet] KFX|NOTEBOOK_UUID... | status"; exit 1 ;;
esac
