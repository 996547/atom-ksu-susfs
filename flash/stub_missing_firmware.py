#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
为缺失的触摸/外设固件 .i 文件创建空桩, 避免 MiCode 公开树缺失厂商私有 blob 导致编译失败.

背景:
  MTK/FTS 等触摸驱动常在 .c 里写:
      #include "include/firmware/fw_ftXXXX.i"
  这些 .i 是厂商私有固件 C 数组, MiCode 公开源码树不含 -> 编译报 "file not found".
  固件仅用于"内核内固件升级"路径, 核心触摸输入不依赖它 (实机固件通常由 vendor 分区加载).
  这里给所有"被引用但不存在"的 .i 建空桩, 让驱动能编译通过 (升级功能为空, 不影响输入).

解析规则:
  引号 include "include/firmware/NAME.i" 相对"当前 .c 文件目录"解析 ->
      在 <dir-of-file>/include/firmware/NAME.i 建桩;
  同时也在 <srctree>/include/firmware/NAME.i 建桩(部分驱动按 -I 根目录解析).
  仅当文件确实不存在时才创建, 不覆盖已有固件.
"""
import os
import re
import sys

# 匹配引号 include 且路径含 include/firmware/NAME.i
INC_RE = re.compile(r'#\s*include\s+"([^"]*include/firmware/[^"]+\.i)"')


def main():
    if len(sys.argv) < 2:
        print("usage: stub_missing_firmware.py <kernel_tree_root>")
        sys.exit(1)

    root = os.path.abspath(sys.argv[1])
    created = 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".git", "out", "AK3")]
        for fn in filenames:
            if not fn.endswith((".c", ".h")):
                continue
            path = os.path.join(dirpath, fn)
            try:
                with open(path, "r", encoding="utf-8", errors="ignore") as f:
                    content = f.read()
            except OSError:
                continue
            for m in INC_RE.finditer(content):
                rel = m.group(1)            # 如 include/firmware/fw_ft3518_j7.i
                rel = rel.lstrip("./")
                # 候选1: 相对当前 .c 文件目录
                cand1 = os.path.join(dirpath, rel)
                # 候选2: 相对内核根 include/firmware/
                cand2 = os.path.join(root, rel)
                for cand in (cand1, cand2):
                    if os.path.exists(cand):
                        continue
                    os.makedirs(os.path.dirname(cand), exist_ok=True)
                    with open(cand, "w", encoding="utf-8") as fh:
                        fh.write("/* stub: missing vendor firmware blob (not in public MiCode source) */\n")
                    rel_disp = os.path.relpath(cand, root)
                    print("[stub] created empty: %s" % rel_disp)
                    created += 1
    print("[stub] done, %d stub file(s) created" % created)


if __name__ == "__main__":
    main()
