# Raw-register-editor-RDNA4
RDNA4 VR Register Editor — i2c register tool with EEPROM

Releasing a tool for direct read/write access to RDNA4 GPU voltage regulator registers over i2c.

Overview:
A lightweight bash utility that auto-detects the correct i2c bus (SMU 0 / bcm backends), validates the target GPU is RDNA4, and exposes a live register table for VR1/VR2 (TRIM, VID, PG, CG1, backup registers across pages 0–2). Any listed register can be edited directly by index, with hex input validation, a write confirmation step, and automatic readback verification.

In this tool: 
Permanent EEPROM commit. Current register state can be written to persistent VR memory, surviving reboots and power cycles — separate from the runtime register writes, and gated behind its own explicit confirmation.

Requirements:
i2c-tools, bc, i2c_dev kernel module (auto-installed/loaded if missing). Root/sudo required for i2cset/i2cget access.

Disclaimer: 
His performs direct i2c writes to VR hardware. Use at your own risk — no warranty, no liability for damaged hardware. EEPROM commits are non-volatile; double-check values before confirming.
