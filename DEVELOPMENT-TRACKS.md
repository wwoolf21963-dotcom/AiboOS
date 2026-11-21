# AiboOS Samsung n69u development tracks

Target: iPhone8,4, CPID 8000 (Samsung S8000). TSMC storage candidate does not apply.

Workstreams: [storage](../../issues/1), [startup](../../issues/2), [battery and charging](../../issues/3), [display and touch](../../issues/4), [audio and haptics](../../issues/5), [connectivity](../../issues/6), [sensors and thermal](../../issues/7), [installer and recovery](../../issues/8).

Shared first step: read-only Linux hardware inventory at iphone-se/research/hardware-inventory.sh. This collects standard sysfs interfaces after Linux is running, not iOS or DFU. It reports missing power data as unavailable, never invents battery readings and never changes charging settings. CI uses synthetic sysfs fixtures; it cannot establish hardware functionality.

Release gates: actual native n69u boot, functioning internal storage, validated power and charging, recoverability, then an independently starting installed system. VM installation tests are not device tests. Keep unsupported device trees and driver research out of release packages. No active automated developer agents have been assigned; issues organize the work, not guarantee concurrent implementation.
