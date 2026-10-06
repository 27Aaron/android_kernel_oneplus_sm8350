#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
#
# Build a boot.img (Android boot image header v3) for the OnePlus 9 Pro
# (lemonadep).  Standalone replacement for mkbootimg + the AOSP build system,
# so that a CI job only needs the freshly built kernel Image and the stock
# ramdisk extracted from the matching LineageOS build.
#
# Layout (header v3, page size 4096):
#
#   offset 0                     header (1580 bytes, padded to page size)
#   offset page_size             kernel  (Image,         padded to page size)
#   offset page_size*(1+n)       ramdisk (lz4 cpio,     padded to page size)
#   offset content_end           AVB vbmeta block  (--avb, optional)
#   offset pad_to - 64           AVBf footer       (--avb, optional)
#
# Header v3 has no second stage and no recovery dtbo; the DTB lives in
# vendor_boot.img on this device, and the kernel command line is passed
# through vendor_boot as well (the stock boot.img has an empty cmdline).
#
# The stock LineageOS boot image is an AVB ("Android Verified Boot") image:
# a 2432 byte vbmeta block sits immediately after the ramdisk, and the 64 byte
# AvbFooter that points at it sits in the last 64 bytes of the partition.
# prebuilt/boot-avb.bin is that block copied from the stock image; the footer
# is regenerated here so that it points at the new content end.  This
# reproduces the stock partition layout exactly (same offsets, same image
# size).  On an unlocked bootloader the stale hash is not enforced, which is
# the same situation as for any other custom kernel flashed on this device.
#
# Usage:
#   pack-boot.py --kernel Image --ramdisk ramdisk.lz4 --output boot.img \
#                [--avb prebuilt/boot-avb.bin] \
#                [--os-version 0x200001a9] [--pad-to 201326592]
#
import argparse
import os
import struct
import sys

BOOT_MAGIC = b"ANDROID!"
BOOT_ARGS_SIZE = 512
BOOT_EXTRA_ARGS_SIZE = 1024
BOOT_NAME_SIZE = 16
HEADER_V3_SIZE = 1580  # 8 + 4*4 + 4 + 4*4 + 4 + 512 + 1024

AVB_FOOTER_MAGIC = b"AVBf"
AVB_FOOTER_SIZE = 64
AVB_FOOTER_VERSION = (1, 0)


def page_align(value: int, page_size: int) -> int:
    return (value + page_size - 1) // page_size * page_size


def build_header(kernel_size: int, ramdisk_size: int, os_version: int,
                 page_size: int, cmdline: str) -> bytes:
    cmdline_bytes = cmdline.encode()
    if len(cmdline_bytes) > BOOT_ARGS_SIZE + BOOT_EXTRA_ARGS_SIZE - 1:
        raise ValueError("cmdline too long for a v3 boot header")

    header = bytearray()
    header += BOOT_MAGIC                       # magic[8]
    header += struct.pack("<I", kernel_size)   # kernel_size
    header += struct.pack("<I", ramdisk_size)  # ramdisk_size
    header += struct.pack("<I", os_version)    # os_version
    header += struct.pack("<I", HEADER_V3_SIZE)  # header_size
    header += struct.pack("<4I", 0, 0, 0, 0)   # reserved[4]
    header += struct.pack("<I", 3)             # header_version
    header += cmdline_bytes.ljust(BOOT_ARGS_SIZE + BOOT_EXTRA_ARGS_SIZE, b"\0")

    assert len(header) == HEADER_V3_SIZE, len(header)
    return bytes(header).ljust(page_align(HEADER_V3_SIZE, page_size), b"\0")


def build_avb_footer(original_image_size: int, vbmeta_offset: int,
                     vbmeta_size: int) -> bytes:
    footer = bytearray()
    footer += AVB_FOOTER_MAGIC
    footer += struct.pack(">II", *AVB_FOOTER_VERSION)
    footer += struct.pack(">QQQ", original_image_size, vbmeta_offset, vbmeta_size)
    footer += b"\0" * 28
    assert len(footer) == AVB_FOOTER_SIZE, len(footer)
    return bytes(footer)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--kernel", required=True, help="path to the raw Image")
    ap.add_argument("--ramdisk", required=True, help="path to the ramdisk (kept byte for byte)")
    ap.add_argument("--output", required=True, help="path of the boot.img to write")
    ap.add_argument("--page-size", type=int, default=4096)
    ap.add_argument("--os-version", default="0x200001a9",
                    help="os_version field; keep the stock value so that the "
                         "bootloader sees an unchanged image (default 0x200001a9)")
    ap.add_argument("--cmdline", default="",
                    help="v3 boot.img cmdline; leave empty, the real one is in vendor_boot")
    ap.add_argument("--pad-to", type=int, default=0,
                    help="zero pad the final image up to this size (partition size)")
    ap.add_argument("--avb", default="",
                    help="stock AVB vbmeta block to place after the ramdisk and "
                         "to point the AvbFooter at; requires --pad-to")
    args = ap.parse_args()

    for path in (args.kernel, args.ramdisk):
        if not os.path.isfile(path):
            print(f"error: {path} does not exist", file=sys.stderr)
            return 1
    if args.avb and not args.pad_to:
        print("error: --avb requires --pad-to", file=sys.stderr)
        return 1
    if args.avb and not os.path.isfile(args.avb):
        print(f"error: {args.avb} does not exist", file=sys.stderr)
        return 1

    kernel = open(args.kernel, "rb").read()
    ramdisk = open(args.ramdisk, "rb").read()
    os_version = int(args.os_version, 0)

    header = build_header(len(kernel), len(ramdisk), os_version,
                          args.page_size, args.cmdline)
    image = bytearray()
    image += header
    image += kernel.ljust(page_align(len(kernel), args.page_size), b"\0")
    image += ramdisk.ljust(page_align(len(ramdisk), args.page_size), b"\0")

    content_end = len(image)
    avb_size = 0
    if args.avb:
        avb = open(args.avb, "rb").read()
        avb_size = len(avb)
        if content_end + avb_size + AVB_FOOTER_SIZE > args.pad_to:
            print("error: content + AVB block does not fit into --pad-to",
                  file=sys.stderr)
            return 1
        image += avb

    if args.pad_to:
        if len(image) > args.pad_to:
            print(f"error: image is {len(image)} bytes, larger than --pad-to "
                  f"{args.pad_to}", file=sys.stderr)
            return 1
        image += b"\0" * (args.pad_to - AVB_FOOTER_SIZE - len(image))
        if args.avb:
            image += build_avb_footer(content_end, content_end, avb_size)
        else:
            image += b"\0" * AVB_FOOTER_SIZE

    with open(args.output, "wb") as fh:
        fh.write(image)

    print(f"boot.img written to {args.output}")
    print(f"  kernel     : {len(kernel):>10} bytes  ({args.kernel})")
    print(f"  ramdisk    : {len(ramdisk):>10} bytes  ({args.ramdisk})")
    print(f"  content end: {content_end:>10} bytes")
    if args.avb:
        print(f"  avb vbmeta : {avb_size:>10} bytes  ({args.avb}) @ {content_end}")
        print(f"  avb footer : {AVB_FOOTER_SIZE:>10} bytes  @ {args.pad_to - AVB_FOOTER_SIZE}")
    print(f"  os_version : {hex(os_version)}")
    print(f"  header     : v3, page size {args.page_size}")
    print(f"  total      : {len(image):>10} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
