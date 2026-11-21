AiboOS native iPhone SE A9 bring-up
===================================

This directory contains a NATIVE Linux userspace display experiment, not
an IPA and not an iOS app. The code is compiled to static ARM64 Linux ELF
in the RAM-only boot workflow, then placed in the initramfs under /bin.

aiboos-fb.c:
- Paints an experimental AiboOS-branded status display on /dev/fb0 when
  Linux provides a compatible 16-bit or 32-bit framebuffer.
- Does not load iOS, call jailbreak tools, write iPhone storage,
  repartition NAND, access device firmware, or run as an iOS process.
- Has a hardware-free --selftest used by the build workflow.
- Falls back to a console when /dev/fb0 is absent.
- Does not pretend the AiboOS web UI is running as native Linux apps.

The RAM-boot workflow now packages Samsung S8000 and TSMC S8003 payload
variants from the same build run instead of relying on an outdated
hard-coded RAM kit artifact. The kernel developer kit remains downloaded
from a previously verified GitHub run; it is NOT built from the current
commit and has NOT been verified on an actual phone.

BLOCKER: Apple A9 internal storage is not established for HoolockLinux,
and native boot + display have not been verified on this iPhone.
A permanent no-iOS install is therefore still unavailable. A kernel,
DTB, userspace binary, or valid ZIP alone is not proof of hardware boot.

No user should flash these artifacts or erase their iPhone.

## November 2026 A9 usability work

The public iPhone SE experiment at https://github.com/efremmanac-prog/Iphone-se-linux
reports native Linux and framebuffer output on Samsung A9, with touchscreen
and wireless drivers still missing. AiboOS now includes a native framebuffer
menu navigable through the Linux evdev volume/home keys (if provided by the
kernel); this is a fallback, not a touchscreen driver. It also includes a
standard configfs ACM gadget initializer which waits for a UDC rather than
assuming the USB controller is ready. It emits a status banner only: no shell
or disk access. Both are included in the RAM and ext4 development builds.
The renderer/navigation self-tests do not exercise the phone's hardware.
Kernel gadget config, host serial enumeration, evdev key mapping, and A9
storage, wireless, and touch support remain to be verified on-device.

## Linux-side installation prototype

The new RAM image includes `/bin/aiboos-install` and a checksum-verified archive of the current ARM64 root filesystem. It inventories Linux block devices, and can deploy the filesystem into a dedicated already-mounted writable ext4 volume under `/mnt`, with an explicit `.aiboos-install-target` marker containing `AIBOOS-DEDICATED-LINUX-VOLUME`. Existing files are refused; deployment uses staging and checks the installed system before renaming. CI exercises actual deployment and overwrite refusal on a disposable loop-mounted ext4 volume. This is not an iOS replacement: no raw disk writing, repartitioning, transport, bootloader changes or automatic boot are implemented. Physical A9 storage access is unknown.

## Branding and A9 storage research

The native framebuffer now draws a superscript-style TM beside AIBOOS. Windows Setup and the root filesystem display AiboOS™. The Home button mapping also accepts KEY_HOMEPAGE, as declared in Hoolock's s800x-se.dtsi.

Source audit: Hoolock's config_16k already enables NVME_APPLE, APPLE_RTKIT and EXT4_FS. Its A9 s800-0-3.dtsi, s800-0-3-common.dtsi and s800x-se.dtsi do not declare an A9 storage controller. The A9 feature matrix does not document internal storage support. Enabling the existing NVMe configuration alone is therefore not evidence of a usable A9 block device. No speculative controller addresses or write operations were added.

## Installed Linux root verification and handoff

Deployment now records SHA-256 checksums for the installed immutable startup payload and an installation marker. `aiboos-root-start --verify` checks init, the system identity, virtual filesystem mountpoints and payload hashes. A separate `--boot-mounted` mode implements a standard Linux PID 1 switch_root from an already booted RAM Linux system, on an explicitly prepared and mounted ext4 volume; it refuses non-PID1 invocation. It is not wired to automatic boot or an iPhone firmware path. CI verifies the installed tree, executes its ARM64 BusyBox and framebuffer binary under QEMU user emulation, checks corruption rejection, and checks non-PID1 refusal. Real switch_root execution on a phone remains untested. No A9 storage controller or phone boot transport is added.

## Physical mute switch and configurable feedback

The native framebuffer UI now handles KEY_MUTE press and release, initializes from EVIOCGKEY, ignores repeats, and accepts KEY_HOMEPAGE. A black Dynamic Island-style pill shows a red crossed bell and SILENT ON or white bell and SILENT OFF for 2.3 seconds. Volume keys navigate to SWITCH SETTINGS or SWITCH SOUND; Home cycles the selection, with actions Silent mode, Dim UI, Open Home, or Disabled and tones None, Soft click, Chime. The alert policy is published in /run/aiboos-silent; this is not system-wide mixer muting. Settings persist in the installed Linux volume's /var/lib/aiboos when writable; RAM boot settings are session-only. Sounds are synthesized as bounded stereo PCM and played through normal ALSA on /dev/snd/pcmC0D0p when available. No A9 audio driver, mixer routing or physical switch test is included. The A9 GPIO device tree declares KEY_MUTE; polarity, actual sound output and display remain untested on hardware. CI tests switch states, rendering and tone samples, not audio hardware.

### Custom MP3 switch sounds

Switch Sound offers Custom MP3 as another choice. Place user-owned audio in `/var/lib/aiboos/sounds/silent-on.mp3` and `silent-off.mp3` for separate effects, or `switch.mp3` for a shared fallback. Files must be ordinary local files, at most 2 MiB; the first two seconds are decoded to reduced-volume 48 kHz stereo PCM, with a short fade-out. Missing/invalid audio falls back to the soft click. Native file picker/import UI and hardware speaker routing are not implemented. The vendored minimp3 decoder is CC0, upstream https://github.com/lieff/minimp3 at commit 142823796ab8efa55e1bf11406028f3be77ecceb (header blob 72c5c30f499fa53cc643432d1359286c67f2504f). CI exercises generated mono and stereo MP3 samples and malformed input on ARM64 under QEMU user emulation.
