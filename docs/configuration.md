# Configuring k4 Home

Everything below is a k4 Home **option**. There are two places to set options:

1. **An options file, no rebuild** (recommended): kppmods merges per-extension
   overrides from its `options.json` over the manifest defaults. Write a file
   like this on your PC, e.g. `my-options.json`:

   ```json
   {
     "k4home": {
       "booksCollection": "Currently reading",
       "articlesCollection": ["Articles", "Read later"],
       "title": "my scribe"
     }
   }
   ```

   and install it (this restarts the Home app once):

   ```bash
   bash scripts/k4home_ext.sh set-options my-options.json
   ```

   Keys you leave out keep their defaults; lists replace the default list. The
   file must be valid JSON (no comments, no trailing commas); the script checks.

   By hand on the Kindle: kppmods keeps the file at
   `/mnt/us/.eink-sdk/var/lib/kppmods/options.json` but only reads its copy in
   `/var/local/kppmods/state/`, which it refreshes when KPP Mods starts. So
   after editing the first one (over SSH or USB), copy it over and reload:

   ```sh
   cp /mnt/us/.eink-sdk/var/lib/kppmods/options.json /var/local/kppmods/state/
   . /mnt/us/.eink-sdk/control/env; kppmod reload
   ```

   `kppmod reload k4home` alone is not enough: it reloads the code, not the options.

2. **In the repository**: edit `options` in
   [kppmods-ext/k4home/manifest.json](../kppmods-ext/k4home/manifest.json) and
   deploy again (`bash scripts/k4home_ext.sh deploy-device`). This changes the
   defaults for every install made from your copy.

## All options

| Option | Default | What it does |
|---|---|---|
| `booksCollection` | `"reading"` | Collection(s) shown under BOOKS. A name, a list of names, or `"*"` for every book and document. |
| `articlesCollection` | `"articles"` | Collection(s) shown under ARTICLES. Same forms as above. |
| `calendarTitle` | `"ReCalendar"` | Title of the document shown as the CALENDAR tile. The tile is hidden when no downloaded item has that title. |
| `hideSections` | `[]` | Sections to leave out: any of `"books"`, `"calendar"`, `"notebooks"`, `"articles"`, `"uncategorized"`. |
| `title` | `""` | Page title as text. Empty = the pre-rendered `assets/heading-title.png` (default "scribe home"). |
| `titleSize` | `44` | Font size of a text `title`, in layout units. |
| `titleImage` | `""` | An image used as the title (a logo). Overrides `title`. |
| `titleImageWidth`, `titleImageHeight` | `300`, `60` | Size of `titleImage` in layout units. |
| `headerImage` | `"assets/vyper.png"` | The image to the right of the title (by default the author's Viper drawing). Any PNG/JPEG/SVG on the Kindle (`"/mnt/us/…"`) or in `assets/`; `""` hides it. |
| `headerImageWidth`, `headerImageHeight` | `260`, `149` | Size of `headerImage` in layout units. |
| `sendToObsidian` | `true` | Show the upload buttons on NOTEBOOKS and ARTICLES rows (needs k4sync, below). |
| `k4syncScript` | `"/mnt/us/k4sync/k4sync.sh"` | Where the upload buttons find k4sync. |
| `notebookDb` | `"/var/local/ksdk.content.db"` | Notebook store (only for testing with a copy). |

## Pointing it at your collections

Collections are matched **by name, ignoring case**, against the collections in
the Kindle's Library (the stock `cc.db`). Use the names exactly as the Library
shows them; spaces and punctuation count.

```json
{ "k4home": { "booksCollection": "Currently Reading" } }
{ "k4home": { "booksCollection": ["Fiction", "Non-fiction"] } }
{ "k4home": { "booksCollection": "*" } }
```

A list shows the items of every listed collection together (most recently
opened first). `"*"` shows everything visible on the stock Home, minus scripts
and crash reports.

Nothing breaks when a collection does not exist. The section stays and says
why it is empty, for example:

> No collection named "reading" (option booksCollection). Collections on this
> Kindle: Articles, Comics, Currently Reading.

so you can copy the right name from the Home screen itself. Other cases:

- *"Create a collection named … in the Library"*: the Kindle has no collections
  at all yet (Library → ⋯ → Create collection).
- *"Add books to the … collection"*: the collection exists but is empty.
- *"Could not read …"*: that one query failed (the message is sqlite3's). Other
  sections keep working; the whole page only shows "Library unavailable" when
  every query failed.

BOOKS **+** opens the stock "Add or remove items" editor for the first listed
collection that exists. With `"*"` or no such collection it opens the Library.

Items that are in no collection at all are listed under UNCATEGORIZED, each
with a button that opens the stock collection picker; that section hides
itself when it is empty.

## Title, logo and header image

Three ways to change the title, from simplest:

1. **Text title**: `"title": "my scribe"`, optionally `"titleSize": 36`. It is
   drawn in the Kindle's own font (KPP can only use firmware fonts).
2. **Re-render the pixel-font title** (Monocraft, like the default): on a PC
   with Python and Pillow, download [Monocraft](https://github.com/IdreesInc/Monocraft)
   and [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) into a folder, then

   ```bash
   cd kppmods-ext/k4home
   python3 tools/render_headings.py ~/fonts --title "my scribe" --title-px 80
   ```

   This rewrites `assets/heading-*.png` and `headings.gen.js`; redeploy. Leave
   option `title` empty so the image is used. `--title-px` is the font size in
   pixels (default 80; the old "k4 library" title was 118).
3. **Your own logo image** as the title: `"titleImage"` plus its size.

Images (`titleImage`, `headerImage`) can be:

- a file in the extension: put it in `kppmods-ext/k4home/assets/` and use
  `"assets/logo.png"` (redeploy to copy it), or
- **any file on the Kindle**, by absolute path, with no rebuild: copy it over
  USB or SSH to e.g. `/mnt/us/k4home/logo.png` and use `"/mnt/us/k4home/logo.png"`.

Use **PNG, JPEG or SVG**: KPP's image view is only known to decode those. (The
build converts `.webp` files in `assets/` to greyscale PNG, so `vyper.webp` is
referenced as `vyper.png`.) Give the size in **layout units**: one unit is
about 1.8 screen pixels on the Scribe, so a 540 × 270 px image fits
`"headerImageWidth": 300, "headerImageHeight": 150`. Keep the aspect ratio of
the file, or it is stretched. Greyscale images with a white or transparent
background look best on e-ink.

```json
{
  "k4home": {
    "titleImage": "/mnt/us/k4home/logo.png",
    "titleImageWidth": 320,
    "titleImageHeight": 64,
    "headerImage": ""
  }
}
```

The small row icons (`notebook.svg`, `send.svg`, `delete.svg`,
`add-to-collection.svg`) and the calendar placeholder (`calendar.svg`) are
replaced by overwriting the files in `assets/` and redeploying; keep them square
SVGs.

## Making "Send to Obsidian" work

The upload button on each NOTEBOOKS and ARTICLES row runs
`k4sync.sh send-item <item>` on the Kindle. k4sync renders the notebook (or the
original PDF with your handwriting added as annotations) to a PDF and uploads it
over **WebDAV**. On the receiving side, the [vault-inbox](../vault-inbox/README.md)
stack writes those PDFs into an Obsidian vault synced with Self-hosted LiveSync.
Without k4sync the button only shows "Send failed"; set
`"sendToObsidian": false` to hide it.

**1. Receiving side** (a server on your network, e.g. a Raspberry Pi with
Docker). You need an Obsidian vault already synced with the
[Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync) plugin and its
CouchDB. Deploy [vault-inbox/docker-compose.yml](../vault-inbox/docker-compose.yml)
with the variables from [vault-inbox/.env.example](../vault-inbox/.env.example):
CouchDB URL and login, the LiveSync E2EE passphrase (and vault ID key on recent
vaults), the target folder (`Kindle/`), and a WebDAV login for the Kindle
(`openssl rand -hex 24` makes a good password). Then check it from a PC:

```bash
echo "# hello" > hello.md
curl -fsS -u kindle:PASS -T hello.md http://SERVER:8080/hello.md
```

`hello.md` should appear in the vault's `Kindle/` folder within a minute.

Any other WebDAV server works too (Nextcloud, rclone, Apache); you then sync
that folder into your vault yourself. k4sync only needs `PUT`, `MKCOL` and `MOVE`.

**2. On the Kindle**, install k4sync from the PC:

```bash
bash scripts/k4home_ext.sh install-k4sync
```

This copies k4sync to `/mnt/us/k4sync/`, adds **Send to Obsidian** to the
Apps list, and creates `k4sync.conf` from the template (an existing one is
kept). Edit `/mnt/us/k4sync/k4sync.conf` (over SSH, or over USB as
`k4sync/k4sync.conf`; Windows line endings are fine):

```sh
WEBDAV_URL=http://192.168.1.20:8080   # the server, no trailing slash
WEBDAV_USER=kindle
WEBDAV_PASS=the-password-from-step-1
COLLECTION=articles                   # every article in it is sent; other PDFs once you write on them
KOREADER=/mnt/us/koreader             # needed only for handwriting on PDFs
```

**3. Test** without uploading, then for real:

```sh
# on the Kindle
sh /mnt/us/k4sync/k4sync.sh send --dry-run   # PDFs go to /mnt/us/k4sync/dry-run/
sh /mnt/us/k4sync/k4sync.sh status
```

Then tap an upload button on Home: the row shows "Waiting to send..." →
"Sending to Obsidian..." → "Sent to Obsidian". **Send to Obsidian** in the
kppmods Apps list sends everything that changed since the last send. Results
end up in the vault as `Kindle/Notebooks/<title>.pdf` and
`Kindle/Articles/<title>.pdf`.

If a send fails, read `/mnt/us/k4sync/k4sync.log`. Common causes: wrong URL or
password (HTTP 401), the Kindle is not on the same network as the server, or
Wi-Fi is off. Keep the WebDAV port on your LAN; it is plain HTTP with basic
auth. Details on the formats and what is sent: [k4sync/README.md](../kppmods-ext/k4sync/README.md).
