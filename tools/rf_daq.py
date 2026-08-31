#!/usr/bin/env python3
"""Drive the AIC8800 lmacfw_rf IQ capture DAQ over USB, and (optionally) live-patch
the running firmware to retask it. Research scaffolding for the antenna-IQ work in
docs/testmode-firmware-api.md Appendix P.

It shells out to ./aic-memtool (build it first: see tools/README.md) for the
DBG_MEM reads/writes, so no kernel driver or sudo is needed once the udev rule is
installed and the chip is running lmacfw_rf (aic_load_fw testmode=1 + reboot).

Commands:
  arm <tap>        source-select capture (0x40342004=0x309, holds the mux) into
                   0x100000, then dump it. <tap> in: adc_in rx_data_iq rc_adc
                   dccancel pre_dgc notch rc_in rc_out loft_out
  patch on|off     live-patch SET_RX_METER's arm (RAM code at 0x120000): mux ->
                   rx_data_iq and NOP the internal-tone enable (P.3). Self-restores
                   on chip reboot; `off` restores the original bytes.
  meter            run SET_RX_METER (rftest 6) and dump 0x100000 (loopback capture,
                   or antenna after `patch on`).

Every dump lands in ./cap.bin; analyse with capture_fft.py.

WARNING: as established in Appendix P, the antenna is NOT routed into this buffer
in stock lmacfw_rf; these taps yield loopback/calibration data. This tool exists
to iterate on the datapath bring-up needed to change that.
"""
import subprocess, sys, re, time

MT = './aic-memtool'
MUX = {  # 0x40342000 value, low-nibble pathsel for 0x4034202C
    'adc_in': (0x00F00010, 2), 'rx_data_iq': (0x44F10010, 0), 'rc_adc': (0x00F10010, 0),
    'dccancel': (0x11F10010, 0), 'pre_dgc': (0x22F10010, 0), 'notch': (0x33F10010, 0),
    'rc_in': (0x00F50010, 0), 'rc_out': (0x11F50010, 0), 'loft_out': (0x44F20010, 0),
}
# live-patch sites in lmacfw_rf (RAM base 0x120000); (addr, original, patched)
PATCH_MUX  = (0x001259D8, 0x00F70410, 0x44F10010)   # arm's mux constant -> rx_data_iq
PATCH_TONE = (0x00125950, 0x5280F042, 0xBF00BF00)   # NOP the tone-enable orr


def mt(*a): return subprocess.run([MT, *a], capture_output=True, text=True, timeout=25).stdout
def rd(a): return int(re.search(r'= 0x([0-9a-f]+)', mt('read', '%08X' % a)).group(1), 16)
def wr(a, v): mt('writeb', '%08X' % a, '%08X' % v)


def arm(tap):
    if tap not in MUX:
        print('unknown tap; choose from', ' '.join(MUX)); return 2
    mux, ps = MUX[tap]
    mt('rftest', '3', '06', '00')                    # SET_RX ch6 (power the RX chain)
    wr(0x40330800, 0x10000002)                        # global enable
    old = rd(0x4034202C); wr(0x4034202C, (old & ~0xff) | (old & 0x70) | ps)
    wr(0x40342000, mux)
    v = rd(0x403420F4); wr(0x403420F4, (v & ~0xfffff) | 0x11123)
    wr(0x40342004, 0x00000309)                        # source-select trigger (keeps mux)
    st = 0
    for _ in range(20):
        st = rd(0x40342228)
        if not (st & 0x80000000):
            break
    print('tap %s  mux now 0x%08x  end_addr 0x%x (%d samples)'
          % (tap, rd(0x40342000), st & 0xffff, (st & 0xffff) // 8))
    mt('dump', '00100000', '10000', 'cap.bin')
    print('-> cap.bin')


def patch(on):
    for addr, orig, new in (PATCH_MUX, PATCH_TONE):
        wr(addr, new if on else orig)
    ok = all(rd(a) == (n if on else o) for a, o, n in (PATCH_MUX, PATCH_TONE))
    print('patch %s: %s' % ('on' if on else 'off', 'applied' if ok else 'FAILED'))


def main():
    if len(sys.argv) < 2:
        print(__doc__); return 2
    cmd = sys.argv[1]
    if cmd == 'arm' and len(sys.argv) > 2:
        return arm(sys.argv[2])
    if cmd == 'patch' and len(sys.argv) > 2:
        patch(sys.argv[2] == 'on'); return 0
    if cmd == 'meter':
        mt('rftest', '3', '06', '00'); mt('rftest', '6', '02')
        mt('dump', '00100000', '10000', 'cap.bin'); print('-> cap.bin'); return 0
    print(__doc__); return 2


if __name__ == '__main__':
    sys.exit(main())
