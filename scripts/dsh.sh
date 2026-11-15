#!/usr/bin/env bash
# Run a shell script (stdin) on the Kindle over SSH. Usage: dsh.sh <<'EOF' ... EOF
KEY="${KINDLE_KEY:-$HOME/.ssh/kindle_key}"
DEV="${KINDLE_DEV:-root@192.168.0.73}"
ssh -i "$KEY" -p 2222 -o BatchMode=yes -o ConnectTimeout=8 "$DEV" 'sh -s'