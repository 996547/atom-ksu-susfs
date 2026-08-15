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

# ---------- 修复 MTK 缺失的板级 DTS include（DTB 构建致命阻塞）----------
# atom.dts 只 include atom-mt6873.dtsi，本身不需要 cust.dtsi；但 make dtbs 会编译
# 目录内全部 .dts（含 mt6873.dts），后者经 xiaomi-mt6873-common.dtsi 需要
# k6873v1_64/cust.dtsi（该文件不在公开仓库，属板级定制）。建一个空桩文件让
# mt6873.dtb 也能编过；atom.dtb 内容不受影响、保持正确。
echo "==> 1b. 补 k6873v1_64/cust.dtsi 空桩（仅供非 atom 的 dtb 编译通过）"
mkdir -p "$SRC/arch/arm64/boot/dts/mediatek/k6873v1_64"
if [ ! -f "$SRC/arch/arm64/boot/dts/mediatek/k6873v1_64/cust.dtsi" ]; then
  printf '/* stub: board-specific cust.dtsi not in public repo; only needed by non-atom dtbs */\n' \
    > "$SRC/arch/arm64/boot/dts/mediatek/k6873v1_64/cust.dtsi"
fi
# 关键修复：原文件用 <k6873v1_64/cust.dtsi>（尖括号）包含，dtc 按 include 搜索路径
# 解析不到我们放在 mediatek/k6873v1_64/ 下的空桩（报 "file not found with <angled> include"）。
# 改成 "k6873v1_64/cust.dtsi"（引号）后，dtc 会相对本文件所在目录（mediatek/）搜索，
# 正好命中 mediatek/k6873v1_64/cust.dtsi。该 include 位于 dtsi 末尾、纯追加式板级覆写，
# 空桩不会影响 atom.dtb 的正确性（只是不追加任何板级覆写节点）。
echo "==> 1b-2. 将 cust.dtsi 的 <angled> 包含改为引号包含，使空桩可被 dtc 找到"
sed -i 's|#include <k6873v1_64/cust.dtsi>|#include "k6873v1_64/cust.dtsi"|' \
  "$SRC/arch/arm64/boot/dts/mediatek/xiaomi-mt6873-common.dtsi"

# ---------- 修复子目录 -Werror 覆盖全局 -Wno-error（编译致命阻塞）----------
# 部分子目录 Makefile（如 drivers/gpu/drm/mediatek）在 KCFLAGS 之后追加 -Werror，
# 导致 -Wno-error 被覆盖，clang-14 把 pointer-to-int-cast / unused 等当致命错误。
# 只用「外科手术式」sed：删掉独立的 -Werror 词、并把 -Werror=xxx 改成 -Wno-error=xxx
# （告警仍保留，只是不当致命错误）。**不能**用贪婪的 's/-Werror[ =][A-Za-z0-9_-]*//g'，
# 否则会把同行的 -Wno-implicit-function-declaration 等标志一起吞掉，反而引出
# 'unknown argument: -implicit-function-declaration' 这类更早的编译失败。
echo "==> 1c. 外科手术式移除内核树内独立的 -Werror / -Werror= （转告警，不破坏 -Wno-* 标志）"
find "$SRC" -name Makefile -exec sed -i \
  -e 's/ -Werror / /g' -e 's/ -Werror$/ /g' -e 's/^-Werror / /g' \
  -e 's/-Werror=/-Wno-error=/g' \
  {} + 2>/dev/null || true

# ---------- 修复 lld 链接期 undefined symbol: stpcpy（链接致命阻塞）----------
# clang-14 会把若干 sprintf/strcpy 模式优化成 stpcpy() 库调用，但 4.14 内核的
# lib/string.c 只定义了 strcpy、没有 stpcpy，于是链接 vmlinux 时报
# "undefined symbol: stpcpy"（tty_io.c / configfs.c / meta.c 等内核核心文件引用）。
# 双保险：(a) 给 KCFLAGS 加 -fno-builtin-stpcpy/-fno-builtin-stpncpy，让 clang 不再
# 吐这些库调用；(b) 直接在 lib/string.c 补一个 stpcpy 定义（即使仍有调用也能链上）。
echo "==> 1d. 给 lib/string.c 补 stpcpy 定义（clang-14 库调用缺失符号）"
cat >> "$SRC/lib/string.c" <<'EOF'

#ifndef __HAVE_ARCH_STPCPY
/* clang-14 emits stpcpy() libcalls for some sprintf/strcpy patterns; the 4.14
   kernel does not provide stpcpy(), so define it here (strcpy-like semantics). */
char *stpcpy(char *dest, const char *src)
{
	while ((*dest = *src) != '\0')
		dest++, src++;
	return dest;
}
EXPORT_SYMBOL(stpcpy);
#endif
EOF

echo "==> 2. GCC 4.9 工具链 (LineageOS prebuilts，仅用作 binutils/汇编器)"
dl "https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9/archive/refs/heads/lineage-19.1.tar.gz" gcc.tar.gz
tar -xzf gcc.tar.gz
GCC="$BASE/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9-lineage-19.1"

# ---------- 修复 clang 汇编器查找：CLANG_TRIPLE=gnu 但 GCC 工具链是 android ----------
# 内核 Makefile 用 GCC_TOOLCHAIN_DIR(=$GCC/bin) 作 --prefix，clang 按 target
# (aarch64-linux-gnu) 去找 aarch64-linux-gnu-as；但 GCC 4.9 预编译只提供
# aarch64-linux-android-as，找不到就回退宿主 /usr/bin/as(x86)，遇到 -EL 直接报错
# （典型症状：CC scripts/mod/empty.o -> /usr/bin/as: unrecognized option '-EL'）。
# 建立 gnu 三元组 -> android 三元组的符号链接，让外部 GNU as 被正确找到（-EL 即可识别），
# .S 文件也继续走真正的交叉 GNU as，与 4.14.336 成功编译条件一致。
echo "==> 2b. 建立 aarch64-linux-gnu-* -> aarch64-linux-android-* 符号链接"
export PATH="$GCC/bin:$PATH"
for b in "$GCC"/bin/aarch64-linux-android-*; do
  [ -e "$b" ] || continue
  base=$(basename "$b")
  gnu=${base/aarch64-linux-android-/aarch64-linux-gnu-}
  if [ ! -e "$GCC/bin/$gnu" ]; then ln -sf "$base" "$GCC/bin/$gnu"; fi
done
ls -l "$GCC"/bin/aarch64-linux-gnu-as 2>/dev/null || echo "    [警告] gnu-as 链接未生成，构建可能仍报 -EL"

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

# ============================================================================
#  3b. 【关键】把 KernelSU 真正挂进内核构建系统
#
#  取证：4.14.186 原厂树 mt6873-dev/kernel_redmi_atom 的 drivers/Makefile 与
#  drivers/Kconfig **均无任何 kernelsu 钩子**（旧的 4.14.336 AstroKernel 树是
#  "KSU-ready" 的，自带钩子，所以当时只把目录拷进去就能编）。换基线后 $SRC/KernelSU
#  成了一个从未被编译的孤儿目录 —— CONFIG_KSU 连符号都不存在，步骤 6 的
#  `scripts/config -e CONFIG_KSU` 被 olddefconfig 静默丢弃，编出的内核里
#  KernelSU/SUSFS 字符串数为 0（已用 zlib 解压 Image.gz-dtb 实测确认）。
#  SUSFS 的 CONFIG_KSU_SUSFS 定义在 KernelSU/kernel/Kconfig 内，未被 source 时
#  一并失效，故 SUSFS 也是空的 —— 刷这种包等于白刷。
#
#  这里按 KernelSU 官方 setup.sh 的标准做法补钩子：
#    drivers/kernelsu -> ../KernelSU/kernel  （符号链接）
#    drivers/Makefile += obj-$(CONFIG_KSU) += kernelsu/
#    drivers/Kconfig  += source "drivers/kernelsu/Kconfig"（插在 Device Drivers 菜单内）
# ============================================================================
echo "==> 3b. 将 KernelSU 挂入内核构建（drivers/kernelsu + Makefile/Kconfig 钩子）"
rm -rf "$SRC/drivers/kernelsu"
ln -sfn "../KernelSU/kernel" "$SRC/drivers/kernelsu"
if ! grep -q 'kernelsu/' "$SRC/drivers/Makefile"; then
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$SRC/drivers/Makefile"
  echo "    [ok] drivers/Makefile 已追加 obj-\$(CONFIG_KSU) += kernelsu/"
fi
if ! grep -q 'drivers/kernelsu/Kconfig' "$SRC/drivers/Kconfig"; then
  SRC="$SRC" python3 - <<'PY'
import os
p = os.path.join(os.environ["SRC"], "drivers", "Kconfig")
lines = open(p).read().splitlines(True)
# 插到最后一个 endmenu 之前，确保 KernelSU 菜单落在 "Device Drivers" 菜单内部
idx = max(i for i, l in enumerate(lines) if l.strip() == "endmenu")
lines.insert(idx, 'source "drivers/kernelsu/Kconfig"\n')
open(p, "w").writelines(lines)
print('    [ok] drivers/Kconfig 已插入 source "drivers/kernelsu/Kconfig"')
PY
fi
# 校验挂载是否真的生效（链接可解析 + 两处钩子都在），否则直接失败，避免再产出空壳包
if [ ! -f "$SRC/drivers/kernelsu/Makefile" ] || [ ! -f "$SRC/drivers/kernelsu/Kconfig" ]; then
  echo "[!] 致命：drivers/kernelsu 链接不可解析，KernelSU 不会被编入。"; exit 1
fi
grep -n 'kernelsu' "$SRC/drivers/Makefile" | tail -2
grep -n 'kernelsu' "$SRC/drivers/Kconfig" | tail -2

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
    # (e-2) 补 path_umount()：atom 4.14.186 厂商树未提供，但 fs/susfs.c 的
    #     susfs_try_umount 需要它（链接期报 undefined symbol: path_umount）。
    #     转发到树内静态 do_umount() 即可。
    if grep -q "int path_umount(struct path \*path, int flags)" "$SRC/fs/namespace.c"; then
      echo "    [跳过] path_umount 已存在"
    else
      cat >> "$SRC/fs/namespace.c" <<'EOF'

#ifdef CONFIG_KSU_SUSFS
/* SUSFS: fs/susfs.c::susfs_try_umount 调用 path_umount()，但 atom 4.14.186
 * 厂商树未提供该函数（仅有静态 do_umount）。补一个 wrapper 转发到 do_umount。 */
int path_umount(struct path *path, int flags)
{
	struct mount *mnt = real_mount(path->mnt);
	return do_umount(mnt, flags);
}
EXPORT_SYMBOL(path_umount);
#endif
EOF
      echo "    [ok] path_umount() 已补入 fs/namespace.c"
    fi
    # (e-3) 手动补 faccessat 的 SUS_PATH 钩子（上游 50 补丁此 hunk 因 atom 树
    #     faccessat 上下文不同被 reject，导致 SUS_PATH 经 faccessat 不生效）
    SRC="$SRC" python3 - <<'PY2' 2>/dev/null || echo "    [警告] faccessat SUS_PATH 钩子补入失败"
import os, re
p = os.path.join(os.environ["SRC"], "fs/open.c")
s = open(p).read()
m = re.search(r'SYSCALL_DEFINE3\(faccessat.*?\n\{\n(.*?)\n\}', s, re.S)
if m:
    fn = m.group(0)
    if 'susfs_sus_path_by_filename' not in fn:
        fn2 = fn.replace('unsigned int lookup_flags = LOOKUP_FOLLOW;\n',
            'unsigned int lookup_flags = LOOKUP_FOLLOW;\n'
            '#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n'
            '\tstruct filename* fname;\n'
            '\tint status;\n'
            '\tint error;\n'
            '\tfname = getname_safe(filename);\n'
            '\tstatus = susfs_sus_path_by_filename(fname, &error, SYSCALL_FAMILY_ALL_ENOENT);\n'
            '\tputname_safe(fname);\n'
            '\tif (status) {\n'
            '\t\treturn error;\n'
            '\t}\n'
            '#endif\n', 1)
        s = s[:m.start()] + fn2 + s[m.end():]
        open(p, "w").write(s)
        print("    [ok] faccessat SUS_PATH 钩子已补入")
    else:
        print("    [跳过] faccessat 已有 SUS_PATH 钩子")
else:
    print("    [警告] 未找到 faccessat 函数")
PY2
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
  -Wno-error=address-of-packed-member -Wno-unknown-warning-option \
  -Wno-error -Wno-unused-but-set-variable -Wno-unused-variable \
  -Wno-unused-function -Wno-error=unused-but-set-variable \
  -fno-builtin-stpcpy -fno-builtin-stpncpy"
# 兜底：4.14+SUSFS 在 clang-14 下会触发若干「set but not used / unused」被 -Werror 当错误
# （如 mm/vmscan.c:3289 的 nid）。用全局 -Wno-error 把所有告警从错误降级为警告，
# 避免反复 15 分钟构建卡在告警类错误；内核仍可正常编译与启动。

OUT="$SRC/out"
mkdir -p "$OUT"
cd "$SRC"

echo "==> 5. 生成 defconfig (vendor/atom_user_defconfig)"
make $MK O="$OUT" ARCH=arm64 vendor/atom_user_defconfig

echo "==> 6. 校正内核配置 (KSU=$WITH_KSU SUSFS=$WITH_SUSFS)"
# 【关键】CONFIG_KPROBES 必须打开。
#   SukiSU 的 Kconfig：config KSU_MANUAL_HOOK  default y if !KPROBES
#   原厂 atom defconfig 是 `# CONFIG_KPROBES is not set`（但 CONFIG_HAVE_KPROBES=y，
#   即 arm64 架构本身支持），因此若不显式打开 KPROBES，MANUAL_HOOK 会被 Kconfig
#   默认置 y —— 而「手动钩子」要求内核源码里预先打好 syscall hook 补丁（fs/exec.c、
#   fs/open.c、fs/read_write.c、fs/stat.c 等），我们并未打这些补丁，结果会编出一个
#   「有 KSU 代码但没有任何 su 钩子」的空壳内核（能开机，但管理器永远拿不到 root）。
#   打开 KPROBES + 关闭 MANUAL_HOOK，走 kprobes 动态挂钩，这是 non-GKI 4.14 的标准做法，
#   无需改动任何内核源码。
# CONFIG_KPM：SukiSU 的内核补丁模块，仅适配 GKI，本机为 Non-GKI 4.14，明确关闭以免影响稳定性。
if [ "$WITH_KSU" = "1" ]; then
  ./scripts/config --file "$OUT/.config" \
    -e CONFIG_KSU -d CONFIG_KSU_MANUAL_HOOK \
    -e CONFIG_KPROBES -e CONFIG_KSU_LSM_SECURITY_HOOKS \
    -d CONFIG_KPM
else
  ./scripts/config --file "$OUT/.config" -d CONFIG_KSU -d CONFIG_KSU_MANUAL_HOOK
fi
./scripts/config --file "$OUT/.config" \
  -e CONFIG_KALLSYMS -e CONFIG_KALLSYMS_ALL \
  -d CONFIG_LTO_CLANG -d CONFIG_LTO -d CONFIG_POLLY_CLANG \
  -d CONFIG_CC_STACKPROTECTOR_STRONG \
  -d CONFIG_COMPAT_VDSO \
  -d CONFIG_DEBUG_INFO -d CONFIG_DEBUG_INFO_REDUCED \
  -d CONFIG_DEBUG_INFO_SPLIT -d CONFIG_DEBUG_INFO_DWARF4 \
  -d CONFIG_DEBUG_INFO_DWARF5 -d CONFIG_GDB_SCRIPTS \
  -d CONFIG_DEBUG_KERNEL
# 修复：公开 kernel_redmi_atom 树缺失板级 focaltech 固件 fw_ft3518_j7.i（不进公开仓库），
# 该固件由 drivers/input/touchscreen/focaltech_touch/focaltech_flash.c 通过
#   #include FTS_UPGRADE_FW_FILE
# 引入，缺文件则 focaltech_flash.o 编译失败 -> 整体构建中止。关闭 FTS 触摸屏驱动
# （含 FOD 子选项），整棵 focaltech_touch 子树不再编入，绕开缺失固件。
# 影响：仅触摸屏暂不可用，内核仍能正常启动过 logo；后续可单独补固件再开启。
./scripts/config --file "$OUT/.config" \
  -d CONFIG_TOUCHSCREEN_FTS -d CONFIG_TOUCHSCREEN_FTS_FOD
# 关键：4.14.186 原厂 defconfig 默认开启 CONFIG_DEBUG_INFO，clang-14 会据此在汇编
# 产物里吐 `.file 0` / `.loc` 调试指令，而 GCC 4.9 自带的旧 GNU as 不认 `.file 0`
# （报 "file number less than one" / "junk at end of line, first unrecognized
# character is '0'"），编译在 arch/arm64/mm/fault.o 处失败。4.14.336 能编正是因为它
# 没开调试信息。关掉 DEBUG_INFO 后，4.14.186 走与 4.14.336 完全一致的外部 as 工具链。
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

# ============================================================================
#  6c. 【硬闸门】编译前校验 KSU/SUSFS 是否真的落进 .config
#
#  历史教训：此前 KernelSU 目录没挂进构建系统，CONFIG_KSU 连符号都不存在，
#  `scripts/config -e CONFIG_KSU` 静默失败、olddefconfig 又把未知符号丢掉，
#  于是花了 16 分钟编出一个「版本正确但没有 KSU/SUSFS」的空壳包，还差点刷进设备。
#  这里在开编前就断言，宁可立刻失败，也不要再浪费一整轮构建 + 一次刷机。
# ============================================================================
echo "==> 6c. 编译前配置硬校验"
gate_fail=0
if [ "$WITH_KSU" = "1" ]; then
  grep -qE '^CONFIG_KSU=y'      "$OUT/.config" || { echo "[!] CONFIG_KSU 未启用"; gate_fail=1; }
  grep -qE '^CONFIG_KPROBES=y'  "$OUT/.config" || { echo "[!] CONFIG_KPROBES 未启用（KSU 将无 su 钩子）"; gate_fail=1; }
  if grep -qE '^CONFIG_KSU_MANUAL_HOOK=y' "$OUT/.config"; then
    echo "[!] MANUAL_HOOK 仍为 y，但内核源码未打手动钩子补丁 → 会编出无 su 钩子的空壳"
    gate_fail=1
  fi
fi
if [ "$WITH_SUSFS" = "1" ]; then
  grep -qE '^CONFIG_KSU_SUSFS=y' "$OUT/.config" || { echo "[!] CONFIG_KSU_SUSFS 未启用"; gate_fail=1; }
fi
echo "--- 实际生效的 KSU/SUSFS 配置 ---"
grep -E '^CONFIG_(KSU|KPROBES|KPM)' "$OUT/.config" | sort | head -30
[ "$gate_fail" = "0" ] || { echo "[!] 配置硬校验失败，终止构建（避免产出空壳包）"; exit 1; }
echo "    [ok] KSU/SUSFS 配置校验通过"

build_kernel() {
  make $MK O="$OUT" ARCH=arm64 -j"$(nproc)" 2>&1 | tee "$BASE/build.log"
}

echo "==> 7. 开始编译 ..."
if ! build_kernel; then
  echo "[!] 编译失败，最后 80 行日志："; tail -80 "$BASE/build.log"; exit 1
fi

IMG="$OUT/arch/arm64/boot/Image.gz-dtb"
[ -f "$IMG" ] || IMG="$OUT/arch/arm64/boot/Image.gz"
[ -f "$IMG" ] || IMG="$OUT/arch/arm64/boot/Image"
echo "==> 产物: $IMG (WITH_SUSFS=$WITH_SUSFS)"

# ============================================================================
#  7b. 【硬闸门】对最终镜像做「二进制取证」，确认 KSU/SUSFS 真的在里面
#  解压 Image.gz-dtb 后统计 KernelSU / susfs 字符串。注意不能直接 grep "ksu"，
#  因为内核里大量 "checksum" 含子串 ksu（实测 169 处），会造成假阳性。
# ============================================================================
echo "==> 7b. 产物二进制取证（KSU/SUSFS 字符串）"
# 注意：workflow 以 `bash -e` 运行，若直接让 python 非零退出会立刻中止、来不及打印提示，
# 故用 if ! ... 包裹，保证失败原因能出现在日志里。
if ! IMG_PATH="$IMG" OUT="$OUT" WITH_KSU="$WITH_KSU" WITH_SUSFS="$WITH_SUSFS" python3 - <<'PY'
import os, re, sys, zlib
p = os.environ["IMG_PATH"]
data = open(p, "rb").read()
i = data.find(b"\x1f\x8b\x08")
raw = zlib.decompressobj(31).decompress(data[i:]) if i >= 0 else data
m = re.search(rb"Linux version [0-9][^\x00]{0,120}", raw)
print("    内核版本:", m.group().decode("utf-8", "replace") if m else "(未找到)")
n_ksu   = raw.count(b"KernelSU")
n_susfs = raw.lower().count(b"susfs")
print(f"    KernelSU 字符串={n_ksu}  susfs 字符串={n_susfs}")
# 同时以 .config 为准：即便 WITH_SUSFS 环境变量被意外复位，只要配置了
# CONFIG_KSU_SUSFS=y，镜像就必须含 susfs 字符串，否则判定为空壳。
need_ksu, need_susfs = False, False
try:
    cfg = open(os.environ["OUT"] + "/.config").read()
except Exception:
    cfg = ""
if os.environ["WITH_KSU"] == "1" or "CONFIG_KSU=y" in cfg:
    need_ksu = True
if os.environ["WITH_SUSFS"] == "1" or "CONFIG_KSU_SUSFS=y" in cfg:
    need_susfs = True
bad = 0
if need_ksu and n_ksu == 0:
    print("[!] 致命：镜像内找不到 KernelSU，编出的是空壳内核"); bad = 1
if need_susfs and n_susfs == 0:
    print("[!] 致命：镜像内找不到 susfs（SUSFS 未真正编入）"); bad = 1
sys.exit(bad)
PY
then
  echo "[!] 产物取证失败，终止（不打包空壳包）"
  exit 1
fi
echo "    [ok] 产物取证通过"

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
