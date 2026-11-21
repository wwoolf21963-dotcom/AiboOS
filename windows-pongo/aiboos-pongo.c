/*
 * AiboOS iPhone SE 2016 - experimental Windows native PongoOS RAM uploader.
 * Protocol based on checkra1n/pongoOS/scripts/pongoterm.c (MIT).
 * No jailbreak, DFU, partitioning, flash, WSL, or driver installation code.
 * Requires PongoOS to already be running (Apple VID 05ac PID 4141).
 *
 * Copyright 2026 AiboOS contributors. MIT license.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <limits.h>
#include <libusb-1.0/libusb.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
static void Sleep(unsigned int ms) { usleep(ms * 1000u); }
#endif

#define PONGO_VID 0x05ac
#define PONGO_PID 0x4141
#define MAX_BYTES (128UL * 1024UL * 1024UL)
#define CHUNK (512UL * 1024UL)
#define TIMEOUT_MS 5000U

static void usage(const char *p) {
    printf("AiboOS SE Windows-native Pongo USB tool (EXPERIMENTAL)\n");
    printf("Usage: %s --selftest | --list | --probe\n", p);
    printf("       %s --dry-run <Samsung-S8000|TSMC-S8003> <path-to-m1n1-linux.bin>\n", p);
    printf("       %s --upload <Samsung-S8000|TSMC-S8003> <path-to-m1n1-linux.bin> --confirm-ram-boot\n", p);
    puts("No DFU/checkm8/driver setup. Requires PongoOS already running (05ac:4141).");
    puts("Upload/boot command is NEVER automatic. Do not flash this bundle.");
}

static int board_path_ok(const char *board, const char *path) {
    if(!board || !path) return 0;
    if(strcmp(board, "Samsung-S8000") != 0 && strcmp(board, "TSMC-S8003") != 0) return 0;
    if(!strstr(path, board)) return 0;
    size_t n=strlen(path);
    const char *name="m1n1-linux.bin", *end=strrchr(path,'\\'), *end2=strrchr(path,'/');
    if(end2 && (!end || end2 > end)) end=end2;
    const char *base = end ? end+1 : path;
    return (size_t)(path+n-base) == strlen(name) && strcmp(base,name)==0;
}

static int check_file(const char *board, const char *path, unsigned long *out_len) {
    if(!board_path_ok(board,path)) {
        fprintf(stderr,"[STOP] The path must contain the chosen chip folder, and end in m1n1-linux.bin.\n");
        fprintf(stderr,"[STOP] Use Samsung-S8000 or TSMC-S8003 ONLY after identifying your chip.\n");
        return 1;
    }
    FILE *f = fopen(path,"rb");
    if(!f) { perror("[STOP] Cannot open payload"); return 1; }
    if(fseek(f,0,SEEK_END)!=0) { fclose(f); return 1; }
    long n=ftell(f); fclose(f);
    if(n < 1024 || (unsigned long)n > MAX_BYTES) {
        fprintf(stderr,"[STOP] Payload size invalid: %ld\n", n); return 1;
    }
    *out_len=(unsigned long)n;
    printf("[OK] Board: %s\n[OK] Payload: %s\n[OK] Bytes: %lu\n",board,path,*out_len);
    puts("[NOTE] This does not validate device identity or payload compatibility.");
    puts("[NOTE] Run the separate Start-Readiness.cmd checksum test first.");
    return 0;
}

static int selftest(void) {
    unsigned long n=0;
    int pass=1;
    pass &= board_path_ok("Samsung-S8000","C:\\kit\\Samsung-S8000\\m1n1-linux.bin");
    pass &= board_path_ok("TSMC-S8003","D:/kit/TSMC-S8003/m1n1-linux.bin");
    pass &= !board_path_ok("TSMC-S8003","C:\\kit\\Samsung-S8000\\m1n1-linux.bin");
    pass &= !board_path_ok("Samsung-S8000","bad.bin");
    pass &= !board_path_ok("other","C:\\kit\\other\\m1n1-linux.bin");
    uint32_t l=0x01020304u;
    unsigned char *p=(unsigned char *)&l;
    pass &= (p[0]==4 && p[1]==3 && p[2]==2 && p[3]==1);
    n=MAX_BYTES;
    pass &= n>CHUNK && CHUNK>0 && TIMEOUT_MS>0;
    if(pass) puts("[PASS] Offline path, variant, size constants and little-endian protocol tests.");
    else puts("[FAIL] Offline test failed.");
    return pass ? 0 : 1;
}

static int list_apple(libusb_context *ctx) {
    libusb_device **list=NULL;
    ssize_t n=libusb_get_device_list(ctx,&list);
    if(n<0) { fprintf(stderr,"[ERROR] USB enumeration: %s\n",libusb_error_name((int)n)); return 1; }
    int apple=0, pongo=0;
    for(ssize_t i=0; i<n; i++) {
        struct libusb_device_descriptor d;
        if(libusb_get_device_descriptor(list[i],&d)!=0) continue;
        if(d.idVendor != PONGO_VID) continue;
        printf("Apple USB: %04x:%04x (bus=%u, port=%u)\n",d.idVendor,d.idProduct,
              (unsigned)libusb_get_bus_number(list[i]),(unsigned)libusb_get_device_address(list[i]));
        ++apple;
        if(d.idProduct==PONGO_PID) pongo++;
    }
    libusb_free_device_list(list,1);
    if(apple==0) puts("No Apple USB device visible through libusb. Normal iOS may use an Apple driver.");
    if(pongo==0) puts("[NOT READY] PongoOS USB mode (05ac:4141) not detected.");
    if(pongo>0) printf("[SEEN] PongoOS device count: %d. Driver access is still unverified.\n",pongo);
    return 0;
}

static int claim_pongo(libusb_context *ctx, libusb_device_handle **out) {
    libusb_device **list=NULL;
    ssize_t n=libusb_get_device_list(ctx,&list);
    if(n<0) return 1;
    int matches=0,rc=LIBUSB_ERROR_NOT_FOUND;
    libusb_device *target=NULL;
    for(ssize_t i=0; i<n; i++) {
        struct libusb_device_descriptor d;
        if(libusb_get_device_descriptor(list[i],&d)==0 && d.idVendor==PONGO_VID && d.idProduct==PONGO_PID) {
            matches++;
            target=list[i];
        }
    }
    if(matches==1) rc=libusb_open(target,out);
    libusb_free_device_list(list,1);
    if(matches!=1) {
        fprintf(stderr,"[STOP] Need exactly one PongoOS 05ac:4141 device; found %d.\n",matches);
        return 1;
    }
    if(rc!=0) {
        fprintf(stderr,"[STOP] Cannot open PongoOS: %s. Check Windows USB driver binding.\n",libusb_error_name(rc));
        return 1;
    }
    rc=libusb_claim_interface(*out,0);
    if(rc!=0) {
        fprintf(stderr,"[STOP] Cannot claim PongoOS interface: %s. No drivers were changed.\n",libusb_error_name(rc));
        libusb_close(*out); *out=NULL; return 1;
    }
    return 0;
}

static int ctrl(libusb_device_handle *h,uint8_t typ,uint8_t req,uint16_t value,
                unsigned char *buf,uint16_t len) {
    int r=libusb_control_transfer(h,typ,req,value,0,buf,len,TIMEOUT_MS);
    if(r<0 || (typ&0x80 ? r>len : r!=len)) {
        fprintf(stderr,"USB request %02x/%02x failed: %s (%d)\n",typ,req,
                r<0 ? libusb_error_name(r) : "short transfer",r);
        return -1;
    }
    return r;
}

static int wait_prompt(libusb_device_handle *h) {
    for(int attempt=0; attempt<80; attempt++) {
        unsigned char busy=1;
        if(ctrl(h,0xa1,2,0,&busy,1)<0) return 1;
        unsigned char msg[4096];
        int r=ctrl(h,0xa1,1,0,msg,sizeof msg);
        if(r<0) return 1;
        if(r>0) { fwrite(msg,1,(size_t)r,stdout); fflush(stdout); }
        if(!busy) {
            return ctrl(h,0x21,4,0xffff,NULL,0)<0;
        }
        Sleep(100);
    }
    fprintf(stderr,"[STOP] Timed out waiting for PongoOS console readiness.\n");
    return 1;
}

static int upload_and_boot(libusb_device_handle *h,const char *path,unsigned long len) {
    FILE *f=fopen(path,"rb"); if(!f) return 1;
    unsigned char size[4]={(unsigned char)len,(unsigned char)(len>>8),(unsigned char)(len>>16),(unsigned char)(len>>24)};
    if(wait_prompt(h) || ctrl(h,0x21,1,0,size,4)<0) { fclose(f); return 1; }
    unsigned char *buf=malloc(CHUNK); if(!buf) { fclose(f); return 1; }
    unsigned long remaining=len;
    int failed=0;
    while(remaining) {
        int want=remaining>CHUNK ? (int)CHUNK : (int)remaining;
        if(fread(buf,1,(size_t)want,f)!=(size_t)want) { failed=1; break; }
        int off=0;
        while(off<want) {
            int transferred=0;
            int r=libusb_bulk_transfer(h,0x02,buf+off,want-off,&transferred,15000);
            if(r!=0 || transferred<=0) {
                fprintf(stderr,"[STOP] USB bulk upload failed: %s\n",libusb_error_name(r));
                failed=1; break;
            }
            off+=transferred;
        }
        if(failed) break;
        remaining-=(unsigned long)want;
        printf("\rUploaded %lu/%lu bytes",len-remaining,len); fflush(stdout);
    }
    free(buf); fclose(f);
    puts("");
    if(failed || remaining) return 1;
    puts("[OK] PongoOS accepted USB file transfer; attempting RAM bootm command.");
    if(wait_prompt(h)) return 1;
    if(ctrl(h,0x21,4,1,NULL,0)<0) return 1;
    unsigned char cmd[]="bootm\n";
    if(ctrl(h,0x21,3,0,cmd,sizeof(cmd)-1)<0) return 1;
    puts("[SENT] bootm. THIS DOES NOT PROVE THE IPHONE BOOTED LINUX.");
    return 0;
}

int main(int argc,char **argv) {
    if(argc<2) { usage(argv[0]); return 1; }
    if(strcmp(argv[1],"--help")==0) { usage(argv[0]); return 0; }
    if(strcmp(argv[1],"--selftest")==0) return selftest();
    if(strcmp(argv[1],"--dry-run")==0) {
        unsigned long n=0;
        if(argc!=4) {usage(argv[0]);return 1;}
        return check_file(argv[2],argv[3],&n);
    }
    libusb_context *ctx=NULL;
    int rc=libusb_init(&ctx);
    if(rc!=0) {fprintf(stderr,"libusb_init failed: %s\n",libusb_error_name(rc));return 1;}
    if(strcmp(argv[1],"--list")==0 && argc==2) {
        rc=list_apple(ctx);
        libusb_exit(ctx);
        return rc;
    }
    if(strcmp(argv[1],"--probe")==0 && argc==2) {
        libusb_device_handle *h=NULL;
        rc=claim_pongo(ctx,&h);
        if(!rc) {
            puts("[OK] PongoOS USB port is accessible. No command sent.");
            libusb_release_interface(h,0);libusb_close(h);
        }
        libusb_exit(ctx);return rc;
    }
    if(strcmp(argv[1],"--upload")==0 && argc==5 && strcmp(argv[4],"--confirm-ram-boot")==0) {
        unsigned long n=0;
        if(check_file(argv[2],argv[3],&n)) {libusb_exit(ctx);return 1;}
        fprintf(stderr,
           "\n[WARNING] This is UNTESTED on the actual iPhone SE.\n"
           "It cannot change NAND directly but may fail boot and require an iOS restore.\n"
           "Chip variant MUST be independently verified. No automatic detection.\n");
        libusb_device_handle *h=NULL;
        rc=claim_pongo(ctx,&h);
        if(!rc) {
            rc=upload_and_boot(h,argv[3],n);
            libusb_release_interface(h,0);libusb_close(h);
        }
        libusb_exit(ctx);return rc;
    }
    usage(argv[0]);libusb_exit(ctx);return 1;
}
