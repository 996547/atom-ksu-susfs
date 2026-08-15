#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SukiSU-Ultra (基于 KernelSU main, 5.x API) 在 Linux 4.14 上的通用适配.
遍历 drivers/kernelsu/ 下所有 .c/.h, 应用:
 1) 删除 5.x 才有的 <linux/pgtable.h> include (4.14 无)
 2) strncpy_from_user_nofault -> strncpy_from_user
 3) ksys_* (5.x syscall wrapper) -> sys_* (4.14 等价, 需 <linux/syscalls.h>)
 4) 若用到 sys_* 但缺 <linux/syscalls.h> 则补 include
 5) strncpy_from_user_nofault -> strncpy_from_user 后, 该函数声明在 4.14 的
    <linux/uaccess.h> 中; 若文件未包含该头则补 include (否则报 implicit declaration)
幂等, 可重复运行.
"""
import os, sys, glob

KSU_DIR = "drivers/kernelsu"


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    base = os.path.join(root, KSU_DIR)
    if not os.path.isdir(base):
        print("[fix_ksu_414_generic] skip (not found):", base)
        return
    files = []
    for ext in ("*.c", "*.h"):
        files += glob.glob(os.path.join(base, "**", ext), recursive=True)
    for path in files:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            lines = f.readlines()
        out = []
        uses_sys = False
        has_syscalls_h = False
        for ln in lines:
            if ln.strip() == "#include <linux/pgtable.h>":
                continue  # drop 5.x-only header
            new = ln.replace("strncpy_from_user_nofault", "strncpy_from_user")
            new = new.replace("ksys_", "sys_")
            if "sys_" in new:
                uses_sys = True
            if "linux/syscalls.h" in new:
                has_syscalls_h = True
            out.append(new)
        if uses_sys and not has_syscalls_h:
            out.insert(0, "#include <linux/syscalls.h>  // 4.14: sys_* 声明\n")
        # strncpy_from_user 在 4.14 中声明于 <linux/uaccess.h>;
        # 改名后若该头未包含, 会报 implicit declaration, 主动补.
        uses_strncpy = "strncpy_from_user" in "".join(out)
        has_uaccess_h = any("linux/uaccess.h" in l for l in out)
        if uses_strncpy and not has_uaccess_h:
            out.insert(0, "#include <linux/uaccess.h>  // 4.14: strncpy_from_user 声明\n")
        with open(path, "w", encoding="utf-8") as f:
            f.writelines(out)
    print(f"[fix_ksu_414_generic] patched {len(files)} files under {KSU_DIR}")


if __name__ == "__main__":
    main()
