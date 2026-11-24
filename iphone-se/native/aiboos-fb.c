/*
 * AiboOS native ARM64 Linux framebuffer bring-up (MIT).
 * Draws a simple boot screen to /dev/fb0, never accesses internal storage.
 * If framebuffer is missing the initramfs falls back to serial console.
 */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <poll.h>
#include <glob.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <sys/wait.h>
#include <sound/asound.h>
#include <sys/stat.h>
#define MINIMP3_ONLY_MP3
#define MINIMP3_NO_SIMD
#define MINIMP3_IMPLEMENTATION
#include "vendor/minimp3.h"
#include "aiboos-power.h"
#include <sys/ioctl.h>
#include <sys/mman.h>

struct screen {
    unsigned char *data;
    size_t len;
    unsigned w, h, stride, bpp, xoff, yoff;
    struct fb_bitfield red, green, blue;
};
static uint32_t component(unsigned value, struct fb_bitfield bits) {
    if (!bits.length || bits.length > 16 || bits.offset + bits.length > 32) return 0;
    uint32_t max = (1u << bits.length) - 1u;
    return ((value * max + 127u) / 255u) << bits.offset;
}
static void pixel(struct screen *s, int x, int y, uint32_t rgb) {
    if (x < 0 || y < 0 || (unsigned)x >= s->w || (unsigned)y >= s->h) return;
    size_t unit = s->bpp / 8;
    size_t row = ((size_t)y + s->yoff) * s->stride;
    size_t col = ((size_t)x + s->xoff) * unit;
    if (row > s->len || col > s->len - row || unit > s->len - row - col) return;
    uint32_t value = component((rgb >> 16) & 255u, s->red)
                   | component((rgb >> 8) & 255u, s->green)
                   | component(rgb & 255u, s->blue);
    memcpy(s->data + row + col, &value, unit);
}
static void rect(struct screen *s, int x, int y, int w, int h, uint32_t rgb) {
    if (w <= 0 || h <= 0) return;
    int64_t right = (int64_t)x + w, bottom = (int64_t)y + h;
    int left = x < 0 ? 0 : x, top = y < 0 ? 0 : y;
    if (left >= (int)s->w || top >= (int)s->h) return;
    if (right > s->w) right = s->w;
    if (bottom > s->h) bottom = s->h;
    for (int yy = top; yy < (int)bottom; yy++)
        for (int xx = left; xx < (int)right; xx++)
            pixel(s, xx, yy, rgb);
}
struct font_entry { char ch; unsigned char rows[7]; };
static const struct font_entry font[] = {
    {'A',{14,17,17,31,17,17,17}}, {'B',{30,17,17,30,17,17,30}},
    {'C',{14,17,16,16,16,17,14}}, {'D',{30,17,17,17,17,17,30}},
    {'E',{31,16,16,30,16,16,31}}, {'F',{31,16,16,30,16,16,16}},
    {'G',{14,17,16,23,17,17,15}}, {'H',{17,17,17,31,17,17,17}},
    {'I',{31,4,4,4,4,4,31}}, {'J',{7,2,2,2,18,18,12}},
    {'K',{17,18,20,24,20,18,17}}, {'L',{16,16,16,16,16,16,31}},
    {'M',{17,27,21,21,17,17,17}}, {'N',{17,25,21,19,17,17,17}},
    {'O',{14,17,17,17,17,17,14}}, {'P',{30,17,17,30,16,16,16}},
    {'Q',{14,17,17,17,21,18,13}}, {'R',{30,17,17,30,20,18,17}},
    {'S',{15,16,16,14,1,1,30}}, {'T',{31,4,4,4,4,4,4}},
    {'U',{17,17,17,17,17,17,14}}, {'V',{17,17,17,17,17,10,4}},
    {'W',{17,17,17,21,21,21,10}}, {'X',{17,17,10,4,10,17,17}},
    {'Y',{17,17,10,4,4,4,4}}, {'Z',{31,1,2,4,8,16,31}},
    {'0',{14,17,19,21,25,17,14}}, {'1',{4,12,4,4,4,4,14}},
    {'2',{14,17,1,2,4,8,31}}, {'3',{30,1,1,14,1,1,30}},
    {'4',{2,6,10,18,31,2,2}}, {'5',{31,16,30,1,1,17,14}},
    {'6',{6,8,16,30,17,17,14}}, {'7',{31,1,2,4,8,8,8}},
    {'8',{14,17,17,14,17,17,14}}, {'9',{14,17,17,15,1,2,12}},
    {'-',{0,0,0,31,0,0,0}}, {':',{0,4,4,0,4,4,0}},
    {' ',{0,0,0,0,0,0,0}}
};
static const unsigned char *glyph(char ch) {
    if (ch >= 'a' && ch <= 'z') ch = (char)(ch - 'a' + 'A');
    for (size_t i = 0; i < sizeof(font)/sizeof(font[0]); i++)
        if (font[i].ch == ch) return font[i].rows;
    return font[sizeof(font)/sizeof(font[0])-1].rows;
}
static void text(struct screen *s, int x, int y, const char *str, int scale, uint32_t color) {
    if (scale < 1 || scale > 10) return;
    for (const char *p = str; *p && x < (int)s->w; p++, x += 6*scale) {
        const unsigned char *r = glyph(*p);
        for (int yy=0; yy<7; yy++)
            for (int xx=0; xx<5; xx++)
                if (r[yy] & (1u << (4 - xx)))
                    rect(s,x+xx*scale,y+yy*scale,scale,scale,color);
    }
}
static void render(struct screen *s) {
    int w = (int)s->w, h = (int)s->h;
    int k = w >= 800 ? 3 : 2;
    rect(s,0,0,w,h,0x191328);
    rect(s,0,0,w,h/4,0x503058);
    rect(s,0,h/4-6,w,6,0xff8fbd);
    text(s,24,25,"AIBO",5,0xff91c1);
    text(s,144,25,"OS",5,0xffffff);
    text(s,206,25,"TM",2,0xff91c1);
    text(s,24,90,"NATIVE LINUX",k,0xffffff);
    text(s,24,h/3,"IPHONE SE 2016",k,0xffffff);
    text(s,24,h/3+45,"A9 RAM BOOT",k,0xffc2df);
    text(s,24,h/3+90,"NO DISK WRITES",k,0x98f0be);
    text(s,24,h-65,"EXPERIMENTAL",k,0xffc2df);
}
/* Volume keys work through the ordinary Linux evdev interface. A real
 * touchscreen driver can later provide navigation through the same UI. */
enum { PAGE_HOME, PAGE_CONNECTION, PAGE_SYSTEM, PAGE_SETTINGS, PAGE_SOUND, PAGE_POWER, PAGE_SECURITY, PAGE_COUNT };
enum { ACTION_SILENT, ACTION_DIM, ACTION_HOME, ACTION_OFF, ACTION_COUNT };
enum { TONE_NONE, TONE_CLICK, TONE_CHIME, TONE_MP3, TONE_COUNT };
#ifdef AIBO18_NATIVE
#include "aibo18-icons.h"
#define LAUNCHER_COUNT AIBO18_COUNT
#else
#define LAUNCHER_COUNT (PAGE_COUNT-1)
#endif
struct switch_ui { int page, selected, action, sound, position, silent, toast; long long until; };
static const char *actions[]={"SILENT MODE","DIM UI","OPEN HOME","DISABLED"};
static const char *sounds[]={"NONE","SOFT CLICK","CHIME","CUSTOM MP3"};
static long long now_ms(void) {
    struct timespec t={0};
    if(clock_gettime(CLOCK_MONOTONIC,&t)<0) return 0;
    return (long long)t.tv_sec*1000+t.tv_nsec/1000000;
}
/* Physical navigation: volume selects icons, Home opens/returns.
 * Inside settings/sound, volume changes the selected option. */
static int navigate(struct switch_ui *u, const struct input_event *ev) {
    if (ev->type != EV_KEY || ev->value != 1) return 0;
    int direction=ev->code==KEY_VOLUMEUP||ev->code==KEY_UP?1:
                  ev->code==KEY_VOLUMEDOWN||ev->code==KEY_DOWN?-1:0;
    if(ev->code==KEY_HOME||ev->code==KEY_HOMEPAGE){
        if(u->page!=PAGE_HOME)u->page=PAGE_HOME;
#ifdef AIBO18_NATIVE
        else u->page=u->selected==10?PAGE_SETTINGS:PAGE_COUNT;
#else
        else u->page=u->selected+1;
#endif
        return 1;
    }
    if(!direction)return 0;
    if(u->page==PAGE_HOME){
        u->selected=(u->selected+direction+LAUNCHER_COUNT)%LAUNCHER_COUNT;
        return 1;
    }
    return 0;
}
static void publish_silent(const struct switch_ui *u) {
    /* AiboOS alert policy, not a claim that the hardware mixer is working. */
    FILE *f=fopen("/run/aiboos-silent","w");
    if(f){fprintf(f,"%d\n",u->silent);fclose(f);}
}
static void load_settings(struct switch_ui *u) {
    FILE *f=fopen("/var/lib/aiboos/switch.conf","r");
    int a,b;
    if(f){if(fscanf(f,"%d %d",&a,&b)==2 && a>=0 && a<ACTION_COUNT && b>=0 && b<TONE_COUNT){u->action=a;u->sound=b;}fclose(f);}
}
static void save_settings(const struct switch_ui *u) {
    FILE *f=fopen("/var/lib/aiboos/switch.conf.new","w");
    if(f){int ok=fprintf(f,"%d %d\n",u->action,u->sound)>0; if(fclose(f)==0 && ok) (void)rename("/var/lib/aiboos/switch.conf.new","/var/lib/aiboos/switch.conf");}
}
static int set_switch(struct switch_ui *u,int position,int notify,long long time) {
    if(position!=0 && position!=1) return 0;
    if(u->position==position) return 0;
    u->position=position;
    u->silent=(u->action==ACTION_SILENT && position);
    if(notify && u->action!=ACTION_OFF){
        if(u->action==ACTION_HOME && position) u->page=PAGE_HOME;
        u->toast=1;u->until=time+2300;
        return 1;
    }
    return 0;
}
static void circle(struct screen *s,int cx,int cy,int r,uint32_t color){
    for(int y=-r;y<=r;y++)for(int x=-r;x<=r;x++)
        if(x*x+y*y<=r*r)pixel(s,cx+x,cy+y,color);
}
static void pill(struct screen *s,int x,int y,int w,int h,uint32_t color){
    int r=h/2;
    rect(s,x+r,y,w-2*r,h,color);
    circle(s,x+r,y+r,r,color);circle(s,x+w-r-1,y+r,r,color);
}
static void bell(struct screen *s,int x,int y,int k,uint32_t color,int slash){
    /* Compact, original bell silhouette with clapper and optional strike. */
    circle(s,x+5*k,y+5*k,4*k,color);
    rect(s,x+k,y+5*k,9*k,5*k,color);
    rect(s,x,y+10*k,11*k,2*k,color);
    circle(s,x+5*k,y+14*k,k,color);
    if(slash)for(int i=0;i<15*k;i++){
        rect(s,x-2*k+i,y+i,2*k,2*k,0x08070b);
        rect(s,x-3*k+i,y+i, k,k,color);
    }
}
static void island(struct screen *s,const struct switch_ui *u){
    if(!u->toast)return;
    int w=(int)s->w,k=w>=400?3:2;
    int pw=(w>=400?290:216);if(pw>w-12)pw=w-12;
    int ph=23*k,x=(w-pw)/2,y=8;
    uint32_t color=u->action==ACTION_SILENT && u->position?0xff455d:0xffffff;
    const char *label;
    if(u->action==ACTION_SILENT)label=u->position?"SILENT ON":"SILENT OFF";
    else if(u->action==ACTION_DIM)label=u->position?"DIM ON":"DIM OFF";
    else label=u->position?"HOME":"SWITCH OFF";
    pill(s,x,y,pw,ph,0x08070b);
    bell(s,x+3*k,y+4*k,k,color,u->action==ACTION_SILENT && u->position);
    int ts=w>=400?3:2;
    text(s,x+18*k,y+(ph-7*ts)/2,label,ts,color);
}
#ifndef AIBO18_NATIVE
static void launcher_icon(struct screen *s,int x,int y,int side,int app){
    const uint32_t colors[]={0x597fdb,0x8b55be,0x59637b,0xe46ca8,0x36a989,0x7957c2};
    int k=side/12;if(k<1)k=1;
    int cx=x+side/2,cy=y+side/2;
    rect(s,x+k,y,side-2*k,side,colors[app]);
    rect(s,x,y+k,side,side-2*k,colors[app]);
    circle(s,x+k,y+k,k,colors[app]);circle(s,x+side-k-1,y+k,k,colors[app]);
    circle(s,x+k,y+side-k-1,k,colors[app]);circle(s,x+side-k-1,y+side-k-1,k,colors[app]);
    uint32_t c=0xffffff;
    switch(app){
      case 0: /* connection */
        for(int i=0;i<3;i++)rect(s,cx-4*k+i*3*k,cy+(2-i*2)*k,2*k,(i*2+2)*k,c);
        break;
      case 1: /* system chip */
        rect(s,cx-3*k,cy-3*k,6*k,6*k,c);
        rect(s,cx-2*k,cy-2*k,4*k,4*k,colors[app]);
        for(int i=-2;i<=2;i+=2){rect(s,cx+i*k,cy-4*k,k,8*k,c);rect(s,cx-4*k,cy+i*k,8*k,k,c);}
        break;
      case 2: /* settings */
        for(int i=-3;i<=3;i+=3){rect(s,cx-4*k,cy+i*k,8*k,k,c);circle(s,cx+(i==0?2:-2)*k,cy+i*k,k+1,c);}
        break;
      case 3: /* sound */
        rect(s,cx-3*k,cy-k,2*k,3*k,c);rect(s,cx-k,cy-3*k,2*k,7*k,c);
        for(int i=0;i<3;i++)rect(s,cx+2*k+i*k,cy-(i+1)*k,k,(i+1)*2*k,c);
        break;
      case 4: /* battery */
        rect(s,cx-4*k,cy-2*k,8*k,4*k,c);rect(s,cx+4*k,cy-k,k,2*k,c);
        rect(s,cx-3*k,cy-k,5*k,2*k,colors[app]);break;
      case 5: /* security */
        circle(s,cx,cy-2*k,3*k,c);circle(s,cx,cy-2*k,2*k,colors[app]);
        rect(s,cx-4*k,cy-k,8*k,5*k,c);rect(s,cx,cy+k,k,2*k,colors[app]);break;
    }
}
static void launcher(struct screen *s,const struct switch_ui *u){
    int w=(int)s->w,h=(int)s->h;
    int scale=w>=480?3:w>=300?2:1;
    int brand=w>=400?5:3;
    for(int y=0;y<h;y++){
        unsigned r=31u+36u*(unsigned)y/(unsigned)h;
        unsigned b=53u+22u*(unsigned)y/(unsigned)h;
        rect(s,0,y,w,1,(r<<16)|(19u<<8)|b);
    }
    text(s,16,12,"AIBO",brand,0xff91c1);
    text(s,16+24*brand,12,"OS",brand,0xffffff);
    text(s,18+36*brand,12,"TM",2,0xff91c1);
    int top=12+7*brand+14,foot=7*scale+14;
    int cellw=w/3,cellh=(h-top-foot)/2;
    int side=cellw-18;
    if(side>cellh-7*scale-12)side=cellh-7*scale-12;
    if(side>112)side=112;
    if(side<12)side=12;
    static const char *names[]={"CONNECT","SYSTEM","SETTINGS","SOUND","BATTERY","SECURITY"};
    for(int i=0;i<PAGE_COUNT-1;i++){
        int cx=(i%3)*cellw+cellw/2,cy=top+(i/3)*cellh;
        int x=cx-side/2,y=cy+(cellh-side-7*scale)/2;
        if(i==u->selected)rect(s,x-4,y-4,side+8,side+8,0xffb1d9);
        launcher_icon(s,x,y,side,i);
        int labelscale=scale;
        if((int)strlen(names[i])*6*labelscale>cellw-4)labelscale=1;
        text(s,cx-(int)strlen(names[i])*3*labelscale,y+side+6,names[i],labelscale,0xffffff);
    }
    const char *hint="VOLUME SELECT  HOME OPEN";
    int hs=(int)strlen(hint)*6*scale>w-12?1:scale;
    text(s,(w-(int)strlen(hint)*6*hs)/2,h-7*hs-7,hint,hs,0xffc2df);
    island(s,u);
}
#else
/* Original 1.8 raster icon artwork, native framebuffer composition. */
static void launcher(struct screen *s,const struct switch_ui *u){
    int w=(int)s->w,h=(int)s->h;
    int scale=w>=480?3:w>=300?2:1;
    int brand=w>=400?5:3;
    for(int y=0;y<h;y++){
        unsigned r=34u+45u*(unsigned)y/(unsigned)h;
        unsigned b=64u+25u*(unsigned)y/(unsigned)h;
        rect(s,0,y,w,1,(r<<16)|(24u<<8)|b);
    }
    text(s,16,12,"AIBO",brand,0xff91c1);
    text(s,16+24*brand,12,"OS",brand,0xffffff);
    text(s,18+36*brand,12,"1-8",2,0xffffff);
    int top=12+7*brand+12, bottom=h-10, cellw=w/4;
    int cellh=(bottom-top)/5;
    int side=cellw-14;
    if(side>cellh-7*scale-12)side=cellh-7*scale-12;
    if(side>110)side=110;
    if(side<10)side=10;
    rect(s,5,top+4*cellh,w-10,cellh,0x68476f);
    for(int i=0;i<AIBO18_COUNT;i++){
        int row=i<AIBO18_HOME_COUNT?i/4:4;
        int col=i<AIBO18_HOME_COUNT?i%4:i-AIBO18_HOME_COUNT;
        int cx=col*cellw+cellw/2,y=top+row*cellh+3,x=cx-side/2;
        if(i==u->selected)rect(s,x-3,y-3,side+6,side+6,0xffb1d9);
        for(int yy=0;yy<side;yy++)for(int xx=0;xx<side;xx++){
            uint32_t p=aibo18_pixels[i][(yy*60/side)*60+xx*60/side];
            if((p>>24)>127)pixel(s,x+xx,y+yy,p&0xffffff);
        }
        int ls=scale,n=(int)strlen(aibo18_names[i]);
        if(n*6*ls>cellw-2)ls=1;
        if(n*6*ls<=cellw-2)text(s,cx-n*3*ls,y+side+3,aibo18_names[i],ls,0xffffff);
    }
    island(s,u);
}
#endif
static void shell_page(struct screen *s,const struct switch_ui *u) {
    if(u->page==PAGE_HOME){launcher(s,u);return;}
#ifdef AIBO18_NATIVE
    if(u->page==PAGE_COUNT){
        rect(s,0,0,(int)s->w,(int)s->h,0x191328);
        text(s,16,20,aibo18_names[u->selected],3,0xff91c1);
        text(s,16,70,"NATIVE APP PENDING",2,0xffffff);
        text(s,16,104,"HOME TO RETURN",2,0xffffff);
        return;
    }
#endif
    int w=(int)s->w,h=(int)s->h,k=w>=600?3:2,page=u->page;
    uint32_t bg=(u->action==ACTION_DIM && u->position==1)?0x08060c:0x191328;
    rect(s,0,0,w,h,bg);
    rect(s,0,0,w,h/5,bg==0x08060c?0x201326:0x503058);
    rect(s,0,h/5-4,w,4,0xff91c1);
    int brand_scale=w>=400?5:3;
    text(s,16,18,"AIBO",brand_scale,0xff91c1);
    text(s,16+24*brand_scale,18,"OS",brand_scale,0xffffff);
    text(s,18+36*brand_scale,18,"TM",2,0xff91c1);
    struct aiboos_power p={.capacity=-1};
    if(page==PAGE_POWER)p=power_sample("/sys");
    char battery[40]="BATTERY UNAVAILABLE",temp[40]="TEMP UNKNOWN";
    if(p.capacity>=0)snprintf(battery,sizeof(battery),"BATTERY %d PERCENT",p.capacity);
    if(p.temp_valid)snprintf(temp,sizeof(temp),"TEMP %d DECIC",p.temp_decic);
    const char *titles[]={"HOME","CONNECTION","SYSTEM","SWITCH SETTINGS","SWITCH SOUND","BATTERY","SECURITY"};
    const char *lines[][3]={
        {"NATIVE LINUX","VOLUME KEYS TO MOVE",u->silent?"SILENT ON":u->position<0?"SWITCH UNKNOWN":"SILENT OFF"},
        {"USB SERIAL","WIFI NOT VERIFIED","TOUCH NOT REQUIRED"},
        {"ARM64 A9","DEVELOPMENT BUILD","NO RAW DISK WRITES"},
        {actions[u->action],"VOLUME TO CHANGE","HOME TO RETURN"},
        {sounds[u->sound],"VOLUME TO CHANGE",u->sound==TONE_MP3?"LOCAL MP3 FILE":"HOME TO RETURN"},
        {battery,power_status(p),temp},
        {"TOUCH ID UNSUPPORTED","HOME BUTTON ONLY","NO BIOMETRIC ENROLLMENT"}
    };
    text(s,16,h/5+14,titles[page],page>=PAGE_SETTINGS?k:k+1,0xffffff);
    int a=h/5+48,step=(h-a-38)/4;if(step<18)step=18;
    for(int i=0;i<3;i++){
        rect(s,12,a+i*step,w-24,step-3,bg==0x08060c?0x15101c:0x332440);
        text(s,20,a+i*step+5,lines[page][i],w>=600?3:2,0xffc2df);
    }
    text(s,16,h-22,"HOME TO RETURN",2,0xff91c1);
    island(s,u);
}
/* Small local tone synthesizer. Playback is optional native ALSA PCM.
 * No mixer controls, external files, network or sound driver bypass. */
static unsigned synth(int tone,int16_t *out,unsigned cap) {
    unsigned frames=tone==TONE_CLICK?2880:tone==TONE_CHIME?9600:0;
    if(frames>cap)frames=cap;
    for(unsigned i=0;i<frames;i++){
        unsigned hz=tone==TONE_CLICK?760:(i<frames/2?880:1320);
        unsigned p=(i*hz)%48000u;
        int wave=p<24000u?(int)p-12000:36000-(int)p;
        unsigned attack=i<240?i:240,left=frames-i;
        unsigned env=left<1200?left:1200;
        int16_t sample=(int16_t)((int64_t)wave*attack*env/(240LL*1200*7));
        out[2*i]=out[2*i+1]=sample;
    }
    return frames;
}
static void pcm_mask(struct snd_pcm_hw_params *p,unsigned n,unsigned bit){
    struct snd_mask *m=&p->masks[n-SNDRV_PCM_HW_PARAM_FIRST_MASK];
    memset(m,0,sizeof(*m));m->bits[bit/32]=1u<<(bit%32);
}
static void pcm_exact(struct snd_pcm_hw_params *p,unsigned n,unsigned v){
    struct snd_interval *i=&p->intervals[n-SNDRV_PCM_HW_PARAM_FIRST_INTERVAL];
    i->min=i->max=v;i->integer=1;
}
/* Read only an ordinary local file; limit storage, time and decoded length. */
static unsigned decode_mp3(const char *path,int16_t *out,unsigned cap){
    int fd=open(path,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0)return 0;
    struct stat st;
    if(fstat(fd,&st)<0||!S_ISREG(st.st_mode)||st.st_size<4||st.st_size>2*1024*1024){close(fd);return 0;}
    unsigned size=(unsigned)st.st_size,got=0;
    uint8_t *data=malloc(size);
    if(!data){close(fd);return 0;}
    while(got<size){ssize_t n=read(fd,data+got,size-got);if(n<=0)break;got+=(unsigned)n;}
    close(fd);
    if(got!=size){free(data);return 0;}
    mp3dec_t dec;mp3dec_init(&dec);
    unsigned off=0,total=0;
    uint64_t phase=0;int previous_rate=0;
    while(off<size&&total<cap){
        mp3dec_frame_info_t info={0};
        int16_t pcm[MINIMP3_MAX_SAMPLES_PER_FRAME];
        int n=mp3dec_decode_frame(&dec,data+off,(int)(size-off),pcm,&info);
        if(info.frame_bytes<=0||(unsigned)info.frame_bytes>size-off)break;
        off+=(unsigned)info.frame_bytes;
        if(n<=0||info.channels<1||info.channels>2||info.hz<8000||info.hz>48000)continue;
        if(n>MINIMP3_MAX_SAMPLES_PER_FRAME/info.channels)break;
        if(previous_rate!=info.hz){phase=0;previous_rate=info.hz;}
        /* Bounded sample-and-hold resampling to 48 kHz, stereo, at reduced volume. */
        for(int i=0;i<n&&total<cap;i++){
            phase+=48000;
            while(phase>=(unsigned)info.hz&&total<cap){
                out[2*total]=(int16_t)(pcm[i*info.channels]/6);
                out[2*total+1]=(int16_t)(pcm[i*info.channels+info.channels-1]/6);
                total++;phase-=(unsigned)info.hz;
            }
        }
    }
    free(data);
    unsigned fade=total<480?total:480;
    for(unsigned i=0;i<fade;i++){
        unsigned at=total-fade+i;
        out[2*at]=(int16_t)((int)out[2*at]*(int)(fade-i)/(int)fade);
        out[2*at+1]=(int16_t)((int)out[2*at+1]*(int)(fade-i)/(int)fade);
    }
    return total;
}
static int play_pcm(int tone,int position){
    int16_t samples[48000*2*2];
    unsigned frames;
    if(tone==TONE_MP3){
        const char *path=position==1?"/var/lib/aiboos/sounds/silent-on.mp3":"/var/lib/aiboos/sounds/silent-off.mp3";
        frames=decode_mp3(path,samples,96000);
        if(!frames)frames=decode_mp3("/var/lib/aiboos/sounds/switch.mp3",samples,96000);
        if(!frames){fputs("AiboOS custom MP3 missing or invalid; using soft click\n",stderr);frames=synth(TONE_CLICK,samples,96000);}
    }else frames=synth(tone,samples,96000);
    if(!frames)return 0;
    int fd=open("/dev/snd/pcmC0D0p",O_RDWR|O_CLOEXEC);
    if(fd<0)return -1;
    struct snd_pcm_hw_params p={0};
    for(size_t i=0;i<sizeof(p.masks)/sizeof(p.masks[0]);i++)memset(&p.masks[i],0xff,sizeof(p.masks[i]));
    for(size_t i=0;i<sizeof(p.intervals)/sizeof(p.intervals[0]);i++)p.intervals[i].max=~0u;
    p.rmask=~0u;
    pcm_mask(&p,SNDRV_PCM_HW_PARAM_ACCESS,SNDRV_PCM_ACCESS_RW_INTERLEAVED);
    pcm_mask(&p,SNDRV_PCM_HW_PARAM_FORMAT,SNDRV_PCM_FORMAT_S16_LE);
    pcm_mask(&p,SNDRV_PCM_HW_PARAM_SUBFORMAT,SNDRV_PCM_SUBFORMAT_STD);
    pcm_exact(&p,SNDRV_PCM_HW_PARAM_CHANNELS,2);
    pcm_exact(&p,SNDRV_PCM_HW_PARAM_RATE,48000);
    pcm_exact(&p,SNDRV_PCM_HW_PARAM_PERIOD_SIZE,480);
    pcm_exact(&p,SNDRV_PCM_HW_PARAM_BUFFER_SIZE,1920);
    if(ioctl(fd,SNDRV_PCM_IOCTL_HW_PARAMS,&p)<0){close(fd);return -1;}
    struct snd_pcm_sw_params sw={0};
    sw.period_step=1;sw.avail_min=480;sw.start_threshold=480;sw.stop_threshold=1920;sw.xfer_align=1;
    sw.boundary=1920;while(sw.boundary<(1UL<<30))sw.boundary*=2;
    if(ioctl(fd,SNDRV_PCM_IOCTL_SW_PARAMS,&sw)<0||ioctl(fd,SNDRV_PCM_IOCTL_PREPARE)<0){close(fd);return -1;}
    unsigned done=0;
    while(done<frames){
        struct snd_xferi x={.buf=samples+2*done,.frames=frames-done};
        if(ioctl(fd,SNDRV_PCM_IOCTL_WRITEI_FRAMES,&x)<0||x.result<=0||(unsigned long)x.result>frames-done)break;
        done+=(unsigned)x.result;
    }
    if(done==frames)(void)ioctl(fd,SNDRV_PCM_IOCTL_DRAIN);
    close(fd);return done==frames?0:-1;
}
static pid_t sound_child;
static void play_async(int tone,int position){
    if(sound_child>0){if(waitpid(sound_child,NULL,WNOHANG)==0)return;sound_child=0;}
    if(tone==TONE_NONE)return;
    pid_t p=fork();
    if(p==0){alarm(3);int r=play_pcm(tone,position);if(r)fputs("AiboOS switch sound: ALSA output unavailable\n",stderr);_exit(r?1:0);}
    if(p>0)sound_child=p;
}
static int bitset(const unsigned long *bits,unsigned code){
    unsigned width=sizeof(unsigned long)*8;
    return (bits[code/width]>>(code%width))&1UL;
}
#ifdef AIBO18_NATIVE
/* Direct multitouch evdev, single-finger tap on slot zero. No controller
 * access here: the kernel must expose a real INPUT_PROP_DIRECT device. */
struct aibo_touch {
    int enabled,slot,active,released,have_x,have_y,x,y;
    struct input_absinfo ax,ay;
};
static int touch_open(int fd,struct aibo_touch *t){
    unsigned long props[(INPUT_PROP_MAX+sizeof(unsigned long)*8)/(sizeof(unsigned long)*8)]={0};
    memset(t,0,sizeof(*t));
    if(ioctl(fd,EVIOCGPROP(sizeof(props)),props)<0||!bitset(props,INPUT_PROP_DIRECT))return 0;
    if(ioctl(fd,EVIOCGABS(ABS_MT_POSITION_X),&t->ax)<0||
       ioctl(fd,EVIOCGABS(ABS_MT_POSITION_Y),&t->ay)<0||
       t->ax.maximum<=t->ax.minimum||t->ay.maximum<=t->ay.minimum)return 0;
    t->enabled=1;
    return 1;
}
static int touch_scale(int v,struct input_absinfo a,int extent){
    if(v<a.minimum)v=a.minimum;
    if(v>a.maximum)v=a.maximum;
    return (int)(((int64_t)v-a.minimum)*(extent-1)/((int64_t)a.maximum-a.minimum));
}
static int touch_tap(struct screen *s,struct switch_ui *u,int x,int y){
    if(u->page!=PAGE_HOME)return 0;
    int w=(int)s->w,h=(int)s->h,brand=w>=400?5:3;
    int top=12+7*brand+12,cellh=(h-10-top)/5,cellw=w/4;
    if(cellh<=0||cellw<=0||x<0||y<top||x>=4*cellw||y>=top+5*cellh)return 0;
    int row=(y-top)/cellh,col=x/cellw;
    int index=row==4?AIBO18_HOME_COUNT+col:row*4+col;
    if(row!=4&&index>=AIBO18_HOME_COUNT)return 0;
    u->selected=index;
    struct input_event ev={.type=EV_KEY,.code=KEY_HOME,.value=1};
    return navigate(u,&ev);
}
static int touch_event(struct screen *s,struct switch_ui *u,struct aibo_touch *t,const struct input_event *ev){
    if(!t->enabled)return 0;
    if(ev->type==EV_SYN&&ev->code==SYN_DROPPED){t->active=t->released=t->have_x=t->have_y=0;return 0;}
    if(ev->type==EV_ABS){
        if(ev->code==ABS_MT_SLOT)t->slot=ev->value;
        else if(t->slot==0){
            if(ev->code==ABS_MT_TRACKING_ID){
                if(ev->value>=0){t->active=1;t->released=t->have_x=t->have_y=0;}
                else if(t->active){t->active=0;t->released=1;}
            }else if(ev->code==ABS_MT_POSITION_X){t->x=ev->value;t->have_x=1;}
            else if(ev->code==ABS_MT_POSITION_Y){t->y=ev->value;t->have_y=1;}
        }
    }
    if(ev->type==EV_SYN&&ev->code==SYN_REPORT&&t->released){
        t->released=0;
        if(t->have_x&&t->have_y)return touch_tap(s,u,touch_scale(t->x,t->ax,(int)s->w),touch_scale(t->y,t->ay,(int)s->h));
    }
    return 0;
}
#endif
static volatile sig_atomic_t stopped;
static void stop_ui(int sig) { (void)sig; stopped=1; }
static int run_ui(struct screen *s) {
    struct pollfd inputs[48];
#ifdef AIBO18_NATIVE
    struct aibo_touch touches[48];
#endif
    unsigned count=0;
    struct switch_ui u={.page=PAGE_HOME,.action=ACTION_SILENT,.sound=TONE_NONE,.position=-1};
    load_settings(&u);publish_silent(&u);
    signal(SIGTERM,stop_ui);signal(SIGINT,stop_ui);
    shell_page(s,&u);
    while(!stopped) {
        glob_t devices={0};
        if(glob("/dev/input/event*",0,NULL,&devices)==0){
            for(size_t i=0;i<devices.gl_pathc && count<48;i++){
                int fd=open(devices.gl_pathv[i],O_RDONLY|O_NONBLOCK|O_CLOEXEC);
                if(fd<0)continue;
                unsigned long bits[(KEY_MAX+sizeof(unsigned long)*8)/(sizeof(unsigned long)*8)]={0};
                int keys=ioctl(fd,EVIOCGBIT(EV_KEY,sizeof(bits)),bits)>=0&&
                   (bitset(bits,KEY_VOLUMEUP)||bitset(bits,KEY_VOLUMEDOWN)||bitset(bits,KEY_HOME)||
                    bitset(bits,KEY_HOMEPAGE)||bitset(bits,KEY_UP)||bitset(bits,KEY_DOWN)||bitset(bits,KEY_MUTE));
#ifdef AIBO18_NATIVE
                int touch=touch_open(fd,&touches[count]);
                if(!keys&&!touch){close(fd);continue;}
#else
                if(!keys){close(fd);continue;}
#endif
                if(bitset(bits,KEY_MUTE)){
                    unsigned long state[(KEY_MAX+sizeof(unsigned long)*8)/(sizeof(unsigned long)*8)]={0};
                    if(ioctl(fd,EVIOCGKEY(sizeof(state)),state)>=0){
                        int old=u.position;
                        int alert=set_switch(&u,bitset(state,KEY_MUTE),old>=0,now_ms());
                        if(old!=u.position){publish_silent(&u);shell_page(s,&u);if(alert)play_async(u.sound,u.position);}
                    }
                }
                inputs[count++]=(struct pollfd){.fd=fd,.events=POLLIN};
            }
        }
        globfree(&devices);
        for(int tick=0;tick<10&&!stopped;tick++){
            int ready=poll(inputs,count,250);
            if(ready<0&&errno!=EINTR)break;
            if(u.toast&&now_ms()>=u.until){u.toast=0;shell_page(s,&u);}
            if(u.page==PAGE_POWER&&tick%8==0)shell_page(s,&u);
            if(sound_child>0&&waitpid(sound_child,NULL,WNOHANG)!=0)sound_child=0;
            for(unsigned i=0;i<count;i++)if(inputs[i].revents&POLLIN){
                struct input_event ev;
                while(read(inputs[i].fd,&ev,sizeof(ev))==(ssize_t)sizeof(ev)){
#ifdef AIBO18_NATIVE
                    if(touch_event(s,&u,&touches[i],&ev)){shell_page(s,&u);continue;}
#endif
                    if(ev.type==EV_KEY&&ev.code==KEY_MUTE&&(ev.value==0||ev.value==1)){
                        int old=u.position;
                        int alert=set_switch(&u,ev.value,1,now_ms());
                        if(old!=u.position){publish_silent(&u);shell_page(s,&u);if(alert)play_async(u.sound,u.position);}
                        continue;
                    }
                    if(ev.type==EV_KEY&&ev.value==1){
                        int direction=ev.code==KEY_VOLUMEUP||ev.code==KEY_UP?1:
                                      ev.code==KEY_VOLUMEDOWN||ev.code==KEY_DOWN?-1:0;
                        if(direction&&u.page==PAGE_SETTINGS){
                            u.action=(u.action+direction+ACTION_COUNT)%ACTION_COUNT;
                            u.silent=(u.action==ACTION_SILENT&&u.position==1);u.toast=0;
                            publish_silent(&u);save_settings(&u);shell_page(s,&u);continue;
                        }
                        if(direction&&u.page==PAGE_SOUND){
                            u.sound=(u.sound+direction+TONE_COUNT)%TONE_COUNT;
                            save_settings(&u);shell_page(s,&u);play_async(u.sound,u.position);continue;
                        }
                    }
                    if(navigate(&u,&ev))shell_page(s,&u);
                }
            }
        }
        for(unsigned i=0;i<count;i++)close(inputs[i].fd);
        count=0;
    }
    return 0;
}
static int selftest(void) {
    static unsigned char buf[320*240*4];
    struct screen s = { .data=buf, .len=sizeof(buf), .w=320,.h=240,
        .stride=320*4,.bpp=32, .red={16,8,0}, .green={8,8,0}, .blue={0,8,0} };
    pixel(&s, 3, 4, 0x112233);
    uint32_t value = 0;
    memcpy(&value, buf+(4*320+3)*4, 4);
    if (value != 0x112233u) return 2;
    render(&s);
    if (!buf[0] && !buf[1] && !buf[2]) return 3;
    memcpy(&value, buf+(25*320+29)*4, 4);
    if (value != 0xff91c1u) return 16;
    memcpy(&value, buf+(25*320+149)*4, 4);
    if (value != 0xffffffu) return 17;
    struct input_event ev={.type=EV_KEY,.code=KEY_VOLUMEUP,.value=1};
    struct switch_ui u={.position=-1,.action=ACTION_SILENT,.sound=TONE_CLICK};
    if(!navigate(&u,&ev)||u.page!=PAGE_HOME||u.selected!=1)return 4;
    ev.value=2;if(navigate(&u,&ev)||u.selected!=1)return 5;
    ev.value=1;ev.code=KEY_VOLUMEDOWN;
    if(!navigate(&u,&ev)||u.selected!=0)return 6;
    ev.code=KEY_HOME;
#ifdef AIBO18_NATIVE
    if(!navigate(&u,&ev)||u.page!=PAGE_COUNT)return 7;
#else
    if(!navigate(&u,&ev)||u.page!=PAGE_CONNECTION)return 7;
#endif
    if(!navigate(&u,&ev)||u.page!=PAGE_HOME)return 18;
    ev.code=KEY_VOLUMEDOWN;
    if(!navigate(&u,&ev)||u.selected!=LAUNCHER_COUNT-1)return 19;
    ev.code=KEY_HOME;
#ifdef AIBO18_NATIVE
    if(!navigate(&u,&ev)||u.page!=PAGE_COUNT)return 20;
#else
    if(!navigate(&u,&ev)||u.page!=PAGE_SECURITY)return 20;
#endif
    if(!navigate(&u,&ev)||u.page!=PAGE_HOME)return 21;
    launcher(&s,&u);
#ifdef AIBO18_NATIVE
    if(!touch_tap(&s,&u,40,50)||u.selected!=0||u.page!=PAGE_COUNT)return 23;
    u.page=PAGE_HOME;
    if(touch_tap(&s,&u,40,10))return 24;
#endif
    memcpy(&value,buf+(12*320+19)*4,4);
    if(value!=0xff91c1u)return 22;
    if(set_switch(&u,0,0,0)||u.silent||u.toast) return 8;
    if(!set_switch(&u,1,1,100)||!u.silent||!u.toast||u.until!=2400) return 9;
    if(set_switch(&u,1,1,101)) return 10;
    for(int page=0;page<PAGE_COUNT;page++){u.page=page;shell_page(&s,&u);}
    if(!set_switch(&u,0,1,500)||u.silent) return 11;
    shell_page(&s,&u);
    u.action=ACTION_OFF;u.toast=0;
    if(set_switch(&u,1,1,100)||u.silent||u.toast) return 12;
    int16_t audio[9600*2];
    if(synth(TONE_NONE,audio,9600)!=0||synth(TONE_CLICK,audio,9600)!=2880||synth(TONE_CHIME,audio,9600)!=9600) return 13;
    int nonzero=0;
    for(unsigned i=0;i<9600*2;i++){if(audio[i]>2000||audio[i]<-2000)return 14;if(audio[i])nonzero=1;}
    if(!nonzero)return 15;
    puts("PASS AiboOS native framebuffer, mute switch, settings and tone synthesis offline tests.");
    return 0;
}
int main(int argc, char **argv) {
    if (argc==2 && !strcmp(argv[1],"--selftest")) return selftest();
    if(argc==3&&!strcmp(argv[1],"--test-power")){
        struct aiboos_power p=power_sample(argv[2]);
        printf("battery=%d capacity=%d temp_valid=%d temp_decic=%d status=%s\n",p.battery,p.capacity,p.temp_valid,p.temp_decic,power_status(p));
        return 0;
    }
    if (argc==3 && !strcmp(argv[1],"--test-mp3")) {
        int16_t pcm[96000*2];
        unsigned n=decode_mp3(argv[2],pcm,96000);
        if(!n||n>96000)return 1;
        int audible=0;
        for(unsigned i=0;i<2*n;i++){if(pcm[i])audible=1;if(pcm[i]>5462||pcm[i]<-5462)return 2;}
        if(!audible)return 3;
        printf("PASS MP3 decode: %u stereo frames at 48000 Hz\n",n);
        return 0;
    }
    if (argc!=2 || (strcmp(argv[1],"--show") && strcmp(argv[1],"--ui"))) {
        fputs("Usage: aiboos-fb --show | --ui | --selftest\n",stderr);
        return 2;
    }
    int fd=open("/dev/fb0",O_RDWR|O_CLOEXEC);
    if (fd<0) { perror("AiboOS: no framebuffer"); return 1; }
    struct fb_var_screeninfo v={0};
    struct fb_fix_screeninfo f={0};
    if(ioctl(fd,FBIOGET_VSCREENINFO,&v)<0 || ioctl(fd,FBIOGET_FSCREENINFO,&f)<0) {
        perror("AiboOS: framebuffer metadata"); close(fd); return 1;
    }
    if ((v.bits_per_pixel != 16 && v.bits_per_pixel != 32)
        || v.xres<160 || v.yres<120 || v.xres>8192 || v.yres>8192
        || !f.smem_len || f.smem_len > 256u*1024u*1024u) {
        fputs("AiboOS: unsupported framebuffer size/format\n",stderr); close(fd); return 1;
    }
    void *memory=mmap(NULL,f.smem_len,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
    if(memory==MAP_FAILED){perror("AiboOS: framebuffer map");close(fd);return 1;}
    struct screen s={ .data=memory, .len=f.smem_len, .w=v.xres, .h=v.yres,
        .stride=f.line_length,.bpp=v.bits_per_pixel,.xoff=v.xoffset,.yoff=v.yoffset,
        .red=v.red,.green=v.green,.blue=v.blue };
    if (!strcmp(argv[1],"--ui")) run_ui(&s); else render(&s);
    munmap(memory,f.smem_len);
    close(fd);
    puts("AiboOS native framebuffer boot preview drawn. No flash/storage operations.");
    return 0;
}
