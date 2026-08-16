#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""系统性修复 MTK 4.14 树 "子目录文件用引号包含父目录头文件" 的 Clang 编译失败。

问题背景:
  MTK 树大量在子目录文件里用 #include "xxx.h" 引用位于**父目录**(或兄弟子目录)的头文件,
  例如:
    drivers/staging/android/ion/mtk/ion_drv.h  ->  #include "ion.h"   (ion.h 在父目录 ion/)
    .../lpm/modules/platform/mt6873/suspend/mt6873_suspend.c -> #include "mt6873.h" (在父 mt6873/)
  GCC 经 -I. 容忍, 但 MTK Makefile 的 -I 只指向子目录本身, 父目录未加入 → Clang 报
  'xxx.h' file not found.

修复策略 (安全):
  对每个 .c/.h 里的裸引号包含 #include "X" (X 不含 '/'):
    - 若 X 已存在于文件自身目录 -> 本就可用, 跳过;
    - 否则自底向上搜索祖先目录及其直接子目录, 找到最近的 X 后,
      在被包含文件所在目录创建符号链接  X -> 相对路径(真实X),
      使引号包含可本地解析。
  用符号链接而非复制: 链接指向真实文件, 故被链接头文件自身的引号包含仍按真实位置解析,
  不会因"复制导致相对包含错位"而二次报错。仅作用于树内真实存在的本地头, 不碰系统头。
"""
import os, re, sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
QUOTE_RE = re.compile(r'#\s*include\s*"([^"]+)"')

# 高频同名头文件拒绝名单: 这类头几乎都由对应 Makefile 的 -I 正确解析,
# 盲目符号链接会指向错误的同名文件并遮蔽 -I, 造成"隐式声明"等诡异错误.
# 典型: rpmb-mtk.c 的 #include "core.h" 应由 drivers/char/rpmb/Makefile 的
#   -I$(srctree)/drivers/mmc/core 解析为 drivers/mmc/core/core.h (声明 mmc_get_card);
#   若链接到 drivers/pinctrl/core.h 则会丢失 mmc_get_card 声明导致编译失败.
DENYLIST = {"core.h"}

# 歧义时优先选用的"规范位置"候选 (basename -> 相对仓库根的路径).
# 依据: 同一树内其它目录的 mtk_iommu_ext.h 均被符号链接到 drivers/iommu/mtk_iommu_ext.h,
# 说明该文件是各平台共用的规范实现. 当窄搜索命中多个同名候选时, 优先用规范位置避免跳过.
CANONICAL = {"mtk_iommu_ext.h": os.path.join("drivers", "iommu", "mtk_iommu_ext.h")}

total = 0
skipped = 0

def find_headers(start_dir, name):
    """在 start_dir 的祖先及祖先的直接子目录中查找 name, 返回所有真实路径列表。"""
    d = os.path.abspath(start_dir)
    chain = [d]
    parent = os.path.dirname(d)
    while parent and parent != os.path.dirname(parent):
        chain.append(parent)
        parent = os.path.dirname(parent)
    cands = []
    # 先查祖先自身, 再查祖先的直接子目录 (覆盖兄弟子目录情况)
    for anc in chain:
        cand = os.path.join(anc, name)
        if os.path.isfile(cand) and cand not in cands:
            cands.append(cand)
    for anc in chain:
        try:
            for entry in os.listdir(anc):
                sub = os.path.join(anc, entry)
                if os.path.isdir(sub):
                    cand = os.path.join(sub, name)
                    if os.path.isfile(cand) and cand not in cands:
                        cands.append(cand)
        except OSError:
            continue
    return cands

for dirpath, dirs, files in os.walk(ROOT):
    if ".git" in dirs:
        dirs.remove(".git")
    srcs = [f for f in files if f.endswith((".c", ".h"))]
    if not srcs:
        continue
    for fn in srcs:
        fp = os.path.join(dirpath, fn)
        try:
            text = open(fp, encoding="utf-8", errors="replace").read()
        except Exception:
            continue
        for m in QUOTE_RE.finditer(text):
            inc = m.group(1)
            if "/" in inc:
                continue  # 含 '/' 的相对包含由 fix_angle_includes.py 处理其角度形式
            base = os.path.basename(inc)
            if base in DENYLIST:
                skipped += 1
                print("SKIP(denylist)", os.path.relpath(fp, ROOT), ":", base)
                continue
            if os.path.isfile(os.path.join(dirpath, base)):
                continue  # 同目录已有, 可用
            reals = find_headers(dirpath, base)
            if not reals:
                continue
            if len(reals) > 1:
                # 多候选歧义: 若规范位置候选存在则优先使用, 否则不臆测
                canon = CANONICAL.get(base)
                real = None
                if canon:
                    norm = canon.replace("\\", "/")
                    for c in reals:
                        if c.replace("\\", "/").endswith(norm):
                            real = c
                            break
                if real is None:
                    skipped += 1
                    print("SKIP(ambiguous %d)" % len(reals), os.path.relpath(fp, ROOT), ":", base)
                    continue
            else:
                real = reals[0]
            link = os.path.join(dirpath, base)
            rel = os.path.relpath(real, dirpath)
            try:
                if os.path.islink(link) or os.path.exists(link):
                    continue
                os.symlink(rel, link)
                total += 1
                print("symlink", os.path.relpath(link, ROOT), "->", rel)
            except OSError as e:
                print("WARN symlink failed", link, e)
print("TOTAL symlinked:", total, "skipped:", skipped)
