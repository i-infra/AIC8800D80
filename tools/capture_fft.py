#!/usr/bin/env python3
"""FFT-analyse a capture dumped from the AIC8800 IQ engine at 0x00100000.

Feed it a raw file written by `aic-memtool dump 00100000 10000 <file>`.

Format is taken from the lmacfw_rf `rx_meter` measure routine itself
(disassembled at mem 0x001257a8; see docs/testmode-firmware-api.md Appendix O):

  * the buffer is 0x00100000..0x00110000 (64 KiB),
  * samples are one 32-bit word every EIGHT bytes (stride 2 words -- the
    intervening word is a second interleaved tap),
  * within a sample word:  I = sign_extend12(bits[15:4]),
                           Q = sign_extend12(bits[31:20])   -- TWO'S COMPLEMENT,
    NOT the offset-binary form used by testmode's 0x100000 dump engine,
  * the firmware picks its start half via a ping-pong flag = ~word[0] & 1.

So there are two interleaved 8192-sample streams ("even"/"odd"). The `measure`
routine reads the ping-pong-selected half with the 12-bit format above (the odd
stream in the captures taken here). The other (even) stream is NOT that format --
under SET_RX_METER it is the chip's internal NCO loopback reference as full-scale
int16 I/Q pairs (hi16=I, lo16=Q), so decoding it as 12-bit yields noise. This
tool applies the 12-bit format to both halves; trust the `measure` half.

Usage:
    capture_fft.py <file>                    analyse both halves
    capture_fft.py <off_file> <on_file>      A/B compare
    capture_fft.py ... --offset-mhz 2.0      also solve Fs from a known offset
    capture_fft.py ... --half even|odd       restrict to one interleave
"""
import sys
import numpy as np


def unpack(path, half):
    w = np.fromfile(path, dtype='<u4')
    start = half if half is not None else (1 - (int(w[0]) & 1))  # firmware ping-pong
    smp = w[start::2][:8192]
    q = ((smp >> 20) ^ 0x800).astype(np.int32) - 0x800          # sx12 two's-complement
    i = (((smp >> 4) & 0xFFF) ^ 0x800).astype(np.int32) - 0x800
    return i.astype(np.float64) + 1j * q.astype(np.float64), smp


def peakinfo(x):
    x = x - x.mean()
    P = np.abs(np.fft.fftshift(np.fft.fft(x * np.hanning(len(x))))) ** 2
    k = int(np.argmax(P)); n = len(P)
    return (k - n // 2) / n, 10 * np.log10(P[k] / np.median(P))


def report(path, halves, offset_mhz=None):
    print(path)
    res = {}
    for h, name in halves:
        x, smp = unpack(path, h)
        frac, ratio = peakinfo(x)
        line = ("  %-4s peak %+.4f Fs  peak/med %5.1f dB  |I| std %6.1f  distinct %d"
                % (name, frac, ratio, x.real.std(), len(np.unique(smp))))
        if offset_mhz is not None and abs(frac) > 1e-6:
            line += "   (=> Fs %.2f MHz)" % abs(offset_mhz / frac)
        print(line)
        res[name] = (frac, ratio)
    return res


def main():
    argv = sys.argv[1:]
    off = None
    if '--offset-mhz' in argv:
        j = argv.index('--offset-mhz'); off = float(argv[j + 1]); del argv[j:j + 2]
    half = None
    if '--half' in argv:
        j = argv.index('--half'); half = {'even': 0, 'odd': 1}[argv[j + 1]]; del argv[j:j + 2]
    args = [a for a in argv if not a.startswith('--')]
    halves = [(half, {0: 'even', 1: 'odd'}[half])] if half is not None else [(0, 'even'), (1, 'odd')]
    if not args:
        print(__doc__); return 2
    if len(args) == 1:
        report(args[0], halves, off)
    else:
        print("=== A (e.g. tone OFF) ==="); a = report(args[0], halves, off)
        print("=== B (e.g. tone ON ) ==="); b = report(args[1], halves, off)
        print("\n=== verdict ===")
        moved = any(abs(b[n][0] - a[n][0]) > 2e-3 and b[n][1] - a[n][1] > 6 for n in a)
        print("  a tone-correlated peak appeared and moved" if moved
              else "  no tone-correlated peak in either interleave")
    return 0


if __name__ == '__main__':
    sys.exit(main())
