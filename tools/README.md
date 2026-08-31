# R&D tooling for the AIC8800 RF test firmware

Support tools for the reverse-engineering work written up in
[`../docs/testmode-firmware-api.md`](../docs/testmode-firmware-api.md). Read that
document's **§0 Verification status** first — it says which findings are confirmed
on hardware and which are static analysis only.

| Tool | Language | What it does |
|---|---|---|
| `aic-memtool.c` | C + libusb-1.0 | Read/write chip memory and drive the RF-test channel over USB, using the vendor's own `DBG_*` messages. No kernel driver, debugfs, or rebuild required. |
| `extract_testmode_cmds.py` | Python 3 | Recover the shell command table from a `testmode*.bin` image by brute-forcing the 64 KiB-aligned load base and walking the 16-byte records. |
| `tinysa.py` | Python 3 | Minimal tinySA / tinySA4 serial control (`talk()`, `sweep()`) used to confirm TX output, and as an external signal generator (`mode output` + `output on`). |
| `capture_fft.py` | Python 3 (numpy) | FFT-analyse a buffer dumped from the IQ capture engine at `0x100000`. Unpacks the lmacfw_rf format (two's-complement 12-bit, 8-byte stride) verified by disassembly; A/B compares tone on/off. See doc Appendix O. |
| `rf_daq.py` | Python 3 | Drive the lmacfw_rf IQ capture DAQ over USB (source-select `0x309` arm, tap mux table) and optionally live-patch the running firmware to retask `SET_RX_METER`. Research scaffolding for antenna-IQ work — see doc Appendix P. |

## `aic-memtool`

```sh
gcc -O2 -Wall -o aic-memtool aic-memtool.c -lusb-1.0
# or: cc -O2 -Wall $(pkg-config --cflags --libs libusb-1.0) -o aic-memtool aic-memtool.c
```

Access: install `../linux/60-aic8800.rules` (grants `uaccess`/`plugdev` to the
AIC USB IDs), or run as root. The tool temporarily detaches whatever driver holds
the vendor-specific interface and reattaches it on exit.

```
read   <hex-addr> [words]         DBG_MEM_READ_REQ        (one word per txn)
dump   <hex-addr> <hex-bytes> [f] DBG_MEM_BLOCK_READ_REQ  (1 KiB per txn)
write  <hex-addr> <hex-val>       DBG_MEM_WRITE_REQ       -- ACKed but a NO-OP
writeb <hex-addr> <hex-val>       DBG_MEM_BLOCK_WRITE_REQ (use this one)
rftest <cmd> [argbyte...]         DBG_RFTEST_CMD_REQ      (needs lmacfw_rf)
reboot [delay_ms]                 DBG_START_APP_REQ type 3
```

`AIC_RAW=1` also hexdumps the raw request/reply frames.

> **`write` is a trap.** `DBG_MEM_WRITE_REQ` is acknowledged — the confirmation
> even echoes your address and data back — but does **not** take effect. Use
> `writeb`. Always read back. See §M.1 of the doc.

> Writes are otherwise unguarded: no address filtering, and the eFuse paths are
> one-time-programmable. Know what you are writing.

Example — read the chip ID and confirm the part:

```
$ ./aic-memtool read 40500000
[0x40500000] = 0xf9078820      # chip_id 0x07 (U03), bit 25 == 0 -> M80
```

## `extract_testmode_cmds.py`

```sh
python3 extract_testmode_cmds.py path/to/testmode20_2025_1205_1950.bin
```

Prints the recovered `(name, usage, min_argc, max_argc, handler)` records. This
is the programmatic source for the command tables in the doc (§4, §6).

## `tinysa.py`

Edit `PORT` (default `/dev/ttyACM1`) to match your instrument, then import or run
it. Used here conductively loopbacked to the adapter's antenna port to measure the
`SET_TXTONE` output (−34.91 dBm at 2412.000 MHz, +54 dB over the noise floor — §N.4).
Requires `pyserial`.
