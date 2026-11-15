# k4sync: "Send to Obsidian"

> Works only on your own **unencrypted** documents (Send-to-Kindle PDFs and
> notebooks). Files that are not plain `CONT` containers, such as purchased
> books, are rejected; nothing is ever decrypted.

A button in the kppmods Apps list (`/mnt/us/documents/SendToObsidian.sh`) that
sends documents changed since the last send to the Pi's WebDAV inbox
([vault-inbox](../../vault-inbox/README.md)), where livesync-bridge puts them in
the vault's `Kindle/` folder:

- `Kindle/Articles/<title>.pdf`: every member of the `articles` collection
  (`COLLECTION` in the config), with or without handwriting, plus any other
  Send-to-Kindle PDF you have written on. It is the **original PDF**, with the
  handwriting added as `/Ink` annotations in an incremental update, so text,
  links and pages stay as they were. Web articles and books (KFX with no PDF
  inside) are skipped.
- `Kindle/Notebooks/<title>.pdf`: every notebook (titles from
  `/var/local/ksdk.content.db`; notebooks in the trash are skipped), with
  all pages (blank ones too) as vector ink on the page template (lines,
  grid, dots, habit tracker…). Templates are vector drawings stored in the
  notebook itself: a section with `nmdl.template_type` whose `$272` drawing
  holds `$273` paths (`$249` = `[op, args…]`, 0 M / 1 L / 2 Q / 3 C / 4 Z).

`sh k4sync.sh send --dry-run` writes the PDFs to `/mnt/us/k4sync/dry-run/`
instead and marks nothing as sent.

**Per item (k4 Home):** NOTEBOOKS and ARTICLES rows in k4 Home have an upload
button that runs `k4sync.sh send-item --quiet <kfx path | notebook uuid>`.
This sends that item even if it is unchanged. Sends are serialised by a lock
in `/var/tmp/k4sync` and run as `framework` (tested). The config is read with
CRs stripped, so a Windows-edited `k4sync.conf` still works.

| File | Role |
|---|---|
| `k4ion.lua` | nbk → fragments: strips KDF fingerprint records, reads via the stock `sqlite3`, Ion-binary decoder |
| `k4strokes.lua` | fragments → pages of strokes (kfxlib's notebook model, point-array delta decoder) |
| `k4pdf.lua` | pure-Lua PDF writer for notebooks (vector strokes; Flate via zlib under LuaJIT) |
| `k4pdfedit.lua` | adds `/Ink` annotations to an existing PDF as an incremental update |
| `k4sync.lua` | `render NBK|- OUT.pdf [--kfx DOC.kfx --yjr DOC.yjr]`: KFX → PDF, `.yjr` page mapping; KOReader's luajit/MuPDF needed only for ink on PDFs |
| `k4sync.sh` | `send [--dry-run]` / `status`: selection, snapshot, render, upload (`.partial` + `MOVE`), per-document state |
| `k4sync-dump.lua` | debugging: print what an nbk contains |
| `test_k4sync.lua` | unit tests (`lua test_k4sync.lua`) |

Where the data lives (verified on the device 2026-11-02): handwriting on
`Downloads/Items01/<title>.pdf_<cdeKey>.kfx` is stored in
`/mnt/us/.notebooks/<cdeKey>!!PDOC!!notebook/nbk`, and standalone notebooks
are the bare-UUID folders there.

## Install

```bash
# on the Kindle
mkdir -p /mnt/us/k4sync
# copy *.lua, k4sync.sh → /mnt/us/k4sync/ ; SendToObsidian.sh → /mnt/us/documents/
cp k4sync.conf.example /mnt/us/k4sync/k4sync.conf   # set WEBDAV_URL / USER / PASS
```

Page mapping: the article store's sections carry no page number. The
reader's sidecar (`<kfx>.sdr/*.yjr`) has one `annotation.personal.handwritten_note`
record per section, holding a position `"<base64>:<n>"`, where the base64 is
`01` + the element id as LE u64, plus the section id. In the KFX, that element
is a page's full-page image, whose `$175` names a `$164` resource with
`$564` = 0-based PDF page.

Snapshots are raw copies, not `sqlite3 .backup`. The stock sqlite3 ignores
the fingerprint records, and its backup copies header-page-count × page size
bytes of the raw file, cutting 1 KiB per record off the end (corrupting
stores over 1 MiB). A copy is accepted when the rollback journal is empty
and the store's mtime/size are unchanged across the copy.

## Status (2026-11-02)

- Full dry run on the device: 45 articles (14 with ink), 42 notebooks, 9
  web articles/books skipped, 0 failures; ~6 min for everything the first
  time, after that only what changed.
- "What I Self-Host": ink on PDF pages 1 and 4 exactly where it was written
  (checked by the user); output opens without repair, text and links intact.
- Notebook templates checked on the device for dotted, graph, habit tracker,
  medium/wide rule and plain (`logs/k4sync-device-20261102/k4review/templates/`).
- Upload tested only against a WebDAV stand-in (emulator), not yet against
  the Pi stack.
