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
enum { PAGE_HOME, PAGE_CONNECTION, PAGE_SYSTEM, PAGE_COUNT };
static int navigate(int page, const struct input_event *ev) {
    if (ev->type != EV_KEY || ev->value != 1) return page;
    switch (ev->code) {
        case KEY_VOLUMEUP: case KEY_UP: return (page + 1) % PAGE_COUNT;
        case KEY_VOLUMEDOWN: case KEY_DOWN: return (page + PAGE_COUNT - 1) % PAGE_COUNT;
        case KEY_HOME: case KEY_HOMEPAGE: return PAGE_HOME;
        default: return page;
    }
}
static void shell_page(struct screen *s, int page) {
    int w=(int)s->w, h=(int)s->h;
    int k=w>=600?3:2;
    rect(s,0,0,w,h,0x191328);
    rect(s,0,0,w,h/5,0x503058);
    rect(s,0,h/5-4,w,4,0xff91c1);
    int brand_scale=w>=400?5:3;
    text(s,16,18,"AIBOOS",brand_scale,0xff91c1);
    text(s,18+36*brand_scale,18,"TM",2,0xff91c1);
    const char *titles[]={"HOME","CONNECTION","SYSTEM"};
    const char *lines[][3]={
        {"NATIVE LINUX","VOLUME KEYS TO MOVE","HOME TO RETURN"},
        {"USB SERIAL","WIFI NOT VERIFIED","TOUCH NOT REQUIRED"},
        {"ARM64 A9","DEVELOPMENT BUILD","NO DISK WRITES"}
    };
    text(s,16,h/5+14,titles[page],k+1,0xffffff);
    int a=h/5+48, step=(h-a-38)/4;
    if (step<18) step=18;
    for(int i=0;i<3;i++){
        rect(s,12,a+i*step,w-24,step-3,0x332440);
        text(s,20,a+i*step+5,lines[page][i],w>=600?3:2,0xffc2df);
    }
    for(int i=0;i<PAGE_COUNT;i++)
        rect(s,w/2-25+i*18,h-22,12,8,i==page?0xff91c1:0x65536f);
}
static volatile sig_atomic_t stopped;
static void stop_ui(int sig) { (void)sig; stopped=1; }
static int run_ui(struct screen *s) {
    struct pollfd inputs[48];
    unsigned count=0;
    int page=PAGE_HOME;
    signal(SIGTERM,stop_ui);
    signal(SIGINT,stop_ui);
    shell_page(s,page);
    while(!stopped) {
        /* Re-enumerate regularly: Linux may register gpio-keys late. */
        glob_t devices={0};
        if (glob("/dev/input/event*",0,NULL,&devices)==0) {
            for(size_t i=0;i<devices.gl_pathc && count<48;i++){
                int fd=open(devices.gl_pathv[i],O_RDONLY|O_NONBLOCK|O_CLOEXEC);
                if(fd<0) continue;
                unsigned long bits[(KEY_MAX+sizeof(unsigned long)*8)/(sizeof(unsigned long)*8)]={0};
                unsigned int width=sizeof(unsigned long)*8;
                if(ioctl(fd,EVIOCGBIT(EV_KEY,sizeof(bits)),bits)<0 ||
                   !((bits[KEY_VOLUMEUP/width]>>(KEY_VOLUMEUP%width))&1UL ||
                     (bits[KEY_VOLUMEDOWN/width]>>(KEY_VOLUMEDOWN%width))&1UL ||
                     (bits[KEY_HOME/width]>>(KEY_HOME%width))&1UL ||
                     (bits[KEY_UP/width]>>(KEY_UP%width))&1UL ||
                     (bits[KEY_DOWN/width]>>(KEY_DOWN%width))&1UL)) { close(fd); continue; }
                inputs[count++]=(struct pollfd){.fd=fd,.events=POLLIN};
            }
        }
        globfree(&devices);
        /* Keep existing fds open for a short interval, then refresh detection. */
        for (int tick=0;tick<10 && !stopped;tick++){
            int ready=poll(inputs,count,250);
            if(ready<0 && errno!=EINTR) break;
            for(unsigned i=0;i<count;i++) if(inputs[i].revents&POLLIN){
                struct input_event ev;
                while(read(inputs[i].fd,&ev,sizeof(ev))==(ssize_t)sizeof(ev)){
                    int next=navigate(page,&ev);
                    if(next!=page){page=next;shell_page(s,page);}
                }
            }
        }
        for(unsigned i=0;i<count;i++) close(inputs[i].fd);
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
    if(navigate(PAGE_HOME,&ev)!=PAGE_SYSTEM) return 6;
    ev.code=KEY_HOME;
    if(navigate(PAGE_SYSTEM,&ev)!=PAGE_HOME) return 7;
    for(int page=0;page<PAGE_COUNT;page++) shell_page(&s,page);
    puts("PASS AiboOS native framebuffer and evdev navigation offline tests.");
    return 0;
}
int main(int argc, char **argv) {
    if (argc==2 && !strcmp(argv[1],"--selftest")) return selftest();
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
