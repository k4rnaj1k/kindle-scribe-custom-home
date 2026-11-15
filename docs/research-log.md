# Research log

Chronological log of the kppmods route: what was tried and what happened.
Entries 1–53 covered an earlier approach (patching the stock app in place) that
has been retired and is not published here, hence the numbering.

## Session: emulator + kppmods (2026-11-01)

54. **Reviewed katadelos repos.** `kppmods` loads React extensions into the stock
    KPP process (LD_PRELOAD host → evaluates JS in KPP's Hermes, patches stock
    components); `react-kindle` is its UI toolkit / a standalone-app kit (same
    limits as the earlier launcher route); `eink-emulator` runs Kindle firmware in
    QEMU, including Scribe 1 (`barolo`).
55. **Emulated the exact device firmware** (Scribe 1 5.16.6.1, build
    4181730001). Needed four emulator fixes plus zero-padding the 576 MiB rootfs to
    the 768 MiB layout: framework permission block (2 vs 5 finds), missing
    `sysctl.conf`, old `setsid` without `-f/-w` (no serial shell), and 5.16's
    userstore `g_mass_storage` claiming the UDC before `g_ether` (no USB SSH).
    Patch: `emulator/eink-emulator-scribe1-5.16.patch`. Stock Home boots; jb.sh and
    opkg 0.7.0 install on first boot.
56. **kppmods works on 5.16.6.1** (core `2.0.0+git.r32.172e9a9` from the public
    kindlehf feed; matches the source commit byte-for-byte for `host.js`).
    Module discovery succeeded (react 168, views 411, home 674, footer 403), all
    scripts evaluated, 0 errors. Its Home hook (`renderHomeFeed`) is absent on
    5.16; `emulator/kppmods-home-5.16.js` wraps HomeView `render` and swaps the
    per-instance `_renderHomeCards`. Test extension `kppmods-ext/k4home` replaced
    Home content (`logs/emu-kppmods-home.png`). Not yet tried on the device.
57. **k4home v0.2 (kppmods Home extension)** — notebooks list, KOReader button and
    an original deadlock SVG (`kppmods-ext/k4home/`, build/deploy with
    `scripts/k4home_ext.sh`). Findings: extension code has no `global` (use
    `globalThis.__r`); release KPP drops `console.log`, so failures are traced on
    screen. Notebook data path mirrors the Notebooks tab: NotebookService
    (module 606) `onViewMount` → `onViewInitialised({rootFolderName,
    totalBreadcrumbWidth, ppi, scale})` → `getViewData(offset, size, 'Render')` →
    `Notebook_updateNotebookData` event (`libraryItems`). Opening: module 505
    `NotebookUtils.executeNotebookAction(OPEN_ACTION, 506.ActionSourceId.NotebookDetails,
    {contentUuid}, item)`. The unregistered emulator returns no notebook data even
    to the stock tab, so the list is unverified until the real device. KOReader:
    `/mnt/us/documents/KOReader.sh` via `management.launchApp`, else
    `/mnt/us/koreader/koreader.sh --kual` as root; the exec path is verified
    (emulator reports "not installed"). Screenshot `logs/emu-k4home-koreader.png`.
58. **Store cart → KOReader** via `kppmods-koreader` 0.1.0 (public feed): it hooks
    `React.createElement` for `testID: 'chrome.store.button'` (5.16.6.1 builds the
    cart with `onPress`/`imageSrc`/`imageStyle`, so it matches). Needs
    `/mnt/us/documents/KOReader.sh` (added `kppmods-ext/koreader-shortcut/`), then
    `kppmod reload` + `kppmod enable koreader`. Emulator: icon replaced, tap runs the
    scriptlet as root; KOReader itself not installed there.
59. **k4home v0.3: LIBRARY dashboard** (inspired by a user-supplied mock-up):
    header + deadlock illustration, BOOKS row (cc.db via one sqlite3 exec; covers,
    progress, author), NOTEBOOKS (stock NotebookService), ARTICLES (`articles`
    collection). Emulator with 5 generated test PDFs: books render and fit one
    screen (`logs/emu-k4home-library-style.png`). After the stock Notebooks tab had
    been opened once, the extension received `Notebook_updateNotebookData` (empty
    list → "No notebooks yet."), so the notebook data path works; real titles and
    the open action still need the registered device. KPP layout units ≈ 1.8 px;
    `letterSpacing` clips the last glyph.
60. **Header image → user's Viper drawing** (`kppmods-ext/k4home/assets/vyper.webp`,
    366x210). KPP's image views are only known to decode PNG/JPEG/SVG, so
    `scripts/k4home_ext.sh build` converts `assets/*.webp` to greyscale PNG with
    Pillow from `~/emu/venv` (user-space venv). Renders in the emulator
    (`logs/emu-k4home-vyper.png`). Also observed: right after a KPP restart the
    notebook provider stays silent (fallback row) until the stock Notebooks tab has
    been opened once; after that the Home receives `Notebook_updateNotebookData`.
61. **kppmods deployed on the real Kindle** (battery 49 %, user-approved). Steps:
    fresh backup → reviewed and hash-checked opkg `install.sh` (only writes
    `/mnt/us/.eink-sdk`; `activate`/`kppmods-start` binds are RAM-only) → CA bundle
    copied into the SDK (missing on real devices) → bytecode patch removed (stock
    bundle) → `opkg install kppmods kppmods-koreader` → 5.16 host, k4home v0.3,
    KOReader.sh → `kppmods-start`, `kppmod enable koreader`. Result: 0 errors,
    real covers/progress/articles render, KOReader icon replaces the cart
    (`logs/device-kppmods-home1.png`). Both KPP restarts froze a lipc-daemon child,
    cleared automatically. Notebooks show the fallback right after a restart.
62. **k4home v0.5–0.6: paging, notebooks from ksdk.content.db, calendar**.
    Notebooks: the stock NotebookService call was wrong (stock
    `updateNotebookViewData` calls `getViewData(offset, pageSize, pageStepSize,
    isVisible=true)`), but fixing it did not help on the device: after a KPP
    restart the provider stays silent until the Notebooks tab has been opened. The
    notebook SDK store `/var/local/ksdk.content.db` (`Nodes`: uuid, title,
    `node_type` STANDALONE_NOTEBOOK/FOLDER, times, `additional_data` JSON with
    title/total_page/delete_state; `NodeRelations`: folder → child) has all
    notebooks with folders, read with `sqlite3 -readonly` (3.26, JSON1 available).
    Lists (notebooks, articles, uncategorized) page locally inside fixed-height
    paginated scrollers; an unsized vertical scroller swallowed the rest of the
    page. Running 5 `extension.exec` calls at once failed with "Command result
    unavailable" (broker evicts finished records at 32), so queries run
    sequentially. Calendar button opens the ReCalendar KFX (verified in the
    emulator with a copy from the device). Emulator KPP often segfaults on
    `kppmod reload` ("Collecting Debug Info" dialog) and respawns. Screens:
    `logs/emu-k4home-v8b.png`, `logs/device-k4home-v5-b.png` (device, v0.5).
    v0.6.3 on the device (2026-11-02): 43 notebooks with folders load on the first
    render after a KPP restart; CALENDAR is its own section beside BOOKS
    (`logs/device-k4home-v6.png`). Opening a notebook from Home is still untested.
63. **k4home v0.7: open fix + tap feedback**. Books/articles failed on the device
    with "Application Error": the reader logged `StartError ... URI Syntax` for
    `app://com.lab126.booklet.reader/mnt/us/documents/Downloads/Items01/Anti-social
    It's fads_ ....kfx` — the start request is parsed as a `java.net.URI`, so file
    names with spaces/`#`/`,` must be percent-encoded per path segment (verified in
    the emulator: raw fails, encoded opens). Tap feedback: the tapped item renders
    black with "Opening..." and the launch waits 400 ms, because winmgr pauses the
    display when an app launch starts (with 50 ms nothing repainted). An absolutely
    positioned overlay never showed over an `Image` (native image draws above
    siblings), so the cover is replaced instead; KPP `Text` paints its own light
    background, so inverted text needs `backgroundColor: '#000'`.
64. **k4home v0.8: BOOKS "+" → stock "Add or remove items"**. The Library's
    collection sheet action is `com.amazon.library.actions.set_collection_items`;
    its ActionService middleware (module 691) shows `AddOrRemoveToCollectionModal`
    with `{collection: items[0]}` and then sets `CollectionUUID`/`ItemsUUID`.
    From the Home extension: module 506 `ActionService.getInstance()` →
    `GetActions(ActionSourceId.ItemDetails, {uuid})` → `ExecuteAction(source,
    action, [{uuid, title, type: 'Collection'}], {contentUuid}, actionId)`, with the
    collection uuid from cc.db. Opens the full-screen editor over Home on the device
    (`logs/device-k4home-v8.png`). The emulator offers no collections (it is not
    registered to an account).
65. **k4home v0.9: per-row stock actions**. ActionService must be called exactly
    like the Library: `ExecuteAction(source, action, [item], {uuid})` — passing
    `{contentUuid}` made native handlers fail with
    `DeleteDocumentActionHandler::ExecuteAction:WrongParameters`. ARTICLES rows
    get a trash button (prefers `permanently_delete_item`, falls back to
    `delete_this_document`; both go through the stock confirmation middleware);
    UNCATEGORIZED rows get an add-to-collection button (`set_item_collections`,
    whose middleware shows PickCollectionModal with `libraryItem: {uuid}`). Lists
    reload when the action promise settles. Emulator: device-only delete of a
    sideloaded test file verified; the emulator offers no cloud delete or
    collections, so those are device-only checks.
66. **Cover Maker (kppmods-ext/cover-maker)**. The 8 items without covers were
    all KFX (`application/x-kfx-ebook`, PDOC). They are unencrypted containers
    (`CONT`, not `DRMION`); Send-to-Kindle PDF conversions keep the original PDF
    as one `$417` raw-media entity (found via the container index `$413/$414`),
    web articles store images as JPEG XR. `com.lab126.coverArtService
    refreshCoverArt` did nothing for these. KOReader's LuaJIT + `ffi/mupdf`
    renders page 1 headless on the device (0.4–23 s) and `ffi/jpeg` writes the
    JPEG; the scriptlet sets `p_thumbnail` (no triggers on Entries; journal mode
    delete; integrity_check ok afterwards). Also removed duplicates: the
    "KoReader" app (`documents/test.sh`, Hello World) and `/mnt/us/koreader-new`
    (old v2025.10 copy), settings backed up to `backups/kindle-20261102-koreader-dupes`.
67. **QR links** (experiment abandoned after entry 68; its code is no longer in
    this repository). Tapping a web link in a book makes the
    reader start `app://com.lab126.browser?view=<url>` (the whole URL
    percent-encoded; the browser's name/value parser decodes it once). The
    browser is Mesquite (`/usr/bin/mesquite -l com.lab126.browser -c
    file:///var/local/mesquite/browser/ -j`) running an HTML/JS UI; `onGo` in
    `javascripts/browser.js` navigates to `state.view`. Findings on the way:
    - appmgrd reads `appreg.db` only at startup (`app_found_for_uri` kept logging
      the old command after the row changed), so repointing the browser at a
      copy needs an appmgrd restart: dropped.
    - appmgrd's post-start copies `/opt/var/local/mesquite` over
      `/var/local/mesquite` (stock files rewritten, extra files kept), so
      in-place edits do not last.
    - The browser runs chrooted in `/chroot`, which has its own bind of
      `/var/local` made at boot: bind mounts on the main tree are invisible to
      it. Binding the patched `index.html`/`browser.js` over
      `/chroot/var/local/mesquite/browser/...` works and is RAM-only.
    - The top bar is KPP "Decanter chrome" (`BrowserTopNavBar`), configured by
      the page through `com.lab126.chromebar configureChrome`; KPP's
      `topNavBar.hideTopNavBar` is only read for KPP's own apps. A native modal
      from `kindle.chrome.createDialog(url, w, h, true, false)` (as the stock
      dialogViewer uses) at screen size covers the bar and status bar.
    - The reading-mode top bar is KPP too: its buttons are `ChromeImageButton`s
      (`aaMenu.button`, `goto.button`, `notesAndHighlightsReader.button`,
      `bookmarks.button`, `chrome.search.button`, `chrome.more.menu.button`).
      `ChromeImageButton` passes its testID to an inner `KPPButton`, so a
      `React.createElement` hook must match on `imageSrc` too, or it fires twice.
    - After a KPP restart the reader bar is empty until a document is opened
      again (the reader sends its bar config only on open).
    The QR encoder is qrcode-terminal's vendored Arase QRCode, bundled to ES5
    (mesquite's WebKit); decoded back with OpenCV in tests.
68. **Device browser is Chromium, not Mesquite**. On the real Scribe (5.16.6.1)
    appmgrd starts `com.lab126.browser` as `/usr/bin/browser -j` although
    `appreg.db` still says Mesquite (the emulator image runs Mesquite).
    `/usr/bin/browser` is a bash launcher: `exec chroot /chroot
    /usr/bin/chromium/bin/kindle_browser --no-zygote --single-process ...
    --content-shell-hide-toolbar` (content_shell based, Silk/80 UA, profile in
    `/mnt/us/system/browser`). So the Mesquite UI patch from entry 67 is never
    loaded on the device: with the mounts in place a book link still opened the
    page directly. Device stock Mesquite files are byte-identical to the
    emulator's (md5 b3539db8… browser.js, 1cce2565… index.html).

## Errors worth remembering

- `pkill -f KPPSimpleLauncher` over SSH terminated the session (matched the SSH
  command line). Use `pkill -x`.
- `cp` into `/tmp` fails with "No space left on device" after a crash: check
  `df /var` and clear `/var/tmp/dmcc.*` before diagnosing anything else.
- The Kindle does not answer ICMP; `ping` always fails even when SSH
  works. Test reachability with SSH.
- A malformed inline `rm -rf ~/$var` wiped the WSL home twice.
- Duplicate `requireNativeComponent` throws on this fork.
- The stock `KPPMainAppV2` records a "crash" every time it is stopped; this is
  normal for `stop kppmainapp`.
