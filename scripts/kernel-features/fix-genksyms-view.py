#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
#
# Keep genksyms from seeing the extra structure definitions that the SUSFS
# hook patches drag into fs/stat.c and fs/statfs.c.
#
# Those patches add
#
#     #ifdef CONFIG_KSU_SUSFS
#     #include <linux/susfs_def.h>
#     #include "mount.h"
#     #endif
#
# to both files.  fs/mount.h is an internal VFS header that defines
# struct mount, struct mountpoint, struct mnt_pcp and (through it) the full
# struct mnt_namespace.  Without it genksyms only ever sees
#
#     struct vfsmount      { UNKNOWN }
#     struct mnt_namespace { UNKNOWN }
#
# in those translation units, and the genksyms CRC of an exported symbol is a
# hash of the symbol's type *as spelled out in that unit*.  Once the full
# definitions become visible, the CRC of every exported symbol whose prototype
# reaches struct path changes:
#
#     vfs_getattr, vfs_getattr_nosec, generic_fillattr, vfs_statfs,
#     vfs_get_fsid, inode_add_bytes, __inode_add_bytes, inode_sub_bytes,
#     __inode_sub_bytes, inode_get_bytes, inode_set_bytes
#
# The vendor modules in vendor_boot / vendor_dlkm were built against the stock
# CRCs, so a change there makes them refuse to load.  Guarding the added
# includes with !defined(__GENKSYMS__) leaves the compiler with exactly the
# same input while genksyms keeps seeing the stock translation unit.
#
# Usage: fix-genksyms-view.py <file> [<file> ...]
#
import re
import sys

# Matches the include block the SUSFS patches insert, in either of the two
# spellings they use ("#endif" or "#endif // ...").
BLOCK = re.compile(
    r"(?P<indent>[ \t]*)#ifdef CONFIG_KSU_SUSFS\r?\n"
    r"(?P<body>(?:[ \t]*#include[^\n]*\r?\n)+)"
    r"(?P<endindent>[ \t]*)#endif[^\n]*\r?\n"
)

GUARD = "#if defined(CONFIG_KSU_SUSFS) && !defined(__GENKSYMS__)"


def fix(path: str) -> bool:
    with open(path, "r") as fh:
        text = fh.read()

    changed = False

    def repl(match: "re.Match") -> str:
        nonlocal changed
        if "__GENKSYMS__" in match.group(0):
            return match.group(0)
        # only touch blocks that actually include something
        if "#include" not in match.group("body"):
            return match.group(0)
        changed = True
        return (f"{match.group('indent')}{GUARD}\n"
                f"{match.group('body')}"
                f"{match.group('endindent')}#endif\n")

    new = BLOCK.sub(repl, text)

    # fs/statfs.c has the two includes glued to a trailing comment line, which
    # the regex above still matches; fs/stat.c is the plain form.  Anything
    # else that survived is handled by the explicit pass below.
    if not changed:
        plain = text.replace(
            "#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n",
            f"{GUARD}\n#include <linux/susfs_def.h>\n")
        if plain != text:
            new = plain
            changed = True

    if changed:
        with open(path, "w") as fh:
            fh.write(new)
        print(f"  guarded SUSFS includes in {path}")
    else:
        print(f"  {path}: nothing to guard (already fixed or no SUSFS includes)")
    return changed


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    for path in argv[1:]:
        fix(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
