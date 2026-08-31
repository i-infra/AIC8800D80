# AIC8800 `testmode*.bin` — RF Test Firmware API

Reverse-engineered reference for the standalone RF/production-test firmware images
shipped in `aic8800/src/tools/testmode_bin/`.

These images are **not** the WiFi driver firmware. They are self-contained ARM
Cortex-M applications that replace the normal firmware in chip RAM and expose an
interactive **command shell on UART0**. They are what the vendor's RF test
documents (`*射频测试说明--UART版*.pdf`) drive.

> Derived by static analysis (radare2 + manual structure recovery) of
> `testmode20_2025_1205_1950.bin`, cross-checked against the other three images
> and against `AIC8800D80X2射频测试说明--UART版v3.0.pdf`. Every address below is a
> load-time virtual address for that specific image.

---

## 0. Verification status

This document mixes findings of very different strength. Read this table before
relying on anything in it.

### Confirmed on hardware

Measured on a live adapter (`368b:8d81` / `a69c:8d81`, AIC8800D80 "M80", U03
silicon) using `tools/aic-memtool.c`, and for RF output a tinySA4 conductively
loopbacked to the antenna port.

| Finding | Where | Evidence |
|---|---|---|
| USB debug-message framing (request + reply) | §E | round-trip works; reply decoded field by field |
| `DBG_MEM_READ_REQ` / `DBG_MEM_BLOCK_READ_REQ` | §E, §K | 1024 B/reply, 64 KiB in 64 transactions |
| `DBG_MEM_WRITE_REQ` is ACKed but **does nothing**; block write works | §M.1 | read-back on quiet RAM and RF registers |
| ~27.4 ms fixed per-transaction latency | §K.2 | 64 single reads = 64 block reads in wall time |
| Chip ID register `0x40500000` | §D.1 | `0xF9078820` → U03, M80 |
| PLL frequency field `0x4034201C[29:13]`, 1.25 MHz/LSB | §B.2 | read `1950` = `lround(2437/1.25)` = channel 6 |
| Tone NCO `round(freq × 204.8)`, signed 14-bit wrap | §A.3, §N.2 | +4 MHz → 819; −8 MHz → −1638 |
| Chip reboot via `DBG_START_APP_REQ` type 3 | §N.1 | device re-enumerated with different firmware |
| RF-test channel `DBG_RFTEST_CMD_REQ` (needs `lmacfw_rf`) | §N.1 | `SET_RX` + `GET_RX_RESULT` decode live traffic |
| **Transmit works** | §N.4 | −34.91 dBm at 2412.000 MHz, +54 dB over noise floor |
| Capture engine runs; `end_addr` is a circular pointer | §M.2, §I.1 | 65205/65536 bytes rewritten per arm |
| Firmware load base `0x120000`; initial SP (stack top) `0x1A0000` | §O.2 | live RAM matches the file byte-for-byte |
| `lmacfw_rf` capture buffer is `0x100000`; format two's-comp 12-bit, 8-byte stride | §O.3 | disassembly of `rx_meter` measure at `0x1257a8` |
| `SET_RX_METER` is an internal NCO loopback (not an antenna capture) | §O.4 | arm at `0x125904` enables tone bit 28; even words are a fixed int16 reference |
| A confirmed external jammer leaves no trace in `0x100000` | §O.5 | −6 dBm CW → 0 fcsok, yet no spectral peak |
| RF-test `GET_RSSI` (`0x52`) is an unreliable stub; `fcsok` is the RX indicator | §O.1 | RSSI static while jamming took fcsok 8→0 |

### Static analysis only — not verified on hardware

Command tables (§4, §6), handler addresses, the LOFT/DPD dump taps (§H.1),
`rx_meter` and `mon` internals (§G), the USB data path structures (§J), and the
`0x1A0000` buffer used by `rx_meter`. These are read out of the binaries and are
internally consistent, but nothing has exercised them.

### Open / negative results

| Question | Status |
|---|---|
| Does `0x00100000` hold live antenna RX samples under `lmacfw_rf`? | **No — resolved.** It is a capture buffer, but the only path the firmware exposes (`SET_RX_METER`) fills it with an *internal NCO loopback* tone for I/Q calibration. A confirmed −6 dBm external jammer (0 fcsok) left no trace — §O |
| Sample rate of the capture taps | **Unknown** — no clean external tone ever reached the buffer to read a bin off — §H.5, §O.5 |
| `0x40342010` "sdm" field meaning | **Undecoded**; the 2²² fractional reading is contradicted by a live read — §B.2 |
| Behaviour of `memsize > 1024` on block read | **Untested** — §E |
| `SET_TXTONE` frequency argument | **Has no effect** on output frequency in `lmacfw_rf`; output pinned to ch1 — §N.5 |

### Claims corrected during this work

Recorded so they are not rediscovered as fact:

* `memsize > 1024` was blamed for wedging the firmware. **Wrong** — the hang was
  a host-side driver deadlock (§L). Firmware behaviour there remains untested.
* The `sdm` field was documented as a 2²² fraction. **Contradicted** by a live
  read (§B.2).
* Capture sample bits `[19:16]`/`[3:0]` were called unused. They are merely
  *ignored by `rx_meter`*; live captures set them (§H.2).
* `end_addr` was described as a fill bound. It is a **circular write pointer**
  (§M.2).
* `lmacfw_rf` was said to lack tone support because `tone_on` is absent from its
  shell table. The tone code **is** present and reachable via `SET_TXTONE` (§N.1).
* `0x1A0000` was taken (from testmode) as the `rx_meter` sample buffer. Under
  `lmacfw_rf` it is the **initial stack pointer** — reads there are stack, not
  samples. The real buffer is `0x00100000` (§O.2, §O.3).
* The `lmacfw_rf` capture format was assumed identical to testmode's. It is not:
  **two's-complement 12-bit, 8-byte stride**, vs testmode's offset-binary 4-byte
  (§O.3).

---

## 1. Which image for which part

| Chip | File | Size | Load base | Initial SP | Cmd table | Cmds | Build stamp | Ver |
|---|---|---:|---|---|---|---:|---|---|
| AIC8800D80 / D40 | `testmode20_2025_1205_1950.bin` | 271348 | 0x00160000 | 0x001B0000 | 0x0019BB88 | 92 | la Dec 05 2025 19:50:21 - g586bc1e8 | v6.9.1.1 |
| AIC8800D80N | `testmode19_2025_1209_2033_g8ca3d35-20251208.bin` | 242072 | 0x00100000 | 0x00150000 | 0x0013493C | 91 | la Dec 09 2025 20:33:22 - g8ca3d35 | v6.9.1.1 |
| AIC8800D80X2 | `testmode22_2025_1205_1947.bin` | 312952 | 0x00160000 | 0x00160000 | 0x001AB638 | 90 | la Dec 05 2025 19:47:37 - g7c7d791 | v6.9.1.1 |
| AIC8800DC/DW/DL | `testmode18_2025_1205_2138.bin` | 185050 | 0x00100000 | 0x00133800 | 0x0012CDA4 | 77 | la Dec 05 2025 21:38:20 - g526c291 | v6.4.3.1 |

The AIC8800D80 dongle this repo targets (`a69c:8d80`) uses the
**`AIC8800D80D40/testmode20_*.bin`** image.

### Image format

There is no container or header — the file is a **raw ARM Cortex-M image mapped
directly at its load base**. Offset 0 is the vector table:

```
+0x00  u32  initial SP
+0x04  u32  reset vector      (Thumb, LSB set)
+0x08  u32  NMI ... etc.
+0x20  char magic[4]          "WFFW"  (WiFi firmware; BT images use "BTFW")
```

The load base is not stored in the file. It is recoverable because the vector
table entries are absolute: for `testmode20` the reset vector is `0x001601AD`,
so the base is `0x00160000`. This matches the driver's own comment in
`aic_load_fw/aicwf_usb.h`: *"8800 use 0x100000, 8800D80 use 0x160000"*.

---

## 2. Getting the firmware running

### UART (the documented path)

The chip's boot ROM has its own small shell on UART0. Per the vendor doc:

| Setting | Value |
|---|---|
| Port | UART0 |
| Baud | 921600 |
| Framing | 8-N-1 |
| Level | 1.8 V or 3.3 V (USB-UART adapter) |

```
x 160000        # boot ROM: start XMODEM receive into 0x160000
<send testmode20_2025_1205_1950.bin via XMODEM, 1024-byte packets>
g 160000        # jump to it
```

The BT test program is loaded the same way at `0x1A0000` (`x 1a0000` / `g 1a0000`).
RAM is volatile — this must be repeated after every power cycle.

### USB

`aic_load_fw` already implements the two primitives needed to do the same thing
over USB on a `a69c:8d80` device — `rwnx_send_dbg_mem_write_req()` (write a block
to an arbitrary chip address) and `rwnx_send_dbg_start_app_req()` (jump to an
address). So the image can be uploaded to `0x160000` and started without a UART.

**But the shell is UART-only.** The console write routine at `0x0017095C` busy-waits
on a status register and pokes bytes straight at a memory-mapped UART:

```c
#define UART0_DATA    0x40032000   /* TX holding register */
#define UART0_STATUS  0x40032020   /* bit 19 = TX busy    */

void puts(const char *s) {
    while (*s) {
        while (readl(UART0_STATUS) & (1u << 19)) ;
        writel(*s++, UART0_DATA);
    }
}
```

**The console is UART-only, and this is provable rather than assumed.** Tracing
the full character path through the image:

| Stage | Address | What it does |
|---|---|---|
| RX ready | `0x001709A0` | `return readl(0x40032014) & 1;` |
| getchar | `0x00170988` | spin on `0x40032014` bit 0, then `readl(0x40032000)` |
| line editor | `0x0018CBB8` | echo, backspace/DEL, 61-char limit, enqueue to `0x001A8690` |
| dispatcher | `0x0018CD60` | pop queue, tokenize, look up `cmd_table[92]` |
| putchar | `0x00170944` | spin on `0x40032020` bit 19, then `writel(0x40032000)` |

The line editor has exactly **two** call sites (`0x0017413A`, `0x0018CE92`) and
both fetch their character from `0x00170988`. Nothing else ever pushes onto the
command queue — the only other references to `0x001A8690` are the shell's own
init (`0x0018CA8C`) and the dispatcher.

Corroborating evidence that there is no USB stack in the image at all:

* The vector table has 20 non-default entries. IRQ36 and IRQ37 (`0x00170728`,
  `0x00170678`) are the only handlers that touch `0x40032xxx`; every other IRQ
  touches MAC/PHY/RF blocks (`0x40320000`, `0x40328000`, `0x4034xxxx`). There is
  no USB interrupt vector.
* No USB device descriptor (`12 01 .. 02`) and no UTF-16 string descriptors
  anywhere in the 271 KB image.
* The only USB-related strings are `get/set ef_usb_id=%x` — the eFuse VID/PID
  *provisioning* fields behind `setusb`/`efusbid`, not a USB implementation.

Since `g` boots the core to the new image and its vector table carries no USB
handler, the boot ROM's own vendor-control debug channel is gone once this
firmware starts. So on a sealed dongle with no UART pads you can start this
firmware but you genuinely cannot talk to it.

### Equivalent capability over USB

The shell is a thin wrapper over register access, and the register access *is*
reachable over USB by other means:

* **`wifi_test` + `lmacfw_rf_*.bin`** — the driver-mediated RF test path (§7).
  Smaller command set, but it is the supported way and it works on a stock dongle.
* **`regdbg` debugfs** — `rwnx_debugfs.c` registers a write-only file that
  performs arbitrary chip memory reads and writes at runtime via
  `rwnx_send_dbg_mem_read_req` / `rwnx_send_dbg_mem_block_write_req`:

  ```
  # /sys/kernel/debug/ieee80211/phyN/rwnx/regdbg     ("rwnx" from rwnx_main.c:9169)
  echo "0 4034206c 0"        > regdbg   # oper 0 = read   -> result in dmesg
  echo "1 4034206c 100003ff" > regdbg   # oper 1 = write  -> before/after in dmesg
  ```

  Format is `<oper> <addr> <val>`, all hex. This is the direct analogue of the
  shell's `r` and `w`, so the tone NCO (`0x4034206C`) and the PLL words
  (`0x4034201C`, `0x40342010`) are all reachable from the host without a UART.

  Note `CONFIG_DEBUG_FS ?= n` in the driver Makefile — it is **off by default**
  and the driver must be rebuilt with `CONFIG_DEBUG_FS=y` for this file to exist.

* **libusb, no kernel driver at all** — the same `DBG_MEM_*` messages the driver
  sends are plain bulk transfers and can be spoken from userspace. This needs no
  rebuild and works whether the device is in boot-ROM or operational mode. The
  wire protocol is in Appendix E; `tools/aic-memtool.c` is a working
  implementation.

---

## 3. Shell protocol

Prompt is `aic> `, emitted after every command completes. Line ending on output
is CRLF.

Commands are dispatched from a message queue, not read synchronously — the reader
ISR fills a buffer, and the shell task pops it, so the console is non-blocking.

### Tokenizer — `0x00188EDC`

```c
int tokenize(char *line, char **argv);   /* returns argc */
```

* Separators are **space (0x20) and tab (0x09)**; runs of them collapse.
* **Double quotes** group a token containing spaces.
* Tokens are NUL-terminated in place; `argv[]` points into the line buffer.
* Hard limit **16 tokens**. Overflow prints `Too many args, max:16` and the
  command still runs with the first 16.

### Numeric arguments — `0x00189138`

A `strtol(str, endptr, base)` clone, always called with **base 0**:

* `0x…` / `0X…` → hex
* leading `-` → negative (so `setxtalcap -4` is a *relative* signed value)
* otherwise decimal

Mixing forms is fine: `efpwrofst2x 1 1 1 0x0A` and `... 10` are equivalent.

### Dispatch — `0x0018CD60`

```
argc = tokenize(line, argv);
if (argc == 0)              -> "No command\r\n"
entry = lookup(argv[0], cmd_table, 92);
if (!entry)                 -> "Unknown command '%s'\r\n"
if (argc < min || argc > max) -> "Usage:\r\n%s %s\r\n"   (name, usage)
ret = entry->handler(argc, argv);
if (ret != 0)               -> "Command fail, ret=%d\r\n"
```

`argc` **includes `argv[0]`**, the command name itself. So `setchan` is declared
`2..2`: the name plus exactly one argument.

Command names are matched exactly — there is no prefix matching and no
abbreviation.

### Command table

```c
struct cmd_entry {          /* 16 bytes */
    const char *name;       /* +0x00 */
    const char *usage;      /* +0x04  printed after name on argc error */
    int16_t     min_argc;   /* +0x08  inclusive, counts argv[0] */
    int16_t     max_argc;   /* +0x0A  inclusive */
    int       (*handler)(int argc, char **argv);  /* +0x0C */
};
```

For `testmode20`: `struct cmd_entry cmd_table[92] @ 0x0019BB88`. Referenced from
exactly two places — the dispatcher (`0x0018CE5C`) and the `h` help handler
(`0x00189214`) — which is how the entry count was confirmed.

`h` with no arguments walks this table and prints every `name` + `usage`, so the
device will tell you its own command list if you can reach the console.

---

## 4. Command reference — AIC8800D80 / D40

92 commands. "argc" is the accepted range **including** the command name.
"Built-in usage text" is verbatim from the image.

#### Shell / debug core

| Command | argc | Handler | Built-in usage text |
|---|---|---|---|
| `h` | 1..1 | `0x001891F5` | - help info |
| `r` | 2..3 | `0x001892C5` | addr <cnt> <sz> - Read Mem(.b/.h) |
| `w` | 3..4 | `0x001893C5` | addr val <cnt> - Write Mem(.b/.h) |
| `ds` | 1..3 | `0x0018AD99` | 0/1 <sev> - Get/Set dbg sev |
| `dm` | 1..3 | `0x001897A1` | 0/1/2 <msk/mod> - Get/Set dbg mask/mod |
| `reboot` | 1..1 | `0x00188659` | - usr reb |
| `g` | 2..3 | `0x00189675` | <type> addr - goto addr |
| `print` | 2..2 | `0x0018AC79` | - print open/close |
| `t` | 1..2 | `0x0018AF09` | - read temp |
| `tp` | 1..2 | `0x0018AA1D` | - timer period in ms |
| `tc` | 1..3 | `0x0018AF8D` | <0/1> <ms> - get/set temp comp |
| `volt` | 1..1 | `0x0018A93D` | - measure volt |

#### TX configuration

| Command | argc | Handler | Built-in usage text |
|---|---|---|---|
| `setchan` | 2..2 | `0x0018FBD9` | chnum - set channel |
| `setbw` | 2..5 | `0x0018FDD5` | chbw sigbw <scb> - set bandwidth |
| `setbcbw` | 3..7 | `0x00190029` | band chnum <chbw> <sigbw> <npidx> <calen> - set band, channel & bandwidth with prim20_index |
| `setrate` | 3..4 | `0x0018FB19` | Format Rate preable |
| `setlen` | 2..2 | `0x0018FAA1` | len - set tx len |
| `setintv` | 2..2 | `0x0018FA35` | intv_time - set tx intv time |
| `setsg` | 2..2 | `0x00190455` | val - ShortGI en/dis |
| `sethegi` | 2..2 | `0x00190541` | val - set he gi ltf |
| `setdcm` | 2..2 | `0x00190591` | val - set he dcm |
| `setdpl` | 2..2 | `0x001905E1` | val - set doppler |
| `setmab` | 2..2 | `0x00190631` | val - set midamble |
| `setbfd` | 2..2 | `0x00190681` | val - set beamformed |
| `setsdg` | 2..2 | `0x001906D1` | val - set he sounding |
| `setbc` | 2..2 | `0x0019071D` | val - set bsscolor |
| `setsr` | 2..2 | `0x00190769` | val - set spatialreuse |
| `setldpc` | 2..2 | `0x001904DD` | val - set ldpc |
| `settx` | 1..2 | `0x0018F6D1` | <val> - tx info/en/dis |

#### RX / statistics

| Command | argc | Handler | Built-in usage text |
|---|---|---|---|
| `setrx` | 1..1 | `0x0018F875` | - start rx |
| `setrxstop` | 1..1 | `0x0018F8D1` | - stop rx |
| `startrxstat` | 1..1 | `0x0018F905` | - start rx stat |
| `getrxstat` | 1..1 | `0x0018F959` | - get rx stat |
| `stoprxstat` | 1..1 | `0x0018F99D` | - stop rx stat |
| `rssi` | 1..1 | `0x00190949` | - get rssi |
| `rx_meter` | 2..2 | `0x0018CA65` | freq - rx meter |
| `mon` | 3..3 | `0x0018AAB9` | mac bssid - set monitor |

#### Tone / RF front-end

| Command | argc | Handler | Built-in usage text |
|---|---|---|---|
| `tone_on` | 2..4 | `0x0018A1A9` | freq <amp> <txgain> - generate tone |
| `tone_off` | 1..1 | `0x001894C5` | - stop tone |
| `srrc` | 2..2 | `0x0018A3BD` | 0/1 - srrc off/on |
| `fss` | 2..2 | `0x0018A3D9` | 0/1 - fss off/on |
| `notch` | 2..2 | `0x0018A3A9` | 0/1/2/3 - notch off/on |
| `papr` | 2..2 | `0x001913B1` | <0/1/2> - unset/set papr |
| `aux` | 2..2 | `0x0018ACC5` | en - aux config |
| `setaux` | 2..2 | `0x00190301` | 5g rf switch - 1:aux, 0:main |
| `swtable` | 3..3 | `0x0019037D` | rftabe sw/hw mode - 1:sw, 0:hw - 1:rx, 0:tx |
| `fix_gain` | 3..3 | `0x0018953D` | lna vga - fix gain |
| `release_gain` | 1..1 | `0x001895C1` | - release gain |
| `mdll_duty` | 1..1 | `0x0018A3ED` | - mdll duty cal |
| `lp_mode` | 2..2 | `0x001891F1` | en - lowpower mode |

#### TX power

| Command | argc | Handler | Built-in usage text |
|---|---|---|---|
| `setpwr` | 2..2 | `0x00190489` | val - set pwr |
| `pwrmm` | 1..2 | `0x00190A75` | <0/1> - manual mode |
| `pwrlvl` | 1..15 | `0x00190BF5` | 0/1/2 <type index> - 0:get cur, 1:set 2.4g, 2:set 5g |
| `pwrofst2x` | 1..5 | `0x00190FE9` | 0/1/2 <type chgrp ofst2x> - 0:get cur, 1:set 2.4g, 2:set 5g |
| `pwradd2x` | 1..3 | `0x00191409` | 0/1/2 <add2x> - rw pwr add2x, 0:rd, 1:wr2g4, 2:wr5g |
| `tonepwrofst` | 1..3 | `0x00191279` | 0/1/2/3 <ofst2x> - rw rf tone_pwr ofst, 0:rd, 1:wr2g4, 2:wr5g, 3:wrbt |
| `drvibit` | 1..4 | `0x0019127D` | 0/1 <ibit> - 0:get cur, 1:set 2.4g |
| `setapc` | 3..4 | `0x001907DD` | positon1 positon2 val |

#### Crystal / calibration

| Command | argc | Handler | Built-in usage text |
|---|---|---|---|
| `setxtalcap` | 2..2 | `0x0018AE6D` | val - adjust xtal cap |
| `setxtalcapfine` | 2..2 | `0x00189615` | val - adjust xtal cap fine |
| `calib` | 4..16 | `0x00189891` | band cfg <alpha> - usr calib |
| `loft` | 3..8 | `0x00189E89` | - loft dump  0:loft_pwr_in_out,1:dac_150m,2:adc_in,3:rx_data_iq,30:rc_adc,31:dccancel,32:pre_dgc,33:notch,4:rc_in_iq,5:rc_out_iq,50:rc_in_iq,6:rc_status,7:lpf_out_bpf_out,8:gain_loft2_in_out,81:gain_loft_in_out,9:aux_fifo_out |
| `dcver` | 2..3 | `0x0018A42D` | mask <chnum> - dc verify |
| `dccomp` | 3..19 | `0x0018A4DD` | 0/1 mask <val...> - rd/wr dc comp |

#### eFuse / flash persistence

| Command | argc | Handler | Built-in usage text |
|---|---|---|---|
| `efuse` | 3..4 | `0x00190995` | fun args - 1:wr, 2:rd |
| `getmac` | 1..1 | `0x0018A599` | - get mac addr from efuse |
| `setmac` | 2..2 | `0x0018A615` | mac_str - set mac addr to efuse |
| `getbtmac` | 1..1 | `0x0018A6DD` | get bt mac addr from efuse |
| `setbtmac` | 2..2 | `0x0018A771` | mac_str - set bt mac addr to efuse |
| `getvinfo` | 1..1 | `0x0018A84D` | get vendor info from efuse |
| `setvinfo` | 2..2 | `0x0018A8A5` | vinfo - set vendor info to efuse |
| `effreqcal` | 1..3 | `0x0018BE89` | 0/1/2 <cap(fine)> - rw efuse freqcal, 0:rd, 1:wrcap, 2:wrcapfine |
| `efpwrofst2x` | 1..5 | `0x0018B935` | 0/1/2 <type chgrp> <ofst> - rw efuse wf pwrofst, 0:rd, 1:wr2g4, 2:wr5g |
| `efdrvibit` | 1..3 | `0x0018B0F5` | 0/1 <ibit> - rw efuse wf pa drvibit, 0:rd, 1:wr2g4 |
| `eftemplvl` | 1..3 | `0x0018BEE5` | 0/1 <lvl> - rw efuse calib temp level, 0:rd, 1:wr |
| `efusbid` | 1..3 | `0x0018C0E9` | 0/1 <id> - rw efuse usb vid+pid, 0:rd, 1:wr |
| `eftonepwr` | 1..3 | `0x00189701` | 0/1/2/3 <tonepwr> - rw efuse rf tone_pwr, 0:rd, 1:wr2g4, 2:wr5g, 3:wrbt |
| `efsdiocfg` | 1..3 | `0x0018BFE5` | 0/1 <cfg> - rw efuse sdio cfg, 0:rd, 1:wr |
| `efheoff` | 1..2 | `0x0018C1AD` | 0/1 - rw efuse he_off, 0:rd, 1:wr |
| `ef5goff` | 1..2 | `0x0018C251` | 0/1 - rw efuse 5g_off, 0:rd, 1:wr |
| `efpwradd2x` | 1..3 | `0x0018C619` | 0/1/2 <pwradd2x> - rw efuse pwradd2x, 0:rd, 1:wr2g4, 2:wr5g |

#### Identity / regulatory

| Command | argc | Handler | Built-in usage text |
|---|---|---|---|
| `setusb` | 3..3 | `0x001916B9` | - setusb <vid> <pid> |
| `getusb` | 1..1 | `0x00191769` | - get usb info |
| `setpcie` | 6..6 | `0x00191B45` | - setpcie <vid> <did> <subsys_vid> <subsys_id> <rev_id> |
| `getpcie` | 1..1 | `0x00191C59` | - get pcie info |
| `set_countrycode` | 2..2 | `0x00191855` | - set country code |
| `get_countrycode` | 1..1 | `0x0019196D` | - get country code |
| `set_ch_countrycode` | 2..2 | `0x001919F1` | - set ch country code |
| `get_ch_countrycode` | 1..1 | `0x00191A95` | - get channel country code |

#### GPIO / production

| Command | argc | Handler | Built-in usage text |
|---|---|---|---|
| `gpioa` | 3..4 | `0x00191559` | idx dir <val> - Get & Set gpioa |
| `gpiob` | 3..4 | `0x00191559` | idx dir <val> - Get & Set gpiob |
| `cob` | 1..2 | `0x00191675` | start cobtest  0:all, 1: xtal dis, 2 xtal only |

<!-- ungrouped: [] -->
---

## 5. Semantics of the commonly used commands

Argument encodings below come from the vendor UART doc where it covers a command,
and from the image's own format strings otherwise. Commands the vendor doc does
**not** describe are marked *(undocumented)*.

### Channel / bandwidth / rate

```
setchan <chnum>            # 2.4G: 1..13   5G: 36..165
                           # 6E:  pass the frequency directly, e.g. "setchan 6500"
setbw   <chbw> <sigbw>     # 0 = 20MHz, 1 = 40MHz, 2 = 80MHz  (both args)
setrate <format> <rate> [preamble/gi] [nss]
```

| `format` | Meaning | `rate` |
|---|---|---|
| 0 | NON-HT | 0..11 → 1, 2, 5.5, 11, 6, 9, 12, 18, 24, 36, 48, 54 Mbps |
| 2 | HT-MF | MCS index |
| 4 | VHT | MCS 0..9 |
| 5 | HE-SU | MCS 0..11 |

`preamble/gi`: for 11b `0` = short, `2` = long; for HT/VHT `0` = long, `1` = short.
`nss`: `0` = single antenna, `1` = dual (where the part supports it).

Confirmation strings: `Rate Set Done`, `Chan %d, Freq. %d, BW %d`,
`BW Set Done : prim freq %d, center freq %d`.

`setbcbw <band> <chnum> [chbw] [sigbw] [npidx] [calen]` *(undocumented)* is a
combined setter that also takes the primary-20 index and a calibration-enable
flag — the only way to control `npidx` from the shell.

### TX

```
setlen  <bytes>            # recommended: 1024 (11b/non-HT), 4096 @20M,
                           # 8192 @40M, 16384 @80M
setintv <microseconds>     # inter-packet gap, minimum 50us
settx   <0|1>              # 0 = stop, 1 = start transmitting
```

`settx` with no argument prints the current configuration (`Current tx info:`,
`chan band=%d, bw=%d, freq=%d,%d,%d`). Rejects intervals below 50 us with
`intv time less than 50us`.

### RX

Two independent mechanisms:

```
# counter-based (for a fixed burst from a signal generator)
startrxstat                # start, and zero the counters
getrxstat                  # -> "rx_stat get: fcsok=%d, total=%d"
stoprxstat

# continuous console print
setrx                      # -> repeated "%4d / %4d, per:%02d.%02d%%"
setrxstop
```

`fcsok` counts CRC-good frames, `total` counts all detected frames. Counters
**accumulate** until the next `startrxstat`. With a generator sending N packets,
`PER = (1 - fcsok/N) * 100%`.

Only channel and bandwidth need to be set for RX.

### Crystal calibration

```
setxtalcap     <delta>     # coarse. default 0x10, range 0x00..0x1F
setxtalcapfine <delta>     # fine.   default 0x1F, range 0x00..0x3F
effreqcal 0                # read the stored value
effreqcal 1 <coarse>       # persist coarse
effreqcal 2 <fine>         # persist fine
```

The `set*` arguments are **signed deltas** applied to the current value, which is
why the doc's procedure is a binary search (`±4, ±2, ±1` coarse, then
`±16, ±8, ±4, ±2, ±1` fine). The command echoes the resulting absolute value in
hex. `effreqcal` writes the **absolute** value.

### MAC addresses

```
setmac   0a1c11223344      # 12 hex digits, no separators
getmac                     # -> "get macaddr: %x, %x"
setbtmac 0a1c11223345
getbtmac
```

The WiFi and BT addresses must differ, and the firmware warns
(`same source with wf mac addr`) if they collide. If P2P and SoftAP are both
needed, the vendor requires the two addresses to differ by at least 4.

### TX power

```
pwrlvl 0                          # read current gain table
pwrlvl <band> <mod> <idx> <val>   # set one rate
pwrlvl <band> <mod> <v0> <v1> ... # set a whole rate group (hence argc up to 15)
```

`band`: 1 = 2.4G, 2 = 5G. `mod`: 0 = 11b+11a/g, 1 = 11n/11ac, 2 = 11ax.
`val` is dBm, decimal. For 5G `mod 0`, the first four entries are invalid and
must be written as `-128`.

```
pwrofst2x   <band> <rate> <ch> <ofst>   # volatile channel-group compensation
efpwrofst2x <band> <rate> <ch> <ofst>   # same, persisted to efuse/flash
pwrofst2x 0                             # read
```

`band`: 1 = 2.4G ANT0, 2 = 2.4G ANT1, 3 = 5.8G ANT0, 4 = 5.8G ANT1.
`rate`: 2.4G 0 = 11b, 1 = ofdm_highrate; 5G 0 = ofdm_highrate.
`ch` is a channel-group index (2.4G: 0 = ch1-4, 1 = ch5-9, 2 = ch10-13;
5G: 0 = ch36-50, 1 = ch51-64, 2 = ch98-114, 3 = ch115-130, 4 = ch131-146,
5 = ch147-166). `ofst` is signed, −15..15, **0.5 dB per step**.

### Tone

```
tone_on <freq> [amp] [txgain]   # freq = offset from carrier in MHz, -20..19
tone_off
```

`amp` and `txgain` are *(undocumented)* extras beyond the vendor doc's one-argument form.

### Persistence model

Every `ef*` command and `setmac`/`setbtmac`/`setusb`/`setpcie`/`set_countrycode`
writes to **eFuse if the part has one and it still has room, otherwise flash**.
The image carries both paths and reports which was used, e.g.
`set xtal_cap to flash: 0x%x` vs `set xtal_cap to efuse: 0x%x`, and reports
remaining eFuse capacity as `(remain:%x)`. eFuse writes are **one-way** — the
firmware writes each value twice for redundancy, and the strings
`no room` / `no_room` are what you get when it is exhausted.

`efuse <fun> <args>` *(undocumented)* is the raw accessor underneath all of the
above — `1` = write, `2` = read.

### Identity — worth knowing for this repo

```
setusb <vid> <pid>         # persist USB VID/PID
getusb                     # -> "get vid 0x%x, pid 0x%x"
                           #    or "no usb info in flash, use setusb to set"
efusbid 0 | efusbid 1 <id> # the same field via the raw efuse accessor
```

This is the vendor-supported way the `a69c:8d80` identity is programmed, and it
is stored in eFuse/flash rather than being fixed in silicon.

```
setpcie <vid> <did> <subsys_vid> <subsys_id> <rev_id>
getpcie
set_countrycode <cc>       # 2-character code; validated, "setcc success"
get_countrycode
set_ch_countrycode <cc>    # per-channel regulatory variant
get_ch_countrycode
```

### Memory access

```
r <addr> [count] [size]    # read;  r.b / r.h select byte / halfword
w <addr> <val> [count]     # write; w.b / w.h likewise
g <type> <addr>            # jump; "Auto boot to 0x%08x" / "Custom boot to 0x%08x"
```

The `.b` / `.h` suffix is parsed off the **command name**, not passed as an
argument. These give unrestricted read/write over the chip's address space,
which is how the UART shell doubles as a bring-up debugger — and why a device
left running this firmware with accessible UART pins is fully open.

### Diagnostics

```
h                          # print the whole command table
t                          # die temperature -> "Temp      : %d C"
volt                       # -> AVDD18 / AVDD13 / VBAT / VRTC0 / VCORE, in mV
rssi                       # -> "RSSI : %d"
reboot
dm / ds                    # debug mask / severity filters
print <0|1>                # console open/close
gpioa <idx> <dir> [val]    # -> "gpioa%d output %d" / "gpioa%d input %d"
gpiob <idx> <dir> [val]
```

`gpioa` and `gpiob` share one handler at `0x00191559`; it selects the bank by
reading `argv[0][4]` and comparing against `'a'`. Not a defect, but it does mean
the handler is sensitive to the command name it was reached by.

### Calibration internals *(all undocumented)*

`calib`, `loft`, `dcver`, `dccomp`, `mdll_duty`, `swtable`, `fix_gain`,
`release_gain`, `notch`, `srrc`, `fss`, `papr`, `aux`, `setaux`, `setapc`, `cob`.

These drive the LOFT (carrier leakage), DPD (digital pre-distortion) and DC-offset
calibration engines directly. The image is full of their progress output —
`misc calib`, `loft start`, `dpd cal end`, `pwr cal 1..3`,
`table %d cal %d times`, `slope too small`,
`detect division by zero in cal_ls det`. `loft` takes a dump-selector whose
17 options the usage string enumerates in full (`0:loft_pwr_in_out`,
`1:dac_150m`, `2:adc_in`, `3:rx_data_iq`, `4:rc_in_iq` … `9:aux_fifo_out`).

`cob` ("chip on board") is the production self-test entry: `cob [0|1|2]`,
`0` = all, `1` = xtal disabled, `2` = xtal only. It prints
`cob dut start` then `dut%d,%d,%d,%d,%d,%d`.

These write calibration state that is then persisted. Running them without the
matching lab setup can leave a part worse-calibrated than it started.

---

## 6. Cross-variant command matrix

`—` means the command is absent from that image. Values are the accepted argc range.

| Command | D80/D40 | D80N | D80X2 | DC/DW/DL |
|---|:-:|:-:|:-:|:-:|
| `h` | `1..1` | `1..1` | `1..1` | `1..1` |
| `r` | `2..3` | `2..3` | `2..3` | `2..3` |
| `w` | `3..4` | `3..4` | `3..4` | `3..4` |
| `ds` | `1..3` | `1..3` | `1..3` | — |
| `dm` | `1..3` | `1..3` | `1..3` | `1..3` |
| `reboot` | `1..1` | `1..1` | `1..1` | `1..1` |
| `t` | `1..2` | `1..2` | `1..2` | `1..1` |
| `tp` | `1..2` | `1..2` | — | — |
| `tc` | `1..3` | `1..3` | `1..3` | — |
| `g` | `2..3` | `2..3` | `2..3` | `2..3` |
| `volt` | `1..1` | `1..1` | `1..1` | — |
| `calib` | `4..16` | `4..16` | `2..6` | `4..5` |
| `aux` | `2..2` | `2..2` | `2..2` | `2..2` |
| `loft` | `3..8` | `3..8` | `3..5` | `2..3` |
| `print` | `2..2` | `2..2` | `2..2` | `2..2` |
| `lp_mode` | `2..2` | `2..2` | `2..2` | `2..2` |
| `tone_on` | `2..4` | `2..4` | `2..5` | `2..2` |
| `tone_off` | `1..1` | `1..1` | `1..2` | `1..1` |
| `rx_meter` | `2..2` | `2..2` | `2..2` | `2..2` |
| `fix_gain` | `3..3` | `3..3` | `3..4` | `3..3` |
| `release_gain` | `1..1` | `1..1` | `1..1` | `1..1` |
| `notch` | `2..2` | `2..2` | `2..2` | `2..2` |
| `srrc` | `2..2` | `2..2` | `2..2` | `2..2` |
| `fss` | `2..2` | `2..2` | — | `2..2` |
| `mdll_duty` | `1..1` | `1..1` | `1..1` | — |
| `dcver` | `2..3` | `2..3` | `2..3` | — |
| `dccomp` | `3..19` | `3..19` | — | — |
| `mon` | `3..3` | `3..3` | — | — |
| `setxtalcap` | `2..2` | `2..2` | `2..2` | `2..2` |
| `setxtalcapfine` | `2..2` | `2..2` | `2..2` | `2..2` |
| `getmac` | `1..1` | `1..1` | `1..1` | `1..1` |
| `setmac` | `2..2` | `2..2` | `2..2` | `2..2` |
| `getbtmac` | `1..1` | `1..1` | `1..1` | `1..1` |
| `setbtmac` | `2..2` | `2..2` | `2..2` | `2..2` |
| `getvinfo` | `1..1` | `1..1` | — | — |
| `setvinfo` | `2..2` | `2..2` | — | — |
| `effreqcal` | `1..3` | `1..3` | `1..3` | `1..3` |
| `efpwrofst2x` | `1..5` | `1..5` | `1..5` | — |
| `efdrvibit` | `1..3` | — | `1..3` | — |
| `eftemplvl` | `1..3` | `1..3` | `1..3` | — |
| `efusbid` | `1..3` | `1..3` | `1..3` | — |
| `eftonepwr` | `1..3` | `1..3` | `1..3` | `1..3` |
| `efsdiocfg` | `1..3` | `1..3` | `1..3` | — |
| `efheoff` | `1..2` | `1..2` | — | — |
| `ef5goff` | `1..2` | `1..2` | — | — |
| `efpwradd2x` | `1..3` | `1..3` | — | — |
| `settx` | `1..2` | `1..2` | `2..2` | `2..2` |
| `setrx` | `1..1` | `1..1` | `1..1` | `1..1` |
| `setrxstop` | `1..1` | `1..1` | `1..1` | `1..1` |
| `startrxstat` | `1..1` | `1..1` | `1..1` | `1..1` |
| `getrxstat` | `1..1` | `1..1` | `1..1` | `1..1` |
| `stoprxstat` | `1..1` | `1..1` | `1..1` | `1..1` |
| `setintv` | `2..2` | `2..2` | `2..2` | `2..2` |
| `setlen` | `2..2` | `2..2` | `2..2` | `2..2` |
| `setrate` | `3..4` | `3..4` | `3..5` | `3..4` |
| `setchan` | `2..2` | `2..2` | `2..3` | `2..2` |
| `setbw` | `2..5` | `2..5` | `2..5` | `3..4` |
| `setbcbw` | `3..7` | `3..7` | `3..7` | — |
| `setaux` | `2..2` | `2..2` | `2..2` | — |
| `swtable` | `3..3` | `3..3` | — | — |
| `setsg` | `2..2` | `2..2` | `2..2` | `2..2` |
| `rssi` | `1..1` | `1..1` | `1..1` | `1..1` |
| `setldpc` | `2..2` | `2..2` | `2..2` | `2..2` |
| `setpwr` | `2..2` | `2..2` | `2..2` | `2..2` |
| `sethegi` | `2..2` | `2..2` | `2..2` | `2..2` |
| `setdcm` | `2..2` | `2..2` | `2..2` | `2..2` |
| `setdpl` | `2..2` | `2..2` | `2..2` | `2..2` |
| `setmab` | `2..2` | `2..2` | `2..2` | `2..2` |
| `setbfd` | `2..2` | `2..2` | `2..2` | `2..2` |
| `setsdg` | `2..2` | `2..2` | `2..2` | `2..2` |
| `setbc` | `2..2` | `2..2` | `2..2` | `2..2` |
| `setsr` | `2..2` | `2..2` | `2..2` | `2..2` |
| `setapc` | `3..4` | `3..4` | `3..4` | `3..4` |
| `efuse` | `3..4` | `3..4` | `3..4` | `3..4` |
| `pwrmm` | `1..2` | `1..2` | `1..2` | `1..2` |
| `pwrlvl` | `1..15` | `1..15` | `1..15` | `1..15` |
| `pwrofst2x` | `1..5` | `1..5` | `1..5` | — |
| `tonepwrofst` | `1..3` | `1..3` | — | — |
| `drvibit` | `1..4` | — | `1..4` | — |
| `papr` | `2..2` | `2..2` | `2..2` | `2..2` |
| `pwradd2x` | `1..3` | `1..3` | — | — |
| `gpioa` | `3..4` | `3..4` | `3..4` | `3..4` |
| `gpiob` | `3..4` | `3..4` | `3..4` | `3..4` |
| `cob` | `1..2` | `1..2` | — | `1..2` |
| `setusb` | `3..3` | `3..3` | `3..3` | — |
| `getusb` | `1..1` | `1..1` | `1..1` | — |
| `set_countrycode` | `2..2` | `2..2` | `2..2` | — |
| `get_countrycode` | `1..1` | `1..1` | `1..1` | — |
| `set_ch_countrycode` | `2..2` | `2..2` | `2..2` | — |
| `get_ch_countrycode` | `1..1` | `1..1` | `1..1` | — |
| `setpcie` | `6..6` | — | `6..6` | — |
| `getpcie` | `1..1` | — | `1..1` | — |
| `boot` | — | `1..1` | — | `1..1` |
| `x` | — | `2..2` | — | `2..2` |
| `e` | — | `2..8` | — | — |
| `baud` | — | — | `2..2` | — |
| `dccal` | — | — | `1..3` | — |
| `dconl` | — | — | `2..2` | — |
| `fls` | — | — | `1..2` | — |
| `setant` | — | — | `2..2` | — |
| `getnoise` | — | — | `1..1` | — |
| `rfdump` | — | — | `1..1` | — |
| `setstbc` | — | — | `2..2` | — |
| `setsmmidx` | — | — | `2..2` | — |
| `setrftbsw` | — | — | `2..2` | — |
| `setrftbhw` | — | — | `2..2` | — |
| `pll_test` | — | — | — | `2..4` |
| `cal_ipa` | — | — | — | `1..1` |
| `ms_ipa` | — | — | — | `1..1` |
| `cal_avdd13` | — | — | — | `1..1` |
| `vrfmode` | — | — | — | `1..2` |
| `calxtal` | — | — | — | `1..1` |
| `calxtalres` | — | — | — | `1..1` |
| `efpwrofst` | — | — | — | `1..4` |
| `efpwrofstfine` | — | — | — | `1..4` |
| `efagcdelta` | — | — | — | `1..3` |
| `efvl_vbit` | — | — | — | `1..3` |
| `certmd` | — | — | — | `1..2` |
| `pwrofst` | — | — | — | `1..4` |
| `pwrofstfine` | — | — | — | `1..4` |
| `vlvbit` | — | — | — | `1..4` |
| `super` | — | — | — | `3..3` |

### Notable per-variant differences

* **D80X2** is the only image with `baud` (runtime console baud change), `setant`
  (antenna selection — it is the 2×2 part), `getnoise`, `rfdump`, `setstbc`,
  `setsmmidx`, `setrftbsw`/`setrftbhw`, `dccal`, `dconl` and `fls` (flash ops).
  It lacks `dccomp`, `mon`, `swtable`, `tonepwrofst`, `pwradd2x` and the
  `getvinfo`/`setvinfo` pair.
* **D80N** is the only image with `e <addr> [args...]` (argc 2..8) — call an
  arbitrary function at an address with up to 6 arguments.
* **D80N** and **DC/DW/DL** additionally expose the boot-ROM style `boot` and
  `x <addr>` (XMODEM receive), so a replacement image can be loaded without
  dropping back to the boot ROM. D80/D40 and D80X2 do not.
* **DC/DW/DL** is an older branch (v6.4.3.1 vs v6.9.1.1) with a different
  calibration vocabulary: `pwrofst`/`pwrofstfine` and `efpwrofst`/`efpwrofstfine`
  instead of the `*2x` forms, plus `pll_test`, `cal_ipa`, `ms_ipa`,
  `cal_avdd13`, `vrfmode`, `calxtal`, `calxtalres`, `efagcdelta`, `efvl_vbit`,
  `vlvbit`, `certmd` (TX certification mode) and `super`.
* **D80/D40** has no commands unique to it; everything it exposes appears in at
  least one other image.

---

## 7. Relationship to the other RF test paths

Three different things in this SDK are all called "test mode". They are not
interchangeable:

| Path | Firmware | Transport | Driven by |
|---|---|---|---|
| **This document** | `testmode*.bin` | UART0 shell @ 921600 | Terminal, by hand |
| Driver testmode | `fmacfw_rf.bin` / `lmacfw_rf_*.bin` | nl80211 vendor testmode | `tools/aicrf_test/wifi_test.c` |
| BT test | separate image at `0x1A0000` | UART0 shell | Terminal, by hand |

The **driver testmode** path is the one that works over USB. It keeps the normal
driver loaded and sends commands through `rwnx_testmode.c`, with the host-side
tool taking a different, smaller command set:

```
wifi_test wlan0 set_tx <chan> <bw> <mode> <rate> <length> [interval]
wifi_test wlan0 set_txstop
wifi_test wlan0 set_rx / set_rxstop / get_rx_result
wifi_test wlan0 set_xtal_cap / set_xtal_cap_fine / set_freq_cal / get_freq_cal
wifi_test wlan0 set_mac_addr / get_mac_addr / set_bt_mac_addr / get_bt_mac_addr
wifi_test wlan0 set_power / rdwr_pwrlvl / rdwr_pwrofst / rdwr_efuse_pwrofst
```

Those map onto the same underlying RF engine, but the encodings differ — notably
`wifi_test set_tx` takes channel, bandwidth, mode, rate and length as **one**
command, where the UART shell needs `setchan` + `setbw` + `setrate` + `setlen` +
`settx 1`. The BT equivalent is `tools/aicrf_test/bt_test.c`.

The BT UART test program has its own vocabulary — `set_mode` (0 = BT, 1 = BLE),
`set_chidx`, `set_pkt` (0x11 = DH1 … 0x44 = LE LongRange S2), `set_pattern`
(0x00 = PRBS9 …), `set_len`, `set_addr`, `settx`, `txpwr_inc`/`txpwr_dec`,
`set_hop`, `toneon <chidx> <txpwr> <mode>`, `toneoff`, `setrxstart`,
`setrxstop`, `getrxresult`, `rx_log`.

---

## 8. Practical worked sequences

**TX EVM / spectrum, channel 1, HT20 MCS7:**

```
setchan 1
setrate 2 7
setbw 0 0
settx 1
...measure...
settx 0
```

> The vendor UART document writes this as `setch`. The command name in all four
> images analysed here is `setchan`; `setch` is not in any of the tables, and
> lookup is exact-match, so use `setchan`.

**Sensitivity / PER, 1000-packet burst:**

```
setchan 1
setbw 0 0
startrxstat
...generator sends 1000 packets...
getrxstat        # -> rx_stat get: fcsok=1000, total=1000
stoprxstat
```

**Program identity and calibration into a blank part:**

```
setmac   0a1c11223344
setbtmac 0a1c11223348
effreqcal 1 0x1A
efpwrofst2x 1 1 1 2
setusb 0xa69c 0x8d80
```

> `setmac`, `setbtmac`, `setusb`, `setpcie` and every `ef*` command write to
> eFuse, which is **one-time-programmable**. There is no undo. Verify with the
> matching `get*` before and after.

---

## 9. Provenance

| Fact | How established |
|---|---|
| Load base `0x160000` | Absolute vector-table entries; confirmed by the vendor doc's `x 160000` / `g 160000` and by `aicwf_usb.h` |
| `struct cmd_entry` layout | Field offsets read directly off the dispatcher at `0x0018CD60` (`ldrd r1,r2,[r0]` for name/usage, `ldrsh [r0,#8]`/`[r0,#0xA]` for argc, `ldr [r0,#0xC]` then `blx` for the handler) |
| Table base and count | Literal `0x19BB88` and immediate `0x5C` passed to the lookup at `0x00188F68`; the base is referenced from exactly two sites, the dispatcher and the `h` handler |
| argc semantics | Dispatcher compares against the tokenizer's return value, which counts `argv[0]` |
| Number format | Arg converter at `0x00189138` is `strtol` with base 0, always called with `base = 0` |
| UART registers | Console writer at `0x0017095C` |
| Command semantics | `AIC8800D80X2射频测试说明--UART版v3.0.pdf` where covered; usage strings and format strings in the image otherwise |

Tables in §4 and §6 were extracted programmatically from the binaries rather
than transcribed, so they are complete rather than a selection.
`tools/extract_testmode_cmds.py` in this repo reproduces them:

```
python3 tools/extract_testmode_cmds.py path/to/testmode20_2025_1205_1950.bin
```

---

## Appendix A. `tone_on` / `tone_off` internals

Handlers: `tone_on` at `0x0018A1A8`, `tone_off` at `0x001894C4`. Addresses are for `testmode20_2025_1205_1950.bin`.

### A.1 Argument parsing

```
tone_on <freq> [amp] [txgain]
```

| Arg | Parsed by | Base | Stored as | Notes |
|---|---|---|---|---|
| `freq` | `strtol` @`0x00189138` | **10** | signed, MHz | `0x` prefix still forces hex; leading `-` accepted |
| `amp` | same | **16** | 12 bits | hex *without* a prefix — `tone_on 1 20` means 0x20 |
| `txgain` | same | **16** | 6 bits | likewise |

Defaults when omitted: `amp = 0x3FF`, `txgain = 1`.

### A.2 Validation — effectively none

The only test in the handler is `argc <= 1` → `parameter missing`, return 1.
That branch is **unreachable**: the dispatcher already rejects `argc < 2` from
the table's `min_argc`. Beyond it:

* `freq` is **not range-checked**. The vendor doc states −20..19 MHz; the
  firmware accepts anything and silently truncates the computed word to 14 bits,
  so out-of-range offsets alias. `tone_on 100` programs the same word as
  `tone_on 20`.
* `amp` is truncated to 12 bits (`ubfx r7, r7, #0, #12`) with no warning.
* `txgain` is masked to 6 bits (`and r6, r0, #0x3f`) with no warning.
* No check that a channel/band was configured first, and no PLL-lock check
  before or after enabling the tone.
* The handler always returns 0, so the shell never reports `Command fail`.

The echo line is the only feedback:
`user tone on, freq=%d, amp=%x, txgain=%x` — and it prints the **pre-truncation**
`amp` (16 bits) and `txgain` (8 bits), not the values actually programmed. A
`txgain` of `0x40` prints as `40` but reaches the register as `0`.

### A.3 Frequency word

Two code paths compute the same quantity, one in hardware float and one in
soft-double, split on the sign of `freq`:

```c
/* freq >= 0 : hardware VFP */
word = lround((float)freq / 160.0f * 32768.0f);

/* freq <  0 : soft double, via __aeabi_f2d/dadd/ddiv/dmul/d2iz */
word = lround(((double)freq + 80.0) / 160.0 * 32768.0);
```

`+80.0` before scaling adds exactly 16384 = 2^14, which is a no-op modulo the
14-bit field — so both paths reduce to the same thing:

```
tone_word = round(freq_MHz * 204.8)   mod 2^14,   interpreted as signed 14-bit
```

LSB = 160/32768 MHz = **4.8828 kHz**; full-scale ±8192 = **±40 MHz**. The
generator is a digital NCO in the TX path — the tone is an *offset from the
carrier* set by `setchan`, not a change to the RF PLL.

### A.4 Register writes

Programmed in this order (read-modify-write throughout):

| Step | Register | Operation | Inferred meaning |
|---|---|---|---|
| 1 | `0x4034206C` | `[11:0] = amp` | NCO amplitude |
| 2 | `0x40344088` | `[5:0] = txgain` | TX gain index |
| 3 | `0x40344088` | `\|= 1<<6` | |
| 4 | `0x40344088` | `\|= 1<<7` | |
| 5 | `0x4034206C` | `[25:12] = tone_word` | NCO frequency |
| 6 | `0x40340010` | `\|= 1<<24` | |
| 7 | `0x4034202C` | `\|= 1<<16` | TX path enable |
| 8 | `0x4034206C` | `\|= 1<<28` | **tone enable** |
| 9 | `0x40342030` | `\|= 1<<8` | |
| 10 | — | delay `0x30D40` ticks | |
| 11 | `0x40344088` | `[22:19] = 2` | PA/ramp stage |
| 12 | — | delay | |
| 13 | `0x40344088` | `\|= 1<<22` | |
| 14 | — | delay | |
| 15 | `0x40344088` | `\|= 1<<21` | |

The three delays busy-poll a free-running counter at **`0x40320120`**, waiting
for it to advance by `0x30D40` (199,488) ticks — the same idiom used elsewhere in
the image for hardware settling waits.

`tone_off` reverses only part of this:

```
0x4034206C &= ~(1<<28)      # tone enable off
0x40344088 &= ~0x780000     # [22:19] = 0
0x4034202C &= ~(1<<16)
0x40344088 &= ~0x3F         # txgain = 0
0x40344088 &= ~(1<<6)
0x40344088 |=  (1<<7)       # note: SET, not cleared
```

**`0x40340010[24]` and `0x40342030[8]` are never cleared**, and bit 7 of
`0x40344088` is set by both paths. So `tone_off` does not restore the pre-`tone_on`
state; a `tone_on`/`tone_off` cycle leaves the RF front-end configured
differently than it was found. Re-run `setchan`/`setbw` before taking other
measurements.

`0x4034206C` is not private to this command — the LOFT and DPD calibration
routines drive the same NCO from ~15 other sites (`0x00165274`, `0x00165650`,
`0x00166354`, `0x001677D2`, `0x00168300`, `0x0016A960`, `0x0016ACC0`,
`0x0016B1F6`, …). `tone_on` is a thin shell wrapper over the calibration tone
generator, which is why its arguments map so directly onto register fields.

---

## Appendix B. What the image reveals about the RF PLL

There are **no register-name strings and no symbol table** in the image, so most
of the RF map is only recoverable as "this address, these bits, this effect".
There is one exception that names fields directly.

### B.1 The one self-documenting PLL access

The channel-programming routine at `0x0016D270` opens by snapshotting five
registers and printing them under a debug-module mask of `0x2000`:

```
page %x,sdm %x,freq %x,lock %x,rfen %x
```

which pins down five PLL registers by name:

| Name | Register | Extraction |
|---|---|---|
| `page` | `0x40344084` | `(reg >> 3) & 0x7` |
| `sdm` | `0x40342010` | whole word |
| `freq` | `0x4034201C` | whole word |
| `lock` | `0x40342204` | whole word |
| `rfen` | `0x40580018` | whole word |

`page` selecting between banks via `0x40344084[5:3]` also explains why the same
RF addresses are written with different meanings in different routines.

### B.2 How `sdm` and `freq` are computed

At `0x0016F560` (reached from the channel/PLL setup path):

```c
sdm  = (int)lround(x * 4194304.0) & 0x7FFFFFFF;   /* 2^22 scaling      */
freq = (int)lround(y / 1.25);                      /* 1.25 MHz per LSB  */

*(u32*)0x40342010  = sdm;                          /* full 31-bit word  */
*(u32*)0x4034201C  = (*(u32*)0x4034201C & 0xC0001FFF)
                   | ((freq << 13) & 0x3FFFE000);  /* bits [29:13]      */
```

So the synthesiser is a **fractional-N PLL**: `0x4034201C[29:13]` is a 17-bit
integer word with a **1.25 MHz** step.

**`0x4034201C[29:13]` is confirmed on live hardware.** Read from a running
`368b:8d81` under normal `fmacfw` (not testmode), the field held `1950` — which is
exactly what the encoder produces for channel 6 (2437 MHz): `lround(2437 / 1.25)
= lround(1949.6) = 1950`. (Decoding straight back gives `1950 × 1.25 = 2437.5`
MHz; the extra ½ MHz is just the ½-LSB rounding, with the residue carried in the
fractional/`sdm` word.) The decode was derived purely by static analysis of
`testmode20.bin` yet reads out the correct channel centre under completely
different firmware.

**The `0x40342010` "sdm" reading is NOT confirmed and is probably wrong.** It was
described here as a 2²² fractional word. On the same live read it held
`0x037B3EE7` → 13.93 in those units, but channel 6 sits exactly on the 1.25 MHz
grid so any fraction should be ~0. More likely it is a live sigma-delta
accumulator — hardware state sampled mid-operation, not a configuration value.
Treat `sdm` as undecoded. Nearby
double-precision constants **2489.0** and **4978.0** (`0x0016F6C0`,
`0x0016F6C8`) sit in the same routine and are consistent with 2.4 GHz and 5 GHz
VCO references, `4978 = 2 × 2489`.

### B.3 Registers in the PLL/RF init sequence

The routine at `0x0016D270` also touches, in order:
`0x40342030`, `0x40342060`, `0x40342068`, `0x4034205C`, `0x40342064`,
`0x4033C044`, `0x40344028`, `0x40344084`, `0x40344088`, and `0x4033C044+0x613C`.
Bit-level effects are recoverable from the disassembly but none of them are
named anywhere in the image.

### B.4 Peripheral blocks, by weight of reference

Counting 32-bit literals in the `0x40000000-0x41000000` range gives 557 distinct
values, but most singletons are false positives — IEEE-754 double high-words
alias into this range (`0x40540000` is 80.0, `0x40640000` is 160.0,
`0x40E00000` is 32768.0). Filtering to blocks with many distinct registers *and*
many references leaves a credible map:

| Block | Refs | Distinct regs | Role (inferred) |
|---|---:|---:|---|
| `0x40320000` | 294 | 89 | MAC / modem core; `0x40320120` is a free-running counter |
| `0x40342000` | 246 | 58 | RF synthesiser + TX NCO (`sdm`, `freq`, tone at `0x…206C`) |
| `0x40344000` | 179 | 33 | RF front-end / gain / PA sequencing (`page`, txgain) |
| `0x40328000` | 153 | 54 | modem (PHY) datapath |
| `0x40501000` | 54 | 1 | — |
| `0x40500000` | 36 | 2 | — |
| `0x40509000` | 36 | 10 | clock / PLL control (read by the freq path) |
| `0x40330000` | 36 | 16 | — |
| `0x4033B000` | 33 | 16 | — |
| `0x40346000` | 22 | 10 | — |
| `0x40340000` | 21 | 6 | RF enables |
| `0x40032000` | 18 | 10 | **UART0** (`0x…000` data, `0x…020` status) |
| `0x40341000` | 14 | 11 | — |

`0x40580018` (`rfen`) sits alone in a lightly-used block, as does `0x4033C044`.

> Everything in this appendix is inferred from one firmware image. The five
> names in B.1 come from the firmware's own format string; every other label is
> a guess from observed behaviour and should be treated as such.

---

## Appendix C. Tuning range, and building a swept/chirp transmitter

### C.1 What each command will actually accept

Two commands set frequency, and **they validate very differently**.

`setbcbw <band> <chnum> …` (handler `0x00190028`) is the strict one:

| Check | Behaviour |
|---|---|
| `band > 1` | `invalid band: %d`, returns −1 |
| band 0, `chnum > 14` | `invalid channel_num: %d @ band %d` |
| band 1, `chnum > 165` | `invalid channel_num: %d @ band %d` |
| band 1, `chnum > 177` (secondary) | `not supported channel_num: %d @ band %d` |

So through `setbcbw` the reachable set is exactly **2412–2484 MHz** (ch 1–14) and
**5180–5825 MHz** (ch 36–165). Band 2 does not exist in this image — there is
**no 6 GHz band** on D80/D40, whatever the X2 document says about 6E.

`setchan <chnum>` (handler `0x0018FBD8`) is the loose one:

```c
chan = strtol(argv[1], NULL, 10) & 0xFF;      /* uxtb — 8 bits! */
if (chan == 0)               error;
if (chan <= 13)  freq = 5 * chan + 2407;      /* 2412 .. 2472 */
else if (chan == 14) freq = 2484;
else if (chan <= 35) error;
else             freq = 5000 + 5 * chan;      /* no upper bound */
```

Two consequences:

* The channel number is **truncated to 8 bits with no warning**. The vendor doc's
  6 GHz idiom `setch 6500` does not work here — `6500 & 0xFF = 100`, so you
  silently get channel 100 = 5500 MHz. Nothing reports the truncation.
* Channels **36–255 are accepted with no upper limit**, giving a nominal
  `5000 + 5*255` = **6275 MHz**. Whether the synthesiser actually locks above the
  5 GHz band is a hardware question this binary cannot answer — but the `lock`
  register (`0x40342204`, §B.1) is readable, so it is directly measurable:
  `setchan 250` then `r 40342204`.

On top of whichever carrier is set, the tone NCO adds **±40 MHz** of
representable offset (§A.3), of which the vendor only documents ±20 MHz as
usable — analog filtering, not the register, is the limit there.

For truly arbitrary frequencies, the PLL words are writable directly:
`0x4034201C[29:13]` in **1.25 MHz** steps and `0x40342010` as a **2²²**
fractional word. The 17-bit integer field is not the constraint; the VCO is.

### C.2 There is no built-in sweep

None of the 92 commands sweeps frequency. `calib`, `loft` and `dcver` do step
internally, but none of them exposes start/stop/step as arguments. `tp <ms>`
looks like a scheduling hook but is not — it stores the period at `0x0019C148`
and installs a **fixed** callback (`0x0018A9D0`) at `0x1A8680+4`; there is no way
to point it at your own code from the shell.

So a chirp has to be built from the memory primitives. Four options, best first.

### C.3 Option 1 — upload a routine and call it (D80N only, cleanest)

The **D80N** image is the only one with `e <addr> [args…]` — *"Exec Func"*, argc
2..8, a genuine call that **returns to the shell** with up to 6 arguments. That
is exactly the primitive a chirp needs:

```
w 1a2400 <word0>          # upload a small Thumb routine, one word per command
w 1a2404 <word1>
...
e 1a2401 <f_start> <f_stop> <step> <dwell>   # note: Thumb bit set in the address
```

The routine writes `0x4034206C[25:12]` in a tight loop, so step dwell is set by
your own delay loop rather than by UART latency. Sub-microsecond steps are
achievable.

### C.4 Option 2 — upload and `g` (D80/D40, one-way)

D80/D40 has no `e`. Its `g <type> <addr>` (handler `0x00189674`) is **not a
subroutine call** — it prints `Goto %p` / `PC=%p`, then writes `8` to
`0x40500104` and toggles bits 17/18 of `0x40506008`, i.e. it latches a boot
address and resets the core. With `type == 1` it treats `addr` as a vector table
and boots to the word at `addr+4`; otherwise it boots to `addr` directly.

That is the same mechanism the boot ROM uses for `g 160000`, and it means:

* your routine must be **self-contained** (own stack, own init), and
* **the shell does not come back**. You lose the console until the next reload.

Workable for a fire-and-forget sweep generator, awkward for iteration.

### C.5 Option 3 — host-driven stepped sweep (no code upload)

The simplest thing that works anywhere:

```
tone_on 0 3ff 1                 # once, to run the full enable + PA ramp
w 4034206c <word>               # then step the NCO directly, repeatedly
```

Caveats:

* `w` is a **plain store, not read-modify-write**, so every word you write must
  carry the amplitude in `[11:0]` and the enable bit `[28]`, not just the
  frequency in `[25:12]`.
* `w` parses **both address and value as hex** (base 16), unlike most commands.
* `w addr val <cnt>` writes the *same* value to `cnt` **consecutive addresses**
  (the address advances by the access size each iteration) — it does not repeat
  in place, so it cannot be used to emit a ramp.
* Step rate is bounded by the UART round trip: ~20 characters at 921600 baud plus
  the `aic> ` echo and command parsing, so on the order of a few kHz of steps per
  second at best. That is a *swept CW*, not a fast chirp.

### C.6 Option 4 — `tone_on` in a loop (avoid)

Re-running `tone_on` per step re-executes the whole enable sequence including
three busy-wait delays of 199,488 counter ticks each plus the `[22:19]` PA ramp
(§A.4), so each step costs milliseconds. It also never restores state on
`tone_off` (§A.4), so a long loop accumulates front-end drift.

### C.7 Range beyond ±40 MHz

The NCO only reaches ±40 MHz around the carrier. A wider sweep means retuning the
PLL itself — writing `0x4034201C` / `0x40342010` — which incurs lock time on each
step. Poll `0x40342204` (`lock`) between steps rather than assuming a fixed
settle. A hybrid works well: retune the PLL coarsely on a 1.25 MHz grid, then use
the NCO for fine sweep inside each step.

> Everything in C.1 is read out of the code. The *physical* limits — VCO lock
> range, filter and PA response outside the WiFi bands, and what the front-end
> matching network will actually radiate — are not determinable from the
> firmware, and the 6275 MHz figure is a register-arithmetic ceiling, not a
> claim that the part tunes there.

---

## Appendix D. Identifying the part, and what the pins are

### D.1 Reading the silicon ID

The authoritative identifier is a register, not the USB PID. `system_config_8800d80()`
in `aic_load_fw/aic_compat_8800d80.c` reads **`0x40500000`** and decodes:

```c
chip_id     = (reg >> 16) & 0xFF;          /* silicon revision   */
chip_mcu_id = ((reg >> 25) & 1) == 0;      /* 1 => "M80" flavour */
IS_CHIP_ID_H() == ((chip_id & 0xC0) == 0xC0);
```

| `chip_id` | Revision |
|---|---|
| `0x01` | U01 |
| `0x03` | U02 |
| `0x07` | U03 |
| `0x0F` | U04 |
| `0x1F` | U05 |
| `0x20` | `CHIP_SUB_REV_U04` |

From the test shell (note `r` parses its address as **hex**):

```
r 40500000
[0x40500000] = 0x........
```

With the stock Linux driver loaded, the same information is printed to the kernel
log without any of this:

```
chip_id=%x, chip_mcu_id = %d
```

`chip_mcu_id` is what gates the extra flash upload:

```c
if (chip_mcu_id)
    rwnx_plat_flash_bin_upload_android(usb_dev,
        FLASH_BIN_ADDR_8800M80 /* 0x08000000 */,
        FLASH_BIN_8800M80      /* "host_wb_8800m80.bin" */);
```

So **`M80` is the D80 die in a module flavour carrying external SPI flash** at
`0x08000000` with a host blob. The driver still classifies it as
`PRODUCT_ID_AIC8800D80`, and `AIC8800D80D40/testmode20_*.bin` is the correct RF
test image for it.

#### `chip_mcu_id` is a sticky global — read it with care

`chip_mcu_id` is a **module-scope global** (`aicwf_usb.c`: `u8 chip_mcu_id = 0;`)
and `system_config_8800d80()` only ever **sets it to 1** — nothing ever clears it:

```c
if (((rd_mem_addr_cfm.memdata >> 25) & 0x01UL) == 0x00UL)
    chip_mcu_id = 1;                 /* no matching "else chip_mcu_id = 0;" */
```

So once any probed device latches it to 1, **every later probe prints 1** until
the module is reloaded, even for a part that is not an M80. In a log like

```
chip_id=7, chip_mcu_id = 0     <- trustworthy: really not M80
chip_id=7, chip_mcu_id = 0
chip_id=7, chip_mcu_id = 1     <- trustworthy: this probe latched it
chip_id=7, chip_mcu_id = 1     <- NOT trustworthy, may be inherited
```

only the `0` lines and the first `0 -> 1` transition carry information.

`chip_id` does not have this problem — it is assigned unconditionally on every
probe (`chip_id = (u8)(memdata >> 16)`), so every line's `chip_id` is valid.

To get a clean per-board answer, either reload the module between boards:

```
sudo rmmod aic_load_fw && sudo modprobe aic_load_fw   # then plug in ONE board
```

or read bit 25 of `0x40500000` yourself and skip the driver's bookkeeping
entirely (`r 40500000` from the test shell).

### D.2 USB IDs — indicative, not authoritative

| VID | PID | Driver `chipid` |
|---|---|---|
| `0xA69C` | `0x8800` | `PRODUCT_ID_AIC8800` |
| `0xA69C` | `0x8801` | `PRODUCT_ID_AIC8801` |
| `0xA69C` | `0x8D80` | `PRODUCT_ID_AIC8800D80` |
| `0xA69C` | `0x8D81` | `PRODUCT_ID_AIC8800D81` |
| `0xA69C` | `0x8D40` | `PRODUCT_ID_AIC8800D80` (D40 shares the D80 path) |
| `0xA69C` | `0x8D41` | `PRODUCT_ID_AIC8800D81` |
| `0x368B` | `0x8D90` | `PRODUCT_ID_AIC8800D80X2` |
| `0x368B` | `0x8D91` | `PRODUCT_ID_AIC8800D81X2` |
| `0x368B` | `0x8D99` | `PRODUCT_ID_AIC8800D89X2` |
| `0x368B` | `0x8D92` | `PRODUCT_ID_AIC8800D40X2` |

**The PID is stored in eFuse/flash and is rewritable** — `setusb <vid> <pid>` and
`efusbid 1 <id>` both program it (§4, Identity). It reflects how the part was
provisioned, not which die it is. Use `0x40500000` when it matters.

The `D81`/`D89` variants differ from `D80` by using an extra bulk "message"
endpoint (`use_msg_ep`, `aicwf_usb.c`), not by RF capability.

### D.3 UART and GPIO pins

| Pad | What it is |
|---|---|
| `tx` / `rx` | **UART0** — boot ROM shell *and* the test-mode console (§2, §3). 921600 8-N-1, 1.8 V or 3.3 V logic |
| `bt_tx` / `bt_rx` | BT HCI UART, live only when the BT controller is configured for `AICBT_BTPORT_UART` |
| `GPIOb0` / `GPIOb1` | Bank B GPIO 0 and 1 — exactly what `gpiob <idx> <dir> [val]` drives |

`tx`/`rx` plus power and ground is all the WiFi RF test needs.

The BT HCI UART default is **`AICBT_BTPORT_MB`** (mailbox over the host bus), not
UART, so `bt_tx`/`bt_rx` are idle unless `btport` is changed. When it is enabled,
`enum aicbt_uart_baud_type` allows 115200, 921600, 1500000 or 3250000, and
`AICBT_UART_FC_DEFAULT` is **flow control enabled** — with only TX/RX brought out
and no RTS/CTS, flow control has to be disabled for the link to work.

Note the BT *test* firmware (loaded at `0x1A0000`) takes its commands on the main
UART0 console, not on `bt_tx`/`bt_rx`.

### D.4 WiFi and BT RF ports

The die has **two separate 2.4 GHz RF ports**, and the BT transceiver can be
routed to either. The BT test command makes this explicit:

```
toneon <chidx> <txpwr> <mode>     # mode 0 = BT RF port
                                  # mode 1 = "combo", out the WiFi 2.4G port
```

The driver's `enum aicbt_btmode_type` describes how the antenna is shared:

| Mode | Meaning |
|---|---|
| `AICBT_BTMODE_BT_ONLY_SW` | BT only, **with** an external RF switch |
| `AICBT_BTMODE_BT_WIFI_COMBO` | WiFi/BT combo |
| `AICBT_BTMODE_BT_ONLY` | BT only, without switch |
| `AICBT_BTMODE_BT_ONLY_TEST` | BT only, test |
| `AICBT_BTMODE_BT_WIFI_COMBO_TEST` | combo, test |
| `AICBT_BTMODE_BT_ONLY_COANT` | BT only, **no external switch** — co-antenna |

`AICBT_BTMODE_DEFAULT_8800d80` and `..._8800d80x2` are both
**`AICBT_BTMODE_BT_ONLY_COANT`**, i.e. the D80 family defaults to sharing one
antenna between WiFi and BT with no external switch.

So this is not two independent radios that can transmit at once — it is one
2.4 GHz BT transceiver with a choice of output pin, arbitrated against WiFi by
coexistence logic. A module with a single trace antenna is the expected case.
(On the 5 GHz side `setaux 1|0` selects an `aux`/`main` RF path, and D80X2 adds
`setant 0|1|2`, so there is more than one RF port there too.)

To determine empirically which port a given board's antenna is bonded to, drive a
tone out each one and compare with a near-field probe or SDR:

```
# WiFi 2.4G port
setchan 6
tone_on 0
tone_off

# BT firmware (x 1a0000 / g 1a0000), same channel, both routings
toneon 20 6 0      # BT RF port
toneoff
toneon 20 6 1      # combo — WiFi 2.4G port
toneoff
```


---

## Appendix E. The USB debug-message protocol

The kernel drivers reach chip memory over plain **bulk transfers** carrying
`DBG_*` messages. Nothing here is privileged, so it is fully reimplementable in
userspace — `tools/aic-memtool.c` does exactly this.

**Verified on hardware 2026-08-29** against a `368b:8d81` device in operational
(firmware-loaded) mode.

### E.1 Endpoints

The vendor-specific interface (class/subclass/protocol `0xFF/0xFF/0xFF`) carries
the messages. Confirmed descriptor layout on `368b:8d81`:

| Interface | Class | Endpoints | Role |
|---|---|---|---|
| 0 | `0xE0/0x01/0x01` | `0x83` intr in, `0x84` bulk in/out | BT HCI + ACL |
| 1 | `0xE0/0x01/0x01` | `0x85` iso in/out, 6 alt settings | BT SCO |
| 2 | `0xFF/0xFF/0xFF` | `0x01` out, `0x81` in, `0x02` out, `0x82` in | WLAN data + messages |

Both drivers walk `interface->endpoint[i]` in descriptor order and assign the
**first** bulk pair to data and the **second** to messages:

| | boot ROM (`aic_load_fw`) | operational (`aic8800_fdrv`) |
|---|---|---|
| data | `bulk_out` / `bulk_in` | `bulk_out` / `bulk_in` = `0x01` / `0x81` |
| messages | same pair (D80: `use_msg_ep = 0`) | `msg_out` / `msg_in` = `0x02` / `0x82` |

So at 8d80 messages ride the first bulk pair; at 8d81/8d83 they ride the second.
Fall back to the first pair if only one exists.

### E.2 Request framing (host → chip)

`aicwf_set_cmd_tx()` is byte-identical in `aic_load_fw` and `aic8800_fdrv`.
With `len = 8 + param_len`, the transfer is `len + 8` bytes:

```
 [0]     (len+4) & 0xFF        length low
 [1]     ((len+4) >> 8) & 0x0F length high (4 bits)
 [2]     0x11                  type
 [3]     0x00
 [4..7]  dummy word (zeroed)
 [8..9]  id         u16 LE
 [10..11] dest_id   u16 LE
 [12..13] src_id    u16 LE
 [14..15] param_len u16 LE
 [16..]   param
```

`TASK_MM = 0`, `TASK_DBG = 1`, `LMAC_FIRST_MSG(t) = t << 10`, `DRV_TASK_ID = 100`:

| Message | id | param |
|---|---|---|
| `DBG_MEM_READ_REQ` | `0x0400` | `u32 memaddr` |
| `DBG_MEM_READ_CFM` | `0x0401` | `u32 memaddr, u32 memdata` |
| `DBG_MEM_WRITE_REQ` | `0x0402` | `u32 memaddr, u32 memdata` |
| `DBG_MEM_WRITE_CFM` | `0x0403` | |
| `DBG_MEM_BLOCK_WRITE_REQ` | `0x040B` | `u32 memaddr, u32 memsize, u32 data[512/4]` |
| `DBG_MEM_BLOCK_WRITE_CFM` | `0x040C` | |
| `DBG_START_APP_REQ` | `0x040D` | `u32 bootaddr, u32 boottype` |
| `DBG_START_APP_CFM` | `0x040E` | `u32 bootstatus` |
| `DBG_RFTEST_CMD_REQ` | `0x0413` | `u32 cmd, u32 argc, u8 argv[30]` |
| `DBG_RFTEST_CMD_CFM` | `0x0414` | `u32 rftest_result[32]` |
| `DBG_EF_USRDATA_READ_REQ` | `0x0421` | |
| **`DBG_MEM_BLOCK_READ_REQ`** | **`0x0423`** | `u32 memaddr, u32 memsize` |
| **`DBG_MEM_BLOCK_READ_CFM`** | **`0x0424`** | `u32 memaddr, u32 memsize, u32 data[1024/4]` |

> **Keep `memsize` <= 1024.** `dbg_mem_block_read_cfm.memdata[1024/4]` bounds the
> reply payload, so larger requests have nowhere to land. What the firmware
> actually does with an oversized `memsize` is **untested** — see Appendix L for
> why an earlier attempt to find out proved nothing.

> **Use the block forms for bulk transfer.** `aic_load_fw/aicbluetooth_cmds.h`
> carries a *trimmed* copy of `enum dbg_msg_tag` that stops at
> `DBG_MEM_MASK_WRITE_CFM`, which makes it look as though only single-word reads
> exist. The full enum is in `aic8800_fdrv/lmac_msg.h` and runs to `DBG_MAX =
> 0x0429`. `DBG_MEM_BLOCK_READ_CFM` returns **up to 1024 bytes (256 words) per
> reply** — 256x fewer round trips than `DBG_MEM_READ_REQ`. The driver wires it up
> as `rwnx_send_dbg_mem_block_read_req()` (`rwnx_msg_tx.c:5026`).

`boottype`: `1 = AUTO`, `2 = CUSTOM`, `3 = REBOOT` (with `bootaddr` reused as a
delay in ms — this is what `rwnx_send_reboot()` sends to bounce the chip back to
boot-ROM mode).

Reading `0x40500000` is 20 bytes on the wire:

```
10 00 11 00  00 00 00 00  00 04  01 00  64 00  04 00  00 00 50 40
```

### E.3 Reply framing (chip → host)

The reply carries the **same 4-byte header** as the request, then an
`ipc_e2a_msg` — which differs from the request header by an extra `pattern`
word. Actual 24-byte reply to the request above:

```
14 00 11 00  01 04  60 11  5f 49  08 00  16 9f 65 20  00 00 50 40  20 88 07 f9
```

```
 [0..3]   header       len field 0x0014, type 0x11
 [4..5]   id           0x0401 = DBG_MEM_READ_CFM
 [6..9]   dummy_dest_id / dummy_src_id   (don't-care)
 [10..11] param_len    8
 [12..15] pattern      valid-buffer stamp, varies
 [16..19] memaddr      echoed: 0x40500000
 [20..23] memdata      0xF9078820
```

Note `aic_txrxif.c:243` casts the RX block at `data + 4`, which is what puts the
payload at offset 16 rather than 12.

### E.4 Worked result

```
$ sudo AIC_RAW=1 ./aic-memtool 40500000
device 368b:8d81
interface 2  bulk_out=0x01 bulk_in=0x81  msg_out=0x02 msg_in=0x82 -> using tx=0x02 rx=0x82
[0x40500000] = 0xf9078820
```

`0xF9078820` = `1111 1001 0000 0111 1000 1000 0010 0000`:

| Field | Bits | Value | Meaning |
|---|---|---|---|
| `chip_id` | 23:16 | `0x07` | `CHIP_REV_U03` |
| `chip_mcu_id` | bit 25 == 0 | 1 | **M80** — external SPI flash, `host_wb_8800m80.bin` at `0x08000000` |
| `IS_CHIP_ID_H()` | `chip_id & 0xC0` | false | not an "H" part; uses `fmacfw_8800d80_u02.bin` |

This is the per-board reading that the driver's own `chip_mcu_id` logging cannot
give you, because that global latches to 1 and never clears (§D.1).


---

## Appendix F. Which firmware images actually implement USB

The standalone `testmode*.bin` images are UART-only (§2). The images the driver
loads are not. Tested by searching each for the USB string descriptors the device
reports on the wire:

| Image | Base | USB descriptors | `aic>` shell | Shell transport |
|---|---|:-:|:-:|---|
| `testmode20_*.bin` | `0x160000` | — | 92 cmds | UART0 only |
| `lmacfw_rf_8800d80_u02.bin` | `0x120000` | **yes** | 57 cmds | UART0 only |
| `fmacfw_8800d80_u02.bin` | `0x120000` | **yes** | 9 cmds (debug) | UART0 only |
| `calibmode_8800d80.bin` | `0x1E0000` | — | 4 cmds | UART0 only |

Bases were recovered from the vector tables and match the driver's own constants
(`RAM_FMAC_FW_ADDR_8800D80_U02`, `RAM_FMAC_RF_FW_ADDR_8800D80_U02` = `0x120000`,
`FW_RAM_CALIBMODE_ADDR_8800D80_U02` = `0x1E0000`).

### F.1 The descriptor table in `lmacfw_rf`

Device descriptor at file offset `0x18618` (address `0x00138618`):

```
12 01 00 02 ef 02 01 40 9c a6 81 8d 00 01 01 02 03 01
```

| Field | Value |
|---|---|
| `bcdUSB` | `0x0200` |
| class / subclass / protocol | `0xEF` / `0x02` / `0x01` — IAD, multi-function |
| `bMaxPacketSize0` | 64 |
| `idVendor` / `idProduct` | **`0xA69C` / `0x8D81`** |
| `bcdDevice` | `0x0100` |
| configurations | 1 |

String descriptors follow immediately: `"01"`, `"Bluetooth"`, `"Wlan"`,
`"AICSemi"`, `"AIC 8800D80"`, `"20220103"`, LANGID `0x0409`. Those are
byte-for-byte what a live device reports.

**The IDs are patched at runtime.** The compiled-in default is `a69c:8d81`, but
the test device enumerates as `368b:8d81` — the firmware overrides them from
flash/eFuse, as the strings `RDWR_FLASH_USBVIDPID` and `get/set ef_usb_id=%x`
show. That is the same storage `setusb` / `efusbid` write (§4), and it is why the
USB PID is not authoritative for identifying silicon (§D.2).

### F.2 `lmacfw_rf` carries the RF shell too — but on UART

Its 57-command table at `0x0015F8A4` is the RF-test subset of testmode's 92:
the whole `settx`/`setrx`/`startrxstat`/`getrxstat` path, `setchan`/`setbw`/
`setbcbw`/`setrate`, the `setpwr`/`pwrlvl`/`pwrofst2x`/`drvibit`/`papr` power
family, `efuse`, `gpioa`/`gpiob`, `setusb`, and the country-code commands.

Absent relative to testmode: **`tone_on`/`tone_off`**, the calibration internals
(`calib`, `loft`, `dcver`, `dccomp`, `mdll_duty`, `fix_gain`, `notch`, `srrc`,
`fss`), `rx_meter`, `mon`, `lp_mode`, `print`, `setxtalcap(fine)`, the
`getmac`/`setmac` pair and the whole `ef*` family.

The shell is still UART-only. Its `getchar` at `0x001313C4` spins on
`0x40032014` bit 0 and reads `0x40032000` — identical to testmode's
`0x00170988` (§2), with the same two call sites feeding the same line editor.

### F.3 What this means in practice

In `lmacfw_rf` the two channels coexist but stay separate:

* **USB** carries the `DBG_MEM_*` / `DBG_START_APP` message protocol (Appendix E)
  — reachable from the host with `tools/aic-memtool.c`, `regdbg`, or the driver.
* **UART0** carries the `aic>` shell.

So `lmacfw_rf` is the useful middle ground: RF-capable firmware that is up on USB
*and* answers memory reads and writes. Since every shell command is a wrapper
over register writes, anything the shell does can be done over USB instead — and
`lmacfw_rf`'s own handler addresses above are the reference for what each one
touches.

> Untested: driving testmode's `tone_on` register sequence (Appendix A.4) over
> USB against `lmacfw_rf`. The registers are the same silicon, but the two images
> may leave the RF front-end in different states, so the sequence is not
> guaranteed to transfer. Verify against a spectrum analyser before trusting it.


---

## Appendix G. `rx_meter` and `mon`

Two of the commands that exist only in `testmode*.bin` (absent from `lmacfw_rf`,
§F.2) and that the vendor documents nowhere.

### G.1 `rx_meter <freq>` — receiver IQ/DC measurement

Handler `0x0018CA64`. `freq` is parsed **base 10** (decimal only, unlike the
`amp`/`txgain` args of `tone_on`).

```c
freq = strtol(argv[1], NULL, 10);
printf("tone_freq=%d, dump start...\r\n", freq);
rx_capture_arm();        /* 0x0018C668 */
rx_capture_measure(freq);/* 0x0018C738 */
return 0;
```

**Capture arm** (`0x0018C668`) runs a fixed trigger sequence:

| Register | Write |
|---|---|
| `0x4034202C` | `2` (RX path select — `tone_on` sets bit 16 of the same register for TX) |
| `0x40341008` | `0` |
| `0x40342000` | `0x00FF0000` |
| `0x40342004` | `0`, then `7` |
| — | wait `0x7D0` (2000) ticks on the `0x40320120` counter |
| `0x40342000` | `0x00FF0000` |
| `0x40342004` | `0xF` |
| — | wait 2000 ticks |

**Measure** (`0x0018C738`) then walks the captured sample buffer at **`0x001A0000`**
(`ldr r3, [r0], #4` over 32-bit IQ words — the same scratch region the vendor doc
uses for the BT test image, so the two cannot be resident at once) and prints:

```
tone_freq=%d, dump start...
N=%d, M=%d,
dc_i = %d.%d,
dc_q = %d.%d
pow = %d.%d
err_am = %d
err_ph = %d.%d
```

| Field | Meaning |
|---|---|
| `N`, `M` | sample count / bin index used for the estimate |
| `dc_i`, `dc_q` | receiver **DC offset** on the I and Q arms |
| `pow` | measured tone **power** |
| `err_am` | I/Q **amplitude imbalance** (gain error) |
| `err_ph` | I/Q **phase imbalance** (quadrature error) |

`%d.%d` pairs are fixed-point printed as integer and fraction — the constant
`0x66666667` in the pool is the reciprocal-multiply for the `/10` split, and
`100.0f` appears for the two-decimal cases.

So this is a **receiver-side measurement, not a transmitter one**: drive a CW
tone into the antenna port at `freq` MHz offset from the tuned channel and
`rx_meter` reports the receiver's DC offsets, the recovered tone power, and the
IQ gain/quadrature imbalance. It is the RX counterpart to the LOFT/DPD machinery
that `loft` and `calib` drive on the TX side.

Sequence: `setchan` / `setbw` first (the capture runs at the tuned frequency),
then `rx_meter <offset>`.

### G.2 `mon <mac> <bssid>` — hardware receive filter

Handler `0x0018AAB8`. Both arguments are **exactly 12 hex digits, no separators**
(same form as `setmac`): `mon 0a1c11223344 0a1c11223399`.

Validation is length-only — `strlen(argv[1]) == 12 && strlen(argv[2]) == 12`,
otherwise it returns **-2** with *no message of its own*, so the only feedback is
the shell's generic `Command fail, ret=-2`. Each address is split into a 32-bit
high half (first 8 digits) and a 16-bit low half (last 4), both parsed base 16.

It then programs the MAC's address-match block:

| Register | Value |
|---|---|
| `0x40320600` | MAC `[47:16]`, byte-reversed (`rev`) |
| `0x40320604` | MAC `[15:0]`, byte-reversed (`rev16`) |
| `0x40320608` | `0xFFFFFFFF` — MAC mask high (exact match) |
| `0x4032060C` | `0xFFFFFFFF` — MAC mask low |
| `0x40320610` | BSSID `[47:16]` |
| `0x40320614` | BSSID `[15:0]` |
| `0x40320618` | `0xFFFFFFFF` — BSSID mask high |
| `0x4032061C` | `0xFFFFFFFF` — BSSID mask low |

plus the surrounding enable/config writes:

| Register | Value |
|---|---|
| `0x40500040` | `0x200` |
| `0x40504000`,`4004`,`4008`,`400C`,`4010`,`4014`,`4018`,`401C` | `7` |
| `0x40320510` | `0x2658` |
| `0x40320024` | BSSID `[15:0]` (byte-reversed) |
| `0x40320580` | `7`, then `0x80000007` |
| `0x40345068` | `0x03030303` |
| `0x40345080` | `0x03020100` |
| `0x40345084` | `0x470D0605` |
| `0x4033B3B0` | `0xAAAA0007` |

Output:

```
set monitor
set mon: mac=%08x%04x, bssid=%08x%04x
```

The all-ones masks mean **exact match**, so this is a targeted receive filter
rather than promiscuous capture — it configures the hardware to accept frames for
one specific station address within one specific BSS. Combined with
`startrxstat` / `getrxstat` it gives per-link FCS statistics; it is not a
substitute for monitor mode in the normal driver.


---

## Appendix H. The IQ capture engine

`rx_meter` (§G.1) is one consumer of a much more general facility: a hardware
capture block that snapshots a selectable point in the RF/PHY chain into RAM.
This is the closest thing the part has to an SDR-style IQ grab.

### H.1 Tap points

`loft`'s usage string enumerates the sources, and the dispatcher at
`0x00164D44` takes the source id in `r0`:

| id | Source | id | Source |
|---:|---|---:|---|
| 0 | `loft_pwr_in_out` | 8 | `gain_loft2_in_out` |
| 1 | `dac_150m` | 9 | `aux_fifo_out` |
| 2 | **`adc_in`** | 30 | `rc_adc` |
| 3 | **`rx_data_iq`** | 31 | `dccancel` out |
| 4 | `rc_in_iq` | 32 | `pre_dgc` out |
| 5 | `rc_out_iq` | 33 | `notch` out |
| 6 | `rc_status` | 50 | `rc_in_iq` |
| 7 | `lpf_out_bpf_out` | 81 | `gain_loft_in_out` |

Ids `10` and `14` are also decoded (`dump dpd tx rx`, `dump loft out`). Anything
else prints `reselect mode`.

Each branch writes a source-specific mux word to **`0x40342000`** (e.g.
`0x00F00010` for `adc_in`, `0x44F10010` for `rx_data_iq`, `0x00F30010` for
`dac_150m`) and a path select into the low byte of **`0x4034202C`**, then arms
via **`0x40342004`**.

### H.2 Buffer, length, format

On completion the firmware prints the readout instruction itself:

```
end_addr=%x
dump finish
*0* dump    r 00100000 %d**
```

with `%d` hardcoded to **`0x4000` = 16384**. So:

| | |
|---|---|
| Buffer base | **`0x00100000`** |
| Length | **16384 words = 64 KiB** |
| Actual fill pointer | readable from **`0x40342228`** (`end_addr`) |

Each 32-bit word packs **two 12-bit offset-binary samples**, unpacked by
`rx_meter` as:

```c
u32 w = *p++;
int q = (w >> 20)          - 0x800;   /* bits 31:20 */
int i = ((w >> 4) & 0xFFF) - 0x800;   /* bits 15:4  */
```

Midscale is `0x800`, so each sample is signed −2048..+2047, making one full
capture **16384 complex samples**.

Bits `19:16` and `3:0` are *ignored by `rx_meter`*, which is not the same as
being unused — live captures have them set. Do not treat them as a format
check; they may carry lower-order bits or a tag.

The engine also detects clipping — `WARNING: data saturated!!!!!!!!!!!!!!!` — and
a simpler statistics path prints `sum_i` / `sum_q` / `dc_i` / `dc_q`.

`0x00100000` is below every firmware load address in use (`0x120000` for
`lmacfw_rf` and `fmacfw`, `0x160000` for `testmode`), so the 64 KiB buffer does
not collide with any of them.

### H.3 Reading it out — and why this is not an RTL-SDR

Over UART the firmware's own suggestion is `r 00100000 4000`, i.e. 16384 words
of formatted hex — slow at 921600 baud.

Over USB use **`DBG_MEM_BLOCK_READ_REQ` (`0x0423`)**, which returns up to 1024
bytes per reply. The whole 64 KiB buffer is **64 round trips**, not 16384 — well
under a second on USB 2.0 bulk.

So this is a **one-shot 16 K-sample snapshot** rather than a streaming receiver,
but the readout is not the bottleneck. It is a built-in logic analyser for the RF
chain: raw ADC or post-decimation IQ, at an arbitrary 2.4/5 GHz centre, from a
selectable tap, with hardware clip detection.

### H.4 The interesting combination

The capture engine is **hardware**, driven entirely by register writes to
`0x40342000` / `0x4034202C` / `0x40342004`, and the buffer is plain RAM. None of
that needs the testmode firmware.

`lmacfw_rf` has no `loft` command (§F.2) but does have a working USB stack and
answers `DBG_MEM_READ/WRITE` (Appendix E). So in principle:

1. load `lmacfw_rf` via the driver's test mode (USB, no UART needed),
2. `DBG_MEM_WRITE_REQ` the mux/path/trigger registers to arm a capture,
3. poll `0x40342228` for the end address,
4. `DBG_MEM_READ_REQ` the buffer out of `0x00100000`.

That would give IQ capture over USB alone on a sealed dongle. **Untested** — the
register sequence is transcribed from testmode's dump engine and `lmacfw_rf` may
leave the RF chain in a different state.

### H.5 Sample rate — not yet determined

The rate depends on which tap is selected: `adc_in` is the raw converter rate,
`rx_data_iq` is post-decimation at the channel rate. The image gives only hints:
the tap named `dac_150m` implies a 150 MHz DAC, the bandwidth labels run
`20M/40M/80M/160M`, and the TX NCO scales as `freq × 204.8` over a signed 14-bit
field (§A.3), which is consistent with an 80 MHz complex rate in *that* domain.

None of that pins the ADC rate, and it is not worth guessing. The clean
experiment: inject a CW tone at a known offset, capture `adc_in`, FFT the 16384
samples, and read the rate off the bin position.


---

## Appendix I. Capture trigger semantics, and the RF-test channel

### I.1 The capture is one-shot

The arm/complete sequence (`0x00165650` onward) is:

```c
/* ... source mux set up via 0x40342000 / 0x4034202C ... */
*(u32*)0x40342004 = 0x01000101;   /* configure */
udelay(125);
*(u32*)0x40342004 = 0x01000109;   /* bit 3 = GO   */

while ((s32)*(u32*)0x40342228 < 0)  /* bit 31 = BUSY */
    udelay(1);

end_addr = *(u32*)0x40342228;     /* same reg, low bits = fill pointer */
printf("end_addr=%x\r\n", end_addr);

*(u32*)0x40342004 = 0;            /* disarm */
```

| Register | Role |
|---|---|
| `0x40342000` | source mux word (per tap, §H.1) |
| `0x4034202C` | path select, low byte |
| `0x40342004` | trigger — `0x01000101` to configure, `0x01000109` to start (bit 3 = go), `0` to disarm |
| `0x40342228` | **bit 31 = busy**, low bits = **end address** when clear |

So the buffer is **written once per trigger**, not circularly: the engine fills
from `0x00100000`, stops, clears the busy bit, and leaves the stop address in
`0x40342228`. Nothing overwrites it until the next arm, so the readout is not
racing the capture. `end_addr - 0x00100000` gives the true byte count, which may
be less than the nominal 64 KiB.

### I.2 RF test over USB — `DBG_RFTEST_CMD_REQ`

This is the channel `wifi_test` uses, and it needs no UART:

```c
struct dbg_rftest_cmd_req { u32 cmd; u32 argc; u8 argv[30]; };  /* id 0x0413 */
struct dbg_rftest_cmd_cfm { u32 rftest_result[32]; };           /* id 0x0414 */
```

Driver entry point: `rwnx_send_rftest_req()` (`rwnx_msg_tx.c:4922`). Command ids
(`aic_priv_cmd.c:41`, `SET_TX = 0`):

| id | Command | id | Command |
|---:|---|---:|---|
| 0 | `SET_TX` | 20 | `RDWR_PWRMM` |
| 1 | `SET_TXSTOP` | 21 | `RDWR_PWRIDX` / `RDWR_PWRLVL` |
| **2** | **`SET_TXTONE`** | 22 | `RDWR_PWROFST` |
| 3 | `SET_RX` | 23 | `RDWR_DRVIBIT` |
| 4 | `GET_RX_RESULT` | 24 | `RDWR_EFUSE_PWROFST` |
| 5 | `SET_RXSTOP` | 26 | `SET_PAPR` |
| **6** | **`SET_RX_METER`** | 27 | `SET_CAL_XTAL` |
| 7 | `SET_POWER` | 29 | `SET_COB_CAL` |
| 8 | `SET_XTAL_CAP` | 32 | `SET_NOTCH` |
| 9 | `SET_XTAL_CAP_FINE` | 36 | `RDWR_EFUSE_USBVIDPID` |
| 11 | `SET_FREQ_CAL` | 37 | `SET_SRRC` |
| 13 | `GET_FREQ_CAL` | 38 | `SET_FSS` |
| 14 | `SET_MAC_ADDR` | 41 | `SET_PLL_TEST` |
| 15 | `GET_MAC_ADDR` | 42 | `SET_ANT_MODE` |
| 16 | `SET_BT_MAC_ADDR` | 43 | `GET_NOISE` |
| 18 | `SET_VENDOR_INFO` | 46 | `RDWR_PWRADD2X` |
| | | `0x52` | `GET_RSSI` |
| | | `0x108` | `CHECK_FLASH` |

**`SET_TXTONE` (2) and `SET_RX_METER` (6) are on this list.** They are absent
from `lmacfw_rf`'s UART shell (§F.2) but reachable over USB through this message,
which corrects the earlier conclusion that a tone required either UART or a
hand-replayed register sequence. Results come back in `rftest_result[32]`.


---

## Appendix J. The USB data path

Appendix E covers the message channel on EP2. This is the other half: how WiFi
data actually moves, on EP1. Everything here is from the driver source
(`aicwf_txrxif.c`, `aicwf_usb.c`, `ipc_shared.h`, `rwnx_rx.h`) — no hardware was
needed, and none of it has been exercised on-device.

### J.1 One block header for everything

Both endpoints and both directions use the **same 4-byte block header**, which is
what the mysterious `0x11` in the message framing (§E.2) turns out to be:

```
 [0..1]  u16  length      (12 bits used; [1] is masked with 0x0f)
 [2]     u8   type
 [3]     u8   reserved / 0
 [4..]        payload
```

| `type` | Name | Direction | Payload |
|---|---|---|---|
| `0x00` | `USB_TYPE_DATA` | chip → host | `hw_rxhdr` + 802.3 frame |
| `0x01` | data | host → chip | `txdesc_api` + frame |
| `0x10` | `USB_TYPE_CFG` | — | class bit, not a value |
| `0x11` | `USB_TYPE_CFG_CMD_RSP` | both | `lmac_msg` / `ipc_e2a_msg` |
| `0x12` | `USB_TYPE_CFG_DATA_CFM` | chip → host | TX confirmation |

The RX demultiplex is `(data[2] & USB_TYPE_CFG) != USB_TYPE_CFG` → data path,
else config, then `data[2] & 0x7f` picks `CMD_RSP` vs `DATA_CFM`
(`aicwf_txrxif.c:409`). So **bit 4 is the class bit**: clear = data, set = control.

Blocks are packed back-to-back within one URB, each padded to a 4-byte boundary
(`TX_ALIGNMENT` / `RX_ALIGNMENT` = 4). The reader walks them by `length`,
rounding up. RX aggregation can deliver very large URBs — the driver has a
special case at `actual_length > 1600 * 30` (~48 KiB).

### J.2 RX: `hw_rxhdr`, 60 bytes ahead of every frame

`RX_HWHRD_LEN` is **60** (`aicwf_txrxif.h:33`, commented "58->60 word allined").
The struct's compiled size varies with build flags — 56 bytes in the
`AICWF_USB_SUPPORT` + `AICWF_RX_REORDER` configuration — so trust the constant,
not `sizeof`. Offsets in that configuration:

| Offset | Field |
|---:|---|
| 0 | `hwvect.len` (16b), `reserved` (8b), `mpdu_cnt` (6b), `ampdu_cnt` (2b) |
| 4 | `hwvect.tsf_lo` |
| 8 | `hwvect.tsf_hi` |
| 12 | `hwvect.rx_vect1` (16 bytes) |
| 28 | `hwvect.rx_vect2` (8 bytes) |
| 36 | status bits — `rx_vect2_valid`, `resp_frame`, `decr_status`, `rx_fifo_oflow`, … |
| 40 | `phy_info` (8 bytes) |
| 48 | RX flags — `is_amsdu`, `is_80211_mpdu`, `is_4addr`, `new_peer`, `need_reord`, `upload`, `vif_idx`, `sta_idx`, `dst_idx` |
| 52 | `pattern` (buffer-valid stamp) |

**`rx_vector_1`** (16 bytes) carries, per packet:

```c
u8  format_mod : 4;   /* non-HT / HT / VHT / HE */
u8  ch_bw      : 3;
u8  pre_type   : 1;
u8  antenna_set: 8;
s32 rssi_leg   : 8;   /* dBm */
u32 leg_length :12;
u32 leg_rate   : 4;
s32 rssi1      : 8;   /* dBm, chain 1 */
union { rx_leg_vect leg; rx_ht_vect ht; rx_vht_vect vht; rx_he_vect he; };
```

**`rx_vector_2`** (8 bytes) is pure instrumentation:

```c
u32 rcpi1:8, rcpi2:8, rcpi3:8, rcpi4:8;   /* per-chain RCPI */
u32 evm1:8,  evm2:8,  evm3:8,  evm4:8;    /* per-chain EVM  */
```

**`phy_channel_info_desc`** (8 bytes): `phy_band`, `phy_channel_type`,
`phy_prim20_freq`, `phy_center1_freq`, `phy_center2_freq`.

That is a genuinely useful measurement surface: **hardware EVM, per-chain RCPI,
RSSI, MCS/format, and a 64-bit TSF timestamp on every received frame**, delivered
inline with the packet and gated only by `rx_vect2_valid`. For RF characterisation
this complements the one-shot IQ capture of Appendix H — the capture gives you
waveform, this gives you per-packet statistics at line rate.

### J.3 TX: `txdesc_api` is a 28-byte fullmac descriptor

`struct txdesc_api` is just `struct hostdesc`, laid out (fullmac build):

| Offset | Size | Field |
|---:|---:|---|
| 0 | 2 | `packet_len` |
| 2 | 2 | `flags_ext` |
| 4 | 4 | `status_desc_addr` |
| 8 | 6 | `eth_dest_addr` |
| 14 | 6 | `eth_src_addr` |
| 20 | 2 | `ethertype` |
| 22 | 4 | `ac`, `tid`, `vif_idx`, `staid` |
| 26 | 2 | `flags` |
| | **28** | total |

A TX data block is therefore `4-byte header + 28-byte hostdesc + frame`, padded
to 4 bytes, with `usb_header[2] = 0x01`.

**This is a full-MAC device.** The host hands over Ethernet addressing and an
ethertype; the firmware builds the 802.11 header, handles sequence numbers,
encryption and aggregation. You cannot inject arbitrary 802.11 through the normal
data path — the descriptor has no field for it.

The escape hatch is `hostdesc.flags`, which takes `TXU_CNTRL_*` bits
(`rwnx_tx.h:50`):

| Bit | Flag |
|---|---|
| 0 | `TXU_CNTRL_RETRY` |
| 2 | `TXU_CNTRL_MORE_DATA` |
| **3** | **`TXU_CNTRL_MGMT`** — payload is a raw 802.11 management frame |
| 4 | `TXU_CNTRL_MGMT_NO_CCK` |
| 6 | `TXU_CNTRL_AMSDU` |
| 7 | `TXU_CNTRL_MGMT_ROBUST` |
| 8 | `TXU_CNTRL_USE_4ADDR` |
| 9 | `TXU_CNTRL_EOSP` |
| 10 | `TXU_CNTRL_MESH_FWD` |
| 11 | `TXU_CNTRL_TDLS` |

With `TXU_CNTRL_MGMT` the payload is taken as a complete 802.11 management frame
rather than an Ethernet payload — that is the only raw-injection route the
interface offers.

### J.4 TX confirmation

Frames that set `need_cfm` are acknowledged with a `0x12` block whose payload is
a `u32` array. `aicwf_usb_host_tx_cfm_handler()` (`usb_host.c`) uses **`data[1]`
as a used-index**, looked up modulo `USB_TXDESC_CNT` in `env->tx_host_id[0][]` to
recover which buffer completed. It is an index/credit scheme, not a per-packet
cookie echoed back.

### J.5 Sizing

| Constant | Value |
|---|---|
| `AICWF_USB_MAX_PKT_SIZE` | 2048 |
| `AICWF_USB_RX_URBS` | 20 |
| `AICWF_USB_TX_URBS` | 50, or 200 in the alternate build |
| `AICWF_USB_TX_LOW_WATER` | `TX_URBS / 4` |
| `TX_ALIGNMENT` / `RX_ALIGNMENT` | 4 |
| `RX_HWHRD_LEN` | 60 |
| `CCMP_OR_WEP_INFO` | 8 (trailer room for MIC/ICV) |

> Everything in this appendix is read from driver source. The block header and
> type codes are corroborated by the message path already validated on hardware
> (§E.4) — the `0x11` we send is `USB_TYPE_CFG_CMD_RSP` from this same enum — but
> the data-path structures themselves have not been exercised here.


---

## Appendix K. Measured transport performance

Measured on `368b:8d81` (firmware-loaded, msg endpoints EP2) with
`tools/aic-memtool.c`, 2026-08-30.

### K.1 Block read is real

`DBG_MEM_BLOCK_READ_REQ` (`0x0423`) **is implemented by this firmware**, not just
declared in the driver's headers:

```
$ ./aic-memtool dump 40500000 10
read 16 bytes in 1 transaction(s)
[0x40500000] = 0xf9078820      <- matches the single-word read exactly
[0x40500004] = 0x00000000
[0x40500008] = 0xffffffff
[0x4050000c] = 0x00000001
```

A reply carrying 1024 data bytes is 1048 bytes on the wire: 4 header + 12
`ipc_e2a_msg` (incl. `pattern`) + 8 (`memaddr`, `memsize`) + 1024.

### K.2 Latency is per-transaction, not per-byte

| Operation | Transactions | Wall time |
|---|---:|---:|
| 64 x single-word read (`DBG_MEM_READ_REQ`) | 64 | **1.754 s** |
| 64 x 1 KiB block read (`DBG_MEM_BLOCK_READ_REQ`) | 64 | **1.771 s** |

Identical. The cost is a fixed **~27.4 ms per message round trip**, independent of
payload size. That is far too slow to be USB bulk latency (~0.125-1 ms), so it
looks like a polling or scheduling interval in the firmware's message task.

Consequences:

| | Throughput | 64 KiB readout |
|---|---:|---:|
| single-word | ~146 B/s | ~7.5 minutes |
| 1 KiB block | ~37 KB/s | **1.77 s** |

So block read is worth 256x — the difference between a usable capture readout and
an unusable one — but the absolute rate is modest, and the bottleneck is message
latency rather than bandwidth. Anything needing higher throughput would have to
avoid the message channel entirely.

### K.3 Reads return real memory

Dumping 64 KiB from `0x00100000` (the capture buffer, with no capture armed)
returns plausible uninitialised RAM including **`0xBAADF00D`** poison at `+0x14`,
confirming genuine memory access rather than echoed or stubbed data.


---

## Appendix L. A host-side driver deadlock (not a firmware fault)

While probing block-read behaviour the device stopped responding and could not be
recovered without a reboot. The initial reading — that an oversized `memsize` had
wedged the firmware — was **wrong**. The kernel log identifies the real cause, and
it is entirely host-side:

```
RIP: rwnx_rx_handle_msg+0x13/0xa0 [aic8800_fdrv]     <- NULL deref, RDI=0
note: aicwf_msg_busrx[...] exited with irqs disabled

refcount_t: addition on 0; use-after-free.
  kthread_stop+0x1b4
  aicwf_rx_deinit    [aic8800_fdrv]
  aicwf_bus_deinit   [aic8800_fdrv]
  aicwf_usb_probe    [aic8800_fdrv]
  usb_probe_interface
```

`kthread_stop()` then waits forever for a thread that no longer exists, **holding
the USB device lock**. That is why every later access hung — including
`USBDEVFS_RESET`, which blocked in `usbdev_open()` before reaching its ioctl. A
misbehaving firmware cannot block an `open()`; a held device lock can. Nothing
here implicates the device.

### L.1 Bug 1 — RX is live before `rwnx_hw` exists

`aicwf_usb_probe()` runs, in order:

```c
aicwf_bus_init(0, dev);            /* starts usb_msg_busrx_thread + usb_busrx_thread */
aicwf_bus_start(bus_if);           /* submits RX URBs -- device can now deliver     */
aicwf_rwnx_usb_platform_init(...); /* eventually: usbdev->rwnx_hw = rwnx_hw         */
```

The assignment is at `rwnx_main.c:8855`. So between `aicwf_bus_start()` and that
line there is a window where RX URBs are live but `usbdev->rwnx_hw` is still NULL.
Any inbound `USB_TYPE_CFG_CMD_RSP` block (§J.1) in that window reaches:

```c
rwnx_rx_handle_msg(rx_priv->usbdev->rwnx_hw, (struct ipc_e2a_msg *)(msg + 4));
```

with a NULL first argument — matching `RDI=0` exactly. There are ~7 such call
sites in `aicwf_txrxif.c`.

Reordering is awkward because `aicwf_rwnx_usb_platform_init()` needs the bus up in
order to talk to the chip. The low-risk fix is to drop messages that arrive before
the owner exists — during that window the driver has not sent anything, so nothing
legitimate can be arriving:

```c
struct rwnx_hw *hw = rx_priv->usbdev->rwnx_hw;
if (hw)
    rwnx_rx_handle_msg(hw, (struct ipc_e2a_msg *)(msg + 4));
/* else: pre-platform_init, no owner yet -- discard */
```

### L.2 Bug 2 — cleanup stops an already-dead thread

Once the kthread dies in the oops, probe fails and takes `goto out_free_bus` →
`aicwf_bus_deinit()` → `aicwf_rx_deinit()` → `kthread_stop(msg_busrx_thread)`
(`aicwf_txrxif.c:1094`). The thread is gone, its `task_struct` refcount is already
zero, and `kthread_stop()` never returns.

This is the part that turns a recoverable oops into an unrecoverable deadlock, and
it is worth hardening independently of Bug 1: cleanup should not assume a thread
it started is still alive. Fixing Bug 1 removes the trigger; fixing Bug 2 removes
the class of outcome.

### L.3 What actually triggered it

A `libusb` session had detached `aic8800_fdrv` from interface 2, and was killed
mid-transaction. On exit the kernel driver was reattached, `aicwf_usb_probe()` ran,
URBs went live, and an in-flight reply from the earlier conversation arrived inside
the Bug 1 window.

So the practical hazard for anything using `tools/aic-memtool.c` is **not** the
`memsize` value — it is detach/reattach with traffic in flight. Until Bug 1 is
fixed, avoid killing the tool mid-transfer, and prefer unbinding the driver
deliberately over letting libusb reattach it on a signal.

> Correction: earlier revisions of this document and of `aic-memtool.c` attributed
> this hang to an oversized `memsize` wedging the firmware. That was an incorrect
> inference from the symptom. The firmware's behaviour on `memsize > 1024` remains
> untested.

---

## Appendix M. Capture engine validated over USB

Measured against a live `368b:8d81` under normal `fmacfw` with the r5 driver,
using `tools/aic-memtool.c`. Everything below is observed, not inferred.

### M.1 Single-word write silently does nothing; block write works

| Message | Behaviour |
|---|---|
| `DBG_MEM_WRITE_REQ` (`0x0402`) | Returns `DBG_MEM_WRITE_CFM` echoing address **and** data — and does not write. Confirmed against quiet RAM and RF registers. |
| `DBG_MEM_BLOCK_WRITE_REQ` (`0x040B`) | **Works.** `memaddr`, `memsize` (bytes), then data words. |

This explains something in the driver that otherwise looks arbitrary: `regdbg`
writes even a single word with `rwnx_send_dbg_mem_block_write_req(priv, addr, 4,
&val)` rather than the single-word message.

The silent-success is the trap — the confirmation echoes your data back, so a
caller that trusts the CFM believes the write landed. **Always read back.**

### M.2 Arming a capture over USB

With block write, the Appendix I sequence works verbatim on live hardware:

```
writeb 0x40342000 0x00F00010      # source mux = adc_in
writeb 0x4034202C (old & 0x70)|2  # path select
writeb 0x40342004 0x01000101      # configure
writeb 0x40342004 0x01000109      # go (bit 3)
read   0x40342228                 # bit 31 clears; low bits = end address
```

Busy cleared by the first poll, and `0x40342228` returned a value that varied
between runs (`0x7D9A`, `0x3FEF`, `0x2C48`, …) rather than a constant.

**`end_addr` is a circular write pointer, not a fill bound.** A before/after diff
shows the engine rewriting the *entire* 64 KiB (offsets `0x0000`–`0xFFFF`, 99.5%
of bytes changed) while `0x40342228` read `0x2C48`. All 16384 words are current;
the pointer marks where the newest word landed, so the oldest data begins just
after it. Do not truncate a read-out at `end_addr`.

A before/after 64 KiB diff of `0x00100000` showed **63465 of 65536 bytes
changed** — confirming that the buffer address from testmode's own operator hint
(`r 00100000`) is where this firmware's capture engine writes too, despite the
entirely different memory map.

### M.3 What the samples showed, and why

With the radio idle (`rfen = 0`, netdev down) the capture is a stuck constant:

| | |
|---|---|
| distinct words | **31 of 4091** |
| most common | `0x83909353`, 4061 times (99.3%) |
| leading identical run | 254 words |

Unpacked, that constant is `I = 309, Q = 57`. An apparent standard deviation of
~80–100 LSB came entirely from ~30 outliers, not from noise. This is the ADC not
being clocked — the engine ran and filled memory correctly.

**Real samples need a live receiver.** Either bring the netdev up so the driver
powers the radio, or drive `DBG_RFTEST_CMD_REQ` (`0x0413`) with `SET_RX` (cmd 3),
§I.2. Neither has been tried yet.

### M.4 Cost

Each 64 KiB dump is 64 block-read transactions, ~1.8 s (§K.2). Capture plus
read-out is a low-single-digit-seconds operation.

---

## Appendix N. RF test over USB: what works, and one honest negative

Measured on a live `a69c:8d81` with `aic_load_fw testmode=1`.

### N.1 Getting RF-test firmware loaded, without touching the hardware

`fmacfw` does **not** implement `DBG_RFTEST_CMD_REQ` — every RF-test command
times out against it, while other messages keep flowing. The RF-test machinery
lives only in `lmacfw_rf`:

| string | `lmacfw_rf` | `fmacfw` |
|---|:-:|:-:|
| `rx_stat get` / `Rate Set Done` / `user tone on` / `setrate` | present | **absent** |

`aic_load_fw` chooses via a module parameter (`FW_NORMAL_MODE = 0`,
`FW_TEST_MODE = 1`):

```
sudo modprobe -r aic8800_fdrv aic_load_fw
sudo modprobe aic_load_fw testmode=1
./aic-memtool reboot            # DBG_START_APP_REQ, boottype = 3
```

The parameter is only read during probe, so the chip must re-enumerate for it to
take effect — and `DBG_START_APP_REQ` does that over USB with no replug, no hub
power control, and no root. The device came back as **`a69c:8d81`** rather than
`368b:8d81`: the compiled-in descriptor IDs (§F.1) instead of the flash-patched
ones, confirming different firmware. Its endpoints also differ — messages moved
to `msg_in = 0x81`.

Then the RF-test channel answers:

```
$ ./aic-memtool rftest 3 06 00     # SET_RX chan 6, bw 20 MHz
$ ./aic-memtool rftest 4           # GET_RX_RESULT
  result[0] = 27      fcsok
  result[1] = 68      total
```

Live decoding of ambient traffic — the receiver is genuinely running.

### N.2 The tone NCO scaling is confirmed exactly

`SET_TXTONE` (cmd 2) takes `argv[0] = func`, `argv[1] = freq` as a **signed**
MHz offset. Reading `0x4034206C` back after each:

| requested | NCO register | freq field | decoded |
|---|---|---:|---|
| off | `0x00333080` | — | bit 28 clear |
| +4 MHz | `0x103333FF` | 819 | **+4.000 MHz** |
| −8 MHz | `0x1399A3FF` | 14746 → signed −1638 | **−8.000 MHz** |

`819 / 204.8 = 4.000` and `−1638 / 204.8 = −8.000`. The `round(freq × 204.8)`
scaling and the two's-complement wrap in a 14-bit field (§A.3) — both derived
purely by reading `testmode20.bin` — are exactly right on live hardware running
different firmware. Amplitude defaults to `0x3FF` as documented, and `0x4034202C`
gains bit 16 while the tone is on, as `tone_on` does.

**The capture arm clobbers the tone.** Writing the source mux at `0x40342000` is
a full-word store that wipes the tone's bits; `0x4034202C` and `0x40342004` do
not. Enable the tone *after* the mux write. Its own `pathsel` value already
carries the right low byte, so leave `0x4034202C` alone.

### N.3 The negative result: the buffer is not demonstrably RF samples

With the receiver running, `0x00100000` holds high-entropy varying data
(13688 distinct words of 16384) where an idle radio gave a stuck constant
(31 of 4091). That looked promising. It does not survive a controlled test:

| capture | FFT peak | peak/median |
|---|---|---|
| tone off | −0.498 Fs | 24.8 dB |
| tone **+4 MHz** | −0.004 Fs | 26.2 dB |
| tone **−8 MHz** | −0.498 Fs | 23.8 dB |

Injecting a confirmed tone at two different offsets produces **no corresponding
spectral peak and no meaningful change**. Adjacent-sample correlation is ~0.20
and the spread is ~60% of full scale under every interpretation tried (complex
`A+jB`, real interleaved, single field).

So the honest position is: the capture engine writes to `0x00100000` and its
contents correlate with receiver activity, but nothing has been shown to be
samples. A plainer reading fits the evidence just as well — that the RF-test
firmware simply churns that memory while the receiver runs.

Candidate explanations, none tested:

* The `adc_in` mux word (`0x00F00010`) is taken from `testmode20`'s dispatcher and
  may not mean the same thing to `lmacfw_rf`.
* Testmode's dump engine performs a long initialisation before triggering
  (`0x00165650` onward touches many more registers); replaying four registers may
  be insufficient.
* **Most likely:** `rx_meter` is built for an *external* generator (§G.1). With a
  dummy load absorbing the transmitted tone there may be no internal loopback
  path at all, so expecting the chip's own tone in its own receiver may simply be
  the wrong experiment.

The clean way to settle it is an external source into the antenna port at a known
offset, or a spectrum analyser confirming the tone radiates — which would at
least separate "TX works" from "capture decodes".

### N.4 TX confirmed on a calibrated instrument

A tinySA4 (`0483:5740`, `/dev/ttyACM1`) conductively loopbacked to the adapter's
antenna port. Noise floor 2.40–2.48 GHz was −88 to −91 dBm. With `SET_TXTONE`
enabled:

```
2412.000 MHz   base -89.16  ->  -34.91 dBm   (+54.25 dB)
```

**The transmitter works and is measurable.** That settles the question the
internal capture could not.

### N.5 `SET_TXTONE`'s frequency argument does nothing here

Sweeping the argument produced an identical result every time:

| arg | measured peak | level |
|---|---|---|
| −8, −4, 0, +4, +8, +12 | **2412.000 MHz** (all) | **−34.62 dBm** (all) |

Linear fit: `f_out = 0.0000 × arg + 2412.000 MHz`.

The output is pinned to **channel 1**, at constant level, regardless of the
offset requested — even though `0x4034206C` *does* update with the correct NCO
word each time (§N.2). So in `lmacfw_rf` the NCO offset is programmed but is not
reaching the transmitter, and the emitted signal is an unmodulated carrier at the
TX channel. Note `SET_RX` sets only the receive channel; nothing in the sequence
selected a TX channel, and it defaulted to ch1 while RX was on ch6.

This also explains the first capture negative: the tone was at 2412 MHz while the
receiver sat on 2437 MHz — **25 MHz outside the passband**, so it could not have
appeared regardless of whether the buffer decode was right.

### N.6 Capture: still negative, now with the tone in band

Repeating with `SET_RX` on channel 2 (2417 MHz), putting the 2412 MHz tone at a
−5 MHz offset, comfortably inside a 20 MHz passband:

| | distinct words | A std | B std | FFT peak | peak/median |
|---|---|---|---|---|---|
| tone off | 13818 | 1312.0 | 1367.4 | −0.0002 Fs | 27.2 |
| tone on | 14311 | 1311.4 | 1360.1 | −0.0039 Fs | 18.4 |

No spectral response. Two controlled experiments — one out of band, one in band —
both negative, so the buffer at `0x00100000` is **not** demonstrated to contain RF
samples under `lmacfw_rf`.

A further candidate explanation, untested: the receiver may be blanked while the
chip transmits, in which case no self-generated signal can ever appear in its own
capture. The decisive experiment is an **external** source — which is what
`rx_meter` was designed for (§G.1), and what the tinySA can provide as a generator
(`mode output` + `output on`).

> **This experiment was since carried out — see Appendix O.** An external tone
> confirmed to be jamming the live receiver still left no trace in `0x00100000`.
> Disassembly of the running `lmacfw_rf` then showed why: its `SET_RX_METER`
> capture is fed the chip's *internal* NCO tone for I/Q calibration, not the
> antenna. The "receiver blanked" guess above is essentially correct.

---

## Appendix O. External-source capture, and what `0x00100000` actually is

Appendices M and N left one question open: does `0x00100000` ever hold live
receive samples under `lmacfw_rf`? This appendix settles it, using an external
signal generator to drive a known tone into the antenna port and — crucially —
by disassembling the running `lmacfw_rf` image rather than extrapolating from
`testmode20.bin`. The firmware analysed is
`lmacfw_rf_8800d80_u02.bin` (md5 `333315275bb23bac64e71b264a57b7ac`), byte-for-byte
the image the driver installs at `/lib/firmware/aic8800_fw/USB/aic8800D80/`.

**Answer: `0x00100000` is a capture buffer, but under `SET_RX_METER` it holds an
internal NCO *loopback* signal for I/Q calibration — not the antenna. The live
antenna receive path is not observable through it in this firmware.**

### O.1 Confirming the external source (the tinySA can be heard)

A tinySA4 in generator mode was set to a CW tone (`mode output`, `sweep <f> <f>
2`, `level -6`, **`output on`**) on the same SMA loopback used for the TX
measurement in §N.4. The generator's own `output on` is required — `mode output`
alone arms the mode but radiates nothing, which invalidated the first attempts.

Emission and reception were then proven *at capture time* using the receiver's
own packet counter, on the busy ambient channel 6 (2437 MHz):

| generator | `GET_RX_RESULT` fcsok / total |
|---|---|
| off | 8 / 11, 11 / 19 (packets decode normally) |
| **on, 2437 MHz, −6 dBm** | **0 / 194** (zero decoded — classic CW jamming) |

A tone strong enough to take the receiver from 8 good frames to **zero** is
unambiguously present in the RX front end. `GET_RSSI` (cmd `0x52`), by contrast,
barely moved and often read a fixed floor — **treat the RF-test RSSI as an
unreliable stub; `fcsok` jamming is the trustworthy RX-liveness indicator.**

### O.2 The load base and the memory map (from the live chip)

The firmware image read straight back from RAM matches the file at
**`0x00120000`**, so that is the load base. Its first vector-table word is the
initial stack pointer: **`0x001A0000`**.

That single fact retires a wrong lead: `0x001A0000` is the **top of stack**, not
a sample buffer. The earlier idea (from testmode static analysis, §G.1) that
`rx_meter` reads I/Q from `0x1A0000` does **not** carry over to `lmacfw_rf` —
reads there return stack frames (full ±int16 range, band-edge FFT artefacts),
which is exactly what a naïve capture of that region showed.

### O.3 `rx_meter` measure, disassembled (buffer + true sample format)

The measure routine at `0x001257a8` (it prints `sum_i`/`sum_q`/`dc_i`/`dc_q`):

```
mov.w r3, #0x00100000        ; buffer base
ldr   r1, [r3]               ; flag = word[0]
and   r1, r1, #1             ; ping-pong: start = 0x100000 + (~flag&1)*4
...                          ; end = start + 0x10000  (64 KiB)
loop:
  ldr r3, [r5]               ; one sample word
  Q = (r3 >> 20);  if r3<0: Q -= 0x1000     ; [31:20], sign-extended 12-bit
  I = ubfx(r3,4,12); if bit15: I -= 0x1000   ; [15:4],  sign-extended 12-bit
  add r5, r5, #8             ; STRIDE 8 BYTES — every other 32-bit word
  cmp r5, r6 ; bne loop
```

So, corrected against the live firmware:

* the buffer is **`0x00100000`** (not `0x1A0000`), 64 KiB;
* samples are **one 32-bit word every 8 bytes** — the two 32-bit words per entry
  are two interleaved taps, and `measure` reads only one of them;
* each sample word is **two's-complement** 12-bit: `I = sx12(bits[15:4])`,
  `Q = sx12(bits[31:20])`. This is *not* the offset-binary (`− 0x800`) form the
  testmode `0x100000` dump engine uses (§H.2) — the two firmwares pack the same
  bit positions with different sign conventions;
* a ping-pong flag in `word[0]` selects which of the two interleaved halves is
  "current".

`tools/capture_fft.py` implements exactly this.

### O.4 `SET_RX_METER` is an internal loopback, not an antenna capture

The arm routine that fills the buffer (at `0x00125904`) is the tell:

```
[0x40342000] = 0x00F70410     ; capture source mux (an internal tap)
... RMW on 0x4034206C ...     ; the tone-NCO register
[0x4034206C] |= 0x10000000    ; *** enable the chip's own NCO tone (bit 28) ***
[0x40342004] = 0x01000101 → 0x01000109   ; configure, then go
```

It **switches the chip's internal transmit tone on and captures that.** Reading
the buffer back confirms it directly: the interleaved *even* words are a
bit-identical, full-scale complex sinusoid (`0x7c30dfc0, 0x7fe007a0, …`, i.e.
int16 `I`/`Q` pairs rotating at constant magnitude) that is **the same in
tone-on and tone-off external captures** — an internally generated reference, not
anything from the antenna. `measure` reads the *odd* words (the 12-bit tap) and
reports the receiver's DC offsets and I/Q amplitude/phase imbalance against that
reference. `rx_meter` here is an **I/Q-calibration loopback**, the RX counterpart
to the LOFT/DPD tone the TX side uses.

### O.5 The decisive negative

With the −6 dBm external tone at **+2 MHz** offset (2439 MHz, RX on ch6 2437 MHz)
and jamming confirmed at capture time (`fcsok` 0 vs 8–12), the tone produces **no
peak** in the buffer, in either interleave, under any of:

* `SET_RX_METER`'s own loopback capture (odd stream peak/median ~11 dB, at DC not
  +2 MHz);
* a manual arm with the internal tone **disabled** and the mux retasked to several
  `adc_in`-style values (`0x00FF0000`, `0x00F70410`, `0x00F00010`): peaks collapse
  toward DC, never +2 MHz.

Manual arming without the firmware's full setup sequence (`0x40330800`, the
`0x4034206C` field programming, the timed waits) is also unstable — successive
arms give either fresh noise or a stuck constant (`0xc3707120`). So:

> Under `lmacfw_rf`, `0x00100000` is a working capture buffer whose format is now
> known, but the only capture path the firmware exposes over USB feeds it the
> **internal loopback tone** for calibration. A signal proven to be jamming the
> live receiver leaves no trace in it. Observing the antenna would require driving
> the capture mux/route to the real RX-ADC tap and replaying the complete arm
> sequence — routing this calibration-oriented firmware does not appear to expose.

This confirms and explains the §N.6 "receiver may be blanked" hypothesis: it is
not merely blanked, it is deliberately fed the internal tone while the meter runs.

### O.6 Corrections this appendix makes to earlier sections

* **`0x1A0000` is the stack top**, not the `rx_meter` buffer, under `lmacfw_rf`
  (§G.1's `0x1A0000` is testmode-only).
* The `lmacfw_rf` buffer format is **two's-complement, 8-byte stride**, distinct
  from testmode's offset-binary 4-byte format (§H.2).
* `rx_meter`/`SET_RX_METER` under `lmacfw_rf` is an **internal loopback**, so
  §G.1's "drive a CW into the antenna port" describes the testmode intent, not
  what this firmware's USB path actually measures.
