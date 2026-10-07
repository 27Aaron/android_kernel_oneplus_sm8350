#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
#
# Dump the symbol/CRC pairs that a set of prebuilt kernel modules expects, in
# `Module.symvers` format, so that `compare-symvers.py` can use the modules
# shipped in the ROM as the module ABI baseline.
#
# A kernel module carries a `__versions` section holding one
# `struct modversion_info` per imported symbol:
#
#     u32 crc;  u32 pad;  char name[56];      /* 64 bytes */
#
# The ROM's vendor modules (vendor_boot ramdisk + vendor_dlkm) were built
# against the ROM's own kernel.  If a replacement kernel does not export the
# exact same CRC for one of those symbols, modprobe refuses to load the module
# and the device loses Wi-Fi, Bluetooth, display or camera.  Comparing our
# `Module.symvers` against this extract is therefore a direct, device-specific
# ABI check - much stronger than comparing two of our own builds.
#
# This avoids committing 36 MB of vendor .ko binaries to the repository: the
# derived symbol/CRC list is a few hundred kilobytes of text.
#
# Usage: rom-modules-symvers.py <module.ko> [...] > rom-vendor-modules.symvers
#
import os
import struct
import sys


def elf_sections(data):
    e = '<'
    shoff = struct.unpack_from(e + 'Q', data, 0x28)[0]
    shentsz = struct.unpack_from(e + 'H', data, 0x3a)[0]
    shnum = struct.unpack_from(e + 'H', data, 0x3c)[0]
    shstrndx = struct.unpack_from(e + 'H', data, 0x3e)[0]
    out = []
    for i in range(shnum):
        o = shoff + i * shentsz
        (name, _typ, _flags, _addr, off, size, _link, _info, _align, _entsz) = \
            struct.unpack_from(e + 'IIQQQQIIQQ', data, o)
        out.append({'name': name, 'off': off, 'size': size})
    stroff = out[shstrndx]['off']
    for s in out:
        end = data.index(b'\0', stroff + s['name'])
        s['sname'] = data[stroff + s['name']:end].decode('latin1')
    return out


def module_crcs(path):
    """Return {symbol: crc} for the symbols a module imports."""
    data = open(path, 'rb').read()
    if data[:4] != b'\x7fELF':
        return {}
    secs = {s['sname']: s for s in elf_sections(data)}
    vs = secs.get('__versions')
    if not vs:
        return {}
    raw = data[vs['off']:vs['off'] + vs['size']]
    out = {}
    for i in range(0, len(raw) - 63, 64):
        crc = struct.unpack_from('<I', raw, i)[0]
        name = raw[i + 8:i + 64].split(b'\0')[0].decode('latin1')
        if name:
            out[name] = crc
    return out


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2

    crcs = {}
    conflicts = []
    files = 0
    for path in argv[1:]:
        mc = module_crcs(path)
        if not mc:
            print(f'warning: {path}: no __versions section', file=sys.stderr)
            continue
        files += 1
        for sym, crc in mc.items():
            if sym in crcs and crcs[sym] != crc:
                conflicts.append((sym, crcs[sym], crc, os.path.basename(path)))
                continue
            crcs[sym] = crc

    for sym, first, other, name in conflicts:
        print(f'warning: {sym}: {first:#010x} (from another module) vs '
              f'{other:#010x} ({name})', file=sys.stderr)

    for sym in sorted(crcs):
        print(f'{crcs[sym]:#010x}\t{sym}')

    print(f'{files} modules, {len(crcs)} imported symbols, '
          f'{len(conflicts)} conflicts', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
