# Cover Maker

Gives covers to Kindle documents that have none. Shows up as **Cover Maker** in
the kppmods Apps list (it is a scriptlet, `/mnt/us/documents/CoverMaker.sh`).

Send-to-Kindle stores converted PDFs as unencrypted KFX containers (`CONT`)
that keep the original PDF as one raw-media entity (`$417`). For each KFX item
in `cc.db` without a cover, `k4covers.lua` (run with KOReader's LuaJIT)
extracts that PDF, renders page 1 with KOReader's MuPDF and writes a grayscale
JPEG (360 px wide) as `/mnt/us/system/thumbnails/thumbnail_<cdeKey>_<cdeType>_portrait.jpg`,
the Kindle's own naming. The scriptlet then sets that item's `p_thumbnail`, so
the Library and k4 Home show it.

> Works only on your own **unencrypted** documents (Send-to-Kindle PDFs and
> notebooks). Files that are not plain `CONT` containers, such as purchased
> books, are rejected; nothing is ever decrypted.

- Only items whose `p_thumbnail` is empty are touched; an existing cover file
  is reused, never overwritten (some had a Kindle-made file that cc.db did not
  point to).
- `cc.db` is copied to `/mnt/us/k4covers/backup/` before each run (last 3 kept).
- Web articles without an embedded PDF (their images are JPEG XR) are skipped.
- Log: `/mnt/us/k4covers/last-run.log`; a one-line summary is drawn with `eips`.
- Needs KOReader at `/mnt/us/koreader` (uses `ffi/mupdf`, `ffi/jpeg`).

```bash
bash scripts/cover_maker.sh install   # copy to the Kindle
bash scripts/cover_maker.sh dry-run   # render into /tmp/k4covers-dry only
bash scripts/cover_maker.sh run       # add covers
```

Undo: copy a backup over `/var/local/cc.db` while KPP is stopped, or set
`p_thumbnail` back to NULL for the items listed in the log.

First run on the device (2026-11-02): 8 items without a cover → 6 rendered,
1 linked to an existing file, 1 web article skipped; `pragma integrity_check`
ok. Rendering takes ~1 s per PDF, ~20 s for a 11 MB scanned book.
