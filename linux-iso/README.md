# AiboOS Linux Edition — bootable installer (experimental)

This is a **real, custom Debian 13 ("trixie") Linux live ISO for 64-bit Intel/AMD computers**, not a browser shortcut, ChromeOS app, Android APK, or iPhone IPA. It ships the AiboOS UI, boots into Xfce and auto-opens AiboOS in an app window using a local-only loopback web server. The underlying operating system is Linux, with Linux drivers, networking, filesystem and accounts.

**Status:** source build pipeline. An ISO download exists only when the GitHub Actions **Build AiboOS Linux Edition ISO** workflow succeeds. It has **not been tested on actual PC or Chromebook hardware**. Booting and disk installation are separate stages.

## Building (requires Linux host or GitHub Actions)

On Debian or Ubuntu with appropriate dependencies:
```sh
sudo apt install live-build debootstrap rsync squashfs-tools xorriso isolinux syslinux-utils grub-efi-amd64-bin
sudo bash linux-iso/build.sh
```
Look for `linux-iso/AiboOS_Linux_amd64.iso` and `.sha256`. Or run the GitHub Actions workflow manually and get the artifact from its run if successful.

## Test before installing

1. **Back up files and make recovery media** before trying a disk installation.
2. Download the built ISO and verify its SHA-256 checksum.
3. Flash it to a **spare USB drive** using a trusted USB imaging tool; this erases the USB stick. Alternatively test in a virtual machine.
4. Boot in live mode **without changing the computer's drive**. Check Wi-Fi, input, sound, display and boot behavior.
5. Only on a supported machine, use the Calamares installer from the Xfce applications menu to install to disk. **Choosing to erase the drive deletes the old OS, ChromeOS, and personal files.** Carefully check the destination disk, partitions, and backups. No automatic erase is performed by the AiboOS installer builder.

### Chromebook support

Only for **specific supported 64-bit Intel/AMD Chromebooks** that can boot a standard Linux ISO. Support depends on the exact hardware board, firmware, write-protect state, peripherals, and storage. **ARM Chromebooks are not supported by this x86_64 image.** Firmware changes may be necessary and risky and may remove ChromeOS; never assume compatibility based only on the model's brand.

Check the firmware support table at https://docs.mrchromebox.tech/docs/supported-devices.html and read its safety/backup guidance before attempting anything. Always try Linux from USB before considering replacement of ChromeOS. If your device is not listed/supported, do not attempt to flash custom firmware.

### iPhone SE (2016)

**This image is NOT an iPhone installer and must not be flashed to an iPhone.** The A9 iPhone uses a completely different boot chain and requires experimental ARM64 kernel, device trees, hardware drivers, installer design, recovery and boot security work. The AiboOS TrollStore IPA is an app inside iOS and cannot replace iOS. No general-purpose stable iPhone SE Linux replacement is supplied here.

### Technical details

- Built using Debian `live-build`, including Xfce, Chromium, live networking, the graphical Debian Calamares installer, and AiboOS app assets copied from `AiboOS/Web/`.
- AiboOS starts from `http://127.0.0.1:18761` only; loopback is not exposed on the network.
- AiboOS locally cached conversations and media belong to the browser profile and are not end-to-end encrypted. Back up any essential data before experiments.
- Wi-Fi and video support can vary by Chromebook board. Battery monitoring may be inaccessible inside Chromium. The AiboOS 1% black screen is a **visual simulation** only.
- Installing does not guarantee 15.6 hours of battery life.
- This is a beta Linux derivative and not an independently developed kernel.
