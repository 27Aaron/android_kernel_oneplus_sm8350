#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# OnePlus 9 Pro (lemonadep / sm8350 / lahaina, msm-5.4) feature integration:
#
#   * Droidspaces     - container support.  Config only; the option block
#                       already lives in vendor/lahaina-qgki_defconfig, so
#                       this script has nothing to do for it.
#   * KernelSU-Next   - root solution, integrated in "manual hook" mode.  A
#                       5.4 kernel is GKI 1.0 for KernelSU: the tracepoint
#                       redirector does not exist there, so the hook sites
#                       are patched into the source directly.
#   * SUSFS           - root hiding, required by Droidspaces users who need to
#                       pass Play Integrity.  Kernel side comes from the
#                       community 5.4 backport by JackA1ltman; the driver side
#                       is already part of the KernelSU-Next "legacy-susfs"
#                       branch that init_ksu.sh installs.
#
# Written for a Linux host (GNU sed / GNU patch); it cd's into the kernel root
# itself, so it can be run from anywhere.
#
# Environment:
#   KSU_SETUP_URL      where to fetch KernelSU-Next's setup.sh from
#   KSU_BRANCH         branch to check out (default legacy-susfs)
#   SUSFS_PATCH_URL    where to fetch the 5.4 SUSFS backport from
#   HOOK_PATCH_URL     where to fetch syscall_hook_patches.sh from
#   OUT=<dir>          if set, also force the KernelSU/SUSFS kconfig options
#                      into $OUT/.config (run after `make <defconfig>`)
#
# Usage:
#   bash scripts/kernel-features/apply.sh
#   OUT=out bash scripts/kernel-features/apply.sh --config-only
#
set -euo pipefail

CONFIG_ONLY=0
for arg in "$@"; do
	case "$arg" in
		--config-only) CONFIG_ONLY=1 ;;
		-h|--help) sed -n '2,34p' "$0"; exit 0 ;;
		*) echo "unknown argument: $arg" >&2; exit 2 ;;
	esac
done

KERNEL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FEATURE_DIR="$KERNEL_ROOT/scripts/kernel-features"

KSU_SETUP_URL="${KSU_SETUP_URL:-https://raw.githubusercontent.com/Gamesmes90/KernelSU-Next/refs/heads/stable-susfs/kernel/setup.sh}"
KSU_BRANCH="${KSU_BRANCH:-legacy-susfs}"
PATCH_SHA="${PATCH_SHA:-0543b379c0c96c5ff92871260b04da8dfcb5c690}"
PATCH_BASE="${PATCH_BASE:-https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/${PATCH_SHA}/Patches}"
SUSFS_PATCH_URL="${SUSFS_PATCH_URL:-${PATCH_BASE}/Patch/susfs_patch_to_5.4.patch}"
HOOK_PATCH_URL="${HOOK_PATCH_URL:-${PATCH_BASE}/syscall_hook_patches.sh}"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

cd "$KERNEL_ROOT"

# ---------------------------------------------------------------------------
# 0. sanity
# ---------------------------------------------------------------------------
[[ -f Makefile && -d drivers ]] || die "not a kernel tree: $KERNEL_ROOT"
grep -q '^VERSION = 5' Makefile || warn "expected a 5.x kernel"
grep -q '^PATCHLEVEL = 4' Makefile || warn "this integration is written for 5.4"

command -v sed >/dev/null || die "sed is required"
sed --version >/dev/null 2>&1 || die "GNU sed is required"
command -v python3 >/dev/null || die "python3 is required"
if [[ "$CONFIG_ONLY" == "0" ]]; then
	command -v patch >/dev/null || die "patch is required"
	command -v curl >/dev/null || die "curl is required"
	command -v git  >/dev/null || die "git is required"
fi

log "kernel tree  : $KERNEL_ROOT"
log "KernelSU-Next: $KSU_BRANCH"
log "SUSFS        : 5.4 backport, manual hook mode"
log "mode         : $([[ "$CONFIG_ONLY" == "1" ]] && echo "kconfig only" || echo "source + kconfig")"

tmpdir=""
cleanup() { [[ -n "$tmpdir" ]] && rm -rf "$tmpdir"; return 0; }
trap cleanup EXIT

fetch() { # fetch <url> <dest>
	curl -LSs --retry 3 --retry-delay 2 -o "$2" "$1" || die "failed to download $1"
	[[ -s "$2" ]] || die "downloaded $1 is empty"
}

if [[ "$CONFIG_ONLY" == "0" ]]; then

tmpdir="$(mktemp -d)"

# ---------------------------------------------------------------------------
# 1. KernelSU-Next driver
# ---------------------------------------------------------------------------
# setup.sh, run from the kernel root:
#   * git clone https://github.com/Gamesmes90/KernelSU-Next
#   * git checkout <branch>                (legacy-susfs carries SUSFS support)
#   * ln -s KernelSU-Next/kernel drivers/kernelsu
#   * append "obj-$(CONFIG_KSU) += kernelsu/" to drivers/Makefile
#   * insert 'source "drivers/kernelsu/Kconfig"' into drivers/Kconfig
# NOTE: KernelSU-Next/.git has to survive - the driver Kbuild reads it for the
# version string and hard-errors without it.
wire_driver() {
	# what setup.sh does after cloning, minus the network
	ln -sf "$(realpath --relative-to=drivers KernelSU-Next/kernel)" drivers/kernelsu
	grep -q 'kernelsu' drivers/Makefile \
		|| printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
	grep -q 'kernelsu/Kconfig' drivers/Kconfig \
		|| sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
}

if [[ -d KernelSU-Next/.git || -e drivers/kernelsu ]]; then
	log "KernelSU-Next driver already present, skipping the install step"
elif [[ -n "${KSU_PREBUILT_DIR:-}" && -d "${KSU_PREBUILT_DIR}/.git" ]]; then
	# Preferred path: a clone made ahead of time.  github.com is not always
	# reachable from the build container, and a failed clone there costs a
	# whole build cycle.
	log "Installing KernelSU-Next from the pre-cloned copy at $KSU_PREBUILT_DIR"
	cp -a "$KSU_PREBUILT_DIR" KernelSU-Next || die "could not copy the pre-cloned driver"
	git -C KernelSU-Next checkout -q "$KSU_BRANCH" 2>/dev/null \
		|| warn "could not check out $KSU_BRANCH, using whatever HEAD is"
	wire_driver
else
	log "Installing KernelSU-Next ($KSU_BRANCH) over the network"
	fetch "$KSU_SETUP_URL" "$tmpdir/setup.sh"
	bash "$tmpdir/setup.sh" "$KSU_BRANCH" || die "KernelSU-Next setup.sh failed"
fi

[[ -d KernelSU-Next/.git ]] || die "KernelSU-Next/.git missing - the driver Kbuild will refuse to build"
[[ -e drivers/kernelsu ]] || die "drivers/kernelsu symlink was not created"
grep -q 'kernelsu' drivers/Makefile || die "drivers/Makefile was not hooked up"
grep -q 'kernelsu/Kconfig' drivers/Kconfig || die "drivers/Kconfig was not hooked up"
log "driver at $(git -C KernelSU-Next rev-parse --short HEAD 2>/dev/null) on $(git -C KernelSU-Next rev-parse --abbrev-ref HEAD 2>/dev/null)"

# ---------------------------------------------------------------------------
# 2. SUSFS kernel side
# ---------------------------------------------------------------------------
log "Applying the SUSFS 5.4 backport (SUSFS v2.3.x)"
fetch "$SUSFS_PATCH_URL" "$tmpdir/susfs.patch"
grep -q 'SUSFS_VERSION' "$tmpdir/susfs.patch" || die "the downloaded SUSFS patch looks wrong"

# The upstream patch carries one hunk for fs/proc/fd.c that does not fit this
# tree: OPLUS prints an extra "ino:" field in the fdinfo output, so the context
# around it differs.  Drop that file from the patch and apply our own adapted
# version right after.
awk '
	/^diff --git / { skip = ($NF == "b/fs/proc/fd.c") }
	!skip { print }
' "$tmpdir/susfs.patch" > "$tmpdir/susfs-nofd.patch"
grep -q 'b/fs/proc/fd\.c' "$tmpdir/susfs-nofd.patch" \
	&& die "failed to strip fs/proc/fd.c from the upstream SUSFS patch"
log "stripped fs/proc/fd.c from the upstream patch (OPLUS fdinfo differs)"

patch -p1 --forward --no-backup-if-mismatch < "$tmpdir/susfs-nofd.patch" \
	|| die "SUSFS core patch failed - see the .rej files"
patch -p1 --forward --no-backup-if-mismatch \
	< "$FEATURE_DIR/fixups/0001-susfs-fs-proc-fd.diff" \
	|| die "SUSFS fs/proc/fd.c fixup failed"

# ---------------------------------------------------------------------------
# 3. KernelSU manual hook call sites
# ---------------------------------------------------------------------------
# 5.4 has no tracepoint redirector, so the call sites are patched in directly.
log "Applying the KernelSU manual hook patches"
fetch "$HOOK_PATCH_URL" "$tmpdir/syscall_hook_patches.sh"
bash "$tmpdir/syscall_hook_patches.sh" || die "syscall_hook_patches.sh failed"

# ---------------------------------------------------------------------------
# 4. reject / marker check
# ---------------------------------------------------------------------------
log "Checking for patch rejects"
rejects="$(find . -path ./.git -prune -o -name '*.rej' -print 2>/dev/null || true)"
if [[ -n "$rejects" ]]; then
	echo "$rejects"
	die "unresolved patch rejects"
fi

log "Checking that the hook call sites are wired up"
for pair in "fs/exec.c:ksu_handle_execveat" \
	    "fs/open.c:ksu_handle_faccessat" \
	    "fs/stat.c:ksu_handle_stat" \
	    "kernel/reboot.c:ksu_handle_sys_reboot" \
	    "kernel/sys.c:ksu_handle_setresuid"; do
	file="${pair%%:*}"; sym="${pair##*:}"
	grep -q "$sym" "$file" || die "missing hook $sym in $file"
	echo "  ok      $sym in $file"
done

for f in fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h; do
	[[ -f "$f" ]] || die "SUSFS file missing: $f"
done

# ---------------------------------------------------------------------------
# 3b. backport path_umount()
# ---------------------------------------------------------------------------
# KernelSU uses path_umount() to unmount the module overlay from the app
# process (feature/kernel_umount.c).  It only exists in kernels after 5.4, so
# it has to be backported; the driver declares it extern itself, so nothing
# outside fs/namespace.c needs to change.  can_umount() is the other half of
# the same upstream commit and is not in this tree either.
log "Backporting path_umount() for the KernelSU umount feature"
if grep -q '^int path_umount(struct path \*path, int flags)' fs/namespace.c; then
	echo "  already present"
else
	python3 - <<'PY'
import io, sys

path = "fs/namespace.c"
src = io.open(path, encoding="utf-8").read()

anchor = """SYSCALL_DEFINE1(oldumount, char __user *, name)
{
\treturn ksys_umount(name, 0);
}

#endif
"""
if anchor not in src:
    sys.exit("fs/namespace.c: cannot find the oldumount block to anchor on")

can_umount = """static int can_umount(const struct path *path, int flags)
{
\tstruct mount *mnt = real_mount(path->mnt);

\tif (flags & ~(MNT_FORCE | MNT_DETACH | MNT_EXPIRE | UMOUNT_NOFOLLOW))
\t\treturn -EINVAL;
\tif (!may_mount())
\t\treturn -EPERM;
\tif (path->dentry != path->mnt->mnt_root)
\t\treturn -EINVAL;
\tif (!check_mnt(mnt))
\t\treturn -EINVAL;
\tif (mnt->mnt.mnt_flags & MNT_LOCKED)
\t\treturn -EINVAL;
\tif (flags & MNT_FORCE && !capable(CAP_SYS_ADMIN))
\t\treturn -EPERM;
\treturn 0;
}

int path_umount(struct path *path, int flags)
{
\tstruct mount *mnt = real_mount(path->mnt);
\tint ret;

\tret = can_umount(path, flags);
\tif (!ret)
\t\tret = do_umount(mnt, flags);

\t/* we mustn't call path_put() as that would clear mnt_expiry_mark */
\tdput(path->dentry);
\tmntput_no_expire(mnt);
\treturn ret;
}
"""

src = src.replace(anchor, anchor + "\n" + can_umount, 1)
io.open(path, "w", encoding="utf-8").write(src)
print("  inserted can_umount() and path_umount() into fs/namespace.c")
PY
fi

grep -q '^int path_umount(struct path \*path, int flags)' fs/namespace.c \
	|| die "path_umount backport did not land"

# ---------------------------------------------------------------------------
# 4a. export susfs_run_sus_path_loop()
# ---------------------------------------------------------------------------
# The community 5.4 backport defines this as static, but the KernelSU-Next
# driver calls it from another translation unit (hook/setuid_hook.c), so the
# link fails with "undefined symbol: susfs_run_sus_path_loop".  The upstream
# tree this configuration is modelled on drops the static keyword and nothing
# else - the header is byte-identical between the two - so do the same.
log "Exporting susfs_run_sus_path_loop() for the KernelSU-Next driver"
if grep -q '^static void susfs_run_sus_path_loop(void)' fs/susfs.c; then
	sed -i 's|^static void susfs_run_sus_path_loop(void)|void susfs_run_sus_path_loop(void)|' fs/susfs.c
	echo "  dropped the static keyword in fs/susfs.c"
elif grep -q '^void susfs_run_sus_path_loop(void)' fs/susfs.c; then
	echo "  already exported"
else
	die "fs/susfs.c: cannot find susfs_run_sus_path_loop to export"
fi

# ---------------------------------------------------------------------------
# 4b. make sure fs/stat.c can actually see the SUSFS constants
# ---------------------------------------------------------------------------
# The 5.4 backport patches the body of fs/stat.c to use STATX_SUS_KSTAT and
# STATX_SUS_KSTAT_FUSE, and adds a block of extern declarations, but on this
# tree it does not add the include that defines those constants.  Add it
# ourselves, already wrapped in the __GENKSYMS__ guard used below.
log "Checking that fs/stat.c can see the SUSFS constants"
if ! grep -q 'linux/susfs_def.h' fs/stat.c; then
	python3 - <<'PY'
import io, re, sys
path = "fs/stat.c"
src = io.open(path, encoding="utf-8").read()
anchor = "#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\nextern bool susfs_is_inode_sus_kstat"
if anchor not in src:
    sys.exit("fs/stat.c: cannot find the SUSFS extern block to anchor on")
block = (
    "#if defined(CONFIG_KSU_SUSFS) && !defined(__GENKSYMS__)\n"
    "#include <linux/susfs_def.h>\n"
    "#endif\n\n"
)
src = src.replace(anchor, block + anchor, 1)
io.open(path, "w", encoding="utf-8").write(src)
print("  inserted the guarded susfs_def.h include into fs/stat.c")
PY
else
	echo "  fs/stat.c already includes susfs_def.h"
fi

# ---------------------------------------------------------------------------
# 5. genksyms view (module ABI)
# ---------------------------------------------------------------------------
# The SUSFS hook patches pull fs/mount.h into fs/stat.c and fs/statfs.c, which
# makes genksyms see full definitions of struct vfsmount / struct mount /
# struct mnt_namespace where the stock kernel only saw { UNKNOWN }.  That moves
# the CRC of vfs_statfs, vfs_get_fsid, vfs_getattr, generic_fillattr, ... and
# the vendor modules in vendor_boot / vendor_dlkm were built against the stock
# values.  Guard the includes so genksyms keeps seeing the stock unit.
log "Restoring the stock genksyms view in fs/stat.c / fs/statfs.c"
python3 "$FEATURE_DIR/fix-genksyms-view.py" fs/stat.c fs/statfs.c \
	|| die "genksyms view fixup failed"

fi # CONFIG_ONLY == 0

# ---------------------------------------------------------------------------
# 6. kconfig
# ---------------------------------------------------------------------------
# Mirrors what the KernelSU-Next Kconfig expects for a 5.4 tree.
ksu_config=(
	"CONFIG_KSU=y"
	"CONFIG_KSU_DEBUG=n"
	"CONFIG_KSU_ALLOWLIST_WORKAROUND=n"
	# 5.4 is GKI 1.0: kprobes/tracepoint hooks are not usable, so manual
	# hooking is mandatory.  KSU_MANUAL_HOOK is a plain bool and the
	# dynamic hook options sit in its "else" choice, so enabling it makes
	# KSU_KPROBES_HOOK / KSU_SYSCALL_TABLE_HOOK disappear on their own.
	"CONFIG_KSU_MANUAL_HOOK=y"
	# SUSFS, from the legacy-susfs branch of the driver.
	"CONFIG_KSU_SUSFS=y"
	"CONFIG_KSU_SUSFS_SUS_PATH=y"
	"CONFIG_KSU_SUSFS_SUS_MOUNT=y"
	"CONFIG_KSU_SUSFS_SUS_KSTAT=y"
	"CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
	"CONFIG_KSU_SUSFS_ENABLE_LOG=y"
	"CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y"
	"CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y"
	"CONFIG_KSU_SUSFS_OPEN_REDIRECT=y"
	"CONFIG_KSU_SUSFS_SUS_MAP=y"
)

apply_kconfig() { # apply_kconfig <config-file>
	local cfg="$1" entry opt val
	[[ -f "$cfg" ]] || die "no such config file: $cfg"
	for entry in "${ksu_config[@]}"; do
		opt="${entry%%=*}"; val="${entry#*=}"
		if [[ "$val" == "n" ]]; then
			if grep -q "^${opt}=" "$cfg"; then
				sed -i "s|^${opt}=.*|# ${opt} is not set|" "$cfg"
			elif ! grep -q "^# ${opt} is not set" "$cfg"; then
				printf '# %s is not set\n' "$opt" >> "$cfg"
			fi
		else
			if grep -q "^# ${opt} is not set" "$cfg"; then
				sed -i "s|^# ${opt} is not set|${opt}=${val}|" "$cfg"
			elif grep -q "^${opt}=" "$cfg"; then
				sed -i "s|^${opt}=.*|${opt}=${val}|" "$cfg"
			else
				printf '%s=%s\n' "$opt" "$val" >> "$cfg"
			fi
		fi
	done
}

if [[ -n "${OUT:-}" ]]; then
	log "Forcing KernelSU/SUSFS options into $OUT/.config"
	apply_kconfig "$OUT/.config"
	resolved="$(grep -cE '^CONFIG_KSU(_SUSFS)?=' "$OUT/.config" || true)"
	log "KSU options present in .config: $resolved"
else
	log "OUT not set - .config untouched (defconfig already carries the options)"
fi

log "Done"
