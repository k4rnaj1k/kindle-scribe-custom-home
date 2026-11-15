#!/usr/bin/env python3
"""Run one shell command on the eink-emulator guest's serial console.

Usage (WSL): python3 scripts/emu_serial.py [--machine k4scribe] [--timeout 20] 'command'

The emulator exposes the guest's root serial shell on a Unix socket when it is
started with `eink run NAME --serial-socket`. The command's output is framed
by unique markers so console noise (kernel log lines) can be filtered out.
"""
import argparse
import os
import socket
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("command")
parser.add_argument("--machine", default="k4scribe")
parser.add_argument("--timeout", type=float, default=20)
args = parser.parse_args()

path = os.path.expanduser(
    f"~/emu/eink-emulator/machines/{args.machine}/{args.machine}.serial.sock")
tag = uuid.uuid4().hex[:8]
begin, end = f"__B{tag}__", f"__E{tag}__"

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(path)
s.settimeout(0.5)
s.sendall(b"\n")
time.sleep(0.3)
# printf keeps the markers out of the echoed command line itself.
line = (f"printf '%s\\n' {begin[:4]}{begin[4:]}; ( {args.command} ) 2>&1; "
        f"printf '%s\\n' {end[:4]}{end[4:]}\n")
s.sendall(line.encode())

buf = b""
deadline = time.time() + args.timeout
while time.time() < deadline:
    try:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
        if (end + "\n").encode() in buf.replace(b"\r", b"") and \
                buf.replace(b"\r", b"").count(end.encode()) >= 1:
            text = buf.decode("utf-8", "replace").replace("\r", "")
            if f"\n{end}" in text:
                break
    except socket.timeout:
        pass
s.close()

text = buf.decode("utf-8", "replace").replace("\r", "")
start = text.rfind(f"\n{begin}\n")
stop = text.rfind(f"\n{end}")
if start < 0 or stop < 0:
    print("[emu_serial] markers not found; raw tail:")
    print(text[-2000:])
    raise SystemExit(1)
body = text[start + len(begin) + 2:stop]
# Drop interleaved kernel log lines ("[   12.345] ...").
print("\n".join(l for l in body.splitlines() if not l.lstrip().startswith("[ ")))
