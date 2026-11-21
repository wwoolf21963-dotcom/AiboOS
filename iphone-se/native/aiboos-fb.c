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
    text(s,24,25,"AIBOOS",5,0xff91c1);
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
struct switch_ui { int page, action, sound, position, silent, toast; long long until; };
static const char *actions[]={"SILENT MODE","DIM UI","OPEN HOME","DISABLED"};
static const char *sounds[]={"NONE","SOFT CLICK","CHIME","CUSTOM MP3"};
static long long now_ms(void) {
    struct timespec t={0};
    if(clock_gettime(CLOCK_MONOTONIC,&t)<0) return 0;
    return (long long)t.tv_sec*1000+t.tv_nsec/1000000;
}
static int navigate(int page, const struct input_event *ev) {
    if (ev->type != EV_KEY || ev->value != 1) return page;
    switch (ev->code) {
        case KEY_VOLUMEUP: case KEY_UP: return (page + 1) % PAGE_COUNT;
        case KEY_VOLUMEDOWN: case KEY_DOWN: return (page + PAGE_COUNT - 1) % PAGE_COUNT;
        case KEY_HOME: case KEY_HOMEPAGE: return PAGE_HOME;
        default: return page;
    }
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
static void shell_page(struct screen *s,const struct switch_ui *u) {
    int w=(int)s->w,h=(int)s->h,k=w>=600?3:2,page=u->page;
    uint32_t bg=(u->action==ACTION_DIM && u->position==1)?0x08060c:0x191328;
    rect(s,0,0,w,h,bg);
    rect(s,0,0,w,h/5,bg==0x08060c?0x201326:0x503058);
    rect(s,0,h/5-4,w,4,0xff91c1);
    int brand_scale=w>=400?5:3;
    text(s,16,18,"AIBOOS",brand_scale,0xff91c1);
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
        {actions[u->action],"HOME TO CHANGE","VOLUME TO NAVIGATE"},
        {sounds[u->sound],"HOME TO CHANGE",u->sound==TONE_MP3?"LOCAL MP3 FILE":"VOLUME TO NAVIGATE"},
        {battery,power_status(p),temp},
        {"TOUCH ID UNSUPPORTED","HOME BUTTON ONLY","NO BIOMETRIC ENROLLMENT"}
    };
    text(s,16,h/5+14,titles[page],page>=PAGE_SETTINGS?k:k+1,0xffffff);
    int a=h/5+48,step=(h-a-38)/4;if(step<18)step=18;
    for(int i=0;i<3;i++){
        rect(s,12,a+i*step,w-24,step-3,bg==0x08060c?0x15101c:0x332440);
        text(s,20,a+i*step+5,lines[page][i],w>=600?3:2,0xffc2df);
    }
    for(int i=0;i<PAGE_COUNT;i++)rect(s,w/2-(PAGE_COUNT*18)/2+i*18,h-22,12,8,i==page?0xff91c1:0x65536f);
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
static volatile sig_atomic_t stopped;
static void stop_ui(int sig) { (void)sig; stopped=1; }
static int run_ui(struct screen *s) {
    struct pollfd inputs[48];
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
                if(ioctl(fd,EVIOCGBIT(EV_KEY,sizeof(bits)),bits)<0||
                   !(bitset(bits,KEY_VOLUMEUP)||bitset(bits,KEY_VOLUMEDOWN)||bitset(bits,KEY_HOME)||
                     bitset(bits,KEY_HOMEPAGE)||bitset(bits,KEY_UP)||bitset(bits,KEY_DOWN)||bitset(bits,KEY_MUTE))){
                    close(fd);continue;
                }
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
                    if(ev.type==EV_KEY&&ev.code==KEY_MUTE&&(ev.value==0||ev.value==1)){
                        int old=u.position;
                        int alert=set_switch(&u,ev.value,1,now_ms());
                        if(old!=u.position){publish_silent(&u);shell_page(s,&u);if(alert)play_async(u.sound,u.position);}
                        continue;
                    }
                    if(ev.type==EV_KEY&&ev.value==1&&(ev.code==KEY_HOME||ev.code==KEY_HOMEPAGE)){
                        if(u.page==PAGE_SETTINGS){
                            u.action=(u.action+1)%ACTION_COUNT;u.silent=(u.action==ACTION_SILENT&&u.position==1);u.toast=0;
                            publish_silent(&u);save_settings(&u);shell_page(s,&u);continue;
                        }
                        if(u.page==PAGE_SOUND){
                            u.sound=(u.sound+1)%TONE_COUNT;save_settings(&u);shell_page(s,&u);play_async(u.sound,u.position);continue;
                        }
                    }
                    int next=navigate(u.page,&ev);
                    if(next!=u.page){u.page=next;shell_page(s,&u);}
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
    struct input_event ev={.type=EV_KEY,.code=KEY_VOLUMEUP,.value=1};
    if(navigate(PAGE_HOME,&ev)!=PAGE_CONNECTION) return 4;
    ev.value=2;
    if(navigate(PAGE_CONNECTION,&ev)!=PAGE_CONNECTION) return 5;
    ev.value=1;ev.code=KEY_VOLUMEDOWN;
    if(navigate(PAGE_HOME,&ev)!=PAGE_SECURITY) return 6;
    ev.code=KEY_HOME;
    if(navigate(PAGE_SYSTEM,&ev)!=PAGE_HOME) return 7;
    struct switch_ui u={.position=-1,.action=ACTION_SILENT,.sound=TONE_CLICK};
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
