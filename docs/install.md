# Installing k4 Home

k4 Home is a kppmods extension, so the order is: get **kppmods** running on the
Kindle, then let `scripts/k4home_ext.sh` build and install k4 Home.
Nothing touches the system partition, and a reboot always gives you the stock
Kindle back until you start KPP Mods again.

## 1. What you need

- A Kindle Scribe (1st gen) on firmware **5.16.6.1**, jailbroken, with root SSH
  (port 2222, key login). Other firmware versions are untested.
- A Linux or WSL shell on your PC with git, Python 3 and Node.js **≥ 22.18**.
- Optional: [KOReader](https://github.com/koreader/koreader) in `/mnt/us/koreader`
  (for the KOReader button, Cover Maker, and handwriting on PDFs).

## 2. Install kppmods

Follow kppmods' own instructions: [katadelos/kppmods](https://github.com/katadelos/kppmods)
and its [runtime guide](https://github.com/katadelos/kppmods/blob/main/docs/runtime.md).
It installs the eink-sdk (opkg) and kppmods into `/mnt/us/.eink-sdk`.
Read the installer before you run it. The package names are `kppmods`, plus
`kppmods-koreader` if you want the KOReader button.

Two notes from installing on a real Scribe:

- If `opkg update` fails with *"Problem with the SSL CA cert"*, give the SDK the
  firmware's certificates:
  `cp -L /etc/ssl/certs/ca-certificates.crt /mnt/us/.eink-sdk/etc/ssl/certs/`
- The version tested here is kppmods `2.0.0+git.r32.172e9a9`.

Check it before going on (on the Kindle):

```sh
. /mnt/us/.eink-sdk/control/env && kppmod status    # no errors
```

## 3. Install k4 Home

From this repository on your PC:

```bash
export KINDLE_DEV=root@192.168.1.50       # your Kindle; KINDLE_KEY if not ~/.ssh/kindle_key
bash scripts/k4home_ext.sh setup          # once: kppmods build tools + Pillow
bash scripts/k4home_ext.sh install-host   # once: kppmods UI host with the 5.16 Home hook
bash scripts/k4home_ext.sh deploy-device  # k4 Home itself (again after every change)
```

- `setup` clones kppmods to `~/emu/kppmods` (for its build tools), runs `npm ci`
  and makes a Python venv with Pillow in `~/emu/venv`. Override the paths with
  `KPPMODS_DIR`, `NODE_DIR`, `VENV`.
- `install-host` is needed because stock kppmods cannot hook the Home on
  5.16.6.1. It builds kppmods' UI host with
  [emulator/kppmods-home-5.16.js](../emulator/kppmods-home-5.16.js), keeps the
  packaged one as `/mnt/us/ui-host.stock.js`, and installs it. Run it again
  after upgrading kppmods with opkg.
- The installing commands restart the Home app. The Kindle may show
  **"Collecting Debug Info"**; close it. The script then deletes the crash
  report this leaves in your Library, and clears a stock lipc-daemon hang that
  restarts sometimes cause (see [troubleshooting.md](troubleshooting.md)).

Press Home on the Kindle. With no collections set up yet, each section tells you
what it is looking for.

**Using a release instead of building k4 Home:** download `k4home-<version>.tar.gz`
from [Releases](https://github.com/k4rnaj1k/kindle-scribe-custom-home/releases)
(built by GitHub Actions from the tagged commit), unpack it, and install it with

```bash
K4_PREBUILT=path/to/k4home bash scripts/k4home_ext.sh deploy-device
```

or copy the `k4home/` folder to `/mnt/us/.eink-sdk/usr/lib/kppmods/extensions/`
yourself and run `kppmod reload` on the Kindle. Releases do not include the 5.16
UI host (it is kppmods' code), so `setup` and `install-host` are still needed once.

Optional extras:

```bash
bash scripts/k4home_ext.sh install-koreader   # Store cart → KOReader button (needs kppmods-koreader)
bash scripts/k4home_ext.sh install-k4sync     # Send to Obsidian; then see configuration.md
bash scripts/cover_maker.sh install           # Cover Maker in the Apps list (needs KOReader)
```

## 4. Configure

Point the sections at your collections, change the title or images, hide
sections: **[configuration.md](configuration.md)**. The short version, from the PC:

```bash
echo '{ "k4home": { "booksCollection": "Currently Reading", "headerImage": "/mnt/us/my-logo.png" } }' > my-options.json
bash scripts/k4home_ext.sh set-options my-options.json
```

## After a reboot

The Kindle starts stock. Open **KPP Mods** in the Library (installed by
kppmods) to bring k4 Home back.

If a book will not open after any restart, run `bash scripts/lipcd_check.sh --fix`
([troubleshooting.md](troubleshooting.md)).

## Undo

| To | Do |
|---|---|
| Show the stock Home again | `kppmod disable k4home` (on the Kindle) |
| Get the Store cart back | `kppmod disable koreader` |
| Stop everything until next time | reboot |
| Restore kppmods' own UI host | copy `/mnt/us/ui-host.stock.js` over `/mnt/us/.eink-sdk/usr/lib/kppmods/extensions/ui-host/host.js` |
| Remove k4 Home | `rm -r /mnt/us/.eink-sdk/usr/lib/kppmods/extensions/k4home` |
| Remove kppmods | see kppmods' documentation |

Before larger experiments, `bash scripts/kindle_backup.sh` saves your Library
database, notebook list and settings to `backups/`.
