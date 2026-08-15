#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
修复 MTK 4.14 内核在 Clang 下的 trace 头文件 include 路径问题。

问题根因:
  MTK DRM 等驱动的 trace 头文件 (如 mtk_layer_layout_trace.h) 里常写:
      #define TRACE_INCLUDE_PATH .
  include/trace/define_trace.h 据此展开成:
      #include "./<name>.h"
  GCC 会把这种宏展开的引号 include 按 ".c 文件所在目录" 解析 -> 能找到同目录头文件.
  Clang 则按 "define_trace.h 所在目录 (include/trace/)" 解析 -> 找不到 -> 编译失败:
      fatal error: './mtk_layer_layout_trace.h' file not found

修复: 把 TRACE_INCLUDE_PATH 的 "." / "./" 改成相对 include/trace/ 的正确相对路径
  (例如 drivers/gpu/drm/mediatek -> ../../drivers/gpu/drm/mediatek).
  这样 GCC 与 Clang 都能正确解析, 且对原本就在 include/trace/ 下的头文件等价 (. -> .).

仅处理确实包含 define_trace.h 引用、且 TRACE_INCLUDE_PATH 值为 "." 或 "./" 的文件,
避免误改其它合法的 TRACE_INCLUDE_PATH 定义.
"""
import os
import re
import sys


def main():
    if len(sys.argv) < 2:
        print("usage: fix_trace_include_path.py <kernel_tree_root>")
        sys.exit(1)

    root = os.path.abspath(sys.argv[1])
    trace_inc_dir = os.path.join(root, "include", "trace")
    if not os.path.isdir(trace_inc_dir):
        print("[fix_trace] include/trace not found under %s, skip" % root)
        return

    # 匹配: #define TRACE_INCLUDE_PATH .   或   #define TRACE_INCLUDE_PATH ./
    pat = re.compile(
        r'^(?P<indent>\s*)#\s*define\s+TRACE_INCLUDE_PATH\s+(?P<val>\.|\./)\s*$',
        re.MULTILINE,
    )

    changed = 0
    for dirpath, dirnames, filenames in os.walk(root):
        # 跳过 .git / 输出目录, 加速
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
            # 只处理 trace 头文件 (定义了 trace point 并包含 define_trace.h)
            if "define_trace.h" not in content:
                continue
            m = pat.search(content)
            if not m:
                continue
            # 计算从 include/trace/ 到本文件目录的相对路径
            rel = os.path.relpath(dirpath, trace_inc_dir)
            newval = rel.replace(os.sep, "/")
            new_line = "%s#define TRACE_INCLUDE_PATH %s" % (m.group("indent"), newval)
            content2 = content[: m.start()] + new_line + content[m.end():]
            try:
                with open(path, "w", encoding="utf-8") as f:
                    f.write(content2)
            except OSError as e:
                print("[fix_trace] WARN cannot write %s: %s" % (path, e))
                continue
            rel_disp = os.path.relpath(path, root)
            print("[fix_trace] %s : TRACE_INCLUDE_PATH . -> %s" % (rel_disp, newval))
            changed += 1

    print("[fix_trace] done, %d file(s) patched" % changed)


if __name__ == "__main__":
    main()
