#!/bin/bash
# =============================================================
#  atom (Redmi 10X 5G / 天玑820 MT6875) SukiSU-Ultra + SUSFS 云端编译
#  专为 GitHub Actions 设计：所有源码/工具链在 CI 内下载，无需提交大体积文件。
#  在本地 WSL 也可直接 bash build.sh 使用。
#
#  环境变量：
#    WITH_SUSFS  1/true  -> 包含 SUSFS（默认）；0/false -> 仅 KernelSU
#    SUSFS_REF   （可选）susfs4ksu 的分支/标签，例如 v1.5.5；留空用默认分支
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

dl() {  # url out
  local url="$1" out="$2" i
  for i in 1 2 3; do
    if curl -fsSL "$url" -o "$out"; then return 0; fi
    sleep 5
  done
  return 1
}

echo "==> 1. 内核源码 (mt6873-dev/android_kernel_xiaomi_mt6885 @ cgroup-v2)"
dl "https://github.com/mt6873-dev/android_kernel_xiaomi_mt6885/archive/refs/heads/cgroup-v2.tar.gz" kernel.tar.gz
tar -xzf kernel.tar.gz
SRC="$BASE/android_kernel_xiaomi_mt6885-cgroup-v2"

echo "==> 2. GCC 4.9 工具链 (LineageOS prebuilts)"
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
if [ "$WITH_SUSFS" = "1" ]; then
  echo "==> 4. SUSFS (gitlab.com/simonpunk/susfs4ksu)"
  rm -rf "$BASE/susfs_src"
  if git clone --depth 1 ${SUSFS_REF:+--branch "$SUSFS_REF"} https://gitlab.com/simonpunk/susfs4ksu.git "$BASE/susfs_src" 2>/dev/null; then
    mkdir -p "$SRC/KernelSU/kernel/susfs"
    cp -a "$BASE/susfs_src/kernel/." "$SRC/KernelSU/kernel/susfs/" 2>/dev/null
    grep -q "CONFIG_KSU_SUSFS) += susfs" "$SRC/KernelSU/kernel/Makefile" || \
      printf '\nobj-$(CONFIG_KSU_SUSFS) += susfs/\n' >> "$SRC/KernelSU/kernel/Makefile"
    grep -q 'susfs/Kconfig' "$SRC/KernelSU/kernel/Kconfig" || \
      sed -i '/^endmenu/i source "susfs/Kconfig"' "$SRC/KernelSU/kernel/Kconfig"
    if [ ! -f "$SRC/KernelSU/kernel/susfs/Kconfig" ]; then
      echo "    [警告] SUSFS 源码结构异常，放弃 SUSFS，仅编译 KernelSU。"; WITH_SUSFS=0
    else
      echo "    SUSFS 已接入 KernelSU/kernel/susfs"
    fi
  else
    echo "    [警告] SUSFS 克隆失败，仅编译 KernelSU。"; WITH_SUSFS=0
  fi
else
  echo "==> 4. 已跳过 SUSFS (WITH_SUSFS=0)"
fi

export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE="$GCC/bin/aarch64-linux-android-"
export PATH="$GCC/bin:$PATH"
OUT="$SRC/out"
cd "$SRC"

echo "==> 5. 生成 defconfig (vendor/atom_user_defconfig)"
make O="$OUT" ARCH=arm64 vendor/atom_user_defconfig

echo "==> 6. 校正内核配置"
./scripts/config --file "$OUT/.config" \
  -e CONFIG_KSU -e CONFIG_KSU_MANUAL_HOOK \
  -e CONFIG_KALLSYMS -e CONFIG_KALLSYMS_ALL \
  -d CONFIG_LTO_CLANG -d CONFIG_LTO -d CONFIG_POLLY_CLANG
if [ "$WITH_SUSFS" = "1" ] && [ -f "$SRC/KernelSU/kernel/susfs/Kconfig" ]; then
  ./scripts/config --file "$OUT/.config" \
    -e CONFIG_KSU_SUSFS -e CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT \
    -e CONFIG_KSU_SUSFS_SUS_PATH -e CONFIG_KSU_SUSFS_SUS_MOUNT \
    -e CONFIG_KSU_SUSFS_SUS_KSTAT -e CONFIG_KSU_SUSFS_SUS_OVERLAYFS \
    -e CONFIG_KSU_SUSFS_TRY_UMOUNT -e CONFIG_KSU_SUSFS_AUTO_SET_SUS_KSTAT \
    -e CONFIG_KSU_SUSFS_SUS_SU
fi
make O="$OUT" ARCH=arm64 olddefconfig

build_kernel() {
  make O="$OUT" ARCH=arm64 -j"$(nproc)"
}

echo "==> 7. 开始编译 ..."
if ! build_kernel; then
  if [ "$WITH_SUSFS" = "1" ]; then
    echo "[!] 带 SUSFS 编译失败，自动回退为仅 KernelSU 重建 ..."
    WITH_SUSFS=0
    ./scripts/config --file "$OUT/.config" -d CONFIG_KSU_SUSFS
    make O="$OUT" ARCH=arm64 olddefconfig
    rm -rf "$OUT/drivers/kernelsu" "$OUT/arch/arm64/boot"
    build_kernel
  else
    echo "[!] 编译失败"; exit 1
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
