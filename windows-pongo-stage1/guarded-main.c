/*
 * AiboOS native Windows experimental Pongo first-stage launcher.
 * Adapted integration for palera1n/openra1n. The upstream checkm8/USB
 * implementation is Apache-2.0 licensed. This file: Apache-2.0.
 *
 * Default: probe / help / offline test. NO device change automatically.
 * DFU stage is intentionally gated behind two explicit CLI switches.
 * This has NOT been tested with an actual iPhone SE (2016).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <libusb-1.0/libusb.h>
#include <openra1n_usb.h>
#include <common.h>
#include <checkm8.h>

#define APPLE_VID_LOCAL 0x05ac
#define APPLE_DFU_LOCAL 0x1227
#define APPLE_PONGO_LOCAL 0x4141

static void usage(const char *name) {
    printf("AiboOS SE (2016) Windows native Pongo first-stage RESEARCH BUILD\n");
    printf("Upstream: palera1n/openra1n @ 49fb794cde1f73cc7a00b502a42b994926c64c63\n");
    printf("Usage: %s --probe | --test-dfu-access | --selftest | --help\n",name);
    printf("       %s --load-pongo --acknowledge-experimental-risk\n",name);
    puts("NOT a real iOS replacement and NOT tested on an iPhone SE.");
    puts("Does not flash NAND or install drivers, but active exploit can fail.");
}
static int probe(int quiet) {
    libusb_context *ctx=NULL;
    int rc=libusb_init(&ctx);
    if(rc!=LIBUSB_SUCCESS) {fprintf(stderr,"USB initialization: %s\n",libusb_error_name(rc));return -1;}
    libusb_device **list=NULL;
    ssize_t n=libusb_get_device_list(ctx,&list);
    if(n<0) {fprintf(stderr,"USB list: %s\n",libusb_error_name((int)n));libusb_exit(ctx);return -1;}
    int dfu=0,pongo=0,normal=0;
    for(ssize_t i=0;i<n;i++) {
        struct libusb_device_descriptor desc={0};
        if(libusb_get_device_descriptor(list[i],&desc)!=LIBUSB_SUCCESS)continue;
        if(desc.idVendor!=APPLE_VID_LOCAL)continue;
        if(desc.idProduct==APPLE_DFU_LOCAL)dfu++;
        else if(desc.idProduct==APPLE_PONGO_LOCAL)pongo++;
        else normal++;
        if(!quiet)printf("Apple USB device %04x:%04x\n",desc.idVendor,desc.idProduct);
    }
    libusb_free_device_list(list,1);
    libusb_exit(ctx);
    if(!quiet) {
        printf("Normal/other Apple devices: %d | DFU: %d | PongoOS: %d\n",normal,dfu,pongo);
        if(normal && !dfu && !pongo)puts("This is normal iOS USB mode. Do not execute an exploit.");
        if(dfu)puts("DFU appears present. This does not prove libusb driver access.");
        if(pongo)puts("PongoOS may be running; use the separate AiboOS transfer tool, not this first stage.");
    }
    return dfu;
}

/* Device access test is READ ONLY. Does not claim interfaces, reset, send USB
 * control transfers, install drivers, enter DFU, or run checkm8.
 */
static int test_dfu_access(void) {
    libusb_context *ctx=NULL;
    int r=libusb_init(&ctx);
    if(r != LIBUSB_SUCCESS) {
        fprintf(stderr,"[ERROR] libusb_init: %s\n",libusb_error_name(r));
        return 2;
    }
    libusb_device **list=NULL;
    ssize_t count=libusb_get_device_list(ctx,&list);
    if(count<0) {
        fprintf(stderr,"[ERROR] libusb list: %s\n",libusb_error_name((int)count));
        libusb_exit(ctx);
        return 2;
    }
    int dfu=0, open_result=LIBUSB_ERROR_NOT_FOUND;
    for(ssize_t i=0;i<count;i++) {
        struct libusb_device_descriptor d={0};
        if(libusb_get_device_descriptor(list[i],&d)!=LIBUSB_SUCCESS) continue;
        if(d.idVendor != APPLE_VID_LOCAL || d.idProduct != APPLE_DFU_LOCAL) continue;
        dfu++;
        if(dfu==1) {
            libusb_device_handle *h=NULL;
            open_result=libusb_open(list[i],&h);
            if(open_result==LIBUSB_SUCCESS) {
                printf("[OK] WinUSB/libusb can OPEN DFU 05AC:1227 on this Windows PC.\n");
                printf("[NOTE] This does NOT verify exploit timing or iOS boot compatibility.\n");
                libusb_close(h);
            }
        }
    }
    libusb_free_device_list(list,1);
    libusb_exit(ctx);
    if(dfu!=1) {
        fprintf(stderr,"[STOP] Expected 1 iPhone in DFU; found %d. No changes made.\n",dfu);
        return 1;
    }
    if(open_result!=LIBUSB_SUCCESS) {
        fprintf(stderr,"[BLOCKED] libusb cannot open DFU: %s\n",libusb_error_name(open_result));
        fprintf(stderr,"[SAFE] Do not change drivers automatically; send us the error text.\n");
        return 3;
    }
    puts("[DONE] Read-only access test completed. No USB command was sent.");
    return 0;
}

int main(int argc,char **argv) {
    if(argc==2 && strcmp(argv[1],"--help")==0) {usage(argv[0]);return 0;}
    if(argc==2 && strcmp(argv[1],"--selftest")==0) {
        int pass=APPLE_VID_LOCAL==0x05ac && APPLE_DFU_LOCAL==0x1227
               && APPLE_PONGO_LOCAL==0x4141 && sizeof(uint32_t)==4;
        printf("%s Offline constants test; no USB accessed.\n",pass?"PASS":"FAIL");
        return pass?0:1;
    }
    if(argc==2 && strcmp(argv[1],"--probe")==0) {
        return probe(0)<0?1:0;
    }
    if(argc==2 && strcmp(argv[1],"--test-dfu-access")==0) {
        return test_dfu_access();
    }
    if(argc==3 && strcmp(argv[1],"--load-pongo")==0
               && strcmp(argv[2],"--acknowledge-experimental-risk")==0) {
        int present=probe(0);
        if(present!=1) {
            fprintf(stderr,"[STOP] Need exactly one DFU-mode Apple device. Found: %d\n",present);
            return 2;
        }
        fprintf(stderr,"UNTESTED A9 / WINDOWS CHECKM8 + PONGO STAGE.\n");
        fprintf(stderr,"May fail, hang, or require restoring iOS. No NAND writes are programmed.\n");
        fprintf(stderr,"PongoOS payload is from a pinned upstream revision; compatibility on this SE is unknown.\n");
        fprintf(stderr,"Do not run this unless driver setup and phone recovery were independently verified.\n");
        usb_handle_t handle;
        usb_timeout=5;
        usb_abort_timeout_min=0;
        if(!checkm8(&handle)) {
            fprintf(stderr,"[ERROR] checkm8 did not succeed.\n");
            return 3;
        }
        sleep_ms(3000);
        if(!checkm8_boot_pongo(&handle)) {
            fprintf(stderr,"[ERROR] PongoOS was not successfully transferred.\n");
            return 4;
        }
        puts("A PongoOS transfer was attempted; actual device boot remains unverified.");
        return 0;
    }
    usage(argv[0]);
    return 1;
}
