// aic-memtool — read/write AIC8800 chip memory and drive its RF-test channel
// over USB, using the vendor's own DBG_* messages on the bulk message endpoints.
// Needs no kernel driver, no debugfs and no rebuild; it temporarily detaches
// whatever driver holds the vendor-specific interface and reattaches on exit.
//
//   build:  gcc -O2 -Wall -o aic-memtool aic-memtool.c -lusb-1.0
//   access: install linux/60-aic8800.rules, else run as root
//
//   read   <hex-addr> [words]         DBG_MEM_READ_REQ        (one word per txn)
//   dump   <hex-addr> <hex-bytes> [f] DBG_MEM_BLOCK_READ_REQ  (1 KiB per txn)
//   write  <hex-addr> <hex-val>       DBG_MEM_WRITE_REQ       -- see WARNING
//   writeb <hex-addr> <hex-val>       DBG_MEM_BLOCK_WRITE_REQ (use this one)
//   rftest <cmd> [argbyte...]         DBG_RFTEST_CMD_REQ      (needs lmacfw_rf)
//   reboot [delay_ms]                 DBG_START_APP_REQ type 3
//
//   AIC_RAW=1  also hexdump the raw request/reply frames
//
// WARNING: `write` (DBG_MEM_WRITE_REQ) is acknowledged by the firmware -- the
// confirmation even echoes your address and data back -- but does NOT take
// effect. Use `writeb`. This is why the driver's own regdbg hook writes a single
// word with rwnx_send_dbg_mem_block_write_req(). Always read back.
//
// Writes are otherwise unguarded: no address filtering, and the eFuse paths are
// one-time-programmable. Both write paths print before/after values.
//
// Useful addresses (see docs/testmode-firmware-api.md, and §0 for what is
// actually verified):
//   0x40500000  chip ID — revision in bits 23:16, bit 25 == 0 marks the M80
//   0x4034201C  PLL frequency, bits[29:13], 1.25 MHz/LSB   (confirmed)
//   0x4034206C  tone NCO — amp[11:0], freq[25:12], enable bit 28  (confirmed)
//   0x40342004  capture trigger; 0x40342000 source mux; 0x4034202C path select
//   0x40342228  capture status — bit 31 busy, low bits = circular write pointer
//   0x00100000  buffer the capture engine fills. NOT demonstrated to contain RF
//               samples — two controlled tone injections found no response.
//
// Verified 2026-08-30 against 368b:8d81 and a69c:8d81 (RF-test firmware):
//   [0x40500000] = 0xf9078820  -> chip_id 0x07 (U03), bit25=0 -> M80
//   SET_TXTONE measured at -34.91 dBm / 2412.000 MHz on a tinySA4
#include <libusb-1.0/libusb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define TASK_DBG                  1
#define DRV_TASK_ID               100
#define LMAC_FIRST_MSG(t)         ((t) << 10)
#define DBG_MEM_READ_REQ          (LMAC_FIRST_MSG(TASK_DBG) + 0x00)
#define DBG_MEM_READ_CFM          (LMAC_FIRST_MSG(TASK_DBG) + 0x01)
#define DBG_MEM_WRITE_REQ         (LMAC_FIRST_MSG(TASK_DBG) + 0x02)
#define DBG_MEM_WRITE_CFM         (LMAC_FIRST_MSG(TASK_DBG) + 0x03)
#define DBG_MEM_BLOCK_WRITE_REQ   (LMAC_FIRST_MSG(TASK_DBG) + 0x0B)
#define DBG_MEM_BLOCK_WRITE_CFM   (LMAC_FIRST_MSG(TASK_DBG) + 0x0C)
#define DBG_START_APP_REQ         (LMAC_FIRST_MSG(TASK_DBG) + 0x0D)
#define DBG_START_APP_CFM         (LMAC_FIRST_MSG(TASK_DBG) + 0x0E)
#define HOST_START_APP_REBOOT     3
#define DBG_RFTEST_CMD_REQ        (LMAC_FIRST_MSG(TASK_DBG) + 0x13)
#define DBG_RFTEST_CMD_CFM        (LMAC_FIRST_MSG(TASK_DBG) + 0x14)
#define DBG_MEM_BLOCK_READ_REQ    (LMAC_FIRST_MSG(TASK_DBG) + 0x23)
#define DBG_MEM_BLOCK_READ_CFM    (LMAC_FIRST_MSG(TASK_DBG) + 0x24)

/* dbg_mem_block_read_cfm.memdata[1024/4] -- the reply struct bounds the payload,
 * so do not request more than this. Whether the firmware clamps or misbehaves on
 * a larger memsize is UNTESTED: an attempt to probe it coincided with an
 * unrelated host-side driver crash, so nothing was learned about the firmware.
 * See docs/testmode-firmware-api.md Appendix L before retrying. */
#define BLOCK_MAX   1024
#define RXBUF       4096
#define PARAM_OFF   16        /* 4 hdr + id/dummy/param_len + pattern word */

static const struct { uint16_t vid, pid; } IDS[] = {
    {0x368b,0x8d81},{0xa69c,0x8d80},{0xa69c,0x8d81},{0xa69c,0x8d83},
    {0xa69c,0x8d40},{0x368b,0x8d90},{0x368b,0x8d91},{0x368b,0x8d92},
    {0x368b,0x8d99},{0,0}
};

static libusb_device_handle *h;
static uint8_t ep_tx, ep_rx;
static int raw;

static void hexdump(const char *tag, const unsigned char *b, int n)
{
    printf("%s (%d bytes):", tag, n);
    for (int i = 0; i < n; i++) {
        if (i % 16 == 0) printf("\n  %04x: ", i);
        printf("%02x ", b[i]);
    }
    printf("\n");
}

/* Build and send one lmac_msg, then read the reply. Returns reply length. */
static int xfer(uint16_t id, const void *param, int param_len,
                unsigned char *in, int in_sz, uint16_t expect)
{
    unsigned char buf[8 + 8 + 1024];
    int len = 8 + param_len;                 /* lmac_msg header + param */
    int total = len + 8;                     /* + 4-byte framing + dummy word */

    if (total > (int)sizeof buf) return -1;
    memset(buf, 0, total);
    buf[0] = (len + 4) & 0xff;
    buf[1] = ((len + 4) >> 8) & 0x0f;
    buf[2] = 0x11;
    buf[3] = 0x00;
    buf[8]  = id & 0xff;      buf[9]  = id >> 8;
    buf[10] = TASK_DBG;       buf[11] = 0;
    buf[12] = DRV_TASK_ID;    buf[13] = 0;
    buf[14] = param_len;      buf[15] = param_len >> 8;
    memcpy(&buf[16], param, param_len);

    int done = 0, r;
    if ((r = libusb_bulk_transfer(h, ep_tx, buf, total, &done, 1000))) {
        fprintf(stderr, "TX failed: %s\n", libusb_error_name(r));
        return -1;
    }
    if (raw) hexdump("request", buf, total);

    /* The firmware emits unsolicited indications on this same endpoint --
     * MM_CHANNEL_SURVEY_IND (0x004F) arrives continuously, for one. Skip
     * anything that is not the confirmation we asked for rather than
     * mistaking it for our reply. */
    for (int attempt = 0; attempt < 16; attempt++) {
        int got = 0;
        if ((r = libusb_bulk_transfer(h, ep_rx, in, in_sz, &got, 3000))) {
            fprintf(stderr, "RX failed: %s\n", libusb_error_name(r));
            return -1;
        }
        if (raw) hexdump("reply", in, got);
        if (got >= 6) {
            uint16_t rid;
            memcpy(&rid, in + 4, 2);
            if (rid == expect) return got;
            if (raw) fprintf(stderr, "  (skipping unsolicited msg id 0x%04x)\n", rid);
        }
    }
    fprintf(stderr, "no reply with id 0x%04x after 16 messages\n", expect);
    return -1;
}

static uint32_t p32(const unsigned char *in, int i)
{ uint32_t v; memcpy(&v, in + PARAM_OFF + 4 * i, 4); return v; }

static int cmd_read(uint32_t addr, int count)
{
    unsigned char in[RXBUF];
    for (int i = 0; i < count; i++, addr += 4) {
        if (xfer(DBG_MEM_READ_REQ, &addr, 4, in, sizeof in, DBG_MEM_READ_CFM) < 0) return 1;
        printf("[0x%08x] = 0x%08x\n", p32(in, 0), p32(in, 1));
    }
    return 0;
}

static int cmd_write(uint32_t addr, uint32_t val)
{
    unsigned char in[RXBUF];
    struct { uint32_t addr, data; } req = { addr, val };

    if (xfer(DBG_MEM_READ_REQ, &addr, 4, in, sizeof in, DBG_MEM_READ_CFM) < 0) return 1;
    printf("before: [0x%08x] = 0x%08x\n", p32(in, 0), p32(in, 1));

    if (xfer(DBG_MEM_WRITE_REQ, &req, 8, in, sizeof in, DBG_MEM_WRITE_CFM) < 0) return 1;

    if (xfer(DBG_MEM_READ_REQ, &addr, 4, in, sizeof in, DBG_MEM_READ_CFM) < 0) return 1;
    printf("after : [0x%08x] = 0x%08x\n", p32(in, 0), p32(in, 1));
    return 0;
}

/* The driver's own regdbg debugfs hook writes even a single word with
 * rwnx_send_dbg_mem_block_write_req(), not DBG_MEM_WRITE_REQ -- and against
 * this firmware the single-word write is acknowledged but has no effect. */
static int cmd_writeb(uint32_t addr, uint32_t val)
{
    unsigned char in[RXBUF];
    struct { uint32_t addr, size, data; } req = { addr, 4, val };

    if (xfer(DBG_MEM_READ_REQ, &addr, 4, in, sizeof in, DBG_MEM_READ_CFM) < 0) return 1;
    printf("before: [0x%08x] = 0x%08x\n", p32(in, 0), p32(in, 1));

    if (xfer(DBG_MEM_BLOCK_WRITE_REQ, &req, 12, in, sizeof in,
             DBG_MEM_BLOCK_WRITE_CFM) < 0) return 1;

    if (xfer(DBG_MEM_READ_REQ, &addr, 4, in, sizeof in, DBG_MEM_READ_CFM) < 0) return 1;
    printf("after : [0x%08x] = 0x%08x\n", p32(in, 0), p32(in, 1));
    return 0;
}

/* DBG_RFTEST_CMD_REQ: struct { u32 cmd; u32 argc; u8 argv[30]; }, sizeof 40.
 * Command ids are the RFTEST enum in aic_priv_cmd.c (SET_TX=0 ... GET_RSSI=0x52).
 * Reply is struct dbg_rftest_cmd_cfm { u32 rftest_result[32]; }. */
static int cmd_rftest(uint32_t cmd, const unsigned char *args, int nargs, int nshow)
{
    unsigned char in[RXBUF];
    struct { uint32_t cmd, argc; unsigned char argv[30]; } req;

    memset(&req, 0, sizeof req);
    req.cmd = cmd;
    req.argc = nargs;
    if (nargs > 0) memcpy(req.argv, args, nargs > 30 ? 30 : nargs);

    printf("rftest cmd=%u argc=%d", cmd, nargs);
    for (int i = 0; i < nargs; i++) printf(" %02x", args[i]);
    printf("\n");

    int got = xfer(DBG_RFTEST_CMD_REQ, &req, 40, in, sizeof in, DBG_RFTEST_CMD_CFM);
    if (got < 0) return 1;
    int avail = (got - PARAM_OFF) / 4;
    if (nshow > avail) nshow = avail;
    for (int i = 0; i < nshow; i++)
        printf("  result[%d] = 0x%08x (%u)\n", i, p32(in, i), p32(in, i));
    return 0;
}

/* Reboot the chip: DBG_START_APP_REQ { bootaddr, boottype }, where for
 * HOST_START_APP_REBOOT bootaddr is reused as a delay in ms. This is what
 * rwnx_send_reboot() sends. The device drops off the bus and re-enumerates,
 * so aic_load_fw probes it afresh and re-uploads firmware -- which is how a
 * changed `testmode` module parameter actually takes effect. */
static int cmd_reboot(uint32_t delay_ms)
{
    unsigned char in[RXBUF];
    struct { uint32_t bootaddr, boottype; } req = { delay_ms, HOST_START_APP_REBOOT };

    printf("rebooting chip (delay %u ms) -- device will re-enumerate\n", delay_ms);
    int got = xfer(DBG_START_APP_REQ, &req, 8, in, sizeof in, DBG_START_APP_CFM);
    if (got < 0) {
        printf("  no CFM -- expected if the chip resets before replying\n");
        return 0;
    }
    printf("  bootstatus = 0x%08x\n", p32(in, 0));
    return 0;
}

static int cmd_dump(uint32_t addr, uint32_t nbytes, const char *path)
{
    unsigned char in[RXBUF];
    FILE *f = NULL;
    uint32_t done_bytes = 0;
    int txns = 0;

    if (path && !(f = fopen(path, "wb"))) { perror(path); return 1; }

    while (done_bytes < nbytes) {
        uint32_t chunk = nbytes - done_bytes;
        if (chunk > BLOCK_MAX) chunk = BLOCK_MAX;
        if (chunk > 1024) {                  /* belt and braces: see BLOCK_MAX */
            fprintf(stderr, "refusing block size %u > 1024\n", chunk);
            if (f) fclose(f);
            return 1;
        }
        struct { uint32_t addr, size; } req = { addr + done_bytes, chunk };

        int got = xfer(DBG_MEM_BLOCK_READ_REQ, &req, 8, in, sizeof in,
                       DBG_MEM_BLOCK_READ_CFM);
        if (got < 0) { if (f) fclose(f); return 1; }
        txns++;
        uint32_t rsize = p32(in, 1);
        if (rsize > chunk) rsize = chunk;
        const unsigned char *data = in + PARAM_OFF + 8;
        int avail = got - (PARAM_OFF + 8);
        if (avail < 0) avail = 0;
        if ((int)rsize > avail) rsize = avail;
        if (rsize == 0) { fprintf(stderr, "empty block reply, stopping\n"); break; }

        if (f) fwrite(data, 1, rsize, f);
        else for (uint32_t i = 0; i + 4 <= rsize; i += 4) {
            uint32_t w; memcpy(&w, data + i, 4);
            printf("[0x%08x] = 0x%08x\n", addr + done_bytes + i, w);
        }
        done_bytes += rsize;
    }
    if (f) fclose(f);
    fprintf(stderr, "read %u bytes in %d transaction(s)%s%s\n",
            done_bytes, txns, path ? " -> " : "", path ? path : "");
    return 0;
}

static void usage(const char *p)
{
    fprintf(stderr,
        "usage: %s read   <hex-addr> [words]\n"
        "       %s dump   <hex-addr> <hex-bytes> [outfile]\n"
        "       %s write  <hex-addr> <hex-val>   (DBG_MEM_WRITE_REQ)\n"
        "       %s writeb <hex-addr> <hex-val>   (DBG_MEM_BLOCK_WRITE_REQ)\n"
        "       %s rftest <cmd> [argbyte...]     (DBG_RFTEST_CMD_REQ)\n"
        "       %s reboot [delay_ms]             (DBG_START_APP_REQ type 3)\n", p, p, p, p, p, p);
}

int main(int argc, char **argv)
{
    if (argc < 3) { usage(argv[0]); return 2; }
    raw = getenv("AIC_RAW") != NULL;

    libusb_context *ctx = NULL;
    if (libusb_init(&ctx)) { fprintf(stderr, "libusb_init failed\n"); return 1; }

    libusb_device **list, *dev = NULL;
    struct libusb_device_descriptor dd;
    ssize_t n = libusb_get_device_list(ctx, &list);
    for (ssize_t i = 0; i < n && !dev; i++) {
        if (libusb_get_device_descriptor(list[i], &dd)) continue;
        for (int k = 0; IDS[k].vid; k++)
            if (dd.idVendor == IDS[k].vid && dd.idProduct == IDS[k].pid) { dev = list[i]; break; }
    }
    if (!dev) { fprintf(stderr, "no AIC device found\n"); libusb_free_device_list(list, 1); return 1; }
    fprintf(stderr, "device %04x:%04x\n", dd.idVendor, dd.idProduct);

    struct libusb_config_descriptor *cfg;
    if (libusb_get_active_config_descriptor(dev, &cfg)) { fprintf(stderr, "no config desc\n"); return 1; }
    int ifnum = -1; uint8_t eo[2] = {0,0}, ei[2] = {0,0}; int no = 0, ni = 0;
    for (int i = 0; i < cfg->bNumInterfaces; i++) {
        const struct libusb_interface_descriptor *id = &cfg->interface[i].altsetting[0];
        if (id->bInterfaceClass != 0xff) continue;
        ifnum = id->bInterfaceNumber;
        for (int e = 0; e < id->bNumEndpoints; e++) {
            const struct libusb_endpoint_descriptor *ed = &id->endpoint[e];
            if ((ed->bmAttributes & 3) != LIBUSB_TRANSFER_TYPE_BULK) continue;
            if (ed->bEndpointAddress & 0x80) { if (ni < 2) ei[ni++] = ed->bEndpointAddress; }
            else                             { if (no < 2) eo[no++] = ed->bEndpointAddress; }
        }
        break;
    }
    libusb_free_config_descriptor(cfg);
    if (ifnum < 0) { fprintf(stderr, "no vendor-specific interface\n"); return 1; }
    /* mirror the driver: messages ride the SECOND bulk pair when it exists */
    ep_tx = (no > 1) ? eo[1] : eo[0];
    ep_rx = (ni > 1) ? ei[1] : ei[0];
    fprintf(stderr, "interface %d  msg_out=0x%02x msg_in=0x%02x\n", ifnum, ep_tx, ep_rx);

    if (libusb_open(dev, &h)) { fprintf(stderr, "open failed (permissions? see 60-aic8800.rules)\n"); return 1; }
    libusb_free_device_list(list, 1);

    int had_kd = libusb_kernel_driver_active(h, ifnum);
    if (had_kd == 1 && libusb_detach_kernel_driver(h, ifnum)) { fprintf(stderr, "detach failed\n"); return 1; }
    int rc = 1;
    if (libusb_claim_interface(h, ifnum)) { fprintf(stderr, "claim failed\n"); goto out; }

    if      (!strcmp(argv[1], "read"))  rc = cmd_read(strtoul(argv[2],NULL,16), argc > 3 ? atoi(argv[3]) : 1);
    else if (!strcmp(argv[1], "write") && argc > 3)
                                        rc = cmd_write(strtoul(argv[2],NULL,16), strtoul(argv[3],NULL,16));
    else if (!strcmp(argv[1], "writeb") && argc > 3)
                                        rc = cmd_writeb(strtoul(argv[2],NULL,16), strtoul(argv[3],NULL,16));
    else if (!strcmp(argv[1], "reboot"))
        rc = cmd_reboot(argc > 2 ? strtoul(argv[2], NULL, 0) : 2000);
    else if (!strcmp(argv[1], "rftest")) {
        unsigned char a[30]; int n = 0;
        for (int k = 3; k < argc && n < 30; k++) a[n++] = strtoul(argv[k], NULL, 16);
        rc = cmd_rftest(strtoul(argv[2], NULL, 0), a, n, 4);
    }
    else if (!strcmp(argv[1], "dump")  && argc > 3)
                                        rc = cmd_dump(strtoul(argv[2],NULL,16), strtoul(argv[3],NULL,16),
                                                      argc > 4 ? argv[4] : NULL);
    else { usage(argv[0]); rc = 2; }

    libusb_release_interface(h, ifnum);
out:
    if (had_kd == 1) libusb_attach_kernel_driver(h, ifnum);
    libusb_close(h);
    libusb_exit(ctx);
    return rc;
}
