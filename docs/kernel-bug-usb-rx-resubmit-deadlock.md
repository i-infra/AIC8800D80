# aic8800_fdrv: USB RX resubmit deadlock wedges the xHCI controller on disconnect

## Symptom

Unplugging or resetting the adapter while it is receiving under load leaves the
kernel spinning in the driver's RX path and never completing USB disconnect. dmesg
fills at 10 Hz:

```
AICWFDBG(LOGERROR)	usb submit msg rx urb fail:-19
AICWFDBG(LOGERROR)	usb submit msg rx urb fail:-19
AICWFDBG(LOGERROR)	usb submit msg rx urb fail:-19
...
```

`-19` is `-ENODEV`. Once this starts, the whole USB controller is unusable:

* `lsusb` hangs; the AIC's netdev/bus stops responding.
* `uhubctl` (any port on that hub) hangs in **D** state — it can't cut port power
  because the control transfer needs a controller that is no longer servicing the
  ring.
* `echo … > /sys/bus/pci/drivers/xhci_hcd/unbind` gets **partway** — dmesg shows
  `usb bus deregistered` then stalls at `usb 1-4: USB disconnect` — because the
  disconnect of the wedged interface never returns.
* `modprobe -r aic8800_fdrv` hangs; the module refcount can go to `-1`.
* `kworker/*:*+usb_hub_wq` sits in **D** state.

Nothing in userspace recovers it — the blocked threads are in uninterruptible
sleep holding the USB locks. Only a reboot clears it.

## Root cause

The device going away makes `usb_submit_urb()` return `-ENODEV`/`-ESHUTDOWN`. But
`usb_dev->state` can still read `USB_UP_ST` at that instant, because the USB core
has not yet invoked the driver's `.disconnect` callback. The RX resubmit path
assumed a submit failure only ever happens with the state already down, and did
three wrong things (`aicwf_usb.c`):

1. **`aicwf_usb_submit_msg_rx_urb()` returned `0` (success) on submit failure**,
   after putting the buffer back on the free list. Its caller
   `aicwf_usb_msg_rx_submit_all_urb()` loops
   `while ((buf = buf_get()) != NULL) submit(buf);` and only bailed on
   `state != USB_UP_ST`. With the state still up, it re-fetched the *same* buffer
   and re-submitted it — forever.
2. **`mdelay(100)` on the failure path.** This runs in the URB-completion (atomic)
   path — a 100 ms busy-wait in atomic context — and is what paced the spin to
   10 Hz. (The data-RX twins had the same `mdelay`.)
3. **No path forced the bus down on a device-gone error**, so the state that would
   have broken the loop was never set until `.disconnect` ran — and `.disconnect`
   could not run, because the spin was blocking it.

### The deadlock chain

```
device unplugged
  → usb_submit_urb() = -ENODEV, but usb_dev->state == USB_UP_ST
    → aicwf_usb_msg_rx_submit_all_urb() re-fetches + re-submits the same buf forever
      → RX resubmit loop never returns (mdelay(100) each pass)
        → USB core .disconnect for this interface never completes
          → usb_hub_wq blocks (D) holding the device + controller locks
            → lsusb / uhubctl / xhci_hcd unbind / modprobe -r all block behind it
              → xHCI controller wedged; reboot required
```

## Fix (`aic8800_fdrv-usb-rx-resubmit-deadlock-on-disconnect.patch`)

Minimal and self-contained -- just break the loop:

* `aicwf_usb_submit_msg_rx_urb()` returns **-1 on submit failure** instead of 0,
  so the caller sees the failure.
* `aicwf_usb_msg_rx_submit_all_urb()` stops on **any** submit failure instead of
  re-fetching the same buffer (it previously bailed only when the state was
  already down -- exactly the condition that never held during the spin).
* `mdelay(100)` is removed from all three submit paths (a 100 ms busy-wait in the
  atomic completion context).

That is sufficient: the spin was a single `submit_all` invocation looping
internally, so making the submit return an error and the caller break stops it.
The in-flight URBs then complete with `urb->status < 0`, the completion handler
already returns without resubmitting, and `cancel_work_sync()` in
`aicwf_usb_deinit()` stops the resubmit workqueue. No further resubmit occurs.

## What was deliberately NOT done, and why

An earlier draft added a helper that forced `usb_dev->state = USB_DOWN_ST` on the
first device-gone error, to make every path bail at once. **That is unsafe here**
and was removed. The RX-completion error path (`aicwf_usb.c` ~301, ~389) can take
`aicwf_deinit_sem` via `down()`, and `aicwf_usb_bus_stop()` performs the matching
`up()` **only if it does not first hit `if (usb_dev->state == USB_DOWN_ST)
return;`**. Forcing the state down from the RX path would make `bus_stop()`
early-return and skip that `up()`, orphaning the semaphore -- trading the
resubmit-spin deadlock for a semaphore deadlock. Breaking the loop is enough; the
existing teardown path (`bus_stop` -> `aicwf_usb_state_change(USB_DOWN_ST)`) sets
the state down correctly and keeps the semaphore protocol intact.

## Hardening principle

The failure family is "the driver does not survive the device going away under
load." The companion `probe-race-rx-oops-kthread-stop-hang` patch covers the
`kthread_stop()`-waits-for-a-dead-thread variant; this covers the resubmit-spin
variant. The safe shared principle: **on a submit/transfer error, stop retrying
that endpoint and let the existing teardown run** -- never busy-loop a dead
device, never `mdelay()` in atomic context, and never reach into the teardown
state machine from the data path.

## How it was found

Hit live during the RF-capture reverse-engineering work (`docs/testmode-firmware-api.md`,
Appendix P). Heavy `aic-memtool` USB interface detach/reattach churn against the
bound driver, plus an `xhci_hcd` unbind attempted as recovery, drove the adapter
into `-ENODEV` while the driver's msg-RX loop was active — reproducing the spin
above and wedging the controller. The dmesg `usb submit msg rx urb fail:-19`
flood was the tell that led straight to `aicwf_usb_submit_msg_rx_urb()`.

## Follow-up audit (r7): the `aicwf_deinit_sem` handshake

A full sweep of the driver for the same failure family found four more defects,
all in the `aicwf_deinit_sem` / `aicwf_deinit_atomic` / `wait_disconnect_cb`
handshake. Two are fixed by
`aic8800_fdrv-usb-disconnect-deinit-sem-imbalance.patch` (r7):

1. **Semaphore count inflates by +1 on every unplug-under-load.** The RX
   completion error path `down()`s the semaphore and sets
   `wait_disconnect_cb = true`; `aicwf_usb_disconnect()` then skips its own
   `down()`, `aicwf_usb_bus_stop()` `up()`s on the RX path's behalf — and
   disconnect's tail `up()`s **again**. `sema_init(...,1)` runs only once at
   module load (`rwnx_mod_init`), so the count grows permanently and the
   exclusion between disconnect teardown and `aicwf_usb_exit()` silently
   disappears (`down_timeout()` succeeds while disconnect is mid-`kfree` —
   use-after-free on `modprobe -r` after a hot unplug). Fixed: disconnect
   tracks whether it took the semaphore and only releases what it acquired.
2. **Disconnect's `!usb_dev` early return leaked the semaphore** (the check sat
   after the `down()`), which would block every later disconnect in D state —
   the same wedge symptom. Fixed: check before taking the semaphore.

Two remain **deliberately unfixed** pending a redesign (they cannot be fixed
minimally):

3. **`down()` in URB-completion (atomic) context** (`aicwf_usb.c` ~305/~393),
   guarded only by a racy `atomic_read`-then-`atomic_set` (check-then-act, not
   test-and-set) and an unlocked bool. Two completions on different CPUs, or a
   completion racing `aicwf_usb_exit()`, can both pass the guard; the loser
   sleeps in softirq — scheduling-while-atomic. Needs the handshake moved to
   process context (`atomic_cmpxchg` + workqueue), or the semaphore protocol
   replaced with a completion + owner flag.
4. **Any negative `urb->status` is treated as device-gone.** A transient
   `-EPROTO`/`-EILSEQ`/`-EOVERFLOW` permanently stops RX resubmission and sets
   `wait_disconnect_cb`, which also makes every scan return `-EBUSY`
   (`rwnx_main.c` ~2903) — one bus glitch bricks the interface until replug.
   Should distinguish fatal (`-ENODEV`/`-ENOENT`/`-ESHUTDOWN`) from transient
   statuses and resubmit on the latter.

Checked and clean during the same audit: the cmd manager (timeout + `CRASHED`
state + drain), both TX paths (bounded waits + `usb_kill_urb`), the msg-RX
completion error path, and the per-STA flow control.

## Status

Applied as a DKMS local fixup (`aic8800d80-setup.sh`, `LOCAL_REV=7`; the r6
resubmit fix plus the r7 semaphore fixes above). Not yet runtime-verified on
hardware — the machine it was found on still needs a reboot to clear the current
wedge before the rebuilt module can load. `aicwf_usb.c` with all three local
patches applied compiles clean against the running kernel's headers
(7.0.0-30-generic); the logic is verified by inspection against the two RX paths,
their callers, and the disconnect/exit teardown.
