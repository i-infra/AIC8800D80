# Kernel bug: RX kthread oops on rebind, then `kthread_stop()` hangs the USB subtree

**Status:** fixed locally by
[`linux/patches/aic8800_fdrv-probe-race-rx-oops-kthread-stop-hang.patch`](../linux/patches/aic8800_fdrv-probe-race-rx-oops-kthread-stop-hang.patch),
applied by `aic8800d80-setup.sh` (`LOCAL_REV=4`). Not in upstream
radxa-pkg/aic8800 as of `df4c783`.

**Affects:** `aic8800_fdrv` (USB). Observed on kernel 7.0.0-30 (Ubuntu),
CHUWI MiniBook X, AIC8800D80 clone at `a69c:8d81`; the code paths are
version-independent and go back to the original AICSemi drop.

## Symptom

After an unbind/bind cycle, `usbreset`, or a probe that fails for any reason
while the chip is still talking:

- `lsusb` hangs partway through its output (reading `manufacturer` on the
  wedged device blocks in the kernel).
- Devices you unplug from the same hub subtree stay in `/sys/bus/usb/devices/`
  forever; nothing under that hub can be enumerated or removed.
- `ps` shows `usbreset` (or `modprobe -r`, or a `probe` worker) in `D` state
  in `usbdev_open`, plus `kworker/*+usb_hub_wq` threads also in `D`.
- `unbind`/`bind`/`remove`/`reset` on the xHCI controller also hang, because
  they need the same device lock.
- The kernel is tainted `D` (an oops happened). Only a reboot clears it, and
  the reboot itself may hang on USB teardown (keep `sysrq` enabled).

## What the log shows

```
BUG: unable to handle page fault for address: 0000000000003458
Oops: 0000 [#1] SMP NOPTI
CPU: 3 PID: 406034 Comm: aicwf_msg_busrx Tainted: G OE
RIP: 0010:rwnx_rx_handle_msg+0x13/0xa0 [aic8800_fdrv]
RDI: 0000000000000000                          <-- rwnx_hw == NULL
Call Trace:
  aicwf_process_msg_rxframes  [aic8800_fdrv]
  usb_msg_busrx_thread        [aic8800_fdrv]
  kthread
note: aicwf_msg_busrx[406034] exited with irqs disabled

... 4 s later (command timeout) ...

cmd_mgr_queue cmd timed-out  cmd:1024-DBG_MEM_READ_REQ
AICWFDBG(LOGERROR) err_lmac_reqs
AICWFDBG(LOGERROR) aicwf_rwnx_usb_platform_init err -1

refcount_t: addition on 0; use-after-free.
WARNING: lib/refcount.c:25 at refcount_warn_saturate, CPU#1: probe/405999
Call Trace:
  kthread_stop
  aicwf_rx_deinit    [aic8800_fdrv]
  aicwf_bus_deinit   [aic8800_fdrv]
  aicwf_usb_probe    [aic8800_fdrv]
  usb_probe_interface
```

`0x3458` is `offsetof(struct rwnx_hw, cmd_mgr)`: the RX thread dereferenced
a NULL `rwnx_hw`.

## Root cause — two bugs that combine

### 1. RX runs before `rwnx_hw` exists (the oops)

`aicwf_usb_probe()` does, in order:

```
aicwf_bus_init()                 -> kthread_run(usb_busrx_thread / usb_msg_busrx_thread)
aicwf_bus_start()                -> submits the bulk-IN URBs; chip can now deliver
aicwf_rwnx_usb_platform_init()   -> rwnx_cfg80211_init(): wiphy_new(), and only
                                    HERE:  usbdev->rwnx_hw = rwnx_hw
```

Between `aicwf_bus_start()` and that assignment the RX threads are live and
`usbdev->rwnx_hw` is NULL. Every RX path hands `rx_priv->usbdev->rwnx_hw`
straight to code that dereferences it without checking:

- `rwnx_rx_handle_msg(rwnx_hw, msg)` → `rwnx_hw->cmd_mgr->msgind(...)`
- `aicwf_usb_host_tx_cfm_handler(&rwnx_hw->usb_env, ...)` — pointer arithmetic
  on NULL yields a small bogus non-NULL pointer that the callee then uses
- `rwnx_rxdataind_aicwf(rwnx_hw, skb, ...)`

The only guard present is `bus_if->state != USB_DOWN_ST`, which does not cover
"not up yet".

In normal cold-plug this window is silent because the chip has nothing to say
until the host sends the first command. It becomes reachable when the chip
still has a queued confirmation from the *previous* driver instance —
exactly what a fast unbind/bind, `usbreset`, or a repeated failed probe
produces (the log preceding the oops shows six `phy11`…`phy16` re-creations
and a `rwnx_send_msg bus is down` teardown 180 ms before the crash). The
stale `CFG_CMD_RSP` arrives on the msg endpoint, `rwnx_rx_handle_msg(NULL, …)`
runs, the thread oopses.

`rwnx_rx_handle_msg` also indexed `msg_hdlrs[MSG_T(id)][MSG_I(id)]` with
firmware-supplied values and no bounds check; a corrupt or foreign message id
is an out-of-bounds read of function pointers. The patch adds the check while
it is there.

### 2. `kthread_stop()` on a thread that died in an oops (the hang)

The DBG_MEM_READ_REQ sent moments later never gets its confirmation processed
(the thread that would process it is dead), so it times out, `err_lmac_reqs`
fires, probe fails, and the cleanup path runs
`aicwf_bus_deinit() → aicwf_rx_deinit() → kthread_stop(msg_busrx_thread)`.

`kthread_stop()` takes a reference on the task and then waits on
`kthread->exited`, which is completed only when the thread function
*returns*. A thread killed by an oops goes through `make_task_dead()` →
`do_exit()`; it never returns, the completion never fires, and because
kthreads autoreap the `task_struct` was already freed — hence
`refcount_t: addition on 0; use-after-free` from `get_task_struct()` inside
`kthread_stop()`. The wait is uninterruptible and permanent.

This happens inside `usb_probe_interface()`, i.e. with the USB device lock
held. Everything that later needs that lock — `usbdev_open` (`lsusb`,
`usbreset`), the hub workqueue processing a disconnect on the same hub,
`usb_remove_hcd` — queues up behind it in `D` state. That is what turns a
driver bug into "my USB controller is stuck".

## The fix

All in `aic8800_fdrv`, no behavioural change on the normal path:

| File | Change |
|---|---|
| `rwnx_msg_rx.c` | `rwnx_rx_handle_msg()`: drop the message with an error log if `rwnx_hw`, `cmd_mgr` or `msgind` is NULL; range-check `MSG_T`/`MSG_I` against a new `msg_hdlrs_len[]` table before indexing. |
| `aicwf_txrxif.c` | Every USB RX site: guard `aicwf_usb_host_tx_cfm_handler(&rwnx_hw->usb_env)` and `rwnx_rxdataind_aicwf(rwnx_hw, skb)` on `rwnx_hw != NULL` (the data skb is freed when dropped). |
| `aicwf_txrxif.c` | `aicwf_bus_init()`: `get_task_struct()` on each successfully created kthread so its `exit_state` can be read safely later. |
| `aicwf_txrxif.h` | New `aicwf_kthread_stop_safe(task, name)`: if the task has `exit_state` set or `PF_EXITING` in `flags` (set at the top of `do_exit()`, so a thread mid-death is caught too), log and **skip** `kthread_stop()` instead of blocking forever; always `put_task_struct()`. Both fields exist on every kernel the driver supports. |
| `aicwf_txrxif.c` | `aicwf_bus_deinit()` / `aicwf_rx_deinit()` use the safe stop for the three USB threads. |
| `aicwf_usb.c` | The three thread loops (`usb_bustx_thread`, `usb_busrx_thread`, `usb_msg_busrx_thread`) now honour `kthread_should_stop()` after their wait. Upstream had this `#if 0`'d, so a thread only ever exited on `BUS_DOWN_ST` — which the probe-failure path never sets, leaving `complete_all()` + `kthread_stop()` to spin. |

Fix 1 removes the trigger seen here, but narrows the window rather than
closing it: `usbdev->rwnx_hw` is assigned partway through
`rwnx_cfg80211_init()` with substantial initialisation still to follow. The
message path is safe across that gap (`cmd_mgr` and `msgind` were set up in
`aicwf_bus_init()` and the guard checks them), but a *data* frame arriving
then reaches `rwnx_rxdataind_aicwf()` with a partially-built `rwnx_hw`. No
data can be in flight before a vif exists, so this is not reachable in
practice — it just is not proven.

Fix 2 is the containment: if the RX
thread dies for any other reason in future, probe/disconnect now fails
cleanly (`aicwf: aicwf_msg_busrx_thread (pid N) already died; skipping
kthread_stop to avoid hang` in dmesg) instead of taking the USB bus with it.

## Verifying

After `sudo ./aic8800d80-setup.sh --force-rebuild` and a reboot:

```
modinfo aic8800_fdrv | grep -i version      # DKMS version should end in .r4
grep -c aicwf_kthread_stop_safe /usr/src/aic8800d80-*/aic8800_fdrv/aicwf_txrxif.h   # 1
```

Stress the original trigger — a rapid unbind/bind loop should now log
`msg id 0x... dropped, driver not ready` at worst, never an oops:

```
D=$(basename "$(readlink -f /sys/bus/usb/drivers/aic8800_fdrv/*:*)")   # e.g. 1-6.4:1.2
for i in $(seq 5); do
  echo "$D" | sudo tee /sys/bus/usb/drivers/aic8800_fdrv/unbind
  echo "$D" | sudo tee /sys/bus/usb/drivers/aic8800_fdrv/bind
done
sudo dmesg | grep -E "aicwf|rwnx_rx_handle_msg|BUG|refcount" | tail
```

## If you are already wedged

Nothing in userspace can release a `kthread_stop()` wait. Do not try
`rmmod aic8800_fdrv` (kworkers are executing inside it) or unbinding
`xhci_hcd` (it needs the same lock and will hang too). Enable sysrq first so
the reboot has an escape hatch, then reboot:

```
echo 1 | sudo tee /proc/sys/kernel/sysrq
sudo systemctl reboot        # if it stalls on USB teardown: Alt+SysRq R E I S U B
```

## Upstreaming

The patch is a plain `-p1` diff against radxa-pkg/aic8800 `df4c783` and
applies without offsets to the pristine tree. It is worth sending upstream;
both halves are generic AICSemi-driver bugs, not clone-specific.
