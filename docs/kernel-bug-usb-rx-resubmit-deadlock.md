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

* Both submit helpers now **return the real error and never `mdelay()`**.
* On a device-gone error (`-ENODEV`/`-ESHUTDOWN`/`-ENOENT`/`-EPROTO`) they call a
  new `aicwf_usb_rx_urb_submit_failed()` that forces the bus to `USB_DOWN_ST`. This
  is the key hardening: it trips on the **first** `-ENODEV` at unplug — before
  `.disconnect` runs — so every RX/TX resubmit path sees the bus is down and
  stops, instead of any one of them busy-looping a dead device.
* `aicwf_usb_msg_rx_submit_all_urb()` now stops on **any** submit failure rather
  than only when the state is already down, matching the data-RX path. This alone
  breaks the infinite loop even for transient (non-device-gone) errors.

## Why this hardens against the deadlock class

The failure family here is "the driver does not survive the device going away
under load." The existing `probe-race-rx-oops-kthread-stop-hang` patch covers the
`kthread_stop()`-waits-for-a-dead-thread variant. This patch covers the
resubmit-spin variant. The shared principle applied by both: **on any sign the
device is gone, drive the bus to DOWN once and let every path notice and unwind —
never retry a transfer against a dead endpoint, and never block the disconnect
callback.** Forcing the state down at the point of first `-ENODEV` (rather than
waiting for `.disconnect`) is what makes an unplug-under-load a clean teardown.

## How it was found

Hit live during the RF-capture reverse-engineering work (`docs/testmode-firmware-api.md`,
Appendix P). Heavy `aic-memtool` USB interface detach/reattach churn against the
bound driver, plus an `xhci_hcd` unbind attempted as recovery, drove the adapter
into `-ENODEV` while the driver's msg-RX loop was active — reproducing the spin
above and wedging the controller. The dmesg `usb submit msg rx urb fail:-19`
flood was the tell that led straight to `aicwf_usb_submit_msg_rx_urb()`.

## Status

Applied as a DKMS local fixup (`aic8800d80-setup.sh`, `LOCAL_REV=6`). Not yet
runtime-verified on hardware — the machine it was found on still needs a reboot to
clear the current wedge before the rebuilt module can load. The change is
compile-clean and the logic is verified by inspection against the two RX paths and
their callers.
