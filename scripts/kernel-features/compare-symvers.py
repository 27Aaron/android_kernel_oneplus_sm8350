#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
#
# Compare two Module.symvers files and report the module ABI (symbol CRC)
# difference between them.
#
# A pristine kernel built from the same base commit with the stock defconfig
# is the reference.  The vendor kernel modules that ship inside vendor_boot /
# vendor_dlkm were built against that reference, so every symbol that exists
# in both files must keep the exact same CRC - otherwise modpost/insmod
# refuses to load them ("disagrees about version of symbol ...") and the
# device loses Wi-Fi, display or storage.
#
# Usage:
#   compare-symvers.py <baseline/Module.symvers> <new/Module.symvers>
#
# Exit status: 0 = ABI preserved, 1 = ABI changed, 2 = usage/parse error.
#
import sys

# A few symbols are known to be volatile and are not consumed by modules.
IGNORED = {
    # genksyms emits a CRC for these but they are never used for module
    # versioning decisions.
    "__crc_",
}


def parse(path):
    """Return {symbol: crc} for a Module.symvers file."""
    symbols = {}
    with open(path, "r", errors="replace") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                print(f"warning: {path}:{lineno}: cannot parse {line!r}",
                      file=sys.stderr)
                continue
            crc, name = parts[0].strip(), parts[1].strip()
            if not crc.startswith("0x"):
                print(f"warning: {path}:{lineno}: odd CRC field {crc!r}",
                      file=sys.stderr)
                continue
            if name in IGNORED:
                continue
            symbols[name] = crc
    return symbols


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2

    baseline = parse(argv[1])
    new = parse(argv[2])

    common = baseline.keys() & new.keys()
    changed = sorted(s for s in common if baseline[s] != new[s])
    removed = sorted(baseline.keys() - new.keys())
    added = sorted(new.keys() - baseline.keys())

    print(f"baseline symbols : {len(baseline)}")
    print(f"new symbols      : {len(new)}")
    print(f"common symbols   : {len(common)}")
    print(f"changed CRC      : {len(changed)}")
    print(f"removed          : {len(removed)}")
    print(f"added            : {len(added)}")
    print()

    if changed:
        print("!! symbols whose CRC changed (vendor modules WILL fail to load):")
        for sym in changed[:200]:
            print(f"   {sym}: {baseline[sym]} -> {new[sym]}")
        if len(changed) > 200:
            print(f"   ... and {len(changed) - 200} more")
        print()

    if removed:
        print("!! symbols that disappeared:")
        for sym in removed[:200]:
            print(f"   {sym} ({baseline[sym]})")
        if len(removed) > 200:
            print(f"   ... and {len(removed) - 200} more")
        print()

    if added:
        print(f"note: {len(added)} new exported symbols (informational only), e.g.")
        for sym in added[:20]:
            print(f"   {sym} ({new[sym]})")
        print()

    if changed or removed:
        print("RESULT: module ABI CHANGED - do not flash this kernel.")
        return 1

    print("RESULT: module ABI preserved - every pre-existing exported symbol "
          "keeps its CRC.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
