# AIC8800D80 Bluetooth patch table — format, contents, and ROM extraction

This documents the Bluetooth firmware-load mechanism of the AIC8800D80, reverse
engineered entirely offline from the shipped firmware files and the vendor driver
source (`aic_load_fw/aicbluetooth*.c`). Unlike the WiFi side there is **no
Bluetooth firmware image**: the BT link controller lives in on-chip ROM, and the
host contributes only a small **patch table** of RAM hooks, config, and
calibration. That table is what this file decodes.

Companion tooling:

* `tools/bt_patch_parse.py` — offline decoder for the patch-table binaries.
* `tools/bt_romdump.py` — reads the BT ROM out over USB (verify-gated sweep).

Related: [`docs/reverse-engineering-results.md`](reverse-engineering-results.md)
(USB interface layout), [`docs/testmode-firmware-api.md`](testmode-firmware-api.md)
(the DBG_MEM protocol these tools use).

## Architecture: ROM controller + patchram

The chip is a **combo die with one shared 2.4 GHz front-end** time-shared between
WiFi and BT (the default BT mode is `AICBT_BTMODE_BT_ONLY_COANT` — *co-antenna,
no external switch*). WiFi and BT enumerate as separate USB interfaces with
separate firmware handling, but share the RF/calibration infrastructure.

The Bluetooth stack — link controller, GFSK modem, LMP, the HCI command surface —
is **masked ROM** in low memory (`0x000xxxxx`). The host cannot replace it; it can
only:

1. **hook** ROM functions through a hardware trap/remap unit at `0x40690000`,
2. **redirect** RAM function pointers (the `B4`/`AF` tables),
3. **configure** operating mode and TX power (the `BTMODE` record),
4. **bring up** power/clocks (the `PWRON` record).

This is the classic "patch a masked-ROM BT controller" model (cf. Broadcom/CSR
`.hcd` patchram). It is the same division of labour found on the WiFi side —
*PHY/MAC in silicon, calibration and policy in firmware* — pushed even further,
since here even the MAC is ROM.

## On-disk format

All little-endian. Files live on the target under
`/lib/firmware/aic8800_fw/USB/aic8800D80/`. Parser: `aicbt_patch_table_alloc()`
in `aicbluetooth.c`.

```
magic     16 bytes   "AICBT_PT_TAG\0..."
record* :
    name  16 bytes   NUL-padded ASCII
    type  u32
    len   u32        number of (addr,val) pairs
    data  len*8      len x { u32 addr, u32 val }
```

Special cases (from the parser):

* `type >= 1000` **or** `len == 0` → no data body.
* `type == 0x06` (VERSION) → the body is a NUL-terminated build string, not pairs.

Record types (`aicbluetooth_cmds.h`):

| type | name | meaning |
|---:|---|---|
| 0x00 | `INF` / ADID | info header; carries ADID/patch load addresses |
| 0x01 | `TRAP` | installs ROM hooks in the `0x40690000` trap unit |
| 0x02 | `B4` | RAM function-pointer redirects (pre-init) |
| 0x03 | `BTMODE` | config struct; values overwritten by the driver at load |
| 0x04 | `PWRON` | power/clock bring-up register writes |
| 0x05 | `AF` | RAM function-pointer redirects (post-init) |
| 0x06 | VERSION | build stamp string |

Applying the table is trivial (`aicbt_patch_table_load()`): for every record it
writes each pair as `DBG_MEM_WRITE(addr, val)`. The only special handling is
`BTMODE` (values are replaced with runtime config first — see below) and `PWRON`
(a 100 ms settle after the writes).

## Decoded table (`fw_patch_table_8800d80_u02.bin`, 1384 B)

Build stamp: **`Aug 01 2025 11:05:26  git a26f071`**.

| # | record | type | pairs | address span |
|---:|---|---|---:|---|
| 0 | `AICBT_PINF_T` | INF/ADID | 6 | `0x00000000 .. 0x40500150` |
| 1 | `AICBT_TRAP_T` | TRAP | 27 | `0x0020f600 .. 0x40690084` |
| 2 | `AICBT_PATCH_TB4` | B4 | 57 | `0x00201950 .. 0x00201fbc` |
| 3 | `AICBT_MODE_T` | BTMODE | 18 | `0x00201fc4 .. 0x0020f1fc` |
| 4 | `AICBT_POWER_ON` | PWRON | 3 | `0x4050004c .. 0x4050012c` |
| 5 | `AICBT_PATCH_TAF` | AF | 31 | `0x001e7f24 .. 0x00201090` |
| 6 | `AICBT_VER_INFO` | VERSION | — | build string |

The `u04` table (`fw_patch_table_8800d80_u04.bin`, 416 B, `git d0a8209`) is a
smaller revision with the same record set (TRAP len 3, B4 len 2, AF empty).

## Address map (falls straight out of the table)

| region | role |
|---|---|
| `0x000xxxxx` | **BT masked ROM** — the hooked functions (e.g. `0x0009f5fc`, `0x000eaf18`); ADID references reach ~`0x000ee5fd` |
| `0x0020xxxx` | **BT patch RAM** — B4/AF redirect targets; TRAP handler landing zone at `0x0020f600+`; BTMODE config words at `0x00201fc4+` |
| `0x00120000+` | WiFi firmware image (loaded separately; see testmode doc) |
| `0x40690000` | **hardware trap / breakpoint-remap unit** (patchram) |
| `0x40500xxx` | BT power/clock control (`PWRON`) |

That the *same* boot-ROM DBG_MEM agent writes all of these in one session (BT ROM
neighbours, BT RAM, trap unit, and the WiFi image) shows it is **one flat address
space** — the fact this document leans on for ROM extraction below.

### The trap unit (`0x40690000`)

In the u02 TRAP record the 27 pairs alternate between a RAM code word
(`0x0020f6xx <- <Thumb-2>`) and a trap-slot word (`0x4069000x <- <ROM addr>`),
i.e. slot *n*'s matched ROM address goes to `0x40690000 + 4n` and the handler
code sits in RAM at `0x0020f600+`. The u04 table shows the arming explicitly:

```
0x40690084 <- 0x0020f600   ; handler base
0x40690080 <- 0x000000ff   ; enable mask
0x40680000 <- 0x00000000
```

So there are a fixed number of ROM-address comparators (~27 usable here) that
redirect execution into RAM fixups — the mechanism you would reuse to hook the
ROM yourself once you have disassembled it.

### BTMODE config injection

The driver overwrites the **value** of the first nine `BTMODE` pairs at load
(`aicbt_patch_table_load()`), writing runtime config into these RAM words:

| pair | target addr | field | default in file |
|---:|---|---|---|
| 0 | `0x00201fd4` | `hwinfo < 0` | `0x00000000` |
| 1 | `0x00201fd8` | `hwinfo` | `0x00000000` |
| 2 | `0x00201fd0` | `cpmode` | `0x000000ff` |
| 3 | `0x00201fc8` | `btmode` | `0x00000005` (`BT_ONLY_COANT`) |
| 4 | `0x00201fc4` | `btport` | `0x00000002` (UART; overridden to USB/MB) |
| 5 | `0x00201fe8` | `uart_baud` | `0x000e1000` |
| 6 | `0x00201fe4` | `uart_flowctrl` | `0x00000000` |
| 7 | `0x00201fdc` | `lpm_enable` | `0x00000000` |
| 8 | `0x00201fe0` | **`txpwr_lvl`** | `0x5f2f7f2f` |

`0x00201fe0` is therefore the **live BT TX-power word** — a RAM location you can
poke to change BT output level (byte-packed min/max levels; the driver default
for D80 is `0x00006F2F`, min `0x2F`/max `0x6F`).

## The code blobs

`fw_patch_8800d80_u02.bin` (32 KB) and `fw_patch_8800d80_u02_ext0.bin` (16 KB)
are **not** tables — they are raw ARM Cortex-M **Thumb-2** code, uploaded to the
`patch_info.addr_patch` RAM region before the table installs its hooks. They
disassemble cleanly (`r2 -a arm -b 16`): standard `push {r4,r5,r6,lr}` prologues,
`ldr`/`ldrb.w`/`cbnz`, with literal pools pointing back at the config words
(e.g. `0x00201fc8`, the btmode target) and ROM addresses (`0x001e7f43`).
`fw_adid_8800d80_u02.bin` (1.7 KB) is a flat table of ROM addresses — the symbols
the patches hook.

## Inspecting it yourself (no hardware)

```
tools/bt_patch_parse.py /lib/firmware/aic8800_fw/USB/aic8800D80/fw_patch_table_8800d80_u02.bin
tools/bt_patch_parse.py --pairs .../fw_patch_table_8800d80_u02.bin   # every addr,val
# disassemble a code blob:
r2 -a arm -b 16 -qc 's 8; pd 40' .../fw_patch_8800d80_u02.bin
```

## Extracting the ROM

The patch files are only the layer *on top of* the ROM; the ~1 MB of link
controller + GFSK modem is in silicon. But it should be readable over USB.

**Why it should work.** `aic_load_fw` writes the ADID/patch/trap data to
`0x000xxxxx` / `0x0020xxxx` / `0x40690000` through the **same DBG_MEM agent**
that `aic-memtool` reads, in one flat address space (see the map above). Read and
block-read (`DBG_MEM_BLOCK_READ_REQ`, 1 KiB/txn, ~27 ms) are companion ops on
that agent — there is no architectural reason it can write `0x0020f600` but not
read `0x000e0000`.

**The decisive test.** Read back words we already decoded from the patch table
(static Thumb-2 in the TRAP landing zone, which the running firmware does not
modify) and compare. If they match, the BT space is visible to our agent and the
dump is sound. `bt_romdump.py verify` does exactly this:

```
$ ./aic-memtool read 0020f600      # expect 0xf0223201  (first TRAP handler word)
$ tools/bt_romdump.py verify       # reads back several known words, pass/fail
```

**The dump.** On success, sweep low memory to a file (ADID references reach
~`0xee000`, so 1 MiB covers it), filling any unreadable holes with `0xFF`:

```
tools/bt_romdump.py dump bt_rom.bin              # verify-gated; --force to skip
tools/bt_romdump.py dump --start 0 --end 100000 --chunk 65536 bt_rom.bin
```

~1000 transactions, ~28 s of transfer, one USB session. Then disassemble as
Thumb-2 from `0x0` and follow the ADID/trap addresses into real functions.

**Caveats.**

* *Readout protection* is possible but unlikely on this class of part (the WiFi
  side reads everywhere freely); if present, `verify` catches it immediately
  (reads return `0x00`/`0xFF` or fault).
* *Unmapped holes* may exist; the tool bisects to 4 KiB and 0xFF-fills so one bad
  region does not stall the sweep or misalign offsets.
* *Vantage point:* the running `fmacfw` DBG_MEM handler is the easy path. If it
  has unmapped the BT ROM, the boot-ROM stage (before `DBG_START_APP`) sees the
  full map — but driving that requires intercepting the load sequence.
* *Wedge risk:* low for a pure read sweep with the netdev **down** and no scans
  running — the controller wedge in
  [`docs/kernel-bug-usb-rx-resubmit-deadlock.md`](kernel-bug-usb-rx-resubmit-deadlock.md)
  came from driver RX churn + mode switches, not block reads. Load the r6/r7
  module first.

## Status

Patch-table format and contents: **decoded and verified offline** against the
shipped u02/u04 binaries (parser output matches the driver's parse logic; code
blobs disassemble as valid Thumb-2). ROM extraction: **method established, not
yet run** — needs the hardware (the box the WiFi work was done on still needs a
reboot to clear the documented wedge). Start with `bt_romdump.py verify`.
