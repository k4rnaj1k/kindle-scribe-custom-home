# Notes on the Scribe's Home app (firmware 5.16.6.1)

Observations useful for writing kppmods Home extensions like k4 Home. These come
from watching the device (processes, logs, databases, LIPC), not from Amazon
source code, and only cover what an extension needs.

## Processes

- The Home, Library, Notebooks tab and top/bottom bars belong to one app, **KPP**
  (`kppmainapp` Upstart job, `/app/bin/KPPMainApp`, running as user `framework`).
  It is React Native on Hermes; kppmods injects extensions into that process.
- Books and documents open in a separate reader process, started through
  **appmgrd**. The web browser is a separate Chromium-based app.
- Restarting KPP (`stop kppmainapp; start kppmainapp`, or any `kppmod reload`)
  is safe but has side effects: a crash report in `/mnt/us/documents`, and
  sometimes a frozen lipc-daemon child (see [troubleshooting.md](troubleshooting.md)).

## The Home screen

- The Home is one full-screen content window between separate top-bar and
  bottom-bar windows, so an extension that replaces the Home *content* keeps
  search, the top bar and the footer.
- Stock kppmods hooks the Home through a `renderHomeFeed` method that 5.16.6.1
  does not have; [emulator/kppmods-home-5.16.js](../emulator/kppmods-home-5.16.js)
  adds the 5.16 path.
- Layout units are about **1.8 device pixels**: the Scribe's 1860 px width is
  about 1030 units.
- Text can only use the firmware's fonts, and `letterSpacing` clips the last
  glyph, so decorative headings are images.
- Image views decode PNG, JPEG and SVG (not WebP).

## Data an extension can read

All read-only, through `/usr/bin/sqlite3 -readonly` (3.26, JSON1 available).
Wait for locks (`.timeout 5000`): the Library and reader write these files.

**`/var/local/cc.db`**: the Library.

- `Entries`: one row per item and per collection. Useful columns: `p_uuid`,
  `p_type` (`Entry:Item`, `Collection`), `p_location` (file path; null when only
  in the cloud), `p_titles_0_nominal`, `p_credits_0_name_collation` (author),
  `p_percentFinished`, `p_thumbnail` (cover path, `0`/empty until the Library has
  made one), `p_lastAccess`, `p_isVisibleInHome`, `p_collectionCount`, `p_mimeType`.
- `Collections(i_collection_uuid, i_member_uuid, i_order, ...)`: membership.

```sql
-- collections
SELECT p_uuid, p_titles_0_nominal FROM Entries WHERE p_type = 'Collection';
-- members of a collection by name, most recently opened first
SELECT e.p_titles_0_nominal, e.p_location FROM Entries e
WHERE e.p_uuid IN (SELECT c.i_member_uuid FROM Collections c
                   JOIN Entries col ON col.p_uuid = c.i_collection_uuid
                   WHERE col.p_titles_0_nominal = 'reading' COLLATE NOCASE)
ORDER BY e.p_lastAccess DESC;
```

**`/var/local/ksdk.content.db`**: notebooks. `Nodes` (`uuid`, `node_type`
`STANDALONE_NOTEBOOK`/`FOLDER`, `title_collation`, `last_access_time`,
`additional_data` JSON with `title`, `total_page`, `delete_state`) and
`NodeRelations` (folder → child). Its indexes use an `icu` collation, so the
stock `sqlite3` can read it but not write it. The stock notebook list provider
stays silent after a KPP restart until the Notebooks tab is opened, which is why
k4 Home reads this file directly.

**Notebook ink** lives in `/mnt/us/.notebooks/` (one folder per notebook, plus
`<cdeKey>!!PDOC!!notebook` folders for handwriting on Send-to-Kindle PDFs); see
[k4sync/README.md](../kppmods-ext/k4sync/README.md) for the format.

## Opening things

- Books and documents: start `app://com.lab126.booklet.reader<path>` through
  appmgrd, with **each path segment percent-encoded** (the reader parses the
  request as a URI; spaces, `#` or `,` otherwise fail with "URI Syntax").
- Views of the main app: `app://com.lab126.KPPMainApp/?view=KPP_LIBRARY`,
  `...?view=KPP_NOTEBOOK`, `...?view=KPP_HOME`.
- From a shell: `lipc-set-prop com.lab126.appmgrd start "<uri>"`;
  `lipc-get-prop com.lab126.appmgrd activeApp` shows what is in front.
- appmgrd freezes the display as soon as a launch starts, so paint any "Opening..."
  feedback first and launch ~400 ms later.
- Stock Library actions (add/remove collection items, delete, pick collections)
  can be run from an extension through the app's ActionService, which shows the
  stock confirmation dialogs; see `runLibraryAction` in
  [main.jsx](../kppmods-ext/k4home/main.jsx). The module ids it uses are specific
  to 5.16.6.1.

## kppmods practicalities

- `extension.exec` runs commands through the kppmods broker, which keeps 32
  command records: run queries **one at a time**, or results get evicted
  ("Command result unavailable"). Its `timeout` is in seconds.
- Release KPP drops `console.log`; use `extension.log` or show errors on screen.
- Extension code has no `global`; use `globalThis`.
- A vertical scroller needs a fixed height, or it takes the rest of the page.
