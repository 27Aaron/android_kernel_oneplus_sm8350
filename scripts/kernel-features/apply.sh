#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# OnePlus 9 Pro (lemonadep / sm8350 / lahaina, msm-5.4) feature integration:
#
#   * Droidspaces  - Linux container support (config only, see the
#                    Droidspaces block already present in
#                    arch/arm64/configs/vendor/lahaina-qgki_defconfig)
#   * ReSukiSU     - KernelSU fork, integrated in "manual hook" mode, which
#                    is the only mode supported on a 5.4 kernel.
#   * SUSFS        - optional root hiding (WITH_SUSFS=1, the default).
#
# The script is written for a Linux host (GNU sed / GNU patch) and must be
# run from anywhere; it cd's into the kernel root itself.
#
# Environment:
#   WITH_SUSFS=1|0    enable the SUSFS patch set (default 1)
#   KSU_SHA=<sha>     ReSukiSU/BakaSU commit to pin (default below)
#   PATCH_SHA=<sha>   NonGKI_Kernel_Build_2nd commit to pin (default below)
#   OUT=<dir>         if set, also force the KernelSU/SUSFS kconfig options
#                     into $OUT/.config (run after `make <defconfig>`)
#
# Usage:
#   WITH_SUSFS=1 bash scripts/kernel-features/apply.sh
#   OUT=out bash scripts/kernel-features/apply.sh --config-only
#
set -euo pipefail

CONFIG_ONLY=0
for arg in "$@"; do
	case "$arg" in
		--config-only) CONFIG_ONLY=1 ;;
		-h|--help) sed -n '2,30p' "$0"; exit 0 ;;
		*) echo "unknown argument: $arg" >&2; exit 2 ;;
	esac
done

KERNEL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FEATURE_DIR="$KERNEL_ROOT/scripts/kernel-features"

WITH_SUSFS="${WITH_SUSFS:-1}"
# ReSukiSU was renamed to BakaSU; the setup.sh below is fetched through the
# old (still resolving) URL but checked out at this exact commit.
KSU_SHA="${KSU_SHA:-c8dc617dd7e19630bc5f39f678cd93de798559d2}"
KSU_SETUP_URL="${KSU_SETUP_URL:-https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/${KSU_SHA}/kernel/setup.sh}"
PATCH_SHA="${PATCH_SHA:-0543b379c0c96c5ff92871260b04da8dfcb5c690}"
PATCH_BASE="${PATCH_BASE:-https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/${PATCH_SHA}/Patches}"
SUSFS_PATCH_URL="${SUSFS_PATCH_URL:-${PATCH_BASE}/Patch/susfs_patch_to_5.4.patch}"

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
sed --version >/dev/null 2>&1 || die "GNU sed is required (this script uses 'sed -i' without a backup suffix)"
command -v python3 >/dev/null || die "python3 is required"
if [[ "$CONFIG_ONLY" == "0" ]]; then
	command -v patch >/dev/null || die "patch is required"
	command -v curl >/dev/null || die "curl is required"
fi

log "kernel tree : $KERNEL_ROOT"
log "ReSukiSU    : $KSU_SHA"
log "SUSFS       : $([[ "$WITH_SUSFS" == "1" ]] && echo "enabled" || echo "disabled")"
log "mode        : $([[ "$CONFIG_ONLY" == "1" ]] && echo "kconfig only" || echo "source + kconfig")"

tmpdir=""
# NOTE: an EXIT trap replaces the script's exit status with its own, so this
# must always succeed.  `[[ ... ]] && cmd` as the last statement returns 1 when
# the test is false, which silently turned a successful --config-only run into
# "Process completed with exit code 1".
cleanup() {
	if [[ -n "$tmpdir" ]]; then
		rm -rf "$tmpdir"
	fi
	return 0
}
trap cleanup EXIT

if [[ "$CONFIG_ONLY" == "0" ]]; then

# ---------------------------------------------------------------------------
# 1. ReSukiSU (BakaSU) driver
# ---------------------------------------------------------------------------
# setup.sh does, relative to the kernel root:
#   * git clone <BakaSU> KernelSU
#   * ln -s KernelSU/kernel drivers/kernelsu
#   * append "obj-\$(CONFIG_KSU) += kernelsu/" to drivers/Makefile
#   * insert 'source "drivers/kernelsu/Kconfig"' into drivers/Kconfig
# NOTE: KernelSU/.git must survive, the driver's Kbuild hard-errors without it.
if [[ -d KernelSU/.git || -e drivers/kernelsu ]]; then
	log "ReSukiSU driver already present, skipping setup.sh"
else
	log "Installing ReSukiSU/BakaSU driver"
	curl -LSs "$KSU_SETUP_URL" | bash -s "$KSU_SHA"
fi

[[ -d KernelSU/.git ]] || die "KernelSU/.git missing - the driver Kbuild will refuse to build"
[[ -e drivers/kernelsu ]] || die "drivers/kernelsu symlink was not created"
grep -q 'kernelsu' drivers/Makefile || die "drivers/Makefile was not hooked up"
grep -q 'kernelsu/Kconfig' drivers/Kconfig || die "drivers/Kconfig was not hooked up"

# ---------------------------------------------------------------------------
# 2. syscall hooks
# ---------------------------------------------------------------------------
# 5.4 is "GKI 1.0" for KernelSU: the tracepoint redirector is compiled out and
# an $(error) is raised, so CONFIG_KSU_MANUAL_HOOK (or the SUSFS inline hook
# variant) is mandatory and the call sites have to be patched into the tree.
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fetch() { # fetch <url> <dest>
	curl -LSs --retry 3 --retry-delay 2 -o "$2" "$1" || die "failed to download $1"
}

if [[ "$WITH_SUSFS" == "1" ]]; then
	# -----------------------------------------------------------------
	# 2a. SUSFS core (fs/susfs.c, include/linux/susfs*.h + the wiring)
	# -----------------------------------------------------------------
	log "Applying SUSFS core patch (SUSFS v2.3.x backport for 5.4)"
	fetch "$SUSFS_PATCH_URL" "$tmpdir/susfs.patch"
	grep -q 'SUSFS_VERSION' "$tmpdir/susfs.patch" || die "downloaded SUSFS patch looks wrong"

	# The upstream patch carries one hunk for fs/proc/fd.c that does not fit
	# this tree (OPLUS added 'ino:' to the fdinfo output).  Drop that file
	# from the patch and apply our own, adapted version right after.
	awk '
		/^diff --git / { skip = ($NF == "b/fs/proc/fd.c") }
		!skip { print }
	' "$tmpdir/susfs.patch" > "$tmpdir/susfs-nofd.patch"
	if grep -q 'b/fs/proc/fd\.c' "$tmpdir/susfs-nofd.patch"; then
		die "failed to strip fs/proc/fd.c from the upstream SUSFS patch"
	fi
	log "stripped fs/proc/fd.c from the upstream SUSFS patch"

	patch -p1 --forward --no-backup-if-mismatch < "$tmpdir/susfs-nofd.patch" \
		|| die "SUSFS core patch failed (see the .rej files)"
	patch -p1 --forward --no-backup-if-mismatch \
		< "$FEATURE_DIR/fixups/0001-susfs-fs-proc-fd.diff" \
		|| die "SUSFS fs/proc/fd.c fixup failed"

	# -----------------------------------------------------------------
	# 2b. SUSFS inline hooks
	# -----------------------------------------------------------------
	log "Applying SUSFS inline hooks"
	fetch "${PATCH_BASE}/susfs_inline_hook_patches.sh" "$tmpdir/susfs_inline_hook_patches.sh"
	bash "$tmpdir/susfs_inline_hook_patches.sh" || die "susfs_inline_hook_patches.sh failed"
else
	# -----------------------------------------------------------------
	# 2b'. plain KernelSU manual hooks
	# -----------------------------------------------------------------
	log "Applying KernelSU manual hooks"
	fetch "${PATCH_BASE}/syscall_hook_patches.sh" "$tmpdir/syscall_hook_patches.sh"
	bash "$tmpdir/syscall_hook_patches.sh" || die "syscall_hook_patches.sh failed"
fi

# ---------------------------------------------------------------------------
# 3. reject / marker check
# ---------------------------------------------------------------------------
log "Checking for patch rejects"
rejects="$(find . -path ./.git -prune -o -name '*.rej' -print 2>/dev/null || true)"
if [[ -n "$rejects" ]]; then
	echo "$rejects"
	die "unresolved patch rejects"
fi

# ---------------------------------------------------------------------------
# 3b. genksyms view fixup (module ABI)
# ---------------------------------------------------------------------------
# The SUSFS hook patches pull fs/mount.h into fs/stat.c and fs/statfs.c, which
# makes genksyms see full definitions of struct vfsmount / struct mount /
# struct mnt_namespace where the stock kernel only saw them as UNKNOWN.  That
# changes the exported symbol CRCs of vfs_getattr, generic_fillattr,
# vfs_statfs, inode_*_bytes, ... and the vendor modules in vendor_boot /
# vendor_dlkm were built against the stock values.
log "Restoring the stock genksyms view in fs/stat.c / fs/statfs.c"
python3 "$FEATURE_DIR/fix-genksyms-view.py" fs/stat.c fs/statfs.c \
	|| die "genksyms view fixup failed"

if [[ "$WITH_SUSFS" == "1" ]]; then
	for f in fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h; do
		[[ -f "$f" ]] || die "SUSFS file missing: $f"
	done
	# Required SUSFS/KernelSU hook call sites.
	for pair in "fs/exec.c:ksu_handle_execveat" \
		    "fs/open.c:ksu_handle_faccessat" \
		    "fs/stat.c:ksu_handle_stat" \
		    "kernel/reboot.c:ksu_handle_sys_reboot"; do
		file="${pair%%:*}"; sym="${pair##*:}"
		grep -q "$sym" "$file" || die "missing hook $sym in $file"
	done
else
	for pair in "fs/exec.c:ksu_handle_execveat" \
		    "fs/open.c:ksu_handle_faccessat" \
		    "fs/stat.c:ksu_handle_stat" \
		    "kernel/reboot.c:ksu_handle_sys_reboot"; do
		file="${pair%%:*}"; sym="${pair##*:}"
		grep -q "$sym" "$file" || die "missing hook $sym in $file"
	done
fi

fi # CONFIG_ONLY == 0

# ---------------------------------------------------------------------------
# 4. kconfig
# ---------------------------------------------------------------------------
# Shared options.  CONFIG_KSU_TRACEPOINT_HOOK is the Kconfig 'choice' default
# and MUST be turned off explicitly, otherwise 5.4 fails the Kbuild check.
ksu_config=(
	"CONFIG_KSU=y"
	"CONFIG_KSU_DEBUG=n"
	"CONFIG_KSU_MULTI_MANAGER_SUPPORT=y"
)

if [[ "$WITH_SUSFS" == "1" ]]; then
	# CONFIG_KSU_SUSFS is a member of the same Kconfig 'choice' as
	# CONFIG_KSU_MANUAL_HOOK, so the two are mutually exclusive.
	ksu_config+=(
		"CONFIG_KSU_TRACEPOINT_HOOK=n"
		"CONFIG_KSU_MANUAL_HOOK=n"
		"CONFIG_KSU_SUSFS=y"
		"CONFIG_KSU_SUSFS_SUS_PATH=y"
		"CONFIG_KSU_SUSFS_SUS_MOUNT=y"
		"CONFIG_KSU_SUSFS_SUS_KSTAT=y"
		"CONFIG_KSU_SUSFS_SUS_MAP=y"
		"CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
		"CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y"
		"CONFIG_KSU_SUSFS_OPEN_REDIRECT=y"
		"CONFIG_KSU_SUSFS_ENABLE_LOG=y"
		"CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y"
	)
else
	ksu_config+=(
		"CONFIG_KSU_TRACEPOINT_HOOK=n"
		"CONFIG_KSU_MANUAL_HOOK=y"
		"CONFIG_KSU_SUSFS=n"
	)
fi

printf '%s\n' "${ksu_config[@]}" > "$FEATURE_DIR/kernel-features.config"
log "kconfig options written to scripts/kernel-features/kernel-features.config"

if [[ -n "${OUT:-}" && -f "$OUT/.config" ]]; then
	log "Forcing KernelSU/SUSFS options into $OUT/.config"
	for entry in "${ksu_config[@]}"; do
		key="${entry%%=*}"; val="${entry##*=}"
		if [[ "$val" == "y" ]]; then
			scripts/config --file "$OUT/.config" --enable  "${key#CONFIG_}"
		else
			scripts/config --file "$OUT/.config" --disable "${key#CONFIG_}"
		fi
	done
	# NOTE: deliberately no `make olddefconfig` here.
	#
	# The caller has to run it with the *same* toolchain arguments as the
	# real build (`LLVM=1 LLVM_IAS=1 ...`).  Running it from this script
	# would use the host default compiler, and for the LTO kconfig choice
	# that changes the answer: the GCC probe makes CONFIG_LTO_CLANG
	# unavailable and the choice silently falls back to CONFIG_LTO_NONE,
	# which also drops CONFIG_CFI_CLANG and turns the -Wframe-larger-than
	# warnings into hard errors.
	log "Run 'make O=$OUT ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE= CLANG_TRIPLE=aarch64-linux-gnu- olddefconfig' next."
fi

log "Done. Kernel is ready to be configured and built."
