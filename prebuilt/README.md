# prebuilt/

`boot-ramdisk.lz4` is the LZ4 compressed generic boot ramdisk taken verbatim
from the stock `boot.img` of

    lineage-23.2-20261005-nightly-lemonadep-signed.zip

(the LineageOS 23.2 nightly built from kernel commit
`187d13cd30e2b22e7c4405b62f162e5218025299`).

It is repacked together with the freshly built kernel `Image` by
`scripts/kernel-features/pack-boot.py` to produce a boot image whose header,
ramdisk and `os_version` field are byte-identical to the stock one, so the
bootloader and first stage init see no difference at all.

    size   : 1788370 bytes
    sha256 : 49f2a82d138f32f9fac0004b3ebf337381d04fc3ca6d8b894562e6bfec6a1c3f
    layout : boot.img header v3, page size 4096
             header  @ 0          (1580 bytes, padded to 4096)
             kernel  @ 4096       (kernel_size padded to 4096)
             ramdisk @ 41234432   (this file)

If you move to a different LineageOS build, re-extract the ramdisk from that
build's `boot.img` and refresh this file, otherwise first stage init may be
out of sync with the rest of the ROM.

---

`boot-avb.bin` is the 2432 byte AVB vbmeta block that sits immediately after
the ramdisk in the same stock `boot.img`:

    offset : 43024384 (= page aligned kernel + ramdisk end)
    size   : 2432 bytes
    sha256 : 1b69bb5001ec0ce7ffae78e394fd3dc81e565448cb08ede430b8c2202f9b07f4

`pack-boot.py --avb` places it right after the freshly built kernel + ramdisk
and writes a regenerated `AvbFooter` (`"AVBf"`, original_image_size =
vbmeta_offset = content end, vbmeta_size = 2432) into the last 64 bytes of the
partition.  That reproduces the stock partition layout exactly - a plain
`mkbootimg` output without the AVB block would still work on an unlocked
bootloader, but this keeps the image byte-compatible with the layout the
device ships with (and with every other custom boot image for this device).
