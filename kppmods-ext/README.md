# kppmods extensions

`k4home/` (v0.13) replaces the stock Home content (kppmods `home` registry) with a
library dashboard modelled on a "LIBRARY" mock-up. Collections, title, images,
hidden sections and the Obsidian buttons are options: see
[docs/configuration.md](../docs/configuration.md).

- **Header**: "scribe home" in Monocraft and section headings in JetBrains Mono,
  pre-rendered to PNG by `tools/render_headings.py` (KPP text can only use
  firmware fonts), or a text title / logo image from the options; and the Viper
  drawing (`assets/vyper.webp`, PNG at build; option `headerImage`).
- **Missing data is not fatal**: each query runs on its own, so a missing
  collection or an unreadable database only empties that section, with a hint
  (e.g. the names of the collections that do exist).
- **BOOKS**: the `reading` collection (option `booksCollection`, `*` = all) from
  `/var/local/cc.db`, 4 per page (5 without a calendar) with cover, progress,
  author and "% read"; tap opens the reader via appmgrd
  (`app://com.lab126.booklet.reader<path>`).
- **CALENDAR**: its own section to the right of BOOKS, a large ReCalendar cover
  (`assets/calendar.svg` until the Library has made one) that opens it in the
  reader. Option `calendarTitle` (default `ReCalendar`, case-insensitive); the
  item is left out of BOOKS, and the section is hidden when it is not found.
- **NOTEBOOKS**: every notebook from `/var/local/ksdk.content.db` (the notebook
  SDK store: `Nodes` + `NodeRelations`), most recently used first, with its parent
  folder on the right. Read directly because the stock NotebookService stays
  silent after a KPP restart until the Notebooks tab has been opened once. Tap
  opens through the stock open action (module 505/506, firmware 5.16.6.1 only).
- BOOKS "+" opens the stock **Add or remove items** screen for the books
  collection: it runs `com.amazon.library.actions.set_collection_items` through
  ActionService (module 506; the first of the ItemDetails/ItemCover/OverflowMenu/
  LibraryHeader sources that offers it), whose middleware shows
  `AddOrRemoveToCollectionModal`. If that is unavailable it opens the Library and
  says why under BOOKS.
- **ARTICLES**: the `articles` collection (option `articlesCollection`). Each row
  has a trash button: stock "Permanently delete" (`permanently_delete_item`,
  device + Amazon cloud), or "Delete this document" (device only) when the item
  has no cloud copy; the stock confirmation dialog appears first.
- **Send to Obsidian** (v0.12): NOTEBOOKS and ARTICLES rows have an upload
  button that runs `/mnt/us/k4sync/k4sync.sh send-item --quiet <kfx path |
  notebook uuid>` through `extension.exec` (as `framework`, timeout 900 s; the
  broker's `timeout` is in seconds). Sends are queued one at a time; the row
  shows "Waiting to send..." / "Sending to Obsidian..." / "Sent to Obsidian" /
  "Send failed" in place of its detail. See [k4sync/README.md](k4sync/README.md).
- **UNCATEGORIZED**: items in no collection (scripts and crash reports excluded).
  Each row has an add-to-collection button: the stock collection picker
  (`set_item_collections`).

Tapping a book, article, notebook or the calendar turns it black at once with
"Opening..." (an e-ink flash), then launches it 400 ms later: the window manager
freezes the display as soon as an app launch starts. Books and documents open
via `app://com.lab126.booklet.reader<path>` with each path segment
percent-encoded; the reader parses the request as a `java.net.URI`, so raw names
with spaces, `#` or `,` failed with "URI Syntax" and an Application Error alert.

The page is a native paginated scroller (explicit height from `onLayout`; with
`flex: 1` alone it rendered nothing, and `mode="controlled"` did not drag) with
the stock scrollbar on the right. The scroller is controlled: its scrollbar is
drawn from the `offset` prop (4294967295 = end), so `onScroll`'s
`contentOffset.y` is fed back into `offset`. NOTEBOOKS and ARTICLES show 5 rows per page and
turn with left/right swipes (a horizontal paginated scroller around the rows,
width measured with `onLayout`) or the arrows; vertical swipes scroll the page; UNCATEGORIZED lists every item below
them and is hidden when empty. Queries wait up to 5 s for database locks
(`.timeout`), and a failed refresh keeps the last lists and retries.

Every list loads up to 100 items and pages locally ("1-3 of N ‹ ›"); swiping a
list turns one page (at most one per 800 ms, since one swipe reports several
scroll events). Lists reload when Home is shown or refreshed and every 30 s,
re-rendering only on change. All data comes from read-only `sqlite3` calls run
one at a time: the kppmods broker keeps 32 command records and evicts finished
ones before they are read when several run at once ("Command result unavailable").

Layout units are about 1.8x device pixels on the Scribe (1860 px ≈ 1030 units),
and `letterSpacing` must not be used (KPP measures text without it and clips the
last glyph). Vertical scrollers need a fixed height (rows are 44 units), or they
take the rest of the page and push later sections off screen. cc.db stores
`p_thumbnail = 0` until the Library has generated a cover; such tiles show a title
placeholder.

Emulator testing: its notebook store is empty and the `sqlite3` CLI cannot write
`ksdk.content.db` (indexes use an `icu` collation), so option `notebookDb` can
point at a test copy with the same tables. Requires the 5.16 Home hook from
`emulator/kppmods-home-5.16.js` in the UI host. Build/deploy:

```bash
bash scripts/k4home_ext.sh build        # -> ~/emu/kppmods-out/k4home
bash scripts/k4home_ext.sh deploy-emu   # emulator; reloads the extension
```

## Top-bar KOReader button (replaces the Store cart)

Uses kppmods' own `kppmods-koreader` package ("KOReader Shortcut"). It wraps
`React.createElement` and swaps the props of the element with
`testID: "chrome.store.button"` (present on 5.16.6.1) for a KOReader icon whose
press runs `/mnt/us/documents/KOReader.sh` through the scriptlet launcher (root).
The extension stays unavailable until that script exists, so install
[koreader-shortcut/KOReader.sh](koreader-shortcut/KOReader.sh), which starts
KOReader the way the KUAL menu does (`/mnt/us/koreader/koreader.sh --kual`):

```sh
# on the device (SDK env loaded: . /mnt/us/.eink-sdk/control/env)
cp KOReader.sh /mnt/us/documents/ && chmod 755 /mnt/us/documents/KOReader.sh
opkg install kppmods-koreader
kppmod reload            # rescan packages
kppmod enable koreader   # disabled by default
```

The script also appears in the Library as a document titled "KOReader", and
k4home's "Launch KOReader" button uses it too. Verified in the emulator: the cart
became the KOReader icon (`logs/emu-koreader-cart.png`) and a tap ran the script
(`/var/run/kppmods/app.log`); actually starting KOReader is unverified there
because KOReader is not installed in the emulator.

## Installing on the real Kindle

See [docs/install.md](../docs/install.md) for the full procedure (eink-sdk,
kppmods, the 5.16 UI host, k4home, KOReader button), re-enabling after a
reboot, and undoing it.
