#!/usr/bin/env python3
"""Draw with the emulated Scribe pen (needs qemu-wacom-pen-hook.patch).

The hook adds a writable QOM property `pen` ("x y pressure [proximity
[eraser]]") to the machine's Wacom EMR digitizer; this drives it over QMP.
Pen coordinates are the digitizer's 0..15624 x 0..20832, which is also the
notebook canvas, so strokes land 1:1 in the nbk.

    python3 eink-pen.py --machine k4scribe line 2000 3000 12000 3000
    python3 eink-pen.py --machine k4scribe demo        # a few test strokes
"""
import argparse
import json
import math
import socket
import time
from pathlib import Path

PRESSURE = 2200  # of 4095
STEP_S = 0.012


class QMP:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.connect(str(path))
        self.buf = b""
        self._read()  # greeting
        self.cmd("qmp_capabilities")

    def _read(self):
        while b"\n" not in self.buf:
            self.buf += self.sock.recv(65536)
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def cmd(self, name, **args):
        self.sock.sendall(json.dumps({"execute": name, "arguments": args}).encode() + b"\n")
        while True:
            msg = self._read()
            if "return" in msg:
                return msg["return"]
            if "error" in msg:
                raise RuntimeError(msg["error"])


class Pen:
    def __init__(self, qmp):
        self.qmp = qmp

    def send(self, x, y, pressure, proximity=1):
        self.qmp.cmd("qom-set", path="/machine/stylus", property="pen",
                     value=f"{int(x)} {int(y)} {int(pressure)} {proximity}")

    def stroke(self, points):
        x, y = points[0]
        self.send(x, y, 0)
        for x, y in points:
            self.send(x, y, PRESSURE)
            time.sleep(STEP_S)
        self.send(x, y, 0)
        time.sleep(0.05)
        self.send(x, y, 0, proximity=0)
        time.sleep(0.15)


def line(x0, y0, x1, y1, n=24):
    return [(x0 + (x1 - x0) * i / n, y0 + (y1 - y0) * i / n) for i in range(n + 1)]


def circle(cx, cy, r, n=36):
    return [(cx + r * math.cos(2 * math.pi * i / n), cy + r * math.sin(2 * math.pi * i / n)) for i in range(n + 1)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--machine", default="k4scribe")
    ap.add_argument("--root", default=str(Path.home() / "emu/eink-emulator"))
    sub = ap.add_subparsers(dest="action", required=True)
    lp = sub.add_parser("line")
    for k in ("x0", "y0", "x1", "y1"):
        lp.add_argument(k, type=int)
    sub.add_parser("demo")
    args = ap.parse_args()

    sock = Path(args.root) / "machines" / args.machine / f"{args.machine}.qmp.sock"
    pen = Pen(QMP(sock))
    if args.action == "line":
        pen.stroke(line(args.x0, args.y0, args.x1, args.y1))
    else:
        pen.stroke(line(2000, 4000, 13000, 4000))        # horizontal rule
        pen.stroke(line(2000, 4000, 2000, 9000))         # vertical
        pen.stroke(circle(7800, 9000, 2500))             # circle
        pen.stroke(line(3000, 14000, 12000, 17000, 40))  # diagonal
    print("done")


if __name__ == "__main__":
    main()
