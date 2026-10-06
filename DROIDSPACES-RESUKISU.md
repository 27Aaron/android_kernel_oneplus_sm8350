# OnePlus 9 Pro — Droidspaces + ReSukiSU (+ SUSFS)

Branch `droidspaces-resukisu-susfs`, based on LineageOS 23.2
(`187d13cd30e2`, kernel `5.4.302-qgki`).

This branch turns the stock LineageOS kernel for the OnePlus 9 Pro
(`lemonadep`, `sm8350` / `lahaina`) into a kernel that can run
[Droidspaces](https://github.com/ravindu644/Droidspaces-OSS) Linux containers
and ships [ReSukiSU](https://github.com/ReSukiSU/ReSukiSU) (now upstream-named
**BakaSU**) as the root solution, with optional SUSFS root hiding.

---

## 1. What the problem is

`boot.img`, `vendor_boot.img` and `vendor_dlkm.img` are three separate
partitions:

| partition | contents | rebuilt here? |
|---|---|---|
| `boot` | kernel `Image` + generic ramdisk (header v3) | **yes** |
| `vendor_boot` | vendor ramdisk (first stage modules) + DTB | no |
| `vendor_dlkm` | the bulk of the Qualcomm/OPLUS kernel modules | no |

The modules in `vendor_boot` / `vendor_dlkm` were compiled against the stock
kernel, and the kernel checks two things before it lets a module in:

1. **vermagic** — the exact release string. The stock kernel reports

   ```
   5.4.302-qgki-g187d13cd30e2 SMP preempt mod_unload modversions aarch64
   ```

   The `-g187d13cd30e2` part comes from `scripts/setlocalversion`, which
   appends the short SHA of the git HEAD the kernel was built from. Building
   this branch normally would produce `-g<new sha>` and **every vendor module
   would be rejected**, which usually means no display, no Wi-Fi and no
   storage. Fixed by committing `.scmversion` containing
   `-g187d13cd30e2`, so the release string is byte-identical no matter which
   commit is built.

2. **symbol CRCs** (`CONFIG_MODVERSIONS`) — a per-symbol checksum computed by
   `genksyms` from the C types. Enabling a Kconfig option that changes the
   layout of a widely used structure changes those checksums and the modules
   are refused with *"disagrees about version of symbol"*.

## 2. How Droidspaces is enabled without breaking the ABI

The Droidspaces options mostly do not touch any structure. Two of them do:

* `CONFIG_SYSVIPC` adds `struct sysv_sem sysvsem` / `struct sysv_shm sysvshm`
  in the **middle** of `struct task_struct`.
* `CONFIG_POSIX_MQUEUE` adds `unsigned long mq_bytes` in the **middle** of
  `struct user_struct`.

Both are moved into the Android kABI padding at the end of the structure
instead (`include/linux/sched.h`, `include/linux/sched/user.h`):

```c
#ifdef CONFIG_SYSVIPC
	ANDROID_KABI_USE(1, struct sysv_sem sysvsem);
	_ANDROID_KABI_REPLACE(ANDROID_KABI_RESERVE(2); ANDROID_KABI_RESERVE(3),
			      struct sysv_shm sysvshm);
#else
	ANDROID_KABI_RESERVE(1);
	ANDROID_KABI_RESERVE(2);
	ANDROID_KABI_RESERVE(3);
#endif
```

Because `_ANDROID_KABI_REPLACE()` collapses to its `_orig` argument under
`__GENKSYMS__`, the type parser still sees the plain
`u64 android_kabi_reservedN` padding — i.e. exactly the stock kernel that was
built with both options **disabled** (which is the case here: stock has
`# CONFIG_SYSVIPC is not set` and `# CONFIG_POSIX_MQUEUE is not set`).
Same size, same alignment, same CRCs.

This is the patch set published with the Droidspaces kernel configuration
guide (`001.GKI-below-6.12-fix_sysvipc_kabi_*.patch` /
`002.5.10_or_lower_use_android_abi_padding_for_posix_mqueue.patch`), adapted
to the slot layout of this tree (slots 1/2/3, `struct user_struct` has no
`ANDROID_OEM_DATA_ARRAY`).

### Enabled

`arch/arm64/configs/vendor/lahaina-qgki_defconfig` (and mirrored into
`vendor/lahaina_QGKI.config` for the `scripts/gki/generate_defconfig.sh`
path):

```
SYSVIPC, POSIX_MQUEUE,
NAMESPACES, UTS_NS, IPC_NS, PID_NS, USER_NS, NET_NS,
CGROUPS, CGROUP_SCHED, CGROUP_FREEZER, CGROUP_CPUACCT,
MEMCG, SECCOMP, SECCOMP_FILTER,
DEVTMPFS, OVERLAY_FS, TMPFS_XATTR, TMPFS_POSIX_ACL,
FW_LOADER, FW_LOADER_USER_HELPER, FW_LOADER_COMPRESS,
VETH, BRIDGE, NETFILTER, NF_CONNTRACK, NF_NAT, NF_NAT_REDIRECT,
IP_NF_IPTABLES, IP_NF_FILTER, IP_NF_NAT, IP_NF_TARGET_MASQUERADE,
NETFILTER_XT_TARGET_MASQUERADE, NETFILTER_XT_TARGET_TCPMSS,
NETFILTER_XT_MATCH_ADDRTYPE, IP_ADVANCED_ROUTER, IP_MULTIPLE_TABLES,
IPV6, IPV6_MULTIPLE_TABLES, IP6_NF_IPTABLES, IP6_NF_FILTER, IP6_NF_MANGLE,
IP6_NF_NAT, IP6_NF_TARGET_MASQUERADE,
NETFILTER_XT_TARGET_REJECT/LOG/NFLOG, NETFILTER_XT_MATCH_RECENT,
IP_SET, IP_SET_HASH_IP, IP_SET_HASH_NET, NETFILTER_XT_SET
```

Everything in this list was checked against a pristine baseline build: the
`Module.symvers` comparison in the release job proves that not a single
pre-existing exported symbol changed its CRC.

### Deliberately **not** enabled

Three options are excluded because they genuinely move the module ABI of this
vendor kernel — each one was confirmed by building it and diffing
`Module.symvers` against the stock baseline:

* **`CONFIG_CGROUP_DEVICE`** — enabling a cgroup controller changes the
  `CGROUP_SUBSYS_COUNT` enum, which is the array bound of
  `struct cgroup.subsys[]` and `struct css_set.subsys[]`. `struct cgroup`
  reaches `struct sock_cgroup_data` → `struct sock` → `struct sk_buff`, so
  enabling it changed 4616 exported symbol CRCs including `__alloc_skb` and
  `kfree_skb`. That would stop the Wi-Fi module from loading.
  Droidspaces does **not** need it: its requirements checker
  (`src/check.c`, `check_requirements_hw()`) only hard-requires root, the
  mount / pid / uts / ipc namespaces, `pivot_root` and a new enough kernel
  version. The cgroup checks it does perform (`cgroup2`, `cgroup_ns`,
  memory/cpu/pids limits) are all reported as *optional*. The table on the
  Droidspaces documentation website that lists "Cgroup device — fatal" is out
  of date with the code.
* **`CONFIG_NF_TABLES`** — adds `SKB_EXT_NFT` to `enum skb_ext_id` (which is
  part of `struct sk_buff`) and `struct netns_nftables nft` to `struct net`.
  Containers that need nftables can use `iptables-legacy` inside the
  container instead, which is what the Droidspaces documentation recommends
  for older kernels anyway.
* **`CONFIG_BRIDGE_NETFILTER`** — adds `SKB_EXT_BRIDGE_NF` to
  `enum skb_ext_id`. NAT mode still works (it is routed via veth, not
  bridged); only filtering of *bridged* traffic is affected.

* `CONFIG_CFS_BANDWIDTH` and `CONFIG_CGROUP_PIDS` are also left off — they
  resize scheduler/cgroup structures and no kABI padding patch exists for
  them. Without them Droidspaces still works, only the `--cpus` and
  `--pids-limit` container options are skipped with a warning.
  `CONFIG_MEMCG` (used by `--memory`) is already enabled in the stock config.
* `CONFIG_CGROUP_NET_PRIO` — `include/net/netprio_cgroup.h` in this tree reads
  `css->cgroup->id`, but `struct cgroup` here has no `id` member (the cgroup id
  is the id of the cgroup's own `css`), so the option cannot be compiled at
  all. That is a pre-existing bug in the tree, independent of this branch;
  LineageOS never enables the option, which is why nobody hit it. The one-line
  fix would be `idx = css->id;`. The `net_prio` controller is optional for
  Droidspaces, so it is simply left off.

## 3. ReSukiSU / SUSFS

`scripts/kernel-features/apply.sh` performs the whole integration and is what
the CI workflow calls. Everything is pinned by commit:

| component | pin |
|---|---|
| ReSukiSU / BakaSU driver | `c8dc617dd7e19630bc5f39f678cd93de798559d2` |
| `syscall_hook_patches.sh` / `susfs_inline_hook_patches.sh` | `0543b379c0c96c5ff92871260b04da8dfcb5c690` |
| SUSFS 5.4 backport | `Patches/Patch/susfs_patch_to_5.4.patch` (SUSFS v2.3.0) |

Notes:

* A 5.4 kernel is **GKI 1.0** for KernelSU. The tracepoint syscall redirector
  does not exist there and the driver's `Kbuild` raises a hard `$(error)` if it
  is selected, so the hook sites have to be patched into the source
  (`fs/exec.c`, `fs/open.c`, `fs/stat.c`, `kernel/reboot.c`, …).
* `CONFIG_KSU_SUSFS` is a member of the same Kconfig `choice` as
  `CONFIG_KSU_MANUAL_HOOK` — they are mutually exclusive. `WITH_SUSFS=0` gives
  the plain manual-hook build, `WITH_SUSFS=1` (default) the SUSFS inline-hook
  build.
* `CONFIG_KSU_TRACEPOINT_HOOK` is the `choice` default and must be turned off
  explicitly, otherwise the build fails. The script does that after
  `make defconfig`.
* **The SUSFS patches move the module ABI on their own**, and this was the
  last thing the kABI check caught. `fs/stat.c` and `fs/statfs.c` gain

  ```c
  #ifdef CONFIG_KSU_SUSFS
  #include <linux/susfs_def.h>
  #include "mount.h"          /* fs/mount.h, a VFS-internal header */
  #endif
  ```

  `fs/mount.h` fully defines `struct mount`, `struct mountpoint`,
  `struct mnt_pcp` and `struct mnt_namespace`. The stock kernel never includes
  it in those two translation units, so genksyms only ever saw

  ```
  struct vfsmount      { UNKNOWN }
  struct mnt_namespace { UNKNOWN }
  ```

  and the CRC of an exported symbol is a hash of the symbol's type *as spelled
  out in that unit*. Including the header changed 11 CRCs — `vfs_getattr`,
  `vfs_getattr_nosec`, `generic_fillattr`, `vfs_statfs`, `vfs_get_fsid`,
  `inode_add_bytes`, `__inode_add_bytes`, `inode_sub_bytes`,
  `__inode_sub_bytes`, `inode_get_bytes`, `inode_set_bytes`.
  `fs/stat.c` also needed `#include "internal.h"`.

  `scripts/kernel-features/fix-genksyms-view.py` (run by `apply.sh`) rewrites
  the added include block to

  ```c
  #if defined(CONFIG_KSU_SUSFS) && !defined(__GENKSYMS__)
  ```

  so the compiler still gets the definitions while genksyms keeps seeing
  exactly the stock translation unit.
* SUSFS for non-GKI kernels was dropped upstream (`gki-android*-5.4` branches
  are gone). The 5.4 support used here is the maintained community backport
  from `JackA1ltman/NonGKI_Kernel_Build_2nd`, which carries the full
  `fs/susfs.c`, `include/linux/susfs.h` and `susfs_def.h`.
* One hunk of that patch does not fit this tree (OPLUS added `ino:` to the
  `fdinfo` output). The script strips `fs/proc/fd.c` from the upstream patch
  and applies `scripts/kernel-features/patches/0001-susfs-fs-proc-fd.patch`
  instead.

## 4. Building

### GitHub Actions

`.github/workflows/build-lemonadep.yml` runs on every push to this branch and
on manual dispatch:

1. `kabi-baseline` — checks out the pristine `187d13cd30e2` with the stock
   defconfig and builds `Image`, producing the reference `Module.symvers`.
2. `build` — applies the integration, verifies the resolved `.config`, builds
   `Image`.
3. `release` — compares the two `Module.symvers` files
   (`scripts/kernel-features/compare-symvers.py`), refuses to publish if any
   pre-existing exported symbol changed CRC, checks the version string,
   packs `boot.img` and creates the release.

Manual dispatch inputs: `with_susfs`, `run_kabi_check`, `allow_kabi_change`,
`create_release`, `release_tag`.

### Locally

```sh
# needs a Linux host with GNU sed/patch and clang
WITH_SUSFS=1 bash scripts/kernel-features/apply.sh

make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 \
     CROSS_COMPILE= CLANG_TRIPLE=aarch64-linux-gnu- \
     vendor/lahaina-qgki_defconfig
OUT=out WITH_SUSFS=1 bash scripts/kernel-features/apply.sh --config-only
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 \
     CROSS_COMPILE= CLANG_TRIPLE=aarch64-linux-gnu- -j"$(nproc)" Image

# pack a flashable boot.img
python3 scripts/kernel-features/pack-boot.py \
    --kernel out/arch/arm64/boot/Image \
    --ramdisk prebuilt/boot-ramdisk.lz4 \
    --output boot.img --pad-to 201326592
```

## 5. Flashing

```sh
fastboot flash boot boot-lemonadep-droidspaces-resukisu-YYYYMMDD.img
```

Only `boot` needs to be flashed. To roll back, flash the stock `boot.img`
from your LineageOS zip.

There is **no** requirement to touch `vbmeta` on an unlocked bootloader.

## 6. Compatibility constraint

The image is built for the LineageOS 23.2 nightly **`20261005`** (kernel commit
`187d13cd30e2`). `prebuilt/boot-ramdisk.lz4` is that build's ramdisk and
`.scmversion` pins that build's vermagic.

If you update LineageOS to a newer nightly, the kernel commit — and therefore
the vermagic of the freshly built vendor modules — changes, and this kernel
will refuse to load them. Re-run the workflow against the new base commit and
re-extract the ramdisk from the new `boot.img` (see `prebuilt/README.md`).
