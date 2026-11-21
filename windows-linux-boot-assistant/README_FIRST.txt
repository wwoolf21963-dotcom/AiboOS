AiboOS Windows Auto Readiness (NO USB STICK REQUIRED)
=====================================================
Build: 0.2.0 — Windows 11 x64, self-contained GUI.

HOW IT WORKS
Double-click AiboOS-Setup.exe. It immediately and automatically:
- Checks the current Windows Apple USB device mode using Windows CIM.
- Looks for Apple VID 05AC in DFU (1227), Recovery (1281),
  normal iOS (12A8) or a PongoOS USB ID (4141).
- Updates the on-screen connection status every 20 seconds.
- Warns clearly when full AiboOS installation is NOT AVAILABLE.
- Lets advanced users optionally select an iPhone generation and iOS version
  for compatibility notes. Selection is not needed for the automatic scan.
- Copies a privacy-preserving local report on user request.

NO RUFUS. NO USB STICK. NO WSL. NO EXTRA DOWNLOADS.
The GUI never calls checkm8, modifies Windows driver bindings, reboots,
enters DFU, erases a USB disk, or writes any iPhone data. It does not need
administrator permissions. It doesn't capture unique serials or ECIDs.

IMPORTANT LIMITATIONS (NOT AUTOMATABLE YET)
- iPhone DFU requires physical button steps or compatible existing device
  tools; it is not accomplished by this Windows app.
- There is no phone-verified A9 Linux kernel+drivers+storage installer.
- The experimental Windows Pongo/checkm8 loader failed during USB operations.
- Therefore no functional, safe, hands-free AiboOS replacement for iOS exists
  today. A successful USB scan is NOT an installation.
- The original ISO/palen1x workflow uses a separate boot environment. It
  cannot be achieved in this app without removable media or other boot
  preparation; don't mistake Windows WSL for native Linux USB support.

AiboOS development repository:
https://github.com/wwoolf21963-dotcom/AiboOS

This program is for diagnosis/development and is not affiliated with Apple.
