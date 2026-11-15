# Emulated Scribe 1 (5.16.6.1) + kppmods

A safe test bed for Home customisation: the exact firmware of the real device
(Scribe 1, `barolo`/`bellatrix3`, 5.16.6.1 build `4181730001`) running in
[katadelos/eink-emulator](https://github.com/katadelos/eink-emulator), with
[katadelos/kppmods](https://github.com/katadelos/kppmods) loading React
extensions inside the stock KPP Home app. Verified 2026-11-01:

- stock KPP boots to Home (`logs/emu-k4scribe-boot1.png`);
- jb.sh jailbreak and opkg 0.7.0 install on first boot; SSH over USB works;
- kppmods core from the public feed activates on 5.16.6.1 with **0 errors**;
- a custom Home extension replaces the stock Home content while native chrome,
  search and the footer stay intact (`logs/emu-kppmods-home.png`).

Everything lives in WSL under `~/emu` (Ubuntu 26.04; nothing here touches the
real Kindle).

## One-time host setup

```bash
# needs your sudo password (run it yourself in a WSL terminal)
sudo apt-get install -y build-essential ninja-build pkg-config meson flex bison \
  python3-venv libglib2.0-dev libpixman-1-dev libslirp-dev zstd libsdl2-dev \
  libgtk-3-dev libarchive-dev nettle-dev libgmp-dev libssl-dev libgcrypt20-dev zlib1g-dev
mkdir -p ~/emu && cd ~/emu
git clone https://github.com/katadelos/eink-emulator.git
git -C eink-emulator config submodule.qemu.url https://github.com/katadelos/qemu.git
git -C eink-emulator submodule update --init --depth 1 qemu
git clone --depth 1 https://github.com/NiLuJe/KindleTool.git && make -C KindleTool -j8
# Node 22 in user space (kppmods' JS build needs >= 22.18)
#   -> ~/emu/node (from nodejs.org latest-v22.x, checksum-verified)
git clone https://github.com/katadelos/kppmods.git
git -C kppmods submodule update --init --depth 1 vendor/react-kindle
```

## Make the emulator accept 5.16.6.1 (Scribe 1)

The emulator targets newer firmware. Four small changes (base commit
`feb6cc38`) are in [eink-emulator-scribe1-5.16.patch](eink-emulator-scribe1-5.16.patch):

1. **Framework permission block**: 5.16 has two `find -exec` calls, not five;
   the emulator replaces the block with its own equivalent script either way.
2. **`/etc/upstart/sysctl.conf`** does not exist on 5.16; skip that tweak.
3. **Serial shell**: 5.16 ships an old util-linux `setsid` without `-f/-w`;
   the console job falls back to plain `getty`.
4. **USB network**: the 5.16 userstore job loads `g_mass_storage`, which grabs
   the only UDC before `g_ether`; apply the emulator's existing
   `remove_legacy_usb_storage` to Scribes too (a no-op on newer firmware).

Plus one manual step after downloading: the 5.16.6.1 rootfs is 576 MiB but the
Scribe image layout expects a 768 MiB partition image. It is plain ext3 without
verity, so zero-pad it (filesystem unchanged; `e2fsck` clean):

```bash
cd ~/emu/eink-emulator
git apply /mnt/e/Projects/vibecoded/kindle-reverse-engineering/emulator/eink-emulator-scribe1-5.16.patch
KT=$HOME/emu/KindleTool/KindleTool/Release
PATH=$KT:$PATH ./eink download --model kindle-scribe-1 5.16.6.1 < /dev/null   # stdin must be a real fd
F=firmware/versions/kindle-scribe-1/5.16.6.1
cp --sparse=always $F/rootfs.img $F/rootfs.img.orig-576M && truncate -s 768M $F/rootfs.img
PATH=$KT:$PATH ./eink create k4scribe --model kindle-scribe-1 --profile production \
  --firmware 5.16.6.1 --jbsh --opkg < /dev/null
./eink run k4scribe --serial-socket --qmp-socket      # WSLg window; first boot ~10 min
```

Access:

```bash
ssh -i ~/emu/eink-emulator/build/ssh/id_ed25519 -p 2222 root@127.0.0.1   # dropbear: use scp -O
python3 scripts/eink-qmp.py --machine k4scribe screendump out.png       # from ~/emu/eink-emulator
python3 scripts/eink-qmp.py --machine k4scribe tap X Y                  # 1860x2480 coordinates
```

## kppmods on 5.16.6.1

```bash
# in the guest
. /mnt/us/.eink-sdk/control/env
opkg update && opkg install kppmods          # 2.0.0+git.r32.172e9a9, kindlehf
```

The core package already ships `ui-host`, `launcher`, `mod-manager`,
`quick-settings`, `custom-icons`, `hide-help`, `hide-legal`, `antidox`,
`fake-registration` (disabled) and `system-tools` under
`/mnt/us/.eink-sdk/usr/lib/kppmods/extensions/`. Activation discovered every
module it needs from the stock 5.16.6.1 bundle (react 168, react-native 2,
views 411, home 674, footer 403, …).

**One firmware gap:** stock kppmods hooks `renderHomeFeed`, which 5.16.6.1 does
not have (its HomeView `render` calls the per-instance `_renderHomeCards`).
[kppmods-home-5.16.js](kppmods-home-5.16.js) is a drop-in
`ui/adapters/home.js` that keeps the original path and adds the 5.16 one.
Build the host and replace the installed one (stock copy kept in
`/mnt/us/ui-host.stock` in the guest):

```bash
cd ~/emu/kppmods && export PATH=$HOME/emu/node/bin:$PATH
cp /mnt/e/Projects/vibecoded/kindle-reverse-engineering/emulator/kppmods-home-5.16.js ui/adapters/home.js
node tools/build/build-host.cjs ~/emu/kppmods-out/host.js
node tools/build/build-extension.cjs \
  /mnt/e/Projects/vibecoded/kindle-reverse-engineering/kppmods-ext/k4home/main.jsx k4home \
  ~/emu/kppmods-out/k4home/main.js /mnt/e/Projects/vibecoded/kindle-reverse-engineering/kppmods-ext/k4home
E=/mnt/us/.eink-sdk/usr/lib/kppmods/extensions
# scp -O host.js -> $E/ui-host/host.js ; manifest.json + main.js -> $E/k4home/
# in the guest:  /var/run/eink-sdk/usr/bin/kppmods-start ; kppmod status
```

`kppmod status` should list `k4home` with "script evaluated" and `errors: 0`.
Activation restarts KPP, so the stock "Collecting Debug Info" alert appears
once (same as on the real device).

