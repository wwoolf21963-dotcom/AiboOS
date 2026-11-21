/* Read-only Linux power_supply telemetry. No charger register or policy writes. */
#ifndef AIBOOS_POWER_H
#define AIBOOS_POWER_H
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <glob.h>
#include <errno.h>
struct aiboos_power {
    int capacity, temp_decic;
    int battery, temp_valid;
    enum { POWER_UNKNOWN, POWER_CHARGING, POWER_DISCHARGING, POWER_FULL, POWER_NOT_CHARGING } status;
};
static int power_read(const char *dir,const char *key,char *out,size_t size) {
    char path[4096];
    int n=snprintf(path,sizeof(path),"%s/%s",dir,key);
    if(n<0||(size_t)n>=sizeof(path))return 0;
    FILE *f=fopen(path,"r");
    if(!f)return 0;
    int ok=fgets(out,(int)size,f)!=NULL;
    if(ok&&!strchr(out,'\n')&&!feof(f))ok=0;
    fclose(f);
    if(ok)out[strcspn(out,"\r\n")]=0;
    return ok;
}
static int power_number(const char *dir,const char *key,int low,int high,int *result) {
    char buf[64],*end;
    if(!power_read(dir,key,buf,sizeof(buf)))return 0;
    errno=0;
    long v=strtol(buf,&end,10);
    if(errno||end==buf||*end||v<low||v>high)return 0;
    *result=(int)v;
    return 1;
}
static struct aiboos_power power_sample(const char *sys) {
    struct aiboos_power result={.capacity=-1};
    char path[4096],buf[64];
    int n=snprintf(path,sizeof(path),"%s/class/power_supply/*",sys);
    if(n<0||(size_t)n>=sizeof(path))return result;
    glob_t items={0};
    if(glob(path,0,NULL,&items)==0){
        for(size_t i=0;i<items.gl_pathc;i++){
            const char *dir=items.gl_pathv[i];
            if(!power_read(dir,"type",buf,sizeof(buf))||strcmp(buf,"Battery"))continue;
            int present;
            if(power_number(dir,"present",0,1,&present)&&!present)continue;
            result.battery=1;
            power_number(dir,"capacity",0,100,&result.capacity);
            result.temp_valid=power_number(dir,"temp",-500,1500,&result.temp_decic);
            if(power_read(dir,"status",buf,sizeof(buf))){
                if(!strcmp(buf,"Charging"))result.status=POWER_CHARGING;
                else if(!strcmp(buf,"Discharging"))result.status=POWER_DISCHARGING;
                else if(!strcmp(buf,"Full"))result.status=POWER_FULL;
                else if(!strcmp(buf,"Not charging"))result.status=POWER_NOT_CHARGING;
            }
            break;
        }
    }
    globfree(&items);
    return result;
}
static const char *power_status(struct aiboos_power p) {
    switch(p.status){
        case POWER_CHARGING:return "CHARGING";
        case POWER_DISCHARGING:return "DISCHARGING";
        case POWER_FULL:return "FULL";
        case POWER_NOT_CHARGING:return "NOT CHARGING";
        default:return "STATUS UNKNOWN";
    }
}
#endif
