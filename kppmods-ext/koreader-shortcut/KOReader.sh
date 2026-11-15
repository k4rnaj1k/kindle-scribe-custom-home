#!/bin/sh
# Name: KOReader
# Library/scriptlet shortcut for KOReader. kppmods' KOReader Shortcut extension
# (and k4home's button) launch /mnt/us/documents/KOReader.sh as root through the
# kppmods scriptlet launcher. This starts KOReader the same way the KUAL menu does.
KOREADER=/mnt/us/koreader/koreader.sh
if [ ! -x "$KOREADER" ]; then
    echo "KOReader is not installed at $KOREADER" >&2
    exit 1
fi
cd /mnt/us/koreader || exit 1
exec "$KOREADER" --kual
