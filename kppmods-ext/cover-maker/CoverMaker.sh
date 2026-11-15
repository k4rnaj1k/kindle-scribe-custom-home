#!/bin/sh
# Name: Cover Maker
# Author: k4home
#
# Gives covers to KFX documents that have none (Send-to-Kindle PDFs keep the
# original PDF inside the KFX): renders page 1 with KOReader's MuPDF
# (k4covers.lua), saves it where the Kindle keeps covers and points the
# item's cc.db cover field at it, so the Library and k4 Home show it.
# Only items without a cover are touched; existing cover files are never
# overwritten. cc.db is backed up first (last 3 kept).
#
#   sh CoverMaker.sh            run (from the kppmods Apps list or a shell)
#   sh CoverMaker.sh --dry-run  render into /tmp/k4covers-dry, change nothing
APP=/mnt/us/k4covers
KOREADER=/mnt/us/koreader
DB=/var/local/cc.db
THUMBS=/mnt/us/system/thumbnails
WIDTH=360
SEP=$(printf '\037')
DRY=
[ "$1" = "--dry-run" ] && DRY=1

status() {
    echo "$1"
    # One line of on-screen feedback; the next screen refresh clears it.
    [ -n "$DRY" ] || eips 1 2 "Cover Maker: $1                    " >/dev/null 2>&1
}

mkdir -p "$APP/backup"
exec >"$APP/last-run.log" 2>&1
echo "Cover Maker $(date) ${DRY:+(dry run)}"

if [ ! -x "$KOREADER/luajit" ] || [ ! -f "$APP/k4covers.lua" ]; then
    status "KOReader or k4covers.lua missing"
    exit 1
fi

out_dir=$THUMBS
if [ -n "$DRY" ]; then
    out_dir=/tmp/k4covers-dry
    mkdir -p "$out_dir"
else
    cp "$DB" "$APP/backup/cc.db.$(date +%Y%m%d-%H%M%S)" || { status "cc.db backup failed"; exit 1; }
    ls -t "$APP"/backup/cc.db.* 2>/dev/null | tail -n +4 | xargs rm -f
fi

list=/tmp/k4covers.list
sqlite3 -readonly -cmd ".timeout 10000" -separator "$SEP" "$DB" \
    "select p_uuid, p_cdeKey, p_cdeType, p_location from Entries
     where p_type = 'Entry:Item' and p_mimeType = 'application/x-kfx-ebook'
       and p_location is not null and ifnull(p_thumbnail, '') not like '/%';" >"$list" ||
    { status "cannot read cc.db"; exit 1; }
total=$(grep -c . "$list")
status "working on $total items..."

added=0
skipped=0
failed=0
while IFS="$SEP" read -r uuid key type loc; do
    [ -n "$uuid" ] || continue
    # These end up in a file name and an SQL literal: expect plain ids.
    case "$uuid$key$type" in
        *[!0-9A-Za-z_-]*) echo "- unexpected id for $loc, skipped"; failed=$((failed + 1)); continue ;;
    esac
    out="$out_dir/thumbnail_${key}_${type}_portrait.jpg"
    echo "- $loc"
    if [ -e "$out" ]; then
        echo "  cover file exists, reusing it"
    else
        (cd "$KOREADER" && ./luajit "$APP/k4covers.lua" "$loc" "$out" "$WIDTH") >/tmp/k4covers.out 2>&1
        rc=$?
        grep -v -e '^ffi\.' -e '^lib_' -e '^has monolibtic' /tmp/k4covers.out | sed 's/^/  /'
        if [ "$rc" = 2 ]; then
            skipped=$((skipped + 1))
            continue
        elif [ "$rc" != 0 ] || [ ! -s "$out" ]; then
            failed=$((failed + 1))
            rm -f "$out"
            continue
        fi
    fi
    if [ -z "$DRY" ]; then
        # uuid and path are [0-9A-Za-z_./-] only: safe to inline.
        sqlite3 -cmd ".timeout 10000" "$DB" \
            "update Entries set p_thumbnail = '$out' where p_uuid = '$uuid' and ifnull(p_thumbnail, '') not like '/%';" ||
            { echo "  cc.db update failed"; failed=$((failed + 1)); continue; }
    fi
    added=$((added + 1))
done <"$list"
rm -f "$list" /tmp/k4covers.out

status "$added covers added, $skipped without a PDF, $failed failed"
