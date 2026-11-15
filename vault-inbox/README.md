# vault-inbox — Kindle → Obsidian (LiveSync) on the Pi

A Portainer stack that receives files from the Kindle and puts them in the
Obsidian vault's `Kindle/` folder. It contains no custom code: just two upstream images.

```
Kindle ──WebDAV PUT/MOVE──▶ webdav (rclone) ──▶ volume kindle_inbox ◀──▶ bridge (livesync-bridge) ──▶ CouchDB ──▶ Obsidian
```

| Service | Image | Role |
|---|---|---|
| `webdav` | `rclone/rclone:1.69.1` | Password-protected upload endpoint on `:8080` |
| `bridge` | built from [vrtmrz/livesync-bridge](https://github.com/vrtmrz/livesync-bridge) @ `4f55e9a` | Syncs the inbox volume ⇄ vault folder `Kindle/` (E2EE, same lib as the plugin) |
| `init-perms` | `busybox:1.36.1` | One-shot: gives the inbox volume to uid 1993 so both services can write it |

The bridge syncs **both ways** but only for `VAULT_FOLDER`. Deleting a note
under `Kindle/` in Obsidian also deletes it from the inbox; nothing outside
that folder is touched.

## Deploy with Portainer

1. **Stacks → Add stack → Web editor**, name it `kindle-vault`, and paste
   [docker-compose.yml](docker-compose.yml).
2. Under **Environment variables**, add every key from [.env.example](.env.example)
   (or use *Load variables from .env file*). `COUCHDB_USER`, `COUCHDB_PASSWORD`,
   `E2EE_PASSPHRASE` and `WEBDAV_PASS` are required, and the deploy fails with
   a clear message if any is missing.
   - `COUCHDB_URL`: `http://host.docker.internal:5984` reaches a CouchDB
     published on the Pi. If CouchDB is another container, use its container
     name and attach the stack to that network.
   - `E2EE_PASSPHRASE`: the passphrase from the LiveSync plugin settings. It
     is also used as the path-obfuscation passphrase, which is the plugin's default.
3. **Deploy the stack.** The first deploy builds the bridge image from GitHub
   on the Pi (a few minutes on a Pi 4).

If Portainer refuses to build from the web editor, build the image once over
SSH and redeploy. Compose reuses the existing `livesync-bridge:4f55e9a` tag:

```bash
docker build -t livesync-bridge:4f55e9a "https://github.com/vrtmrz/livesync-bridge.git#4f55e9ab71d055fb5f5f4488afe4b713e6668178"
```

## Check it works

From any machine on the LAN (replace `pi` and the password):

```bash
echo "# hello from the inbox" > hello.md
curl -fsS -u kindle:PASS -T hello.md http://pi:8080/hello.md
```

`Kindle/hello.md` should appear in Obsidian within a few seconds. The bridge
logs (Portainer → container `bridge` → Logs) show each file it syncs, and the
container turns *healthy* once its heartbeat is running.

## Upload rule for the Kindle (and anything else)

Upload to a temporary `.partial` name, then rename it. The bridge ignores
`*.partial`, so Obsidian never sees a half-written PDF:

```bash
B=http://pi:8080; A=kindle:PASS; N="Articles/My%20Article.pdf"   # URL-encoded path
curl -fsS -u "$A" -X MKCOL "$B/Articles/"            # once; 405 = already exists
curl -fsS -u "$A" -T "My Article.pdf" "$B/$N.partial"
curl -fsS -u "$A" -X MOVE -H "Destination: $B/$N" -H "Overwrite: T" "$B/$N.partial"
```

Re-uploading the same name overwrites the vault copy. The Kindle-side daemon
re-sends a document every time its handwriting changes.

## Notes

- WebDAV is plain HTTP with basic auth, so it's fine on the home LAN. Don't
  forward port 8080 to the internet.
- Bridge sync checkpoints live in the `bridge_state` volume. To force a full
  rescan, remove that volume and redeploy.
- To update the bridge, bump the commit in both the `build.context` URL and
  the `image` tag.
