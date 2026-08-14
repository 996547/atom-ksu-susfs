#!/bin/bash
# =============================================================
#  atom (Redmi 10X 5G / 天玑820 MT6875) SukiSU-Ultra + SUSFS 云端编译
#  专为 GitHub Actions 设计：所有源码/工具链在 CI 内下载，无需提交大体积文件。
#  本地 WSL 也可直接 bash build.sh 使用（需先 sudo apt install clang lld）。
#
#  环境变量：
#    WITH_SUSFS  1/true  -> 包含 SUSFS（默认）；0/false -> 仅 KernelSU
#    SUSFS_REF   （可选）susfs4ksu 的分支/标签，例如 v1.5.5；留空用 master
#
#  产物：仓库根目录 atom-ksu-susfs-AnyKernel3.zip
# =============================================================
set -euo pipefail

# 归一化 WITH_SUSFS（兼容 GitHub workflow_dispatch 的 "true"/"false" 与本地 "1"/"0"）
WITH_SUSFS="${WITH_SUSFS:-1}"
case "$WITH_SUSFS" in
  1|true|yes|on|TRUE) WITH_SUSFS=1 ;;
  *) WITH_SUSFS=0 ;;
esac
# KSU 开关（隔离测试用）：默认 1 开启；设为 0 则编译纯基础内核（同时强制关闭依赖 KSU 的 SUSFS）
WITH_KSU="${WITH_KSU:-1}"
case "$WITH_KSU" in
  1|true|yes|on|TRUE) WITH_KSU=1 ;;
  *) WITH_KSU=0 ;;
esac
if [ "$WITH_KSU" = "0" ]; then WITH_SUSFS=0; fi
SUSFS_REF="${SUSFS_REF:-}"

BASE="$(cd "$(dirname "$0")" && pwd)"
cd "$BASE"

# 工具函数：带重试的下载
dl() {  # url out
  local url="$1" out="$2" i
  for i in 1 2 3; do
    if curl -fsSL "$url" -o "$out"; then return 0; fi
    sleep 5
  done
  return 1
}

# ---------- 工具链：Clang + lld（内核 build.config 指定 clang + ld.lld） ----------
# 该 4.14.186 内核（atom 原厂树 kernel_redmi_atom）用 clang + ld.lld 编译；
# GCC 4.9 太旧无法编译此内核。
# 优先 clang-14（对 4.14 兼容性最佳，implicit-function-declaration 仍只是警告），
# 其次回退到系统 clang / clang-18。
pick_clang() {
  if command -v clang-14 >/dev/null 2>&1; then
    CLANG_BIN=clang-14; LLD_BIN=ld.lld-14
  elif command -v clang >/dev/null 2>&1; then
    CLANG_BIN=clang; LLD_BIN=ld.lld
  else
    echo "[!] 未找到 clang，请先安装 clang/lld"; exit 1
  fi
  echo "    使用编译器: $CLANG_BIN / 链接器: $LLD_BIN"
}

echo "==> 1. 内核源码 (mt6873-dev/kernel_redmi_atom @ android-4.14-r-stable = 4.14.186 原厂 atom 树)"
dl "https://github.com/mt6873-dev/kernel_redmi_atom/archive/refs/heads/android-4.14-r-stable.tar.gz" kernel.tar.gz
tar -xzf kernel.tar.gz
SRC="$BASE/kernel_redmi_atom-android-4.14-r-stable"

echo "==> 2. GCC 4.9 工具链 (LineageOS prebuilts，仅用作 binutils/汇编器)"
dl "https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9/archive/refs/heads/lineage-19.1.tar.gz" gcc.tar.gz
tar -xzf gcc.tar.gz
GCC="$BASE/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9-lineage-19.1"

echo "==> 3. SukiSU-Ultra (nongki) —— 来自本仓库附带的 susu.tar.gz"
rm -rf "$SRC/KernelSU" "$BASE"/SukiSU-Ultra-*
tar -xzf "$BASE/susu.tar.gz" -C "$BASE"
SU_SRC=$(find "$BASE" -maxdepth 1 -type d -name 'SukiSU-Ultra-*' | head -1)
mkdir -p "$SRC/KernelSU"
cp -a "$SU_SRC/." "$SRC/KernelSU/"
# 注意：nongki 自带 kernel_compat.c 此处本没有 ksu_access_ok 函数。只有带 SUSFS 时，
# 步骤 4 的 10_enable_susfs_for_ksu.patch 才会新增该函数定义，并与 kernel_compat.h 里的
#   #define ksu_access_ok(addr, size) access_ok(...)
# 同名冲突（预处理器会把函数定义的名字展开成垃圾代码，clang 报
# "function cannot return function type"）。真正的修复（#undef）放在步骤 4 打补丁之后执行（见下）。

# ---------- SUSFS ----------
SUSFS_PATCHED=0
if [ "$WITH_SUSFS" = "1" ]; then
  echo "==> 4. SUSFS (gitlab.com/simonpunk/susfs4ksu)"
  rm -rf "$BASE/susfs_src"
  if git clone --depth 1 ${SUSFS_REF:+--branch "$SUSFS_REF"} https://gitlab.com/simonpunk/susfs4ksu.git "$BASE/susfs_src" 2>&1 | tail -3; then
    KP="$BASE/susfs_src/kernel_patches"
    # (a) 拷贝 SUSFS 核心源文件（补丁本身不创建这两个文件）
    cp -a "$KP/fs/susfs.c"            "$SRC/fs/susfs.c"            2>/dev/null || { echo "    [警告] 拷贝 fs/susfs.c 失败"; WITH_SUSFS=0; }
    cp -a "$KP/include/linux/susfs.h" "$SRC/include/linux/susfs.h" 2>/dev/null || { echo "    [警告] 拷贝 include/linux/susfs.h 失败"; WITH_SUSFS=0; }
    # (b) 内核侧补丁：添加 VFS 钩子 + fs/Makefile 条目
    echo "    应用内核补丁 (50_add_susfs_in_kernel-4.14.patch)..."
    patch -p1 --forward -d "$SRC" < "$KP/50_add_susfs_in_kernel-4.14.patch" 2>&1 | grep -iE "fail|rej" || true
    # (c) KernelSU 侧补丁（SukiSU nongki 上 6/7 文件可合入，selinux/rules.c 一处 hunk 上下文不同，稍后手动补）
    echo "    应用 KernelSU 补丁 (10_enable_susfs_for_ksu.patch)..."
    patch -p1 --forward -d "$SRC/KernelSU" < "$KP/KernelSU/10_enable_susfs_for_ksu.patch" 2>&1 | grep -iE "fail|rej" || true
    # 修复 SUSFS 补丁引入的「宏/函数同名冲突」：kernel_compat.h 的
    #   #define ksu_access_ok(addr, size) access_ok(...)
    # 会在预处理阶段把 kernel_compat.c 里新加的函数定义 int ksu_access_ok(const void *addr, ...)
    # 展开成垃圾代码，clang 报 "function cannot return function type 'int (const void *)'"。
    # 在定义前 #undef ksu_access_ok 即可消除冲突；函数体本身只调 access_ok，语义不变，
    # 其它 .c 文件仍走宏 -> access_ok，行为一致。仅匹配函数定义行（结尾 ')' 紧跟 '{'），
    # 不误伤 extern 声明与调用点。
    sed -i -E 's/^(\s*)(int ksu_access_ok\(const void \*addr, unsigned long size\) \{)/\1#undef ksu_access_ok\n\1\2/' \
      "$SRC/KernelSU/kernel/kernel_compat.c"
    # (d) 手动补 selinux/rules.c 被 reject 的那一处（允许 zygote unmount，SUSFS try_umount 所需）
    SRC="$SRC" python3 - <<'PY' 2>/dev/null || true
import os
p = os.path.join(os.environ["SRC"], "KernelSU", "kernel", "selinux", "rules.c")
try:
    s = open(p).read()
    if "labeledfs" not in s:
        anchor = 'ksu_allow(db, "system_server", KERNEL_SU_DOMAIN, "process", "sigkill");'
        ins = anchor + "\n\n#ifdef CONFIG_KSU_SUSFS\n\t// Allow umount in zygote process without installing zygisk\n\tksu_allow(db, \"zygote\", \"labeledfs\", \"filesystem\", \"unmount\");\n#endif\n"
        s = s.replace(anchor, ins, 1)
        open(p, "w").write(s)
        print("    [ok] selinux SUSFS 规则已补入")
except Exception as e:
    print("    [警告] selinux 规则手动补入失败:", e)
PY
    # (e) 校验
    if [ -f "$SRC/fs/susfs.c" ] && [ -f "$SRC/include/linux/susfs.h" ] && grep -q "config KSU_SUSFS" "$SRC/KernelSU/kernel/Kconfig" 2>/dev/null; then
      echo "    SUSFS 已接入 (fs/susfs.c + include/linux/susfs.h + CONFIG_KSU_SUSFS)"
      SUSFS_PATCHED=1
    else
      echo "    [警告] SUSFS 集成不完整，回退纯 KernelSU"; WITH_SUSFS=0
    fi
  else
    echo "    [警告] SUSFS 克隆失败，仅编译 KernelSU。"; WITH_SUSFS=0
  fi
else
  echo "==> 4. 已跳过 SUSFS (WITH_SUSFS=0)"
fi

# ---------- 编译环境 ----------
pick_clang
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE="$GCC/bin/aarch64-linux-android-"
# 关键：4.14 内核 Makefile 写死 `CC = $(CROSS_COMPILE)gcc`，会**覆盖**环境变量中的 CC，
# 导致 clang 不生效、退回过旧的 GCC 4.9 而无法编译此内核。必须把 CC/LD/CLANG_TRIPLE/HOSTCC
# 放到 make 命令行（命令行赋值优先级高于 Makefile）才能真正走 clang。
MK="CC=$CLANG_BIN LD=$LLD_BIN CLANG_TRIPLE=aarch64-linux-gnu- HOSTCC=$CLANG_BIN"
# 防御性：4.14 + clang 下把若干告警从错误降级为警告，避免完整编译途中被打断。
# 仅保留 clang 真实存在的告警名；-Wno-unknown-warning-option 确保未知选项本身不报错。
# 注意：clang-14 中 implicit-int / implicit-function-declaration 默认就是 error（不是被 -Werror 升级），
# 所以必须用 -Wno-... 直接关闭，-Wno-error=... 对它们无效。这是 4.14 老内核 + 新 clang 的标配。
export KCFLAGS="-Wno-implicit-function-declaration -Wno-implicit-int \
  -Wno-error=incompatible-pointer-types -Wno-error=array-bounds \
  -Wno-error=format -Wno-error=enum-conversion \
  -Wno-error=address-of-packed-member -Wno-unknown-warning-option"

OUT="$SRC/out"
mkdir -p "$OUT"
cd "$SRC"

echo "==> 5. 生成 defconfig (vendor/atom_user_defconfig)"
make $MK O="$OUT" ARCH=arm64 vendor/atom_user_defconfig

echo "==> 6. 校正内核配置 (KSU=$WITH_KSU SUSFS=$WITH_SUSFS)"
if [ "$WITH_KSU" = "1" ]; then
  ./scripts/config --file "$OUT/.config" -e CONFIG_KSU -d CONFIG_KSU_MANUAL_HOOK
else
  ./scripts/config --file "$OUT/.config" -d CONFIG_KSU -d CONFIG_KSU_MANUAL_HOOK
fi
./scripts/config --file "$OUT/.config" \
  -e CONFIG_KALLSYMS -e CONFIG_KALLSYMS_ALL \
  -d CONFIG_LTO_CLANG -d CONFIG_LTO -d CONFIG_POLLY_CLANG \
  -d CONFIG_CC_STACKPROTECTOR_STRONG \
  -d CONFIG_COMPAT_VDSO
# 关键：本树 vendor/atom_user_defconfig 的 APPENDED_DTB_IMAGE_NAMES 写的是 "mediatek/mt6873"
# （通用参考板，model="MT6873"），但**设备实际运行的 boot.img 内置 IKCONFIG 提取出的真实值
# 是 "mediatek/atom"**（已核对 atom_stock_defconfig.txt）。atom 的板级 DTS 是 atom.dts
# （model="ATOM"），编译产物为 atom.dtb。若把 mt6873 通用板 DTB 附进 Image.gz-dtb，内核会用
# 不匹配的设备树启动而早期 panic -> 卡 Redmi logo 反复重启。这里强制改成正确的 atom DTB。
./scripts/config --file "$OUT/.config" \
  --set-str CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE_NAMES "mediatek/atom"

# ============================================================================
#  6b. 开机兼容性校正 —— 依据「原厂内核 IKCONFIG 提取的真实配置」逐项对齐
#
#  取证方法：从设备 boot.img 抽出 stock kernel，其内置 IKCFG_ST..IKCFG_ED 解出
#  完整 .config（4.14.186，4542 项），与我们编出的内核内置 config（4448 项）逐项 diff。
#  ABI 级配置（PAGE_SHIFT=12 / VA_BITS=39 / PGTABLE_LEVELS=3 / NR_CPUS=8 / HZ=250）
#  两边完全一致，故排除页大小、地址位宽这类「静默秒死」病因；真正的危险差异如下。
#
#  ⚠ 这些选项若本树（4.14.186 atom 原厂树）未提供，olddefconfig 会自动丢弃，不会导致编译失败，
#    因此统一用 -e/-d 声明式对齐即可，无需条件判断。
# ============================================================================
echo "==> 6b. 开机兼容性校正（对齐原厂 IKCONFIG）"

# (1) 【头号嫌疑】PANIC_ON_OOPS：原厂=n，我们=y。
#     开启后任何「本可恢复的 oops」都会立即升级为 panic 重启，屏幕来不及有任何输出
#     —— 完全吻合「只有 logo、无文字、静默重启」。原厂关闭，故遇到同类问题只打
#     WARNING 继续跑（原厂 dmesg 里就有一条 RCU tree_plugin.h:329 WARNING 但系统照跑）。
./scripts/config --file "$OUT/.config" -d CONFIG_PANIC_ON_OOPS

# (2) 【关键诊断能力】MTK AEE：原厂全开，我们全关。
#     AEE-IPANIC 是 MTK 平台把 kernel panic 落盘到 expdb 分区的原生机制。
#     之前 /proc/last_kmsg 被 recovery 覆盖、抓不到崩溃现场，根因就是缺这套。
./scripts/config --file "$OUT/.config" \
  -e CONFIG_MTK_AEE_FEATURE -e CONFIG_MTK_AEE_AED \
  -e CONFIG_MTK_AEE_IPANIC -e CONFIG_MTK_AEE_HANG_DETECT

# (3) 【挂载 /data 必需】缺任一都会「内核起来了但挂不上 data」→ 重启循环
#     UNICODE: ext4/f2fs casefold 支持；MMC_CRYPTO_LEGACY: 内联硬件加密(FBE 解密)
./scripts/config --file "$OUT/.config" \
  -e CONFIG_UNICODE -e CONFIG_MMC_CRYPTO_LEGACY

# (4) TEE / 可信执行环境（原厂 CONFIG_TEE=y + Microtrust TZ 驱动）
./scripts/config --file "$OUT/.config" \
  -e CONFIG_TEE -e CONFIG_MTK_SVP_ON_MTEE_SUPPORT -e CONFIG_MTK_DRM_KEY_MNG_SUPPORT

# (5) MIUI 用户态依赖的 sysfs 节点，缺失会让 MIUI init 找不到节点而失败
./scripts/config --file "$OUT/.config" \
  -e CONFIG_MIHW -e CONFIG_MIGT -e CONFIG_MILLET -e CONFIG_MI_MEMORY_SYSFS

# (6) WLAN 驱动：原厂=n（走模块加载），我们=y（编进内核）。
#     编进内核会在早期 probe，一旦失败 + PANIC_ON_OOPS=y 就是「探测失败即秒重启」。
#     这里改回与原厂一致，消除早期 probe 风险。
./scripts/config --file "$OUT/.config" -d CONFIG_WLAN_DRV_BUILD_IN

# (7) 内核 cmdline 与原厂完全对齐：原厂末尾是 slub_debug=O（字母 O，
#     含义「对会增大对象体积的 cache 关闭 debug」），我们是 slub_debug=0（数字零，
#     非法 flag，内核解析时会走 unknown 分支）。一字之差，顺手改正。
./scripts/config --file "$OUT/.config" \
  --set-str CONFIG_CMDLINE "console=tty0 console=ttyMT3,921600n1 root=/dev/ram vmalloc=496M slub_max_order=0 slub_debug=O "
if [ "$WITH_SUSFS" = "1" ]; then
  ./scripts/config --file "$OUT/.config" \
    -e CONFIG_KSU_SUSFS -e CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT \
    -e CONFIG_KSU_SUSFS_SUS_PATH -e CONFIG_KSU_SUSFS_SUS_MOUNT \
    -e CONFIG_KSU_SUSFS_SUS_KSTAT -e CONFIG_KSU_SUSFS_SUS_OVERLAYFS \
    -e CONFIG_KSU_SUSFS_TRY_UMOUNT -e CONFIG_KSU_SUSFS_AUTO_SET_SUS_KSTAT \
    -e CONFIG_KSU_SUSFS_SUS_SU
fi
# 调试开关：开启 pstore/ramoops，使 bootloop 后的内核崩溃日志能在 recovery 里被读出
# （/sys/fs/pstore/console-ramoops-0）。仅抓日志时打开，不影响正常构建产物功能。
WITH_PSTORE="${WITH_PSTORE:-0}"
case "$WITH_PSTORE" in
  1|true|yes|on|TRUE) WITH_PSTORE=1 ;;
  *) WITH_PSTORE=0 ;;
esac
if [ "$WITH_PSTORE" = "1" ]; then
  ./scripts/config --file "$OUT/.config" \
    -e CONFIG_PSTORE -e CONFIG_PSTORE_CONSOLE -e CONFIG_PSTORE_RAM \
    -e CONFIG_PSTORE_PMSG -e CONFIG_PSTORE_FTRACE -e CONFIG_PSTORE_ZONE
fi
make $MK O="$OUT" ARCH=arm64 olddefconfig

build_kernel() {
  make $MK O="$OUT" ARCH=arm64 -j"$(nproc)" 2>&1 | tee "$BASE/build.log"
}

echo "==> 7. 开始编译 ..."
if ! build_kernel; then
  if [ "$WITH_SUSFS" = "1" ]; then
    echo "[!] 带 SUSFS 编译失败，自动回退为仅 KernelSU 重建 ..."
    WITH_SUSFS=0
    ./scripts/config --file "$OUT/.config" -d CONFIG_KSU_SUSFS
    make $MK O="$OUT" ARCH=arm64 olddefconfig
    rm -rf "$OUT/drivers/kernelsu" "$OUT/arch/arm64/boot"
    if ! build_kernel; then
      echo "[!] 编译失败，最后 80 行日志："; tail -80 "$BASE/build.log"; exit 1
    fi
  else
    echo "[!] 编译失败，最后 80 行日志："; tail -80 "$BASE/build.log"; exit 1
  fi
fi

IMG="$OUT/arch/arm64/boot/Image.gz-dtb"
[ -f "$IMG" ] || IMG="$OUT/arch/arm64/boot/Image.gz"
[ -f "$IMG" ] || IMG="$OUT/arch/arm64/boot/Image"
echo "==> 产物: $IMG (WITH_SUSFS=$WITH_SUSFS)"

echo "==> 8. 打包 AnyKernel3"
mkdir -p "$BASE/ak3"
cp "$IMG" "$BASE/ak3/Image.gz-dtb"
cd "$BASE/ak3"
# 关键：git 只对 100755 保留可执行位，仓库内 busybox/脚本为 100644，
# 若不在打包前补 chmod，zip 会存成 0644，设备上 busybox 不可执行 → Busybox setup failed。
chmod 755 tools/busybox tools/arm/busybox tools/x86/busybox 2>/dev/null || true
chmod 755 tools/ak3-core.sh META-INF/com/google/android/update-binary anykernel.sh 2>/dev/null || true
find . -type d -exec chmod 755 {} + 2>/dev/null || true
echo "--- 打包前权限确认 ---"
ls -l tools/busybox tools/arm/busybox META-INF/com/google/android/update-binary
rm -f "$BASE/atom-ksu-susfs-AnyKernel3.zip"
zip -r9 "$BASE/atom-ksu-susfs-AnyKernel3.zip" . -x "*.git*"
echo "--- zip 内权限确认 ---"
unzip -Z -l -v "$BASE/atom-ksu-susfs-AnyKernel3.zip" 2>/dev/null | grep -E 'busybox|update-binary' || \
  unzip -l "$BASE/atom-ksu-susfs-AnyKernel3.zip" | grep -E 'busybox|update-binary'
echo "==> 刷机包: $BASE/atom-ksu-susfs-AnyKernel3.zip"
echo "DONE"
