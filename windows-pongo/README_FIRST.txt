AiboOS Windows Pongo USB stage — experimental / not an OS installer
================================================================

What has been built:
- Native Windows C program (aiboos-pongo.exe) using libusb, with libusb DLL
- Basic USB recognition of Apple 05AC:4141 Pongo mode
- Manual / safe-by-default upload protocol to send a combined m1n1/Linux RAM image
- Self-test and non-modifying USB probe
- No WSL or Ubuntu needed to run the Windows USB stage

CRITICAL BLOCKER:
This tool DOES NOT place an iPhone in DFU or invoke checkm8 / palera1n.
It can only send the prepared image AFTER PongoOS is running and the proper
driver is bound. Your iPhone currently shows up in iOS, not PongoOS.
Official palera1n does not support Windows directly; experimental third-party
native Windows loaders exist but are not proven here on this iPhone SE.
Do not follow any untested exploit or driver installation instructions.

To test what is possible TODAY on your Windows PC (READ ONLY):
1. Extract this ZIP.
2. Double-click Start-Windows-USB-Check.cmd.
3. Send the displayed text or a screenshot.

Expected result on a normally booted iPhone:
'PongoOS 05ac:4141 not detected.' This is not an error in your cable.

ADVANCED, ONLY once an externally validated Pongo stage is available:
  aiboos-pongo.exe --dry-run Samsung-S8000 "C:\...\Samsung-S8000\m1n1-linux.bin"
  aiboos-pongo.exe --probe

To attempt a transfer requires all of:
- verified chip variant (Samsung S8000/n69u or TSMC S8003/n69)
- PongoOS already running, displayed on the iPhone
- functioning compatible Windows USB driver for PongoOS
- independently reviewed kernel payload; an iOS recovery method
- explicit command typed with --confirm-ram-boot

WE HAVE NOT VERIFIED THAT THE FULL BOOT WORKS ON ANY REAL iPHONE.
Successful USB upload is not proof of working Linux.
DO NOT FLASH the payload or replace internal storage.
A9 internal storage replacement is not supported by Hoolock tools.

Protocol based on checkra1n/pongoOS/scripts/pongoterm.c (MIT):
https://github.com/checkra1n/pongoOS
Vendor/product: 05ac:4141; control endpoint transfers and bulk endpoint 2.
This implementation is an experimental port, NOT official palera1n.

Source license: MIT. Binary dynamically uses LGPL-2.1 libusb.
