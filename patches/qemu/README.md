# Downstream QEMU patches (temporary)

`scripts/build-qemu.sh` applies every `*.patch` here, in name order, right after cloning the pinned
Espressif tag. A patch that does not apply is a hard failure. The name and sha256 of each patch are part
of the build's config contract, so adding, removing or changing a patch forces a rebuild.

## 0001-hw-misc-esp32_dport-switch-the-cache-without-rebuild.patch

Espressif's ESP32 model rebuilt QEMU's memory map every time ESP-IDF turned the flash cache off and on,
which it does around every flash operation. On a Raspberry Pi Zero 2W that froze MeshCom for about 55 s
per settings save and stretched boot to about 270 s. The patch switches the cache through an IOMMU
instead. Cache-off behaviour is unchanged.

- Upstream issue: https://github.com/espressif/qemu/issues/182
- Upstream PR: https://github.com/espressif/qemu/pull/183 (commit 93a61de409 on esp-develop febae182e1)
- Exit reminder: https://github.com/makrohard/meshcom-qemu-raspi/issues/1 and `.github/workflows/qemu-patch-exit-check.yml`

## Exit: when Espressif ships the change

Espressif imports outside PRs internally and may close #183 without merging it on GitHub. What counts is
a release tag whose `hw/misc/esp32_dport.c` contains `TYPE_ESP32_CACHE_IOMMU`. Then:

1. Delete the patch from this directory and point `QEMU_TAG`/`QEMU_COMMIT` in `scripts/build-qemu.sh`
   at that tag.
2. Update the QEMU install path, pin and docs in loraham-pi-control, and the licence line in
   lhpc-binaries, the same way this patch introduced them.
3. Run the normal LHPC MeshCom test matrix on the box.
4. Close the tracking issue, and delete the temporary fork makrohard/qemu.
