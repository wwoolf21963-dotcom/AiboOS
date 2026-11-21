/*
 * AiboOS SE (2016) - read-only DFU identity inspection.
 * This utility does NOT perform a DFU exploit, alter USB configuration,
 * claim interfaces, reset, flash, reboot, or change device drivers.
 * The ECID / actual serial number is NEVER printed.
 * Copyright 2026 AiboOS contributors - MIT license.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <libusb-1.0/libusb.h>

#define APPLE_VID 0x05ac
#define DFU_PID 0x1227

static const char *find_ci(const char *text,const char *needle) {
    if(!text || !needle || !needle[0])return NULL;
    size_t len=strlen(needle);
    for(const char *p=text;*p;p++) {
        size_t i=0;
        while(i<len && p[i] &&
              tolower((unsigned char)p[i])==tolower((unsigned char)needle[i]))i++;
        if(i==len)return p;
    }
    return NULL;
}

static int extract_after(const char *source,const char *field,
                         char *out,size_t capacity,char close) {
    if(capacity<2)return 0;
    const char *s=find_ci(source,field);
    if(!s)return 0;
    s+=strlen(field);
    size_t n=0;
    while(s[n] && n+1<capacity) {
        unsigned char c=(unsigned char)s[n];
        if((close && c==(unsigned char)close) || isspace(c))break;
        if(!(isalnum(c) || c=='.' || c=='-' || c=='_'))return 0;
        out[n]=(char)c;
        ++n;
    }
    out[n]=0;
    return n>0;
}
static int same_ci(const char *a,const char *b) {
    while(*a && *b) {
        if(tolower((unsigned char)*a)!=tolower((unsigned char)*b))return 0;
        ++a; ++b;
    }
    return *a==0 && *b==0;
}
static int inspect_identity(const char *raw) {
    char chip[16]={0},iboot[80]={0};
    int gotchip=extract_after(raw,"CPID:",chip,sizeof(chip),'\0');
    int gotboot=extract_after(raw,"SRTG:[",iboot,sizeof(iboot),']');
    if(gotchip)printf("[CHIP] CPID: %s\n",chip);
    else puts("[MISSING] CPID field was not available in USB string.");
    if(gotboot)printf("[BOOTROM] SRTG: %s\n",iboot);
    else puts("[MISSING] iBoot/SRTG field was not available in USB string.");
    if(!gotchip || !gotboot) {
        puts("[STOP] Identity incomplete; do not run exploit.");
        return 1;
    }
    if(same_ci(chip,"8000") && same_ci(iboot,"iBoot-2234.0.0.3.3")) {
        puts("[MATCH] Samsung A9 S8000 / expected upstream iBoot signature.");
        return 0;
    }
    if(same_ci(chip,"8003") && same_ci(iboot,"iBoot-2234.0.0.2.22")) {
        puts("[MATCH] TSMC A9 S8003 / expected upstream iBoot signature.");
        return 0;
    }
    puts("[STOP] Identity does not match one of the two expected SE A9 signatures.");
    return 1;
}
static int selftest(void) {
    const char *a="CPID:8000 CPRV:20 ECID:0123456789 SRTG:[iBoot-2234.0.0.3.3]";
    const char *b="CPID:8000 CPRV:20 ECID:0123456789 SRTG:[iBOOT-2234.0.0.3.3]";
    const char *c="CPID:8003 ECID:0123456789 SRTG:[iBoot-2234.0.0.2.22]";
    const char *d="CPID:8000 ECID:0123456789 SRTG:[other]";
    int ok=inspect_identity(a)==0 && inspect_identity(b)==0 &&
           inspect_identity(c)==0 && inspect_identity(d)!=0;
    puts(ok?"[PASS] Offline identity parsing selftests. No USB accessed.":
            "[FAIL] Identity parser selftest.");
    return ok?0:1;
}
static int read_utf16_descriptor(libusb_device_handle *h,unsigned char index,
                                 char *out,size_t capacity) {
    unsigned char raw[254]={0};
    int n=libusb_get_string_descriptor(h,index,0x0409,raw,sizeof(raw));
    if(n<4 || raw[1]!=LIBUSB_DT_STRING)return n<0?n:LIBUSB_ERROR_IO;
    size_t count=(size_t)(n-2)/2;
    if(count>=capacity) count=capacity-1;
    for(size_t i=0;i<count;i++) {
        if(raw[2+2*i+1]!=0)return LIBUSB_ERROR_IO;
        out[i]=(char)raw[2+2*i];
    }
    out[count]=0;
    return (int)count;
}
int main(int argc,char **argv) {
    if(argc!=2) {
        puts("Usage: aiboos-dfu-identity.exe --inspect | --selftest");
        return 2;
    }
    if(strcmp(argv[1],"--selftest")==0)return selftest();
    if(strcmp(argv[1],"--inspect")!=0) {
        puts("Usage: aiboos-dfu-identity.exe --inspect | --selftest");
        return 2;
    }
    puts("AiboOS iPhone SE DFU identity check (READ ONLY)");
    puts("No exploit, driver changes, USB configuration changes or NAND writes.");
    libusb_context *ctx=NULL;
    int status=libusb_init(&ctx);
    if(status!=LIBUSB_SUCCESS) {
        fprintf(stderr,"[BLOCKED] USB init: %s\n",libusb_error_name(status));return 2;
    }
    libusb_device **list=NULL;
    ssize_t count=libusb_get_device_list(ctx,&list);
    if(count<0) {
        fprintf(stderr,"[BLOCKED] USB enumeration: %s\n",libusb_error_name((int)count));
        libusb_exit(ctx);return 2;
    }
    libusb_device *target=NULL;
    int found=0;
    struct libusb_device_descriptor descriptor;
    for(ssize_t i=0;i<count;i++) {
        struct libusb_device_descriptor d={0};
        if(libusb_get_device_descriptor(list[i],&d)!=LIBUSB_SUCCESS)continue;
        if(d.idVendor==APPLE_VID && d.idProduct==DFU_PID) {
            ++found;
            target=list[i];descriptor=d;
        }
    }
    if(found!=1) {
        printf("[STOP] Need exactly one Apple DFU 05ac:1227 device; found %d.\n",found);
        libusb_free_device_list(list,1);libusb_exit(ctx);
        return 1;
    }
    printf("[USB] Apple DFU %04x:%04x detected.\n",
           descriptor.idVendor,descriptor.idProduct);
    libusb_device_handle *h=NULL;
    status=libusb_open(target,&h);
    if(status!=LIBUSB_SUCCESS) {
        printf("[BLOCKED] Cannot open DFU: %s\n",libusb_error_name(status));
        libusb_free_device_list(list,1);libusb_exit(ctx);
        return 2;
    }
    char serial[256]={0};
    int n=descriptor.iSerialNumber?
          libusb_get_string_descriptor_ascii(h,descriptor.iSerialNumber,
                       (unsigned char *)serial,sizeof(serial)-1):
          LIBUSB_ERROR_NOT_FOUND;
    if(n<0 && descriptor.iSerialNumber) {
        printf("[USB] Standard ASCII descriptor read failed: %s; trying UTF16 descriptor.\n",
               libusb_error_name(n));
        n=read_utf16_descriptor(h,descriptor.iSerialNumber,serial,sizeof(serial));
    }
    int result=2;
    if(n<0) {
        printf("[BLOCKED] DFU identity descriptor could not be read: %s\n",
               libusb_error_name(n));
        puts("[NOTE] The device opening successfully does not prove standard USB reads work.");
    } else if(n==0) {
        puts("[BLOCKED] USB serial descriptor is empty.");
    } else {
        if(n>=(int)sizeof(serial))n=(int)sizeof(serial)-1;
        serial[n]=0;
        result=inspect_identity(serial);
        puts("[PRIVACY] Full USB serial and ECID intentionally hidden.");
    }
    libusb_close(h);
    libusb_free_device_list(list,1);
    libusb_exit(ctx);
    puts("[DONE] No DFU state or iPhone storage was changed.");
    return result;
}
