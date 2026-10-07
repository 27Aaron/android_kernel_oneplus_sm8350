# prebuilt/

`boot-ramdisk.lz4` is the LZ4 compressed generic boot ramdisk, taken verbatim
from the stock `boot.img` of

    Project_Infinity-X-3.12-lemonadep-06.07.2026-GAPPS-OFFICIAL.zip

(partition `boot` extracted from that OTA's `payload.bin`; the ROM's kernel
reports `5.4.302-qgki-gb0634b416a64-dirty`).

    layout  : boot.img header v3, page size 4096, os_version 0x200001a7
              header  @ 0          (1580 bytes, padded to 4096)
              kernel  @ 4096       (43891200 bytes)
              ramdisk @ 43896832   (this file)
    size    : 1432426 bytes
    sha256  : 68027ceef2049c75ca0d4866ee3383cc045c39fe91d0d5c492eb525cf77a5d88

`boot-avb.bin` is the 2432 byte AVB vbmeta block that sits immediately after
the page-aligned ramdisk in the same stock `boot.img`:

    offset : 45330432
    size   : 2432 bytes
    sha256 : 91b17b41e9dcdb6920998a8de76e3b326cc01b6dc34ba58f2a98957431eacad

`pack-boot.py --avb` places it right after the freshly built kernel + ramdisk
and writes a regenerated `AvbFooter` (`"AVBf"`, original_image_size =
vbmeta_offset = content end, vbmeta_size = 2432) into the last 64 bytes of the
partition, so the result reproduces the stock partition layout exactly.  Use
`--os-version 0x200001a7` to keep the header field identical to the stock
image; a plain `mkbootimg` output without the AVB block would still boot on an
unlocked bootloader, but this keeps the image layout byte-compatible with the
one the ROM ships.

If you move to a different ROM build, re-extract both files from that build's
`boot.img`, otherwise first stage init may be out of sync with the rest of the
ROM.

`infinityx-vendor-modules.symvers` is the symbol/CRC set that the ROM's 84
vendor modules (`vendor_dlkm`) import, in `Module.symvers` format.  It is the
authoritative module ABI baseline: a replacement kernel must not change a
single CRC in it, otherwise the stock modules are refused at load time
("disagrees about version of symbol") and the device loses Wi-Fi, Bluetooth,
display or camera.  Regenerate with:

    payload-dumper-go -partitions vendor_dlkm -o out payload.bin
    fsck.erofs --extract=vdlkm out/vendor_dlkm.img
    python3 scripts/kernel-features/rom-modules-symvers.py \
        vdlkm/lib/modules/*.ko > prebuilt/infinityx-vendor-modules.symvers
