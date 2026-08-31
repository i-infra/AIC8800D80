#!/usr/bin/env bash
#
# aic8800d80-setup.sh — idempotent, persistent setup for AIC8800D80 / 88M80 / AX900
# USB WiFi 6 + Bluetooth adapters that ship in "ZeroCD" mass-storage mode as 1111:1111.
#
# Design goals (differences from install.sh, see SECURITY-REVIEW.md):
#   * Idempotent    — converges to a desired state; safe to re-run; only rebuilds when inputs change.
#   * Persistent    — every module is under DKMS, so a kernel upgrade rebuilds them automatically.
#   * Pinned        — upstream source is fetched at a verified commit, not a moving HEAD.
#   * Non-invasive  — never unloads btusb globally; only unbinds the AIC device from it.
#   * Reversible    — --uninstall removes everything it installed.
#
# Usage:
#   sudo ./aic8800d80-setup.sh                 # install / converge
#   sudo ./aic8800d80-setup.sh --check         # dry run: report what would change
#   sudo ./aic8800d80-setup.sh --status        # report current state only (no root needed)
#   sudo ./aic8800d80-setup.sh --uninstall     # remove everything
#   sudo ./aic8800d80-setup.sh --force-rebuild # rebuild DKMS even if already installed
#
# Options:
#   --commit SHA     override the pinned upstream commit
#   --source DIR     build from a local checkout instead of cloning (air-gapped installs)
#   --skip-deps      do not touch the package manager
#
set -euo pipefail
umask 022

###############################################################################
# Configuration
###############################################################################

# Pinned upstream. Verified 2026-08-22 against https://github.com/radxa-pkg/aic8800
# Bump deliberately; the commit is part of the DKMS version, so changing it forces
# a clean rebuild rather than silently mutating an installed driver.
RADXA_REPO="${AIC_RADXA_REPO:-https://github.com/radxa-pkg/aic8800.git}"
RADXA_COMMIT="${AIC_RADXA_COMMIT:-df4c783b663eba1956579c681acd5e45f25c671d}"

# Revision of the LOCAL fixups in apply_local_fixups(). This is part of the DKMS
# version because the idempotency check keys on that version: without it, editing
# an ID-table fixup here leaves the previously built modules in place and the
# change silently never reaches the kernel. Bump whenever apply_local_fixups()
# changes what it produces.
LOCAL_REV="7"

# Patches shipped alongside this script (in ./patches/) that are applied on top
# of upstream's debian/patches series. Listed explicitly rather than globbed:
# the directory also holds older reference-only patches that are not meant to
# apply. Any change to a listed patch must bump LOCAL_REV above.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_PATCHES=(
    # NULL rwnx_hw deref in the bus RX kthread during a fast rebind, and the
    # kthread_stop() that then hangs USB probe/disconnect forever.
    # See docs/kernel-bug-probe-race-rx-oops-kthread-stop-hang.md
    aic8800_fdrv-probe-race-rx-oops-kthread-stop-hang.patch
    # BUG_ON() in rwnx_freq_to_idx() on a firmware-supplied survey frequency the
    # wiphy has no channel for, plus an off-by-one that writes one element past
    # rwnx_hw->survey[SCAN_CHANNEL_MAX]. Found by rebind burn-in against r4.
    # See docs/kernel-bug-probe-race-rx-oops-kthread-stop-hang.md
    aic8800_fdrv-survey-ind-bugon-and-survey-oob.patch
    # USB RX resubmit spins forever on -ENODEV when the device is unplugged/reset
    # under load (state still reads USB_UP_ST), blocking USB disconnect and
    # wedging the whole xHCI controller until reboot. Found live during RF capture
    # work. See docs/kernel-bug-usb-rx-resubmit-deadlock.md
    aic8800_fdrv-usb-rx-resubmit-deadlock-on-disconnect.patch
    # aicwf_deinit_sem count inflates by +1 on every unplug-under-load (double
    # up()), voiding the disconnect-vs-module-exit exclusion; and disconnect's
    # NULL-usb_dev early return leaked the semaphore. Found by auditing the
    # driver after the wedge above. See docs/kernel-bug-usb-rx-resubmit-deadlock.md
    aic8800_fdrv-usb-disconnect-deinit-sem-imbalance.patch
)

DKMS_PKG="aic8800d80"
MODULES=(aic_load_fw aic8800_fdrv aic_btusb)

# Device identities
# Pre-switch identities, "vid:pid". Each needs a matching config in
# /etc/usb_modeswitch.d/; the helper selects the config from the device's own IDs.
SWITCH_IDS=("1111:1111" "a69c:5721")

BOOT_VID="1111"; BOOT_PID="1111"          # mass-storage / ZeroCD mode
AIC_VID="a69c"                            # post-switch vendor (D80 clone)
AIC_VID2="368b"                           # post-switch vendor (AIC_V2 variants)
AIC_PIDS=(8d80 8d81 8d83 5721)            # 8d80 bootrom, 8d81 WiFi+BT, 8d83 WiFi-only

# Installed paths
MS_CONF="/etc/usb_modeswitch.d/${BOOT_VID}:${BOOT_PID}"
UDEV_RULES="/etc/udev/rules.d/41-aic8800d80.rules"
MODPROBE_CONF="/etc/modprobe.d/aic8800d80.conf"
MODLOAD_CONF="/etc/modules-load.d/aic8800d80.conf"
HELPER="/usr/local/sbin/aic8800d80-modeswitch"
BT_HELPER="/usr/local/sbin/aic8800d80-btbind"
SYSTEMD_UNIT="/etc/systemd/system/aic8800d80-modeswitch@.service"
BT_UNIT="/etc/systemd/system/aic8800d80-btbind@.service"
STATE_DIR="/var/lib/aic8800d80"

KVER="$(uname -r)"
DKMS_VER="1.0+git.${RADXA_COMMIT:0:7}.r${LOCAL_REV}"

DRY_RUN=0
DO_UNINSTALL=0
DO_STATUS_ONLY=0
FORCE_REBUILD=0
SKIP_DEPS=0
LOCAL_SOURCE=""
CHANGED=0
WORK_DIR=""

###############################################################################
# Output helpers
###############################################################################

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[1;33m'
    C_C=$'\033[0;36m'; C_B=$'\033[1m';    C_N=$'\033[0m'
else
    C_R=""; C_G=""; C_Y=""; C_C=""; C_B=""; C_N=""
fi

step()  { printf '%s==>%s %s%s%s\n' "$C_G" "$C_N" "$C_B" "$*" "$C_N"; }
info()  { printf '    %s\n' "$*"; }
ok()    { printf '    %s✓%s %s\n' "$C_G" "$C_N" "$*"; }
skip()  { printf '    %s·%s %s\n' "$C_C" "$C_N" "$*"; }
warn()  { printf '    %s!%s %s\n' "$C_Y" "$C_N" "$*" >&2; }
die()   { printf '%sError:%s %s\n' "$C_R" "$C_N" "$*" >&2; exit 1; }

# Mark that this run actually changed system state.
changed() { CHANGED=1; printf '    %s+%s %s\n' "$C_Y" "$C_N" "$*"; }

###############################################################################
# Argument parsing
###############################################################################

while [ $# -gt 0 ]; do
    case "$1" in
        --check|--dry-run) DRY_RUN=1 ;;
        --status)          DO_STATUS_ONLY=1 ;;
        --uninstall)       DO_UNINSTALL=1 ;;
        --force-rebuild)   FORCE_REBUILD=1 ;;
        --skip-deps)       SKIP_DEPS=1 ;;
        --commit)          RADXA_COMMIT="${2:?--commit needs a SHA}"; DKMS_VER="1.0+git.${RADXA_COMMIT:0:7}.r${LOCAL_REV}"; shift ;;
        --commit=*)        RADXA_COMMIT="${1#*=}"; DKMS_VER="1.0+git.${RADXA_COMMIT:0:7}.r${LOCAL_REV}" ;;
        --source)          LOCAL_SOURCE="${2:?--source needs a directory}"; shift ;;
        --source=*)        LOCAL_SOURCE="${1#*=}" ;;
        -h|--help)         awk 'NR>1 && /^set -euo/{exit} NR>1{sub(/^#[ ]?/,""); print}' "$0"; exit 0 ;;
        *)                 die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

###############################################################################
# Primitives
###############################################################################

cleanup() {
    local rc=$?
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        rm -rf -- "$WORK_DIR"
    fi
    return $rc
}
trap cleanup EXIT

# Write stdin to a file, but only if the content differs. Returns 0 if it wrote.
# Honours --check by reporting instead of writing.
write_file() {
    local path="$1" mode="${2:-0644}" tmp
    mkdir -p -- "$(dirname -- "$path")"
    tmp="$(mktemp -- "${path}.XXXXXXXX")"
    cat > "$tmp"
    chmod "$mode" "$tmp"
    if [ -e "$path" ] && cmp -s -- "$tmp" "$path"; then
        rm -f -- "$tmp"
        return 1
    fi
    if [ "$DRY_RUN" = 1 ]; then
        rm -f -- "$tmp"
        return 0
    fi
    mv -f -- "$tmp" "$path"
    return 0
}

remove_file() {
    local path="$1"
    [ -e "$path" ] || return 1
    [ "$DRY_RUN" = 1 ] || rm -f -- "$path"
    return 0
}

need_root() {
    [ "$(id -u)" -eq 0 ] || die "must run as root (sudo $0)"
}

have() { command -v "$1" >/dev/null 2>&1; }

###############################################################################
# Status reporting
###############################################################################

usb_devices_matching() {
    # $1=vid  $2=pid ; prints sysfs names (e.g. "1-4") of matching usb_device nodes
    local vid="$1" pid="$2" d
    for d in /sys/bus/usb/devices/*/; do
        [ -r "$d/idVendor" ] || continue
        [ "$(cat "$d/idVendor")" = "$vid" ] || continue
        [ -z "$pid" ] || [ "$(cat "$d/idProduct")" = "$pid" ] || continue
        basename "$d"
    done
}

report_status() {
    local d pid v found=0
    step "Current state"

    printf '    %-28s %s\n' "kernel" "$KVER"
    printf '    %-28s %s\n' "dkms package" "${DKMS_PKG}/${DKMS_VER}"

    if have dkms; then
        local built
        built="$(dkms status "${DKMS_PKG}/${DKMS_VER}" 2>/dev/null | sed 's/.*, \([^,]*\), .*/\1/' | tr '\n' ' ')"
        printf '    %-28s %s\n' "dkms built for" "${built:-<nothing>}"
        if dkms_installed_for "$KVER"; then
            printf '    %-28s %s\n' "running kernel" "$KVER (modules present)"
        else
            printf '    %-28s %s\n' "running kernel" "$KVER (NO MODULES -- re-run to build)"
        fi
    else
        printf '    %-28s %s\n' "dkms status" "dkms not present"
    fi

    for f in "$MS_CONF" "$UDEV_RULES" "$MODPROBE_CONF" "$MODLOAD_CONF" "$HELPER" "$BT_HELPER" "$SYSTEMD_UNIT" "$BT_UNIT"; do
        printf '    %-28s %s\n' "$(basename "$(dirname "$f")")/$(basename "$f")" "$([ -e "$f" ] && echo present || echo missing)"
    done

    printf '    %-28s ' "adapter"
    for d in $(for id in "${SWITCH_IDS[@]}"; do usb_devices_matching "${id%%:*}" "${id##*:}"; done); do
        echo "$d: ${BOOT_VID}:${BOOT_PID} (mass-storage mode, not switched)"
        found=1
    done
    for v in "$AIC_VID" "$AIC_VID2"; do
        for pid in "${AIC_PIDS[@]}"; do
            for d in $(usb_devices_matching "$v" "$pid"); do
                if [ "$pid" = "5721" ]; then echo "$d: ${v}:${pid} (mass-storage mode, not switched)"
                else echo "$d: ${v}:${pid} (switched)"; fi
                found=1
            done
        done
    done
    [ "$found" = 1 ] || echo "not detected"

    printf '    %-28s %s\n' "loaded modules" "$(lsmod | awk '/^aic_load_fw|^aic8800_fdrv|^aic_btusb/{printf "%s ", $1}' || true)"
    printf '    %-28s %s\n' "wifi interfaces" "$(ls /sys/class/ieee80211 2>/dev/null | tr '\n' ' ' || true)"
    printf '    %-28s %s\n' "hci devices" "$(ls /sys/class/bluetooth 2>/dev/null | tr '\n' ' ' || true)"
    echo
}

###############################################################################
# Preflight
###############################################################################

preflight() {
    step "Preflight"

    if [ "$(uname -s)" != "Linux" ]; then die "Linux only"; fi

    # Secure Boot: out-of-tree unsigned modules will not load. Fail early and loudly
    # rather than after a 10 minute build.
    if have mokutil && mokutil --sb-state 2>/dev/null | grep -qi 'SecureBoot enabled'; then
        warn "Secure Boot is ENABLED."
        warn "Unsigned out-of-tree modules will be refused by the kernel."
        warn "Either disable Secure Boot, or enrol a MOK key and sign the modules"
        warn "(dkms can sign automatically via /etc/dkms/framework.conf)."
        if [ "$DRY_RUN" = 0 ] && [ "${AIC_ALLOW_SECUREBOOT:-0}" != "1" ]; then
            die "refusing to build modules that cannot load (set AIC_ALLOW_SECUREBOOT=1 to override)"
        fi
    else
        ok "Secure Boot not blocking module load"
    fi

    if [ ! -d "/lib/modules/$KVER/build" ] && [ "$SKIP_DEPS" = 1 ]; then
        die "kernel headers for $KVER are missing and --skip-deps was given"
    fi

    ok "kernel $KVER"
}

###############################################################################
# Step: dependencies
###############################################################################

install_deps() {
    step "Dependencies"
    if [ "$SKIP_DEPS" = 1 ]; then skip "--skip-deps given"; return; fi

    if ! have apt-get; then
        warn "no apt-get found; this installer only automates Debian/Ubuntu."
        warn "Install manually: usb-modeswitch sg3-utils git build-essential dkms"
        warn "plus kernel headers for $KVER, then re-run with --skip-deps."
        die "unsupported package manager"
    fi

    local want=()
    have usb_modeswitch          || want+=(usb-modeswitch usb-modeswitch-data)
    have git                     || want+=(git)
    have make                    || want+=(build-essential)
    have dkms                    || want+=(dkms)
    have rfkill                  || want+=(rfkill)
    [ -d "/lib/modules/$KVER/build" ] || want+=("linux-headers-$KVER")

    if [ ${#want[@]} -eq 0 ]; then
        skip "all prerequisites present"
        return
    fi

    info "installing: ${want[*]}"
    if [ "$DRY_RUN" = 1 ]; then skip "(dry run)"; return; fi
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${want[@]}"
    changed "installed ${want[*]}"
}

###############################################################################
# Step: fetch and verify upstream source
###############################################################################

fetch_source() {
    step "Upstream source"

    WORK_DIR="$(mktemp -d -t aic8800d80.XXXXXXXX)"
    chmod 0700 "$WORK_DIR"
    SRC="$WORK_DIR/src"

    if [ -n "$LOCAL_SOURCE" ]; then
        [ -d "$LOCAL_SOURCE/debian/patches" ] || die "--source $LOCAL_SOURCE does not look like an aic8800 checkout"
        info "using local checkout: $LOCAL_SOURCE"
        cp -a -- "$LOCAL_SOURCE" "$SRC"
        ok "copied local source"
        return
    fi

    info "cloning $RADXA_REPO"
    info "pinned commit: $RADXA_COMMIT"

    # Fetch exactly the pinned commit. This is the security boundary: everything
    # downstream compiles into a kernel module, so an unpinned HEAD would mean
    # "whatever upstream published today runs as ring 0 on this machine".
    git init -q "$SRC"
    git -C "$SRC" remote add origin "$RADXA_REPO"
    if ! git -C "$SRC" fetch -q --depth 1 origin "$RADXA_COMMIT"; then
        die "could not fetch pinned commit $RADXA_COMMIT from $RADXA_REPO"
    fi
    git -C "$SRC" checkout -q FETCH_HEAD

    local got
    got="$(git -C "$SRC" rev-parse HEAD)"
    [ "$got" = "$RADXA_COMMIT" ] || die "commit mismatch: expected $RADXA_COMMIT, got $got"
    ok "verified commit $got"
}

###############################################################################
# Step: apply the upstream patch series
###############################################################################

apply_patches() {
    step "Patch series"

    local series="$SRC/debian/patches/series"
    [ -f "$series" ] || die "no debian/patches/series in source tree"

    # Apply the whole series at -p1 from the repo root, exactly as Radxa's own
    # packaging does. install.sh instead guessed -p5/-p6 against a partial tree,
    # which silently skipped multi-file patches.
    local applied=0 failed=0 normalised=0 p rc out
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        case "$p" in \#*) continue ;; esac
        [ -f "$SRC/debian/patches/$p" ] || { warn "patch listed in series but missing: $p"; continue; }
        rc=0; out=""
        out="$( cd "$SRC" && patch -p1 -N --batch --ignore-whitespace \
            < "debian/patches/$p" 2>&1 )" || rc=$?
        # `patch -N` exits non-zero both for genuinely failed hunks and for hunks it
        # skipped because they were already applied. Only the former is a problem.
        if [ "$rc" -ne 0 ] && ! printf '%s\n' "$out" | grep -q 'FAILED'; then rc=0; fi

        if [ "$rc" -ne 0 ]; then
            # Upstream ships several sources with CRLF line endings while the patches
            # are LF, and GNU patch refuses those hunks ("different line endings").
            # Normalise only the files this patch touches, then retry. The kernel
            # build is indifferent to line endings, so this is semantically inert --
            # and it is what makes fix-usb-firmware-path.patch apply deterministically
            # instead of silently leaving the firmware search path at its default.
            local t norm=0
            while IFS= read -r t; do
                [ -n "$t" ] || continue
                [ -f "$SRC/$t" ] || continue
                if grep -q $'\r' "$SRC/$t" 2>/dev/null; then
                    sed -i 's/\r$//' "$SRC/$t"
                    norm=1
                fi
            done < <(sed -n 's@^--- a/@@p' "$SRC/debian/patches/$p")

            if [ "$norm" -eq 1 ]; then
                rc=0
                out="$( cd "$SRC" && patch -p1 -N --batch --ignore-whitespace \
                    < "debian/patches/$p" 2>&1 )" || rc=$?
                if [ "$rc" -ne 0 ] && ! printf '%s\n' "$out" | grep -q 'FAILED'; then rc=0; fi
                [ "$rc" -eq 0 ] && normalised=$((normalised + 1))
            fi
        fi

        if [ "$rc" -eq 0 ]; then
            applied=$((applied + 1))
        else
            failed=$((failed + 1))
            # PCIe/SDIO hunks are irrelevant to this USB adapter, so a partial
            # apply is not necessarily fatal. Report it and let the build decide.
            warn "patch did not fully apply: $p"
        fi
    done < "$series"
    if [ "$failed" -gt 0 ]; then
        ok "$applied patches applied ($normalised after CRLF normalisation), $failed with skipped hunks"
    else
        ok "$applied patches applied ($normalised after CRLF normalisation)"
    fi
}

###############################################################################
# Step: local fixups on top of upstream
###############################################################################

apply_local_fixups() {
    step "Local fixups"

    local btusb_c="$SRC/src/USB/driver_fw/drivers/aic_btusb/aic_btusb.c"
    local btusb_h="$SRC/src/USB/driver_fw/drivers/aic_btusb/aic_btusb.h"
    local fdrv_c="$SRC/src/USB/driver_fw/drivers/aic8800/aic8800_fdrv/aicwf_usb.c"
    local fdrv_mk="$SRC/src/USB/driver_fw/drivers/aic8800/aic8800_fdrv/Makefile"

    for f in "$btusb_c" "$btusb_h" "$fdrv_c" "$fdrv_mk"; do
        [ -f "$f" ] || die "expected source file missing: ${f#$SRC/}"
    done

    # --- BlueZ, not Android BlueDroid -------------------------------------
    # Upstream's fix-aic_btusb-use-bluez-by-default.patch already does this for the
    # CONFIG_PLATFORM_UBUNTU branch. Assert rather than blindly sed, so we notice
    # if upstream changes shape.
    if grep -qE '^#define[[:space:]]+CONFIG_BLUEDROID[[:space:]]+0' "$btusb_h"; then
        ok "CONFIG_BLUEDROID=0 (BlueZ) present"
    else
        warn "CONFIG_BLUEDROID=0 not found after patching; forcing it"
        sed -i 's/^\(#define[[:space:]]\+CONFIG_BLUEDROID[[:space:]]\+\)1/\10/' "$btusb_h"
        ok "forced CONFIG_BLUEDROID=0"
    fi

    # --- Add the a69c:8d83 variant to the Bluetooth ID table ---------------
    # install.sh anchored on 'USB_PRODUCT_ID_AIC8800D80.*0xe0.*0x01.*0x01', which
    # also prefix-matches USB_PRODUCT_ID_AIC8800D80X2 / D80X2P / D80N / D80LN and
    # therefore inserted the entry five times. Anchor on the trailing comma.
    if grep -q '0x8d83' "$btusb_c"; then
        skip "aic_btusb already lists 0x8d83"
    else
        local n
        n="$(grep -c 'USB_PRODUCT_ID_AIC8800D80,[[:space:]]*0xe0' "$btusb_c" || true)"
        [ "$n" = "1" ] || die "expected exactly 1 anchor in aic_btusb.c, found $n — upstream layout changed"
        sed -i '/USB_PRODUCT_ID_AIC8800D80,[[:space:]]*0xe0/a\    {USB_DEVICE_AND_INTERFACE_INFO(USB_VENDOR_ID_AIC, 0x8d83, 0xe0, 0x01, 0x01)},   /* 1111:1111 clone, WiFi-only firmware */' "$btusb_c"
        ok "added a69c:8d83 to aic_btusb ID table"
    fi

    # --- Add the AIC_V2 368b:8d81 variant to both ID tables ----------------
    # A second AIC design switches a69c:5721 -> 368b:8d81 on a plain SCSI eject,
    # arriving already firmware-loaded. Upstream pairs 0x8d81 only with the a69c
    # vendor, and pairs 368b with 8d90/8d91/8d92/8d99 -- so 368b:8d81 matches
    # nothing in any of the three drivers and the device binds to nothing.
    if grep -q 'AIC_V2, 0x8d81' "$fdrv_c"; then
        skip "aic8800_fdrv already lists 368b:8d81"
    else
        local v1
        v1="$(grep -c 'USB_VENDOR_ID_AIC_V2, USB_PRODUCT_ID_AIC8800D81X2, 0xff' "$fdrv_c" || true)"
        [ "$v1" = "1" ] || die "expected exactly 1 AIC_V2 anchor in aic8800_fdrv, found $v1"
        sed -i '/USB_VENDOR_ID_AIC_V2, USB_PRODUCT_ID_AIC8800D81X2, 0xff/a\    {USB_DEVICE_AND_INTERFACE_INFO(USB_VENDOR_ID_AIC_V2, 0x8d81, 0xff, 0xff, 0xff)},   /* AIC_V2 variant, post-eject */' "$fdrv_c"
        ok "added 368b:8d81 to aic8800_fdrv ID table"
    fi

    if grep -q 'AIC_V2, 0x8d81' "$btusb_c"; then
        skip "aic_btusb already lists 368b:8d81"
    else
        local v2
        v2="$(grep -c 'USB_VENDOR_ID_AIC_V2, USB_PRODUCT_ID_AIC8800D80X2, 0xe0' "$btusb_c" || true)"
        [ "$v2" = "1" ] || die "expected exactly 1 AIC_V2 anchor in aic_btusb, found $v2"
        sed -i '/USB_VENDOR_ID_AIC_V2, USB_PRODUCT_ID_AIC8800D80X2, 0xe0/a\    {USB_DEVICE_AND_INTERFACE_INFO(USB_VENDOR_ID_AIC_V2, 0x8d81, 0xe0, 0x01, 0x01)},   /* AIC_V2 variant, post-eject */' "$btusb_c"
        ok "added 368b:8d81 to aic_btusb ID table"
    fi

    # --- Add the a69c:8d83 variant to the WiFi ID table --------------------
    # install.sh applied its sed to aic8800_fdrv/aicwf_usb.c but anchored on
    # USB_DEVICE_ID_AIC_8800D80, an identifier that only exists in aic_load_fw.
    # The anchor matched zero lines, so the patch was a silent no-op.
    if grep -q '0x8d83' "$fdrv_c"; then
        skip "aic8800_fdrv already lists 0x8d83"
    else
        local m
        m="$(grep -c 'USB_PRODUCT_ID_AIC8800D81,[[:space:]]*0xff' "$fdrv_c" || true)"
        [ "$m" -ge 1 ] || die "no anchor found in aic8800_fdrv/aicwf_usb.c — upstream layout changed"
        sed -i '0,/USB_PRODUCT_ID_AIC8800D81,[[:space:]]*0xff/s//&/; /USB_PRODUCT_ID_AIC8800D81,[[:space:]]*0xff/a\    {USB_DEVICE_AND_INTERFACE_INFO(USB_VENDOR_ID_AIC, 0x8d83, 0xff, 0xff, 0xff)},   /* 1111:1111 clone, WiFi-only firmware */' "$fdrv_c"
        ok "added a69c:8d83 to aic8800_fdrv ID table"
    fi

    # --- Enable debugfs so runtime register access exists ------------------
    # aic8800_fdrv/Makefile ships "CONFIG_DEBUG_FS ?= n", which drops
    # rwnx_debugfs.o and the -DCONFIG_RWNX_DEBUGFS flag. That removes the
    # write-only "regdbg" file -- the only way to read or write chip registers
    # at runtime over USB, since the firmware's own test shell is UART-only:
    #
    #   /sys/kernel/debug/ieee80211/phyN/rwnx/regdbg     <oper> <addr> <val>, hex
    #   echo "0 40500000 0"        > regdbg   # oper 0 = read,  result in dmesg
    #   echo "1 4034206c 100003ff" > regdbg   # oper 1 = write, before/after in dmesg
    #
    # 0x40500000 is the chip ID register: revision in bits 23:16 (0x07 = U03),
    # and bit 25 == 0 marks the M80 flavour. Reading it directly avoids the
    # sticky-global bug in the driver's own chip_mcu_id reporting.
    # See docs/testmode-firmware-api.md, Appendix D.
    #
    # Verified to build clean against 7.0.0-30: rwnx_debugfs.o and
    # rwnx_fw_trace.o compile with no new warnings.
    if grep -qE '^CONFIG_DEBUG_FS[[:space:]]*\?=[[:space:]]*y' "$fdrv_mk"; then
        skip "aic8800_fdrv debugfs already enabled"
    else
        local dbgn
        dbgn="$(grep -cE '^CONFIG_DEBUG_FS[[:space:]]*\?=[[:space:]]*n' "$fdrv_mk" || true)"
        [ "$dbgn" = "1" ] || die "expected exactly 1 'CONFIG_DEBUG_FS ?= n' in aic8800_fdrv/Makefile, found $dbgn — upstream layout changed"
        sed -i 's/^CONFIG_DEBUG_FS[[:space:]]*?=[[:space:]]*n/CONFIG_DEBUG_FS ?= y/' "$fdrv_mk"
        ok "enabled CONFIG_DEBUG_FS in aic8800_fdrv (regdbg register access)"
    fi

    # --- Local patches -----------------------------------------------------
    # Real unified diffs against the upstream tree (-p1 from the repo root, like
    # the debian series), applied after the sed fixups above. Unlike the debian
    # series a failed hunk here is fatal: these patches exist to stop a kernel
    # oops, so silently building without them is the wrong outcome.
    local lp rc out
    for lp in "${LOCAL_PATCHES[@]}"; do
        [ -f "$SCRIPT_DIR/patches/$lp" ] || die "local patch missing: patches/$lp"
        if ( cd "$SRC" && patch -p1 -R -f --dry-run --silent < "$SCRIPT_DIR/patches/$lp" >/dev/null 2>&1 ); then
            skip "local patch already applied: $lp"
            continue
        fi
        rc=0
        out="$( cd "$SRC" && patch -p1 -N --batch --ignore-whitespace < "$SCRIPT_DIR/patches/$lp" 2>&1 )" || rc=$?
        if [ "$rc" -ne 0 ]; then
            printf '%s\n' "$out" >&2
            die "local patch failed to apply: $lp -- upstream layout changed; refusing to build without it"
        fi
        ok "applied local patch: $lp"
    done
}

###############################################################################
# Step: stage the DKMS source tree
###############################################################################

stage_dkms() {
    step "DKMS source tree"

    local drv="$SRC/src/USB/driver_fw/drivers"
    local dest="/usr/src/${DKMS_PKG}-${DKMS_VER}"

    DKMS_SRC="$dest"

    if [ "$DRY_RUN" = 1 ]; then
        if [ -d "$dest" ]; then skip "$dest already staged"; else changed "would stage $dest"; fi
        return
    fi

    rm -rf -- "$dest"
    mkdir -p -- "$dest"
    cp -a -- "$drv/aic8800/aic_load_fw"   "$dest/aic_load_fw"
    cp -a -- "$drv/aic8800/aic8800_fdrv"  "$dest/aic8800_fdrv"
    cp -a -- "$drv/aic_btusb"             "$dest/aic_btusb"

    local build="\${dkms_tree}/${DKMS_PKG}/${DKMS_VER}/build"
    local mk=""
    local m
    for m in "${MODULES[@]}"; do
        [ -z "$mk" ] || mk="$mk && "
        # aic8800_fdrv references symbols exported by aic_load_fw. DKMS builds each
        # module in its own modpost pass, so without KBUILD_EXTRA_SYMBOLS the link
        # fails with "get_fw_path undefined". aic_load_fw is built first (see the
        # MODULES order), so its Module.symvers exists by then.
        local env=""
        [ "$m" != "aic8800_fdrv" ] || env="KBUILD_EXTRA_SYMBOLS=${build}/aic_load_fw/Module.symvers "
        # PWD must be passed explicitly: aic8800_fdrv's Makefile uses `PWD ?= $(shell pwd)`,
        # and PWD is exported by the calling shell, so the ?= would otherwise keep the
        # parent directory and the module would build in the wrong place.
        mk="${mk}${env}make -C ${m} KDIR=\${kernel_source_dir} PWD=${build}/${m} CONFIG_PLATFORM_UBUNTU=y modules"
    done

    {
        echo "PACKAGE_NAME=\"${DKMS_PKG}\""
        echo "PACKAGE_VERSION=\"${DKMS_VER}\""
        echo
        echo "MAKE[0]=\"${mk}\""
        echo "CLEAN=\"$(for m in "${MODULES[@]}"; do printf 'make -C %s KDIR=${kernel_source_dir} PWD=%s/%s clean; ' "$m" "$build" "$m"; done)\""
        echo
        local i=0
        for m in "${MODULES[@]}"; do
            echo "BUILT_MODULE_NAME[$i]=\"${m}\""
            echo "BUILT_MODULE_LOCATION[$i]=\"${m}\""
            echo "DEST_MODULE_LOCATION[$i]=\"/updates/dkms\""
            i=$((i + 1))
        done
        echo
        # AUTOINSTALL is what makes this survive kernel upgrades. install.sh hand-copied
        # aic_btusb.ko into /lib/modules/<ver>/kernel/, which is orphaned on every upgrade.
        echo 'AUTOINSTALL="yes"'
    } > "$dest/dkms.conf"

    changed "staged $dest (3 modules, AUTOINSTALL=yes)"
}

###############################################################################
# Step: build and install via DKMS
###############################################################################

# Kernels we should have modules for: the running one, plus every other installed
# kernel that has headers. AUTOINSTALL only covers kernels installed *after* this
# package, so a kernel already on disk at install time falls through the gap --
# install while booted on A, reboot into already-present B, and the adapter
# silently has no driver at all.
target_kernels() {
    local k
    echo "$KVER"
    for k in /lib/modules/*/; do
        k="$(basename -- "$k")"
        [ "$k" != "$KVER" ] || continue
        [ -d "/lib/modules/$k/build" ] || continue
        echo "$k"
    done
}

dkms_installed_for() {
    dkms status "${DKMS_PKG}/${DKMS_VER}" 2>/dev/null | grep -q "$1.*installed"
}

build_dkms() {
    step "DKMS build"

    have dkms || die "dkms is not installed"

    local kernels k
    kernels="$(target_kernels)"

    if [ "$DRY_RUN" = 1 ]; then
        for k in $kernels; do
            if dkms_installed_for "$k"; then
                skip "already installed for $k"
            else
                changed "would build ${DKMS_PKG}/${DKMS_VER} for $k"
            fi
        done
        return
    fi

    # Retire our own older versions only. Unlike install.sh we never touch
    # /usr/src/aic8800* belonging to other packagers.
    local entry ver
    while read -r entry; do
        [ -n "$entry" ] || continue
        ver="${entry#*/}"; ver="${ver%%[,:]*}"; ver="${ver// /}"
        [ "$ver" != "$DKMS_VER" ] || continue
        info "removing previous ${DKMS_PKG}/${ver}"
        dkms remove "${DKMS_PKG}/${ver}" --all >/dev/null 2>&1 || true
        rm -rf -- "/usr/src/${DKMS_PKG}-${ver}"
    done < <(dkms status "$DKMS_PKG" 2>/dev/null | sed 's/[,:].*//' | tr -d ' ' || true)

    dkms add "${DKMS_PKG}/${DKMS_VER}" >/dev/null 2>&1 || true

    for k in $kernels; do
        if [ "$FORCE_REBUILD" = 0 ] && dkms_installed_for "$k"; then
            skip "${DKMS_PKG}/${DKMS_VER} already installed for $k"
            continue
        fi
        [ "$FORCE_REBUILD" = 0 ] || dkms remove "${DKMS_PKG}/${DKMS_VER}" -k "$k" >/dev/null 2>&1 || true
        info "building for $k (this takes a few minutes)..."
        if ! dkms build "${DKMS_PKG}/${DKMS_VER}" -k "$k"; then
            if [ "$k" = "$KVER" ]; then
                die "DKMS build failed for the running kernel -- see /var/lib/dkms/${DKMS_PKG}/${DKMS_VER}/build/make.log"
            fi
            warn "build failed for $k (not the running kernel) -- continuing"
            continue
        fi
        dkms install "${DKMS_PKG}/${DKMS_VER}" -k "$k" --force
        changed "built and installed ${DKMS_PKG}/${DKMS_VER} for $k"
    done

    dkms_installed_for "$KVER" || die "no modules were installed for the running kernel $KVER"

    # Sanity check: the D80 Bluetooth firmware loader must be compiled in, otherwise
    # the adapter comes up as 8d83 (WiFi only) and Bluetooth silently never appears.
    local ko="/lib/modules/$KVER/updates/dkms/aic_load_fw.ko" found=1
    if   [ -f "$ko.zst" ]; then zstd -dc "$ko.zst" 2>/dev/null | strings | grep -q 'fw_adid_8800d80' || found=0
    elif [ -f "$ko.xz"  ]; then xz   -dc "$ko.xz"  2>/dev/null | strings | grep -q 'fw_adid_8800d80' || found=0
    elif [ -f "$ko"     ]; then strings "$ko"                  | grep -q 'fw_adid_8800d80' || found=0
    else found=0
    fi
    if [ "$found" = 1 ]; then
        ok "aic_load_fw contains the D80 BT firmware loader"
    else
        warn "could not confirm BT firmware strings in aic_load_fw.ko"
    fi
}

###############################################################################
# Step: firmware
###############################################################################

install_firmware() {
    step "Firmware"

    # Derive the firmware root from the (patched) driver source rather than
    # hardcoding it. Upstream's fix-usb-firmware-path.patch moves this to
    # /lib/firmware/aic8800_fw/USB, but only applies when the source has LF
    # line endings — so the effective path is not knowable in advance.
    local src_c="$SRC/src/USB/driver_fw/drivers/aic8800/aic_load_fw/aicbluetooth.c"
    local root
    root="$(sed -n 's@.*aic_default_fw_path[[:space:]]*=[[:space:]]*"\(/lib/firmware[^"]*\)".*@\1@p' "$src_c" | head -1)"
    root="${root:-/lib/firmware}"

    local fw_src="$SRC/src/USB/driver_fw/fw/aic8800D80"
    local fw_dst="$root/aic8800D80"
    [ -d "$fw_src" ] || die "firmware missing from upstream tree"

    info "driver expects firmware under $root"

    if [ "$DRY_RUN" = 1 ]; then
        if [ -f "$fw_dst/fmacfw_8800d80_u02.bin" ]; then skip "$fw_dst populated"; else changed "would install firmware to $fw_dst"; fi
        return
    fi

    mkdir -p -- "$fw_dst"
    local f base wrote=0
    for f in "$fw_src"/*; do
        [ -f "$f" ] || continue
        base="$(basename -- "$f")"
        if [ ! -e "$fw_dst/$base" ] || ! cmp -s -- "$f" "$fw_dst/$base"; then
            install -m 0644 -- "$f" "$fw_dst/$base"
            wrote=$((wrote + 1))
        fi
    done
    if [ "$wrote" -gt 0 ]; then changed "installed $wrote firmware file(s) to $fw_dst"; else skip "firmware up to date in $fw_dst"; fi

    # Belt and braces: if the driver ever gets built with the other path, make the
    # alternative resolve to the same files instead of failing to load.
    local alt
    if [ "$root" = "/lib/firmware" ]; then alt="/lib/firmware/aic8800_fw/USB/aic8800D80"; else alt="/lib/firmware/aic8800D80"; fi
    if [ ! -e "$alt" ]; then
        mkdir -p -- "$(dirname -- "$alt")"
        ln -sfn -- "$fw_dst" "$alt"
        changed "symlinked $alt -> $fw_dst"
    fi
}

###############################################################################
# Step: usb_modeswitch configuration
###############################################################################

install_modeswitch_conf() {
    step "usb_modeswitch configuration"

    if write_file "$MS_CONF" 0644 <<EOF
# AIC8800D80 / 88M80 clone adapter (${BOOT_VID}:${BOOT_PID}), ZeroCD mass-storage mode.
#
# Vendor-specific 16-byte SCSI CDB that switches the device into WiFi+BT mode:
#   FD 00 00 00 00 00 00 00 00 00 00 00 00 00 00 F2
# wrapped in a 31-byte USB Bulk-Only Command Block Wrapper:
#   dCBWSignature       55 53 42 43   ("USBC")
#   dCBWTag             12 34 56 78
#   dCBWDataTransferLen 00 00 00 00
#   bmCBWFlags          00            (host -> device)
#   bCBWLUN             00
#   bCBWCBLength        10            (16)
#   CBWCB               FD 00 ... 00 F2
#
# Managed by aic8800d80-setup.sh — local edits will be overwritten.

DefaultVendor=0x${BOOT_VID}
DefaultProduct=0x${BOOT_PID}
TargetVendor=0x${AIC_VID}
TargetProduct=0x8d80
MessageContent="555342431234567800000000000010fd0000000000000000000000000000f2"
EOF
    then changed "wrote $MS_CONF"; else skip "$MS_CONF up to date"; fi

    # AIC_V2 variant: switches on a plain SCSI eject rather than the vendor CDB,
    # and lands on vendor 368b instead of a69c.
    if write_file "/etc/usb_modeswitch.d/a69c:5721" 0644 <<'EOF'
# AIC8800D80 variant presenting as a69c:5721 in mass-storage mode.
# This one needs no vendor CDB -- a standard START_STOP_UNIT eject is enough.
# Switches to 368b:8d81, already firmware-loaded (WiFi + BT, 3 interfaces).
#
# Managed by aic8800d80-setup.sh -- local edits will be overwritten.

DefaultVendor=0xa69c
DefaultProduct=0x5721
TargetVendor=0x368b
TargetProduct=0x8d81
StandardEject=1
EOF
    then changed "wrote /etc/usb_modeswitch.d/a69c:5721"; else skip "/etc/usb_modeswitch.d/a69c:5721 up to date"; fi
}

###############################################################################
# Step: mode-switch helper
###############################################################################

install_helper() {
    step "Mode-switch helper"

    if write_file "$HELPER" 0755 <<'EOF'
#!/bin/sh
# aic8800d80-modeswitch <usb-sysfs-name>
#
# Switch one specific AIC8800D80 adapter out of ZeroCD mass-storage mode.
# Invoked from udev (via a systemd unit) with the device's sysfs name, e.g. "1-4".
#
# Re-checking the IDs here makes the operation idempotent and target-safe: if the
# device has already switched, or udev handed us a different device, we exit 0
# without touching anything.
set -eu

dev="${1:?usage: aic8800d80-modeswitch <usb-sysfs-name>}"
sys="/sys/bus/usb/devices/$dev"

[ -r "$sys/idVendor" ] && [ -r "$sys/idProduct" ] || exit 0

# Select the config from the device's own IDs, so one helper covers every
# pre-switch identity: 1111:1111 -> vendor SCSI CDB, a69c:5721 -> plain eject.
conf="/etc/usb_modeswitch.d/$(cat "$sys/idVendor"):$(cat "$sys/idProduct")"
[ -f "$conf" ] || exit 0

exec usb_modeswitch \
    -b "$(cat "$sys/busnum")" \
    -g "$(cat "$sys/devnum")" \
    -c "$conf"
EOF
    then changed "wrote $HELPER"; else skip "$HELPER up to date"; fi

    if write_file "$BT_HELPER" 0755 <<'EOF'
#!/bin/sh
# aic8800d80-btbind <usb-interface-name>
#
# Move one AIC Bluetooth interface from the generic btusb driver to aic_btusb.
#
# `softdep btusb pre: aic_btusb` only orders module *loading*. It cannot stop
# btusb from winning the probe when btusb is already loaded and registered for
# another adapter -- an internal Intel controller, say. btusb then claims the AIC
# interface first and Bluetooth fails with HCI_Reset timeouts (Opcode 0x0c03
# failed: -110). So rebind explicitly, and only ever for a69c devices.
set -eu

iface="${1:?usage: aic8800d80-btbind <usb-interface-name>}"
sys="/sys/bus/usb/devices/$iface"

[ -d "$sys" ] || exit 0
[ -r "$sys/../idVendor" ] || exit 0
case "$(cat "$sys/../idVendor")" in a69c|368b) ;; *) exit 0 ;; esac

modprobe aic_btusb 2>/dev/null || true
[ -d /sys/bus/usb/drivers/aic_btusb ] || exit 0

cur=""
[ -e "$sys/driver" ] && cur="$(basename "$(readlink -f "$sys/driver")")"
[ "$cur" = "aic_btusb" ] && exit 0

[ -n "$cur" ] && printf '%s' "$iface" > "/sys/bus/usb/drivers/$cur/unbind" 2>/dev/null || true
printf '%s' "$iface" > /sys/bus/usb/drivers/aic_btusb/bind 2>/dev/null || true
EOF
    then changed "wrote $BT_HELPER"; else skip "$BT_HELPER up to date"; fi
}

###############################################################################
# Step: systemd unit
###############################################################################

install_systemd_unit() {
    step "systemd unit"

    if ! have systemctl; then
        skip "no systemd; udev will call the helper directly"
        return
    fi

    # %i (not %I): udev passes the sysfs name "1-4", and systemd's unescaping would
    # turn that into "1/4".
    if write_file "$SYSTEMD_UNIT" 0644 <<EOF
[Unit]
Description=AIC8800D80 USB mode switch for %i
Documentation=https://github.com/olamellberg/AIC8800D80

[Service]
Type=oneshot
RemainAfterExit=no
ExecStart=${HELPER} %i
EOF
    then
        changed "wrote $SYSTEMD_UNIT"
        RELOAD_SYSTEMD=1
    else
        skip "$SYSTEMD_UNIT up to date"
    fi

    if write_file "$BT_UNIT" 0644 <<EOF
[Unit]
Description=AIC8800D80 Bluetooth driver rebind for %i

[Service]
Type=oneshot
RemainAfterExit=no
ExecStart=${BT_HELPER} %i
EOF
    then
        changed "wrote $BT_UNIT"
        RELOAD_SYSTEMD=1
    else
        skip "$BT_UNIT up to date"
    fi

    if [ "${RELOAD_SYSTEMD:-0}" = 1 ] && [ "$DRY_RUN" = 0 ]; then systemctl daemon-reload; fi
}

###############################################################################
# Step: udev rules
###############################################################################

install_udev_rules() {
    step "udev rules"

    local body id
    if have systemctl; then
        # Hand off to systemd so usb_modeswitch does not run inside the udev event
        # handler. A blocking RUN+= stalls the whole udev queue and is killed after
        # the event timeout; the original rule also matched every child subsystem
        # of the device, firing usb_modeswitch several times per plug-in.
        body=""
        for id in "${SWITCH_IDS[@]}"; do
            [ -z "$body" ] || body="$body"$'\n'
            body="${body}ACTION==\"add\", SUBSYSTEM==\"usb\", ENV{DEVTYPE}==\"usb_device\", ATTR{idVendor}==\"${id%%:*}\", ATTR{idProduct}==\"${id##*:}\", TAG+=\"systemd\", ENV{SYSTEMD_WANTS}+=\"aic8800d80-modeswitch@\$kernel.service\""
        done
    else
        body=""
        for id in "${SWITCH_IDS[@]}"; do
            [ -z "$body" ] || body="$body"$'\n'
            body="${body}ACTION==\"add\", SUBSYSTEM==\"usb\", ENV{DEVTYPE}==\"usb_device\", ATTR{idVendor}==\"${id%%:*}\", ATTR{idProduct}==\"${id##*:}\", RUN+=\"${HELPER} \$kernel\""
        done
    fi

    [ -n "$body" ] || die "internal error: no mode-switch rules generated (SWITCH_IDS empty?)"

    if write_file "$UDEV_RULES" 0644 <<EOF
# AIC8800D80 / 88M80 USB WiFi 6 + Bluetooth adapter.
# Managed by aic8800d80-setup.sh — local edits will be overwritten.

# --- ZeroCD mode switch -------------------------------------------------------
# Guarded on SUBSYSTEM/DEVTYPE so this fires once per physical device rather than
# once per child (scsi_host, block, scsi_generic, ...).
${body}

# --- Late driver binding ------------------------------------------------------
# The ID tables built above already cover 8d81 and 8d83; these are a fallback for
# the case where a module was rebuilt from unpatched sources.
ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="${AIC_VID}", ATTR{idProduct}=="8d83", RUN+="/bin/sh -c 'echo ${AIC_VID} 8d83 > /sys/bus/usb/drivers/aic8800_fdrv/new_id 2>/dev/null || true'"
ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="${AIC_VID2}", ATTR{idProduct}=="8d81", RUN+="/bin/sh -c 'echo ${AIC_VID2} 8d81 > /sys/bus/usb/drivers/aic8800_fdrv/new_id 2>/dev/null || true'"

# --- Bluetooth ----------------------------------------------------------------
# Adding the ID to aic_btusb via new_id is not enough: if btusb is already loaded
# for another adapter it claims the interface first, and new_id will not take it
# away. Rebind explicitly instead.
ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_interface", ATTRS{idVendor}=="${AIC_VID}|${AIC_VID2}", ATTR{bInterfaceClass}=="e0", ATTR{bInterfaceSubClass}=="01", ATTR{bInterfaceProtocol}=="01", TAG+="systemd", ENV{SYSTEMD_WANTS}+="aic8800d80-btbind@\$kernel.service"
ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="${AIC_VID}|${AIC_VID2}", ATTR{idProduct}=="8d81", RUN+="/usr/sbin/rfkill unblock bluetooth"
EOF
    then
        changed "wrote $UDEV_RULES"
        [ "$DRY_RUN" = 1 ] || udevadm control --reload-rules
    else
        skip "$UDEV_RULES up to date"
    fi
}

###############################################################################
# Step: modprobe / autoload configuration
###############################################################################

install_modprobe_conf() {
    step "modprobe configuration"

    # NOTE the vendor field is FOUR hex digits. The original config shipped
    # "usb:v0A69Cp8D83..." (five), which can never match a real modalias
    # (compare: usb:v8087p0026d0002dcE0dsc01dp01icE0isc01ip01in00), so the
    # aliases were dead and aic_btusb was never autoloaded.
    if write_file "$MODPROBE_CONF" 0644 <<EOF
# AIC8800D80 Bluetooth.
# Managed by aic8800d80-setup.sh — local edits will be overwritten.

# Load aic_btusb before btusb so it is registered first and has a chance at the
# probe. This does NOT prevent btusb from loading, so other Bluetooth adapters on
# this machine keep working -- but it is also NOT sufficient on its own: when
# btusb is already loaded for another adapter it still wins the race. The
# authoritative fix is the explicit rebind in aic8800d80-btbind, driven by udev.
softdep btusb pre: aic_btusb

# Autoload aic_btusb when an AIC Bluetooth interface appears.
alias usb:vA69Cp8D81d*dc*dsc*dp*icE0isc01ip01in* aic_btusb
alias usb:vA69Cp8D83d*dc*dsc*dp*icE0isc01ip01in* aic_btusb
EOF
    then changed "wrote $MODPROBE_CONF"; else skip "$MODPROBE_CONF up to date"; fi

    if write_file "$MODLOAD_CONF" 0644 <<EOF
# Managed by aic8800d80-setup.sh
aic_load_fw
aic_btusb
EOF
    then changed "wrote $MODLOAD_CONF"; else skip "$MODLOAD_CONF up to date"; fi
}

###############################################################################
# Step: activate without disturbing other hardware
###############################################################################

activate() {
    step "Activation"

    if [ "$DRY_RUN" = 1 ]; then skip "(dry run)"; return; fi

    depmod -a "$KVER"

    # Move only AIC interfaces off btusb. install.sh ran a bare `rmmod btusb`,
    # which takes down every other Bluetooth adapter in the machine (e.g. an
    # internal Intel controller) as a side effect of installing a USB dongle.
    local link name path vid moved=0
    for link in /sys/bus/usb/drivers/btusb/*:*; do
        [ -e "$link" ] || continue
        name="$(basename -- "$link")"
        path="$(readlink -f -- "$link")" || continue
        vid="$(cat "$(dirname -- "$path")/idVendor" 2>/dev/null || true)"
        case "$vid" in "$AIC_VID"|"$AIC_VID2") ;; *) continue ;; esac
        echo "$name" > /sys/bus/usb/drivers/btusb/unbind 2>/dev/null || true
        moved=$((moved + 1))
    done
    [ "$moved" -eq 0 ] || changed "unbound $moved AIC interface(s) from btusb (other adapters untouched)"

    modprobe aic_load_fw 2>/dev/null || true
    modprobe aic8800_fdrv 2>/dev/null || true
    modprobe aic_btusb 2>/dev/null || true

    # Hand every AIC Bluetooth interface to aic_btusb, whether btusb grabbed it or
    # nothing did. The helper is idempotent and ignores non-a69c devices.
    for link in /sys/bus/usb/devices/*:*; do
        [ -e "$link/bInterfaceClass" ] || continue
        [ "$(cat "$link/bInterfaceClass")" = "e0" ] || continue
        vid="$(cat "$link/../idVendor" 2>/dev/null || true)"
        case "$vid" in "$AIC_VID"|"$AIC_VID2") ;; *) continue ;; esac
        "$BT_HELPER" "$(basename -- "$link")" || true
    done

    have rfkill && rfkill unblock bluetooth 2>/dev/null || true

    # Switch any adapter that is sitting in mass-storage mode right now.
    local d id switched=0
    for d in $(usb_devices_matching "$BOOT_VID" "$BOOT_PID"); do
        info "switching $d out of mass-storage mode…"
        if "$HELPER" "$d"; then switched=$((switched + 1)); fi
    done
    if [ "$switched" -gt 0 ]; then
        changed "mode-switched $switched adapter(s)"
        sleep 3
    fi

    mkdir -p -- "$STATE_DIR"
    printf 'commit=%s\nversion=%s\nkernel=%s\n' "$RADXA_COMMIT" "$DKMS_VER" "$KVER" > "$STATE_DIR/installed"
}

###############################################################################
# Uninstall
###############################################################################

do_uninstall() {
    need_root
    step "Uninstall"

    if have dkms; then
        local entry ver
        while read -r entry; do
            [ -n "$entry" ] || continue
            ver="${entry#*/}"; ver="${ver%%[,:]*}"; ver="${ver// /}"
            info "removing dkms ${DKMS_PKG}/${ver}"
            [ "$DRY_RUN" = 1 ] || dkms remove "${DKMS_PKG}/${ver}" --all >/dev/null 2>&1 || true
            [ "$DRY_RUN" = 1 ] || rm -rf -- "/usr/src/${DKMS_PKG}-${ver}"
            CHANGED=1
        done < <(dkms status "$DKMS_PKG" 2>/dev/null | sed 's/[,:].*//' | tr -d ' ' || true)
    fi

    local f
    for f in "$MS_CONF" "$UDEV_RULES" "$MODPROBE_CONF" "$MODLOAD_CONF" "$HELPER" "$BT_HELPER" "$SYSTEMD_UNIT" "$BT_UNIT"; do
        if remove_file "$f"; then changed "removed $f"; fi
    done

    if [ "$DRY_RUN" = 0 ]; then
        rm -rf -- "$STATE_DIR"
        have systemctl && systemctl daemon-reload || true
        udevadm control --reload-rules || true
        depmod -a "$KVER" || true
        modprobe -r aic_btusb aic8800_fdrv aic_load_fw 2>/dev/null || true
        modprobe btusb 2>/dev/null || true
    fi

    info "firmware under /lib/firmware/aic8800D80 was left in place (harmless)."
    ok "uninstall complete"
}

###############################################################################
# Main
###############################################################################

main() {
    printf '%s%s%s\n' "$C_B" "AIC8800D80 / 88M80 adapter setup" "$C_N"
    printf 'pinned upstream: %s@%s\n\n' "${RADXA_REPO##*/}" "${RADXA_COMMIT:0:7}"

    if [ "$DO_STATUS_ONLY" = 1 ]; then report_status; exit 0; fi
    if [ "$DO_UNINSTALL" = 1 ]; then do_uninstall; exit 0; fi

    need_root
    [ "$DRY_RUN" = 0 ] || info "${C_C}dry run — no changes will be made${C_N}"

    preflight
    install_deps
    fetch_source
    apply_patches
    apply_local_fixups
    stage_dkms
    build_dkms
    install_firmware
    install_modeswitch_conf
    install_helper
    install_systemd_unit
    install_udev_rules
    install_modprobe_conf
    activate

    echo
    if [ "$DRY_RUN" = 1 ]; then
        if [ "$CHANGED" = 1 ]; then
            printf '%sDry run: changes are pending.%s Re-run without --check to apply.\n' "$C_Y" "$C_N"
        else
            printf '%sDry run: system already converged.%s\n' "$C_G" "$C_N"
        fi
        exit 0
    fi

    if [ "$CHANGED" = 1 ]; then
        printf '%sSetup complete — configuration changed.%s\n' "$C_G" "$C_N"
    else
        printf '%sSetup complete — already converged, nothing changed.%s\n' "$C_G" "$C_N"
    fi
    echo
    report_status
    info "If the adapter is still shown as ${BOOT_VID}:${BOOT_PID}, unplug and re-plug it."
    info "Verify with: ip link ; bluetoothctl show"
}

main "$@"
