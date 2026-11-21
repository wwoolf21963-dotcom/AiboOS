AiboOS Windows DFU / Native OS Readiness
=======================================
Build 0.4.0 — Windows x64 self-contained GUI.

This is for the NATIVE AiboOS OPERATING SYSTEM project, NOT the iOS IPA app.
No USB STICK, Rufus, Linux live USB, WSL, IPA, TrollStore or QR-code route.

What it does automatically when opened:
- Finds connected Apple USB mode through read-only Windows device enumeration.
- Clearly distinguishes DFU (05AC:1227), Recovery (1281), normal USB (12A8),
  and a possible PongoOS USB mode (4141).
- Displays sanitized driver service info, not ECID/serial/IMEI.
- Re-scans every 20 seconds.
- Allows selecting precise iPhone SE generation and last-known iOS version,
  saving only those choices locally for subsequent sessions.
- Shows honest boot and installation readiness blockers.
- Can copy a redacted diagnostic report to the clipboard.

The iPhone should be connected by its normal Lightning DATA cable to
the PC if you want Windows to detect DFU. "NO USB STICK" does not mean
wireless access to DFU is possible. While the device is in DFU, Windows
cannot reliably read the installed iOS version or distinguish Samsung
S8000 from TSMC S8003 using VID/PID alone.

The 2016 iPhone SE (Apple A9) has an experimental RAM-only Linux build in
the repository. It has NOT been verified booting on the actual device.
The experimental Windows checkm8/Pongo loader has not passed real-hardware
USB boot verification. Hoolock's documented internal-storage support is
for A11, not A9. There is no tested A9 full AiboOS image or storage
installation procedure. Consequently, iOS replacement is BLOCKED.

NO AUTOMATIC EXPLOIT OR FLASH: the GUI never changes drivers, resets DFU,
transfers boot images, writes internal storage, restarts the PC, erases
iOS, jailbreaks, or claims the OS was replaced. It requires no admin rights.
Successful DFU detection only means that Windows observed a device in
that USB mode, not that Linux will boot.

Next research gates (in order):
1. Observe DFU and driver capabilities on the actual Windows PC.
2. Confirm Samsung vs TSMC board using trustworthy hardware diagnostics.
3. Validate reproducible A9 RAM boot through an appropriately reviewed
   transfer path, with no storage writes, and collect console logs.
4. Build and test touchscreen, display, power, storage and recovery support.
5. Design, review, and verify A9 storage installation with backup/recovery
   before ever enabling permanent replacement.

AiboOS source: https://github.com/wwoolf21963-dotcom/AiboOS
Upstream Hoolock: https://github.com/HoolockLinux/docs
This tool is not affiliated with Apple.
