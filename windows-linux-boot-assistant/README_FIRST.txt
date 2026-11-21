AiboOS WINDOWS → LINUX BOOT ASSISTANT
=====================================
Version 0.1 — Windows 11 x64, portable GUI, no Python, no WSL.

WHAT IT DOES:
- Checks the Windows CPU architecture and removable drives (read-only).
- Downloads palen1x v3.0.0-beta.4 x86_64 ISO directly from official GitHub
  and verifies SHA-256 against GitHub release metadata.
- Downloads Rufus 4.16 directly from official GitHub and SHA-256 verifies it.
- Opens Rufus only after user confirmation and verified downloads.
- Guides you through selecting spare USB, DD image mode, boot picker,
  and manual DFU/iPhone steps.
- Shows explicit warnings before the USB-erasing step.
- Never automatically selects/erases a disk or changes firmware/boot options.

WHAT IT CANNOT DO:
- Start Linux from a normal running Windows process.
- Reliably execute checkm8 in Windows/WSL/VM.
- Automatically enter DFU mode with button presses.
- Replace iOS with AiboOS or guarantee our ARM64 payload boots.
- Run the unverified AiboOS bootloader or flash your phone.

YOU NEED A SPARE USB DRIVE (official download recommends 32GB), or other
bootable removable media. You previously indicated you do not have one.
You can download and verify everything now, but cannot complete the boot
without obtaining removable boot media or using a separate Linux/Mac PC.

START:
1. Extract the ZIP completely.
2. Double-click AiboOS-Setup.exe.
3. Click PREPARE EVERYTHING and follow its buttons.
4. If you have no USB, stop before USB creation and acquire suitable media.

PRIVACY:
No telemetry, account logins, driver installation, jailbreak actions,
and no iPhone access occur in the GUI.

PINNED AND VERIFIED DOWNLOADS:
palen1x v3.0.0-beta.4 x86_64 ISO
SHA256 9f47c7d4a8d8824e210a6795cc5cdb22964a0de26298800e8ba7b55953a743f3
https://github.com/palera1n/palen1x/releases
Rufus v4.16
SHA256 8351a56c134aa6dd26a930d702cc3fd57f11ef90b17e55a8de960d5a73d46cfc
https://github.com/pbatard/rufus/releases

OFFICIAL GUIDES:
https://docs.palera.in/using-palen1x/
https://palera.in/download/
https://rufus.ie/

IMPORTANT:
palen1x is a Linux environment for palera1n/jailbreaking. It does NOT
replace iOS with AiboOS. Testing the AiboOS ARM64 Linux kernel on your
actual SE is a separate unproven next milestone.

This assistant is not affiliated with Apple or palera1n.
