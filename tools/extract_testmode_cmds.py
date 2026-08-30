#!/usr/bin/env python3
"""Extract the command table from an AIC8800 testmode*.bin RF-test image.

These images are raw ARM Cortex-M binaries mapped at a fixed load base (not
stored in the file) that expose a UART command shell.  Each shell command is a
16-byte record:

    struct cmd_entry {
        const char *name;
        const char *usage;
        int16_t     min_argc;   /* inclusive, counts argv[0] */
        int16_t     max_argc;
        int       (*handler)(int argc, char **argv);
    };

The load base is recovered by trying 64K-aligned candidates and keeping the one
that yields the longest run of self-consistent records.

Usage: extract_testmode_cmds.py testmode20_2025_1205_1950.bin [...]

See docs/testmode-firmware-api.md for the decoded API.
"""
import struct
import sys

RECORD = 16


def analyze(path):
    data = open(path, 'rb').read()
    best = None

    for base in range(0x00080000, 0x00400000, 0x10000):
        end = base + len(data)

        def cstr(addr, maxlen=250):
            off = addr - base
            if off < 0 or off >= len(data):
                return None
            nul = data.find(b'\0', off)
            if nul < 0 or nul - off > maxlen:
                return None
            s = data[off:nul]
            if any(c < 9 or c > 0x7e for c in s):
                return None
            return s.decode('ascii')

        hits = []
        for off in range(0, len(data) - RECORD, 4):
            name, usage, lo, hi, handler = struct.unpack('<IIhhI',
                                                         data[off:off + RECORD])
            if not (base <= handler < end) or not (handler & 1):
                continue  # handlers are Thumb, so the low bit is always set
            if lo < 1 or hi < lo or hi > 32:
                continue
            n = cstr(name, 24)
            u = cstr(usage)
            if not n or u is None or ' ' in n or not n[0].isalpha():
                continue
            hits.append(off)

        seen = set(hits)
        longest = []
        for off in hits:
            if off - RECORD in seen:
                continue
            run, p = [], off
            while p in seen:
                run.append(p)
                p += RECORD
            if len(run) > len(longest):
                longest = run

        if best is None or len(longest) > len(best[1]):
            best = (base, longest)

    base, run = best

    def cstr(addr):
        off = addr - base
        return data[off:data.find(b'\0', off)].decode('ascii', 'replace')

    cmds = []
    for off in run:
        name, usage, lo, hi, handler = struct.unpack('<IIhhI',
                                                     data[off:off + RECORD])
        cmds.append(dict(name=cstr(name), usage=cstr(usage),
                         min_argc=lo, max_argc=hi, handler=handler,
                         entry=base + off))

    sp, reset = struct.unpack('<II', data[:8])
    return dict(path=path, size=len(data), base=base, sp=sp, reset=reset,
                magic=data[0x20:0x24].decode('ascii', 'replace'),
                table=base + run[0] if run else 0, cmds=cmds)


def main(argv):
    if not argv:
        print(__doc__)
        return 1
    for path in argv:
        r = analyze(path)
        print("# %s" % r['path'])
        print("#   size 0x%X  base 0x%08X  SP 0x%08X  reset 0x%08X  magic %r"
              % (r['size'], r['base'], r['sp'], r['reset'], r['magic']))
        print("#   cmd_table[%d] @ 0x%08X" % (len(r['cmds']), r['table']))
        for c in r['cmds']:
            print("%-20s argc %2d..%-2d  handler 0x%08X  %s"
                  % (c['name'], c['min_argc'], c['max_argc'], c['handler'],
                     c['usage'].replace('\t', ' ')))
        print()
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
