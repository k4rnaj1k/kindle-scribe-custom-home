#!/bin/sh
# Name: Send to Obsidian
# Author: k4home
#
# Sends every notebook and annotated Send-to-Kindle PDF whose handwriting
# changed since the last send to the Obsidian vault (via the Pi's WebDAV
# inbox) as PDFs. Shows up in the kppmods Apps list; the work is done by
# /mnt/us/k4sync/k4sync.sh, which logs to /mnt/us/k4sync/k4sync.log.
exec sh /mnt/us/k4sync/k4sync.sh send >/dev/null 2>&1
