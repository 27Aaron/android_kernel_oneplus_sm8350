# Droidspaces + KernelSU-Next + SUSFS for the OnePlus 9 Pro (lemonadep)

Target: **Project Infinity-X 3.12 lemonadep 06.07.2026** (Android 16, sm8350 /
lahaina, kernel `5.4.302-qgki-gb0634b416a64-dirty`), branch `droidspaces-ksun`
on top of LineageOS `android_kernel_oneplus_sm8350` @ `lineage-23.2`
(`187d13cd30e2`).

Verified on hardware 2026-10-07: boots on slot A with the modules from this
tree, display / storage / modules all up, `CONFIG_KSU_SUSFS` active,
Droidspaces installed.

---

## What this branch adds

### 1. Droidspaces (container / namespace support)

`arch/arm64/configs/vendor/lahaina-qgki_defconfig` gains the kABI-safe subset:

```
CONFIG_SYSVIPC=y CONFIG_POSIX_MQUEUE=y
CONFIG_PID_NS=y CONFIG_IPC_NS=y CONFIG_USER_NS=y CONFIG_UTS_NS=y CONFIG_NET_NS=y
CONFIG_DEVTMPFS=y CONFIG_OVERLAY_FS=y
CONFIG_TMPFS_XATTR=y CONFIG_TMPFS_POSIX_ACL=y
CONFIG_VETH=y CONFIG_BRIDGE=y
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_IP6_NF_NAT=y CONFIG_IP6_NF_TARGET_MASQUERADE=y
CONFIG_NETFILTER_XT_TARGET_REJECT=y CONFIG_NETFILTER_XT_TARGET_LOG=y
CONFIG_NETFILTER_XT_MATCH_RECENT=y
CONFIG_IP_SET=y CONFIG_IP_SET_HASH_IP=y CONFIG_IP_SET_HASH_NET=y
CONFIG_NETFILTER_XT_SET=y
CONFIG_NETFILTER_NETLINK_QUEUE=y CONFIG_NETFILTER_NETLINK_LOG=y
CONFIG_NETFILTER_XT_TARGET_NFLOG=y
CONFIG_NET_SCH_TBF=y
CONFIG_MEMCG=y
```

Deliberately **not** enabled, because they move a core structure or an enum
used as an array bound and there is no kABI padding for them (the Droidspaces
documentation rules them out as well):

`CONFIG_CGROUP_DEVICE`, `CONFIG_CGROUP_PIDS`, `CONFIG_CFS_BANDWIDTH`,
`CONFIG_NF_TABLES`, `CONFIG_BRIDGE_NETFILTER`.

Consequence: `--memory` works (MEMCG), `--cpus` and `--pids-limit` do not.

### 2. kABI preservation

`CONFIG_SYSVIPC` and `CONFIG_POSIX_MQUEUE` normally insert fields in the
middle of `struct task_struct` / `struct user_struct`, which moves every
following field and changes genksyms CRCs.  `include/linux/sched.h` and
`include/linux/sched/user.h` move them into the Android kABI padding
(`ANDROID_KABI_USE(1, ...)`) and keep the `__GENKSYMS__` view at the stock
layout, so the exported symbol CRCs stay identical to a stock build.

That is what makes `kabi-baseline` (pristine tree, stock defconfig, same base
commit) come out with **zero** CRC changes.

### 3. KernelSU-Next + SUSFS

`scripts/kernel-features/apply.sh` installs, pinned by commit:

* KernelSU-Next from `Gamesmes90/KernelSU-Next` branch `legacy-susfs`
  (manual hook mode — the only hook mode a 5.4 kernel supports), wired in as
  `KernelSU-Next/` + a `drivers/kernelsu` symlink;
* the SUSFS 2.3 5.4 backport (`JackA1ltman/NonGKI_Kernel_Build_2nd`,
  `susfs_patch_to_5.4.patch`), with an adapted `fs/proc/fd.c` hunk for OPLUS
  (the upstream hunk does not fit this tree), and
* the manual hook call sites (`syscall_hook_patches.sh`), plus the small
  fixups this tree needs: `path_umount()` backport, exporting
  `susfs_run_sus_path_loop()`, a guarded `susfs_def.h` include in `fs/stat.c`
  and the genksyms view fix for `fs/stat.c` / `fs/statfs.c`.

`KSU_SUSFS*` and `KSU_MANUAL_HOOK` are enabled through the defconfig.

### 4. Version pinning

`.scmversion` = `-gb0634b416a64-dirty`, i.e. the release string of the ROM's
own kernel, so `uname -r` and module vermagic are unchanged from the ROM's
point of view.

---

## Build

Linux host (or GitHub Actions, see `.github/workflows/build-lemonadep.yml`).
The workflow uses the AOSP clang the ROM itself was built with
(`clang-r563880`, LLVM 21); any reasonably new clang also works — this tree was
also built successfully with Ubuntu clang 18.1.3 + LLD 18.1.3.

```sh
export PATH=/path/to/clang/bin:$PATH          # llvm-nm/objcopy/objdump needed too
MAKE="make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE= CLANG_TRIPLE=aarch64-linux-gnu-"

# 1. integrate KernelSU-Next + SUSFS + hooks (network, or KSU_PREBUILT_DIR=...)
KSU_PREBUILT_DIR=/path/to/KernelSU-Next-prebuilt WITH_SUSFS=1 \
    bash scripts/kernel-features/apply.sh

# 2. configure and build
$MAKE vendor/lahaina-qgki_defconfig
$MAKE olddefconfig
$MAKE -j"$(nproc)" Image modules
$MAKE INSTALL_MOD_PATH=out/modinst INSTALL_MOD_STRIP=1 modules_install
```

## Package

```sh
# boot.img: our Image + the ROM's stock generic ramdisk + its AVB block
python3 scripts/kernel-features/pack-boot.py \
    --kernel out/arch/arm64/boot/Image \
    --ramdisk prebuilt/boot-ramdisk.lz4 \
    --avb prebuilt/boot-avb.bin \
    --output dist/boot.img \
    --page-size 4096 --os-version 0x200001a7 --pad-to 201326592

# vendor_dlkm.img: the ROM's vendor_dlkm base with all .ko replaced by ours
payload-dumper-go -partitions vendor_dlkm -o /tmp/rom <rom zip>
fsck.erofs --extract=/tmp/vdlkm --overwrite /tmp/rom/vendor_dlkm.img
scripts/kernel-features/repack-vendor-dlkm.sh \
    /tmp/rom/vendor_dlkm.img out/modinst dist/vendor_dlkm.img \
    5.4.302-qgki-gb0634b416a64-dirty
```

`prebuilt/README.md` documents where the ramdisk / AVB block come from and how
to refresh them when the ROM moves to a new build.

## Flash — order matters

```sh
# 1. while the STOCK kernel is still in boot, enter fastbootd and replace the modules
fastboot reboot fastboot
fastboot flash vendor_dlkm vendor_dlkm.img
fastboot reboot bootloader
# 2. then replace the kernel
fastboot flash boot boot-lemonadep-*.img
fastboot reboot
```

**Both images must match.** The ROM was built from its own kernel fork: 2852
of the 5169 symbol CRCs its vendor modules import differ from this tree, so
each side refuses the other's modules (`disagrees about version of symbol`).
Booting this kernel with the ROM's modules — which is what happens if you only
flash `boot` and then `fastboot reboot fastboot` — crashes the boot chain into
XBL ramdump mode.  Recovery: keep a second slot untouched, or re-flash the
ROM's stock `boot` + `vendor_dlkm`, or sideload the ROM zip.

`vendor_boot` does **not** need to be flashed: this ROM ships no modules in its
vendor ramdisk (only DTB + init scripts), all 84 modules live in `vendor_dlkm`.

## Verifying the module ABI yourself

```sh
# our build vs a pristine tree at the same commit (CI does this too)
python3 scripts/kernel-features/compare-symvers.py baseline/Module.symvers dist/Module.symvers

# our build vs the .ko files actually shipped in a ROM
python3 scripts/kernel-features/verify-module-abi.py dist/Module.symvers /path/to/lib/modules/*.ko

# the ROM's expectations as a Module.symvers-style baseline
python3 scripts/kernel-features/rom-modules-symvers.py /path/to/lib/modules/*.ko \
    > prebuilt/infinityx-vendor-modules.symvers
```

Result on 2026-10-07, for the record:

| compared against | symbol CRCs checked | mismatches |
|---|---|---|
| LineageOS 23.2 nightly vendor_dlkm | 5225 | **0** |
| Project Infinity-X 3.12 vendor_dlkm (this ROM) | 5169 | 2852 |

So this kernel's exported symbols are identical to LineageOS's official build
(same tree), while the ROM's own modules belong to a diverged tree — which is
why the modules travel with the kernel.

## Known limitations

### 1. The kernel does not boot the recovery / fastbootd path

`adb reboot sideload`, `fastboot reboot fastboot` and recovery boots all end in
the XBL ramdump screen.  Normal boots are unaffected, and so are root, SUSFS
and Droidspaces.  Consequences:

* `adb sideload` of a ROM zip requires the ROM's stock `boot` to be flashed
  back first — the recovery path works fine with the stock kernel, and recovery
  does not care which modules live in `vendor_dlkm`.
* Logical partitions can only be written from fastbootd, which therefore also
  needs the stock `boot` in place.
* OTA updates started from the running system (update_engine writing the
  inactive slot) are not affected.

### 2. `fastboot --set-active` leaves this device in an inconsistent state

On this device `fastboot --set-active=<slot>` updates the bootloader's slot
variable but **not** the super partition's metadata slot.  Booting the other
slot then pairs that slot's `boot` (physical, per slot) with the *current*
metadata slot's logical partitions (`system`, `vendor`, `vendor_dlkm`, ...).

Observed twice on 2026-10-07: with the custom `vendor_dlkm` on slot A,
`fastboot --set-active=b` + boot → the stock kernel from `boot_b` was paired
with A's custom modules → boot chain crashed into XBL ramdump.

Evidence, from fastbootd with `current-slot: b`:

```
partition-size:vendor_dlkm      FAILED (remote: 'Could not open partition')
partition-size:vendor_dlkm_a    0xD09000        <- the custom image's size
partition-size:vendor_dlkm_b    FAILED (remote: 'Could not open partition')
```

Only the OTA path (`update_engine` + `boot_control`, e.g. `adb sideload` of the
full ROM zip) switches the metadata slot together with the boot slot; that is
why slot B booted fine right after an OTA and crashes after a fastboot slot
switch.

Practical consequences:

* A custom kernel cannot be installed on the second slot: its logical
  partitions are unreachable from fastbootd, and flashing only `boot` would mix
  builds.
* Treat the slot the ROM currently boots from as *the* slot, and use re-flashing
  the ROM zip (then re-applying `boot` + `vendor_dlkm`) as the recovery path —
  not `fastboot --set-active`.
* To move to the other slot deliberately, use the ROM's own OTA updater.

### 3. Droidspaces resource limits

* `--cpus` / `--pids-limit` unavailable (`CFS_BANDWIDTH`, `CGROUP_PIDS` off).
* `CONFIG_CGROUP_DEVICE` is off as well: Droidspaces' documentation table calls
  it required, but Droidspaces 6.6.0's own check reports
  `[✓] All required features found!` on this kernel, and the community sm8350
  Droidspaces kernels leave it off too.  `--memory` works (`CONFIG_MEMCG=y`).

### 4. ROM updates

Any ROM update rewrites `boot` and `vendor_dlkm` for the updated slot, so the
kernel and its modules have to be re-flashed afterwards, in the order described
above (modules first, then kernel).
