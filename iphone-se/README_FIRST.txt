AiboOS — iPhone SE 2016 (A9) RAM-ONLY boot development package
==============================================================

Status: CLOUD-BUILT AND CHECKSUM-VERIFIED; NOT PHONE-BOOT-TESTED.
THIS IS NOT A PERMANENT iOS REPLACEMENT OR AN INSTALLER.
DO NOT FLASH THESE FILES, REPARTITION, OR ERASE iOS.

There are two different Apple A9 chips in the original iPhone SE (iPhone8,4).
This package preserves a correctly matched DTB for each chip:
  Samsung-S8000/s8000-n69u.dtb  - Samsung S8000, board N69u
  TSMC-S8003/s8003-n69.dtb     - TSMC S8003, board N69

DO NOT GUESS WHICH CHIP YOUR PHONE HAS.
The phone's visible model number (e.g. A1723) alone is insufficient to
distinguish the silicon vendor. Determine chip/board from trustworthy device
diagnostics before selecting a specific payload.

Each variant contains m1n1-linux.bin, Image.gz, initramfs.cpio.gz, m1n1.bin,
one matching DTB and SHA256SUMS.txt. The payload uses the boot-file
concatenation layout documented in HoolockLinux's pongoOS guide.
This only establishes byte layout, NOT runtime bootability.

Windows: Run Start-Readiness.cmd to check that the right files are present
and verify their SHA-256 hashes, and whether Windows currently detects an
Apple device. This is a READ-ONLY check: no administrator rights, WSL,
reboots, drivers, DFU, flashing, or iPhone filesystem access.

IMPORTANT — The Windows readiness script CANNOT boot the phone. Hoolock's
documented PongoOS boot uses Linux or macOS for palera1n and pongoterm.
Windows-only boot delivery has NOT been verified for this device/project.
No Windows checkm8/DFU driver switching is done by these scripts.

Even with a successful USB boot test, AiboOS is not yet a native graphical
desktop on the SE. The RAM initramfs is an experiment, not a finished OS,
and the AiboOS web UI is not a running window manager.

References:
https://github.com/HoolockLinux/docs/blob/master/tutorials/SETUP_pongoOS.md
https://github.com/HoolockLinux/docs/blob/master/features/A9.md
https://github.com/HoolockLinux/docs/blob/master/tools/README.md
