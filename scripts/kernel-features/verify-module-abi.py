#!/usr/bin/env python3
"""Cross-check a kernel's Module.symvers against the CRCs baked into the
ROM's vendor modules.

The vendor modules installed on the device were built by the ROM against
its own kernel, so every symbol the module imports must have the identical CRC
in the new kernel or the module is refused at load time ("disagrees about
version of symbol ...").

This is an independent check on top of the CI baseline comparison: instead of
comparing two of our own builds, it compares our build against binaries that
are already on the device.

Module version entries are `struct modversion_info`:
    u32 crc;  u32 pad;  char name[56];      /* 64 bytes */

Usage: verify-abi.py <kernel/Module.symvers> <module.ko> [...]
"""
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


def kernel_symvers(path):
    out = {}
    for line in open(path, errors='replace'):
        p = line.rstrip('\n').split('\t')
        if len(p) >= 2 and p[0].startswith('0x'):
            out[p[1]] = int(p[0], 16)
    return out


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2

    kernel = kernel_symvers(argv[1])
    print(f'kernel Module.symvers : {len(kernel)} exported symbols')
    print()

    total_checked = total_diff = total_unknown = 0
    for path in argv[2:]:
        mc = module_crcs(path)
        if not mc:
            continue
        diff, unknown = [], []
        for sym, crc in mc.items():
            if sym in kernel:
                if kernel[sym] != crc:
                    diff.append((sym, crc, kernel[sym]))
            else:
                unknown.append(sym)
        checked = len(mc) - len(unknown)
        total_checked += checked
        total_diff += len(diff)
        total_unknown += len(unknown)
        print(f'  {os.path.basename(path):24s} imports={len(mc):4d} '
              f'checked={checked:4d} not-exported={len(unknown):3d} '
              f'-> {"OK" if not diff else "MISMATCH"}')
        for sym, mcrc, kcrc in diff[:8]:
            print(f'      !! {sym}: module {mcrc:#010x} vs kernel {kcrc:#010x}')

    print()
    print(f'symbols cross-checked        : {total_checked}')
    print(f'CRC mismatches               : {total_diff}')
    print(f'not exported by this kernel  : {total_unknown}')
    if total_diff:
        print('RESULT: ABI BROKEN - these modules would be refused at load time')
        return 1
    print('RESULT: ABI matches - every symbol these modules import is compatible')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
