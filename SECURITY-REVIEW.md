# Security & correctness review — `linux/install.sh`

Reviewed at commit `98ccdbf`, against Ubuntu 26.04 / kernel `7.0.0-29-generic`, with a
`1111:1111` adapter attached (`88M80`, bus 1 device 20, currently bound to `usb-storage`).

Findings marked **verified** were reproduced directly: by building the upstream driver
tree, by inspecting the resulting modules, or by observing the live device. The rest are
read from the source.

Replacement installer: [`linux/aic8800d80-setup.sh`](linux/aic8800d80-setup.sh).

---

## Summary

`install.sh` does not currently work on this machine, for two independent reasons (C1, C6),
and would leave Bluetooth broken after the next kernel upgrade even if it did (C2). Beyond
that it has one high-severity supply-chain issue (S1) and one local privilege-escalation
issue (S2), both of which end with attacker-controlled code compiled into a kernel module
and loaded as root.

| # | Severity | Issue |
|---|----------|-------|
| S1 | High | Unpinned upstream source compiled into a kernel module |
| S2 | High | Predictable `/tmp` path + skip-if-exists → local privilege escalation |
| S3 | Medium | `rmmod btusb` disables unrelated Bluetooth hardware |
| S4 | Medium | Over-broad deletion / purging of other packages' files |
| S5 | Medium | No Secure Boot check; silently produces unloadable modules |
| S6 | Low | udev rule blocks the event queue and fires repeatedly |
| S7 | Low | No `pipefail`/`-u`, no cleanup trap, no rollback |
| C1 | **Blocker** (verified) | DKMS build fails: missing `KBUILD_EXTRA_SYMBOLS` |
| C2 | High (verified) | `aic_btusb` is not under DKMS — lost on every kernel upgrade |
| C3 | High (verified) | modprobe aliases have a 5-digit vendor field and can never match |
| C4 | High (verified) | WiFi PID patch is a silent no-op (wrong anchor identifier) |
| C5 | Medium (verified) | Bluetooth PID patch inserts five duplicate entries |
| C6 | Medium (verified) | Referenced `aic_btusb` patches no longer exist upstream |
| C7 | Medium | Strip-level guessing silently skips multi-file patches |

---

## Security findings

### S1 — Unpinned upstream source is compiled into a kernel module (High)

`install.sh:57` clones whatever `radxa-pkg/aic8800` publishes at install time:

```bash
git clone --depth 1 --filter=blob:none --sparse \
    https://github.com/radxa-pkg/aic8800.git "$RADXA_DIR"
```

There is no commit pin, tag, signature or checksum, and the clone is repeated on every
run. Everything fetched is compiled into `aic_load_fw`, `aic8800_fdrv` and `aic_btusb`
and loaded into the kernel — so an upstream repository compromise, a maintainer account
takeover, or a malicious force-push converts directly into ring-0 code execution and
persistence on every machine that runs the installer afterwards. The firmware blobs
copied into `/lib/firmware` are likewise unverified.

This is the single highest-impact issue: the trust boundary is "whatever that GitHub repo
contains at the moment you type the command".

**Fix.** Pin an explicit commit and verify it after fetch, so upgrading upstream is a
deliberate, reviewable act. The replacement fetches the pinned object directly and aborts
on mismatch:

```bash
git -C "$SRC" fetch -q --depth 1 origin "$RADXA_COMMIT"
[ "$(git -C "$SRC" rev-parse HEAD)" = "$RADXA_COMMIT" ] || die "commit mismatch"
```

### S2 — Predictable temp directory plus skip-if-exists → local privilege escalation (High)

```bash
RADXA_DIR="/tmp/radxa-aic-$$"          # install.sh:33

ensure_radxa_clone() {
    if [ ! -d "$RADXA_DIR" ]; then     # install.sh:56
        git clone ... "$RADXA_DIR"
    fi
}
```

`/tmp` is world-writable and `$$` is a small, enumerable number. Any local user can
pre-create `/tmp/radxa-aic-<pid>` containing an attacker-controlled driver tree. The
existence check then **skips the clone entirely**, and the attacker's source is what gets
compiled and inserted into the kernel — by root. The script never checks the directory's
ownership, mode, or that it is not a symlink.

`build-aic-btusb.sh:37` is worse in one respect: it uses the fully static
`/tmp/aic_btusb_build`, so no PID guessing is needed at all.

**Fix.** `mktemp -d` with mode `0700` and a cleanup `trap`, never a predictable name and
never "reuse whatever is already there".

### S3 — `rmmod btusb` disables unrelated Bluetooth hardware (Medium)

`install.sh` unloads the generic Bluetooth driver twice (step 2a and step 8), as does
`build-aic-btusb.sh`. `btusb` is the driver for essentially every non-AIC Bluetooth
adapter. On this machine that includes the internal controller:

```
Bus 001 Device 003: ID 8087:0026 Intel Corp. AX201 Bluetooth
    |__ Port 010: Dev 003, If 0, Class=Wireless, Driver=btusb
```

Installing a USB dongle should not take down the laptop's built-in Bluetooth.

**Fix.** Unbind only the AIC interfaces and leave the module loaded:

```bash
for link in /sys/bus/usb/drivers/btusb/*:*; do
    vid=$(cat "$(dirname "$(readlink -f "$link")")/idVendor")
    [ "$vid" = a69c ] && echo "${link##*/}" > /sys/bus/usb/drivers/btusb/unbind
done
```

### S4 — Over-broad deletion and purging (Medium)

In the `RADXA_USB` branch the script purges `aic8800-usb-dkms` and `aic8800-firmware`,
then deletes with a wider glob than it uses elsewhere:

```bash
for d in /usr/src/aic8800*/; do [ -d "$d" ] && rm -rf "$d"; done
```

Elsewhere the glob is `aic8800-*`. This one also matches e.g. `/usr/src/aic8800dc-.../`,
so a second, unrelated AIC driver on the system is removed. Combined with
`find /lib/modules/$KVER/ -name "${mod}.ko*" -exec rm -f {} \;` and unattended
`dpkg --purge`, the installer can uninstall software the user depends on without asking.

### S5 — No Secure Boot check (Medium)

Out-of-tree modules must be signed with an enrolled key when Secure Boot is on, otherwise
the kernel refuses to load them. `install.sh` never checks, so on a Secure Boot machine it
runs a long build, reports success, and produces a device that does not work — with no
indication why. (Secure Boot is *disabled* on this machine, so it is not the current
blocker.)

### S6 — udev rule blocks the event queue and fires repeatedly (Low)

```
ACTION=="add", ATTRS{idVendor}=="1111", ATTRS{idProduct}=="1111", RUN+="/usr/sbin/usb_modeswitch -c /etc/usb_modeswitch.d/1111:1111"
```

Three problems:

1. No `SUBSYSTEM`/`DEVTYPE` guard, and `ATTRS{}` matches ancestors — so the rule matches
   the USB device *and* its `scsi_host`, `scsi_generic`, `block`, … children, running
   `usb_modeswitch` several times per plug-in.
2. `RUN+=` executes synchronously inside the udev event handler. A slow or hanging
   `usb_modeswitch` stalls the udev queue and is killed at the event timeout.
3. No `-b`/`-g`, so the invocation is not scoped to the device that triggered it, and
   `/usr/sbin/usb_modeswitch` is hardcoded (it is `/usr/bin` on some distributions).

**Fix.** Guard on `SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device"`, hand off to a systemd
unit instead of blocking udev, and pass the triggering device's bus/device numbers.

### S7 — No `pipefail`/`-u`, no cleanup trap, no rollback (Low)

`set -e` alone. On any mid-run failure the script exits having already unloaded the
WiFi and Bluetooth modules (step 2a), leaving the adapter dead, temporary trees behind in
`/tmp`, and the system in a half-configured state. There is no trap and no rollback.

---

## Correctness and persistence findings

### C1 — The DKMS build fails (Blocker, verified)

The generated `dkms.conf` builds the two WiFi modules in separate `modpost` passes:

```
MAKE[0]="make -C ${kernel_source_dir} M=.../build/aic_load_fw modules && \
         make -C ${kernel_source_dir} M=.../build/aic8800_fdrv modules"
```

`aic8800_fdrv` links against symbols exported by `aic_load_fw`, and a separate `modpost`
pass cannot see them. Reproduced against the pinned tree on kernel 7.0.0-29:

```
ERROR: modpost: "get_fw_path" [aic8800_fdrv.ko] undefined!
ERROR: modpost: "get_testmode" [aic8800_fdrv.ko] undefined!
ERROR: modpost: "aicwf_prealloc_txq_alloc" [aic8800_fdrv.ko] undefined!
…9 symbols total, build exits 2
```

**Fix.** Point the second build at the first module's symbol table:

```
KBUILD_EXTRA_SYMBOLS=<build>/aic_load_fw/Module.symvers make -C aic8800_fdrv … modules
```

With that one change all three modules build cleanly (exit 0) from the pinned tree.

### C2 — `aic_btusb` is not under DKMS, so Bluetooth dies on the next kernel upgrade (High, verified)

Step 5 compiles `aic_btusb` by hand and copies it into a directory owned by the kernel
package:

```bash
MODDIR="/lib/modules/$KVER/kernel/drivers/bluetooth"
cp aic_btusb.ko "$MODDIR/"
```

Nothing rebuilds it. WiFi survives a kernel upgrade because it is a DKMS package;
Bluetooth does not, and fails silently — the module is simply absent from the new kernel's
tree, and the user has no reason to connect the two events.

**Fix.** Put all three modules in one DKMS package with `AUTOINSTALL="yes"`.

### C3 — The modprobe aliases can never match (High, verified)

```
alias usb:v0A69Cp8D83d*dc*dsc*dp*icE0isc01ip01in* aic_btusb
```

The vendor field in a USB modalias is **four** hex digits; this has five. Compare the real
modalias of the Intel adapter on this machine, and the alias emitted by the module built
from the patched source:

```
usb:v8087p0026d0002dcE0dsc01dp01icE0isc01ip01in00   ← real device
usb:vA69Cp8D83d*dc*dsc*dp*icE0isc01ip01in*          ← correct form
```

Both alias lines are dead, so `aic_btusb` is never autoloaded on device presence. The
`modules-load.d` entry masks this at boot, which is probably why it went unnoticed.

### C4 — The WiFi PID patch is a silent no-op (High, verified)

```bash
WIFI_SRC="$DKMS_SRC/aic8800_fdrv/aicwf_usb.c"
sed -i '/USB_DEVICE_ID_AIC_8800D80/a\...{USB_DEVICE(0xa69c, 0x8d83)}...' "$WIFI_SRC"
echo "  -> Added a69c:8d83 to WiFi USB ID table."
```

`USB_DEVICE_ID_AIC_8800D80` exists only in `aic_load_fw/aicwf_usb.c`. The file being
edited, `aic8800_fdrv/aicwf_usb.c`, uses the `USB_PRODUCT_ID_*` naming and contains **zero**
occurrences of that identifier. The `sed` matches nothing, the script prints the success
message anyway and sets `NEED_DKMS_REBUILD=1`, triggering a full rebuild that changes
nothing.

### C5 — The Bluetooth PID patch inserts five duplicates (Medium, verified)

```bash
sed -i '/USB_PRODUCT_ID_AIC8800D80.*0xe0.*0x01.*0x01/a\...0x8d83...' aic_btusb.c
```

`USB_PRODUCT_ID_AIC8800D80` is a prefix of `USB_PRODUCT_ID_AIC8800D80X2`,
`…D80X2P`, `…D80N` and `…D80LN`, all of which appear in the same table with the same
interface triple. The anchor matches **5** lines, so the entry is appended five times.
Anchoring on the trailing comma (`USB_PRODUCT_ID_AIC8800D80,`) matches exactly once.

### C6 — The referenced `aic_btusb` patches no longer exist (Medium, verified)

```bash
for patch_name in fix-aic_btusb.patch fix-aic_btusb-implicit-declare-compat_ptr.patch; do
```

Neither file is in `debian/patches/` at current upstream. The real one is
`fix-aic_btusb-use-bluez-by-default.patch` — which, usefully, already sets
`CONFIG_BLUEDROID 0` for the Ubuntu branch, making the script's own `sed` redundant. As
written the loop applies nothing and prints nothing, because the `[ -f ]` guard skips both.

### C7 — Strip-level guessing silently skips multi-file patches (Medium)

The installer copies two module directories out of the upstream tree and then tries each
patch at `-p6`, falling back to `-p5`, skipping on failure. Any patch that also touches
`src/PCIE/…` or `src/SDIO/…` — paths that do not exist in the staged tree — fails its
dry-run at both levels and is skipped wholesale, taking its USB hunks with it.

`fix-usb-firmware-path.patch` is one of these. It sets the driver's firmware search path,
so whether firmware ends up where the driver looks for it currently depends on a patch
quietly failing. (It also has a genuine CRLF-vs-LF conflict, below.)

**Fix.** Apply the whole series at `-p1` from the repository root, exactly as upstream's
own Debian packaging does, and copy the module directories out afterwards.

### Minor

- **CRLF sources.** Several upstream files ship with CRLF line endings while the patches
  are LF, and GNU `patch` refuses those hunks (`different line endings`). This affects
  `fix-usb-firmware-path.patch` and `fix-Lower-the-debugging-log-level.patch`. Normalising
  just the affected files before retrying takes the series from 24/26 to 26/26.
- **`hciconfig hci1 up`** hardcodes `hci1` (the AIC controller may be any index) and
  `hciconfig` is deprecated and absent on many current distributions.
- **Debian/Ubuntu only.** The script advertises that it "auto-detects your system" but
  calls `apt-get` unconditionally.
- **Not idempotent in practice.** Step 5 re-clones and rebuilds `aic_btusb` on every run
  regardless of state ("Rebuilding anyway to ensure latest patches"), which — with S1 —
  means each run can produce a different binary from the same script.

---

## The replacement

`linux/aic8800d80-setup.sh` implements the same outcome with the issues above addressed.

| Concern | Approach |
|---|---|
| S1 | Upstream pinned to a commit and verified after fetch; `--commit` to move it deliberately, `--source` for air-gapped installs |
| S2 | `mktemp -d` at mode 0700, `trap` cleanup, never reuses an existing path |
| S3 | Unbinds only `a69c` interfaces from `btusb`; the module stays loaded for other adapters |
| S4 | Touches only its own DKMS package name; never purges another packager's files |
| S5 | Checks Secure Boot and refuses rather than building unloadable modules (`AIC_ALLOW_SECUREBOOT=1` overrides) |
| S6 | udev rule guarded on `SUBSYSTEM`/`DEVTYPE`, hands off to a systemd unit, passes the device's bus/dev to `usb_modeswitch` |
| S7 | `set -euo pipefail`, cleanup trap, `--check` dry run |
| C1 | `KBUILD_EXTRA_SYMBOLS` wired from `aic_load_fw` into `aic8800_fdrv` |
| C2 | All three modules in one DKMS package with `AUTOINSTALL="yes"` |
| C3 | Correct 4-digit-vendor modalias aliases |
| C4/C5 | Exact anchors, asserted match counts, verified in the built modules' alias tables |
| C6/C7 | Full series applied at `-p1` from the repo root, with CRLF normalisation and retry |

Idempotency is by convergence: config files are rewritten only when their content differs,
`udevadm`/`systemctl` reload only when something changed, and the DKMS version embeds the
upstream commit so re-running with the same pin is a no-op while changing the pin forces a
clean rebuild.

### Verified on this machine

- 26/26 upstream patches apply (24 directly, 2 after CRLF normalisation).
- `0x8d83` is inserted exactly once into each of the WiFi and Bluetooth ID tables, and
  remains exactly once when the fixups are re-run.
- All three modules compile against `7.0.0-29-generic`, build exit 0.
- The built modules advertise `usb:vA69Cp8D81…` and `usb:vA69Cp8D83…` for both drivers.
- `aic_load_fw.ko` contains the D80 BT firmware strings (`fw_adid_8800d80`) and resolves
  its firmware root to `/lib/firmware/aic8800_fw/USB`, which is what the installer derives
  from the patched source rather than hardcoding.

Not yet exercised: `dkms build/install`, the udev/systemd path, and the live mode switch —
all require root, which this review did not have.
