# A9 storage porting evidence — 2026-11-21

## New finding
OrchardLinux's iPad 5 TSMC A9 (j71t/j72t) device trees enable a PCIe storage path. The same SoC is used by the TSMC iPhone SE (n69), so this is a substantially closer reference than A10/A11 ANS2. This is not evidence that the iPhone SE itself has working Linux storage.

Source snapshot: OrchardLinux/linux commit ef92d0d3b34aecba1fca233c4b983f89d1dbaaa1 (2026-11-11).
- https://github.com/OrchardLinux/linux/blob/ef92d0d3b34aecba1fca233c4b983f89d1dbaaa1/arch/arm64/boot/dts/apple/s8003.dtsi
- https://github.com/OrchardLinux/linux/blob/ef92d0d3b34aecba1fca233c4b983f89d1dbaaa1/arch/arm64/boot/dts/apple/s800x-ipad5.dtsi
- https://github.com/OrchardLinux/linux/blob/ef92d0d3b34aecba1fca233c4b983f89d1dbaaa1/arch/arm64/boot/dts/apple/s8003-j71t.dts
- https://github.com/OrchardLinux/linux/blob/ef92d0d3b34aecba1fca233c4b983f89d1dbaaa1/arch/arm64/boot/dts/apple/s8003-n69.dts
- https://github.com/OrchardLinux/orchard/blob/main/docs/compatibility.md

The TSMC SoC tree has PCIe and associated DART nodes disabled by default. The iPad board description enables these. The iPhone SE board does not. The upstream source also explains that the Samsung S8000 differs in its PCIe PHY and is not covered by this root-complex description.

## Required evidence before writing storage
1. Establish actual handset variant.
2. Establish successful native Linux execution on that handset.
3. Establish board-specific controller initialization and nondestructive block-device enumeration, then repeated read-only tests.
4. Demonstrate stable read/write on a dedicated disposable Linux volume without touching iOS volumes.
5. Separately establish startup from installed Linux storage. A successful root filesystem deployment is not evidence of standalone firmware startup.

No controller addresses, pin mappings, DMA settings, or storage write paths have been guessed or enabled for the iPhone. Both variants still lack demonstrated internal storage support. The current Windows packages and Linux-side installer do not solve this. Do not ship or label them as permanent replacement installers.
