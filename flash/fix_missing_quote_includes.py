#!/usr/bin/env python3
"""通用修复: 解析 MTK 公开树中\"引号引用但自身目录不存在\"的本地头文件.

MTK 4.14 公开源码树常有这种情况: 某头文件 (如 mt_iommu.h) 写
    #include "mtk_iommu_ext.h"
但该文件实际位于树的其它目录 (如 drivers/iommu/mtk_iommu_ext.h), 而引号 include
只先在\"引用者所在目录\"查找 -> 找不到 -> 编译 fatal error.

本脚本:
  1) 扫描整树所有 .c/.h, 提取 `#include "name"` (name 不含 '/', 即本地相对引用).
  2) 若 name 在\"引用者目录\"已存在 -> 跳过.
  3) 否则在整树内按文件名精确搜索候选:
       - 恰好 1 个候选 -> 拷贝到引用者目录 (若候选已在那儿则跳过).
       - 多个候选 / 0 个候选 -> 跳过并在 stderr 报告 (不臆测平台, 避免拷错).
  4) 不处理尖括号 (<name>) -- 那由 fix_angle_includes.py 负责.

幂等: 已存在则不重复拷贝.
"""
import os
import re
import sys
import shutil

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."

# 不扫描这些目录 (第三方/工具链/已打补丁产物), 且这些目录里的头文件不该被当作候选源
SKIP_DIRS = {".git", "out", "AK3", "vendor", "toolchain", "clang", "gcc", "prebuilts"}

quote_re = re.compile(r'^\s*#\s*include\s+"([^"/]+\.h)"\s*$')
candidate_cache = {}


def find_candidates(name):
    """整树内按文件名查找候选, 返回绝对路径列表 (排除引用者自身目录的命中)."""
    if name in candidate_cache:
        return candidate_cache[name]
    hits = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        # 剪枝
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        if name in filenames:
            hits.append(os.path.join(dirpath, name))
    candidate_cache[name] = hits
    return hits


def main():
    copied = 0
    skipped_ambiguous = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if not fn.endswith((".c", ".h")):
                continue
            fpath = os.path.join(dirpath, fn)
            try:
                with open(fpath, "r", encoding="utf-8", errors="ignore") as f:
                    lines = f.readlines()
            except OSError:
                continue
            for ln in lines:
                m = quote_re.match(ln)
                if not m:
                    continue
                name = m.group(1)
                # 已在引用者目录?
                if os.path.exists(os.path.join(dirpath, name)):
                    continue
                cands = find_candidates(name)
                if len(cands) == 1:
                    src = cands[0]
                    dst = os.path.join(dirpath, name)
                    try:
                        shutil.copy2(src, dst)
                        copied += 1
                        print(f"[fix_quote] copy {os.path.relpath(src, ROOT)} -> {os.path.relpath(dst, ROOT)}")
                    except OSError as e:
                        print(f"[fix_quote] WARN copy failed {src} -> {dst}: {e}", file=sys.stderr)
                elif len(cands) == 0:
                    skipped_ambiguous.append(f"{os.path.relpath(fpath, ROOT)}: {name} (no candidate in tree)")
                else:
                    skipped_ambiguous.append(
                        f"{os.path.relpath(fpath, ROOT)}: {name} (ambiguous {len(cands)} candidates)"
                    )
    print(f"[fix_quote] done. copied={copied} ambiguous_skipped={len(skipped_ambiguous)}")
    for s in skipped_ambiguous:
        print(f"[fix_quote] SKIP {s}", file=sys.stderr)


if __name__ == "__main__":
    main()
