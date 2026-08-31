#!/usr/bin/env python3
"""Extract the AIC8800 Bluetooth ROM over USB via DBG_MEM block reads.

Rationale (see docs/bt-patch-table.md, "Extracting the ROM"): aic_load_fw writes
the BT ADID/patch/trap data to addresses 0x000xxxxx / 0x0020xxxx / 0x40690000
through the very same DBG_MEM agent that aic-memtool reads. Read and block-read
are companion ops on that agent, so the BT ROM in low memory should be readable
by the same mechanism that already writes its neighbours every boot. This tool
proves that with a readback check, then sweeps the ROM to a file.

It shells out to ./aic-memtool (build it first: tools/README.md); no kernel
driver or sudo is needed once 60-aic8800.rules is installed and any AIC firmware
is running (normal fmacfw is fine -- the BT patches are loaded at probe).

Commands:
  verify [table.bin]   read back a handful of known BT-patch words and compare to
                       the on-disk patch table. If these match, the BT address
                       space is visible to our DBG_MEM agent and a dump is sound.
                       Default table: the u02 D80 table under /lib/firmware.
  dump [out.bin]       verify, then sweep START..END (see --start/--end) into
                       out.bin (default bt_rom.bin), filling unreadable holes with
                       0xFF and reporting them. Prints size, CRC32, and a crude
                       byte-entropy so you can tell ROM from empty space.

Options:  --start HEX (default 00000000)  --end HEX (default 00100000)
          --chunk N  bytes per dump call (default 65536; retried at 4096 on error)
          --memtool PATH   --force  (skip the verify gate for dump)

SAFETY: a pure read sweep with the netdev DOWN and no scans running is low risk
(the wedge documented in docs/kernel-bug-usb-rx-resubmit-deadlock.md came from
driver RX churn + mode switches, not block reads). Load the r6/r7 module first.
Bring the interface down:  sudo ip link set <wlan> down
"""
import binascii
import os
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bt_patch_parse as pt  # noqa: E402

MT = os.environ.get("AIC_MEMTOOL", "./aic-memtool")
DEFAULT_TABLE = ("/lib/firmware/aic8800_fw/USB/aic8800D80/"
                 "fw_patch_table_8800d80_u02.bin")
# Static-code patch words that the running firmware should NOT have altered:
# the TRAP handler landing zone (0x0020f6xx) holds Thumb-2 code, not live state.
VERIFY_REGION = (0x00200000, 0x00210000)


def mt(*a, timeout=60):
    return subprocess.run([MT, *a], capture_output=True, text=True, timeout=timeout)


def read1(addr):
    """One 32-bit read via aic-memtool; return int or None on failure."""
    r = mt("read", "%08X" % addr)
    m = re.search(r"=\s*0x([0-9a-fA-F]+)", r.stdout)
    return int(m.group(1), 16) if (r.returncode == 0 and m) else None


def pick_verify_pairs(table, n=6):
    """Return up to n (addr, expected) pairs from code/const patch records that
    land in BT RAM -- these are written verbatim and are safe to read back."""
    ok, recs = pt.parse(table)
    if not ok:
        return []
    out = []
    for r in recs:
        if r["name"] == "AICBT_MODE_T" or r["ver"] is not None:
            continue  # BTMODE values are host-overwritten at load; skip
        for a, v in r["pairs"]:
            if VERIFY_REGION[0] <= a < VERIFY_REGION[1]:
                out.append((a, v))
    return out[:n]


def verify(table):
    pairs = pick_verify_pairs(table)
    if not pairs:
        print("verify: no usable RAM patch words in %s" % table); return False
    print("verify: reading back %d known BT-patch words from %s"
          % (len(pairs), table))
    good = 0
    for a, exp in pairs:
        got = read1(a)
        tag = "??" if got is None else ("OK" if got == exp else "MISMATCH")
        good += got == exp
        print("  %#010x  expect %#010x  got %s  [%s]"
              % (a, exp, "----------" if got is None else "%#010x" % got, tag))
    ok = good == len(pairs)
    print("verify: %d/%d matched -> BT memory %s visible to DBG_MEM agent"
          % (good, len(pairs), "IS" if ok else "NOT reliably"))
    return ok


def dump_range(start, end, chunk, out):
    """Sweep [start,end) into out, one aic-memtool dump per chunk; on a chunk
    failure retry at 4 KiB, and fill any still-unreadable 4 KiB with 0xFF."""
    holes, total = [], 0
    with open(out, "wb") as f:
        a = start
        while a < end:
            n = min(chunk, end - a)
            data = _try_dump(a, n)
            if data is not None:
                f.write(data); total += len(data); a += n
                _progress(a - start, end - start); continue
            # bisect to 4 KiB to keep holes small
            step = 4096
            for b in range(a, a + n, step):
                m = min(step, end - b)
                d = _try_dump(b, m)
                if d is None:
                    d = b"\xff" * m; holes.append((b, m))
                f.write(d); total += len(d)
            a += n
            _progress(a - start, end - start)
    sys.stdout.write("\n")
    return total, holes


def _try_dump(addr, n):
    with tempfile.NamedTemporaryFile(delete=False) as tf:
        tmp = tf.name
    try:
        r = mt("dump", "%08X" % addr, "%X" % n, tmp, timeout=max(30, n // 256))
        if r.returncode != 0:
            return None
        d = open(tmp, "rb").read()
        return d if len(d) == n else None
    except subprocess.TimeoutExpired:
        return None
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def _progress(done, tot):
    sys.stdout.write("\r  dumped %d / %d KiB (%.0f%%)"
                     % (done // 1024, tot // 1024, 100.0 * done / tot))
    sys.stdout.flush()


def entropy(b):
    if not b:
        return 0.0
    import math
    from collections import Counter
    c = Counter(b); n = len(b)
    return -sum((v / n) * math.log2(v / n) for v in c.values())


def main():
    argv = sys.argv[1:]

    def opt(name, default):
        if name in argv:
            i = argv.index(name); v = argv[i + 1]; del argv[i:i + 2]; return v
        return default

    start = int(opt("--start", "00000000"), 16)
    end = int(opt("--end", "00100000"), 16)
    chunk = int(opt("--chunk", "65536"))
    force = "--force" in argv
    if "--force" in argv:
        argv.remove("--force")
    global MT
    MT = opt("--memtool", MT)
    args = [a for a in argv if not a.startswith("--")]
    cmd = args[0] if args else ""

    if cmd == "verify":
        table = args[1] if len(args) > 1 else DEFAULT_TABLE
        return 0 if verify(table) else 1

    if cmd == "dump":
        out = args[1] if len(args) > 1 else "bt_rom.bin"
        table = opt("--table", DEFAULT_TABLE)
        if not force and not verify(table):
            print("dump: verify failed; re-run with --force to sweep anyway")
            return 1
        print("dump: sweeping %#010x..%#010x -> %s" % (start, end, out))
        total, holes = dump_range(start, end, chunk, out)
        data = open(out, "rb").read()
        print("dump: wrote %d bytes  CRC32=%08x  entropy=%.2f bits/byte"
              % (total, binascii.crc32(data) & 0xffffffff, entropy(data)))
        if holes:
            hb = sum(n for _, n in holes)
            print("dump: %d hole(s), %d bytes filled 0xFF:" % (len(holes), hb))
            for h, n in holes[:16]:
                print("      %#010x +%#x" % (h, n))
            if len(holes) > 16:
                print("      ... (+%d more)" % (len(holes) - 16))
        else:
            print("dump: no holes; whole range read cleanly")
        return 0

    print(__doc__); return 2


if __name__ == "__main__":
    sys.exit(main())
