#!/usr/bin/env python3
"""Decode an AIC8800 Bluetooth patch-table binary offline.

These files live on the target under /lib/firmware/aic8800_fw/USB/<chip>/ and are
uploaded to the chip by aic_load_fw at probe time. The format is self-describing;
this parser needs no hardware. See docs/bt-patch-table.md for the full write-up.

Layout (little-endian):
    magic       16 bytes  "AICBT_PT_TAG\\0..."
    record*:
        name    16 bytes  (NUL-padded)
        type    u32
        len     u32       (# of (addr,val) pairs; see special cases)
        data    len*8 bytes  = len x (u32 addr, u32 val)
    Special: type >= 1000 or len == 0  -> no data body (len forced to 0).
             type == 0x06 (VERSION)    -> data body is a NUL-terminated string.

Usage:
    bt_patch_parse.py <patch_table.bin> [more.bin ...]
    bt_patch_parse.py --pairs <patch_table.bin>   # emit every addr,val pair
"""
import struct
import sys

TAG = b"AICBT_PT_TAG"
TYPES = {
    0x00: "INF/ADID", 0x01: "TRAP", 0x02: "B4",
    0x03: "BTMODE", 0x04: "PWRON", 0x05: "AF", 0x06: "VERSION",
}
# In an AICBT_MODE_T (BTMODE) record the driver overwrites the VALUE of the first
# nine pairs with runtime config (aicbt_patch_table_load, aicbluetooth.c). Index
# -> field, in pair order.
BTMODE_FIELDS = [
    "hwinfo<0", "hwinfo", "cpmode", "btmode", "btport",
    "uart_baud", "uart_flowctrl", "lpm_enable", "txpwr_lvl",
]


def parse(path):
    """Return (ok, [records]); each record = dict(name,type,tname,len,pairs,ver)."""
    d = open(path, "rb").read()
    if d[:len(TAG)] != TAG:
        return False, d
    p, recs = 16, []
    while p < len(d):
        name = d[p:p + 16].split(b"\0")[0].decode("latin1"); p += 16
        typ, ln = struct.unpack_from("<II", d, p); p += 8
        r = {"name": name, "type": typ, "tname": TYPES.get(typ, "0x%x" % typ),
             "len": ln, "pairs": [], "ver": None}
        if typ >= 1000 or ln == 0:
            r["len"] = 0
        elif typ == 0x06:
            r["ver"] = d[p:p + ln * 8].split(b"\0")[0].decode("latin1"); p += ln * 8
        else:
            r["pairs"] = [struct.unpack_from("<II", d, p + i * 8) for i in range(ln)]
            p += ln * 8
        recs.append(r)
    return True, recs


def dump(path, show_pairs):
    ok, recs = parse(path)
    print("\n===== %s =====" % path)
    if not ok:
        print("  no AICBT_PT_TAG magic (first16=%s) -- not a patch table"
              % recs[:16].hex())
        return
    for i, r in enumerate(recs):
        if r["ver"] is not None:
            print("  [%d] %-16s VERSION   -> %r" % (i, r["name"], r["ver"])); continue
        if r["len"] == 0:
            print("  [%d] %-16s %-9s len=0" % (i, r["name"], r["tname"])); continue
        addrs = [a for a, _ in r["pairs"]]
        print("  [%d] %-16s %-9s len=%-3d  addr %#010x..%#010x"
              % (i, r["name"], r["tname"], r["len"], min(addrs), max(addrs)))
        if r["name"] == "AICBT_MODE_T":
            for k, (a, v) in enumerate(r["pairs"]):
                f = BTMODE_FIELDS[k] if k < len(BTMODE_FIELDS) else ""
                print("        pair[%2d] %#010x = %#010x  %s"
                      % (k, a, v, "<- " + f if f else ""))
        elif show_pairs:
            for a, v in r["pairs"]:
                print("        %#010x <- %#010x" % (a, v))


def main():
    argv = sys.argv[1:]
    show_pairs = "--pairs" in argv
    files = [a for a in argv if not a.startswith("--")]
    if not files:
        print(__doc__); return 2
    for f in files:
        dump(f, show_pairs)
    return 0


if __name__ == "__main__":
    sys.exit(main())
