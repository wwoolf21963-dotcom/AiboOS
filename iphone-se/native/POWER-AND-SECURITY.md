# Native power and authentication status

Power page: samples Linux power_supply once per refresh, shows actual reported battery capacity, charge status and temperature in tenths of a degree Celsius. Missing or invalid values are unknown. This is a read-only userspace feature, not an S8000 charger driver or a thermal policy. It performs no power-supply writes.

Security page: explicitly reports Touch ID unsupported. Home-button events are not fingerprint evidence. No fingerprint enrollment, verification, access-control or PIN lock is implemented in this preview. A supported secure authentication backend and tested lock screen are prerequisites before offering any biometric setting.

CI: synthetic power_supply fixtures are checked through the ARM64 binary under QEMU user-mode. These are not handset tests.
