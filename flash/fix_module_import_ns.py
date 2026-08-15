#!/usr/bin/env python3
# 修复 4.14 内核缺 MODULE_IMPORT_NS 宏 (run#14 暴露)
#
# 背景: MODULE_IMPORT_NS 是 Linux 5.x 引入的"模块符号命名空间导入"宏,
# KernelSU-Ultra main 分支的 drivers/kernelsu/core/init.c 用到它:
#   MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);
# 在 Linux 4.14 上该宏根本没有定义, 编译器把它当成一个
#   "a parameter list without types is only allowed in a function definition"
# 的函数声明 -> 编译失败.
#
# 4.14 内核没有模块 namespace 概念, 因此把它定义为 no-op 即可.
# 做法:
#   1) 全局兜底: 在 include/linux/export.h (5.x 中该宏的定义位置) 追加 no-op 定义;
#   2) 双保险: 扫描 drivers/kernelsu 所有用到该宏的源文件, 在文件顶部加同样的 guard.

import os
import sys
import glob

KERNEL_DIR = sys.argv[1] if len(sys.argv) > 1 else "."

GUARD = (
    "#ifndef MODULE_IMPORT_NS\n"
    "#define MODULE_IMPORT_NS(ns)\n"
    "#endif\n"
)

added = 0

# 1) 全局兜底: include/linux/export.h
exp = os.path.join(KERNEL_DIR, "include/linux/export.h")
if os.path.exists(exp):
    with open(exp, "r", encoding="utf-8", errors="ignore") as f:
        c = f.read()
    if "define MODULE_IMPORT_NS" not in c:
        with open(exp, "a", encoding="utf-8") as f:
            f.write("\n" + GUARD)
        print("patched include/linux/export.h")
        added += 1
    else:
        print("include/linux/export.h already has MODULE_IMPORT_NS, skip")
else:
    print("WARN: include/linux/export.h not found at", exp)

# 2) 双保险: 扫描 drivers/kernelsu 用到该宏的源文件, 顶部加 guard
for pat in ("drivers/kernelsu/**/*.c", "drivers/kernelsu/**/*.h"):
    for fp in glob.glob(os.path.join(KERNEL_DIR, pat), recursive=True):
        with open(fp, "r", encoding="utf-8", errors="ignore") as f:
            c = f.read()
        if "MODULE_IMPORT_NS" in c and "define MODULE_IMPORT_NS" not in c:
            with open(fp, "w", encoding="utf-8") as f:
                f.write(GUARD + c)
            print("patched top guard:", fp)
            added += 1

print("MODULE_IMPORT_NS guard added to", added, "file(s)")
