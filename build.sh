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
# 该 4.14.336 内核官方用 clang + ld.lld 编译；GCC 4.9 太旧无法编译此内核。
# 优先 clang-14（对 4.14 兼容性最佳，implicit-function-declaration 仍只是警告），
# 其次回退到系统 clang / clang-18。
pick_clang() {
  if command -v clang-14 >/dev/null 2>&1; then
    export CC=clang-14; export LD=ld.lld-14
  elif command -v clang >/dev/null 2>&1; then
    export CC=clang; export LD=ld.lld
  else
    echo "[!] 未找到 clang，请先安装 clang/lld"; exit 1
  fi
  echo "    使用编译器: $CC / 链接器: $LD"
}

echo "==> 1. 内核源码 (mt6873-dev/android_kernel_xiaomi_mt6885 @ cgroup-v2)"
dl "https://github.com/mt6873-dev/android_kernel_xiaomi_mt6885/archive/refs/heads/cgroup-v2.tar.gz" kernel.tar.gz
tar -xzf kernel.tar.gz
SRC="$BASE/android_kernel_xiaomi_mt6885-cgroup-v2"

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
export CLANG_TRIPLE=aarch64-linux-gnu-
# 防御性：4.14 + 新版 clang 下把若干新警告从错误降级为警告，避免完整编译途中被打断。
# -Wno-unknown-warning-option 确保任一未知告警选项本身不会触发错误。
export KCFLAGS="-Wno-error=implicit-function-declaration -Wno-error=implicit-int \
  -Wno-error=incompatible-pointer-types -Wno-error=array-bounds \
  -Wno-error=stringop-overflow -Wno-error=shift-count-overflow \
  -Wno-error=enum-conversion -Wno-error=unused-but-set-variable \
  -Wno-error=address-of-packed-member -Wno-error=format \
  -Wno-unknown-warning-option"

OUT="$SRC/out"
mkdir -p "$OUT"
cd "$SRC"

echo "==> 5. 生成 defconfig (vendor/atom_user_defconfig)"
make O="$OUT" ARCH=arm64 vendor/atom_user_defconfig

echo "==> 6. 校正内核配置"
./scripts/config --file "$OUT/.config" \
  -e CONFIG_KSU -e CONFIG_KSU_MANUAL_HOOK \
  -e CONFIG_KALLSYMS -e CONFIG_KALLSYMS_ALL \
  -d CONFIG_LTO_CLANG -d CONFIG_LTO -d CONFIG_POLLY_CLANG \
  -d CONFIG_CC_STACKPROTECTOR_STRONG \
  -d CONFIG_COMPAT_VDSO
if [ "$WITH_SUSFS" = "1" ]; then
  ./scripts/config --file "$OUT/.config" \
    -e CONFIG_KSU_SUSFS -e CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT \
    -e CONFIG_KSU_SUSFS_SUS_PATH -e CONFIG_KSU_SUSFS_SUS_MOUNT \
    -e CONFIG_KSU_SUSFS_SUS_KSTAT -e CONFIG_KSU_SUSFS_SUS_OVERLAYFS \
    -e CONFIG_KSU_SUSFS_TRY_UMOUNT -e CONFIG_KSU_SUSFS_AUTO_SET_SUS_KSTAT \
    -e CONFIG_KSU_SUSFS_SUS_SU
fi
make O="$OUT" ARCH=arm64 olddefconfig

build_kernel() {
  make O="$OUT" ARCH=arm64 -j"$(nproc)" 2>&1 | tee "$BASE/build.log"
}

echo "==> 7. 开始编译 ..."
if ! build_kernel; then
  if [ "$WITH_SUSFS" = "1" ]; then
    echo "[!] 带 SUSFS 编译失败，自动回退为仅 KernelSU 重建 ..."
    WITH_SUSFS=0
    ./scripts/config --file "$OUT/.config" -d CONFIG_KSU_SUSFS
    make O="$OUT" ARCH=arm64 olddefconfig
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
rm -f "$BASE/atom-ksu-susfs-AnyKernel3.zip"
zip -r9 "$BASE/atom-ksu-susfs-AnyKernel3.zip" . -x "*.git*"
echo "==> 刷机包: $BASE/atom-ksu-susfs-AnyKernel3.zip"
echo "DONE"
