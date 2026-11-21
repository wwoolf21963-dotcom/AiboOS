# SE storage port: engineering checkpoints

Public firmware comparison: run 44959050878. Both boards contain apcie, nvme-mmu0 and dart-apcie0/1/3 descriptions. The TSMC apcie resource list includes the additional 0x60a000000 PHY-IP region; Samsung lacks it. Upstream pcie-apple-h9p supports apple,s8003-pcie, not apple,s8000-pcie. The old A9 storage transport is PCI NVMe with NVMMU, not simply the newer ANS2 platform driver.

For the next TSMC board port, compare firmware bridge reset/clock-request functions and DART initialization properties against s8003.dtsi, including the inherited GPIO 160 reset, before enabling PCIe. Preserve separate board identities. Verify power sequencing, MSI, lane configuration, and NVMMU on real hardware before mount or write testing. The public ADT representation is not a Linux FDT and raw bytes must not be interpreted as Linux cells without translation.

Build now asserts the PCI, PCI MSI, H9P, DART and PCI NVMe drivers are built in, and enables verbose NVMe errors. The existing upstream SE controller remains disabled. No new Samsung PHY algorithm or validated storage driver is claimed.
