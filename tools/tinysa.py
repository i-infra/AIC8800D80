#!/usr/bin/env python3
"""Minimal tinySA control over its USB CDC-ACM shell.

Used to verify AIC8800 transmit output independently of the chip's own
measurements — see docs/testmode-firmware-api.md, Appendix N.4/N.5.

  ./tinysa.py version
  ./tinysa.py "rbw 300" "scan 2400000000 2480000000 101 3"
  ./tinysa.py --sweep 2400e6 2480e6 101      # parsed: (freq_hz, level_dbm) rows

The device presents a text shell terminated by a "ch> " prompt. A bare CR is
sent first because a partial line left in its buffer otherwise corrupts the
next command (observed as a stray leading character in the echo).
"""
import re
import sys
import time

import serial

PORT = "/dev/ttyACM1"
BAUD = 115200


def talk(cmds, port=PORT, wait=1.5):
    """Send each command, return the raw response text for each."""
    s = serial.Serial(port, BAUD, timeout=0.3)
    time.sleep(0.2)
    s.write(b"\r")
    s.flush()
    time.sleep(0.3)
    s.reset_input_buffer()
    out = []
    for c in cmds:
        s.write((c + "\r").encode())
        s.flush()
        buf = b""
        t0 = time.time()
        while time.time() - t0 < wait:
            d = s.read(8192)
            if d:
                buf += d
                t0 = time.time() - wait + 0.4
            if buf.endswith(b"ch> "):
                break
        out.append(buf.decode("utf-8", "replace"))
    s.close()
    return out


def sweep(start_hz, stop_hz, points=101, port=PORT, wait=8):
    """Run one scan; return [(freq_hz, level_dbm), ...]."""
    cmd = "scan %d %d %d 3" % (int(start_hz), int(stop_hz), points)
    text = talk([cmd], port=port, wait=wait)[0]
    rows = []
    for line in text.splitlines():
        m = re.match(r"\s*(\d+)\s+(-?[\d.]+e[+-]\d+)", line)
        if m:
            rows.append((int(m.group(1)), float(m.group(2))))
    return rows


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    if argv[0] == "--sweep":
        for f, lvl in sweep(float(argv[1]), float(argv[2]),
                            int(argv[3]) if len(argv) > 3 else 101):
            print("%12.6f MHz  %8.2f dBm" % (f / 1e6, lvl))
        return 0
    for r in talk(argv):
        print(r)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
