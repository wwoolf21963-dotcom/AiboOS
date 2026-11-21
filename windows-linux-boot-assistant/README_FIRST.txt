AiboOS Windows DFU Driver Preparation — v0.5.0
==============================================

THIS IS FOR A REAL NATIVE-OS AIBOOS PROJECT, NOT AN IPA.
NO USB STICK, RUFUS, WSL, OR LINUX LIVE USB. Keep using the Lightning cable.

Open AiboOS-Setup.exe. The application automatically checks Windows for a
connected iPhone in DFU 05AC:1227, and asks for the exact iPhone model and
LAST-KNOWN iOS version (DFU mode cannot read installed iOS version).
If exactly one Apple DFU device is present and the A9/iOS 15 research
profile is selected, it enables PREPARE / INSTALL USB DRIVER.

One-click driver preparation:
1. The user explicitly approves the operation in AiboOS Setup.
2. The PowerShell script checks that exactly one device is present in DFU.
3. If WinUSB/libusbK is already bound, the app skips installation.
4. If Apple's current DFU driver must be changed, it first exports the
   original INF and associated files using Microsoft's pnputil.
5. Windows asks for administrator approval (UAC). Decline to cancel.
6. A bundled, source-built libwdi wdi-simple helper prepares/installs a
   WinUSB driver for VID 05AC and PID 1227 only, not the iPhone's normal or
   Recovery USB interface.
7. It re-detects and verifies that a compatible driver service is bound.
   It reports failure rather than claiming success without verification.

Driver helper:
Upstream https://github.com/pbatard/libwdi, pinned commit
30df0c0e051b0132c4b9ebed8c054bc8eb3aaaec
Licensing is in LIBWDI-LICENSE.txt and LIBWDI-GPL-LICENSE.txt.
Building from a pinned commit does NOT prove compatibility on every PC.

Changing the Windows USB driver can interfere with Apple Devices/iTunes
and DFU restore procedures. The original Apple INF backup is stored in
the user's Downloads/AiboOS-Apple-Driver-Backup folder if required.
If backup fails, the installer refuses to replace the Apple driver.
An unknown third-party driver is never automatically replaced.
Diagnostic log: %LOCALAPPDATA%/AiboOS/Driver-Setup-Last-Run.txt

IMPORTANT — NO OPERATING-SYSTEM INSTALLATION YET.
A driver installation permits Windows USB driver access; it does not
run checkm8, load PongoOS, boot Linux, provide A9 touchscreen drivers or
overwrite iOS. The A9 RAM-only kernel package is not phone-boot-verified
and A9 internal-storage installation has not been verified. An actual
replacement step remains DISABLED to prevent unrecoverable erasure.
Do not repeatedly exploit, re-partition, or erase the device as a test.

AiboOS source: https://github.com/wwoolf21963-dotcom/AiboOS
