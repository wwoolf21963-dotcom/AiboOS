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
