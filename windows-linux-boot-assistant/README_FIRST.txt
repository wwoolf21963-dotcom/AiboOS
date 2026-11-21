AiboOS Cable-Free Setup — Windows
================================
Version 0.3.0

NO USB STICK, NO RUFUS, NO LIGHTNING CABLE, NO WSL OR LINUX BOOT.

Double-click AiboOS-Setup.exe. This single-window setup:
1. Asks for your iPhone generation and exact installed iOS version.
2. Saves the chosen model/version locally for next time.
3. Checks whether the current AiboOS iPhone app beta is intended for that
   combination. The model and version are user-entered, not detected.
4. Shows a QR code to the official GitHub release page, ready for your
   iPhone Camera to scan, and offers an Open/Copy link.
5. Does not offer unsafe actions for incompatible selections.

Phone release:
https://github.com/wwoolf21963-dotcom/AiboOS/releases/tag/aiboos-se-latest

The release is an iOS app IPA. A compatible on-phone installer such as
TrollStore must ALREADY be available. Users must explicitly approve any
installation on the phone. The desktop setup cannot perform that remotely.

CRITICAL: THIS DOES NOT REPLACE iOS.
There is no tested permanent AiboOS image or verified A9 storage/boot
installation procedure for iPhone SE (2016). We will not simulate completion,
flash the phone, alter Windows drivers, or mislabel an app as an OS.
No USB enumeration, DFU, PowerShell, admin access, pairing, or download is
performed by the Windows setup.

The only locally stored preferences are the selected model and version,
at %LOCALAPPDATA%\AiboOS\setup-profile.json. No device identifiers are read.
This tool is not affiliated with Apple.
