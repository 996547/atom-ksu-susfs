#!/usr/bin/env python3
"""
SukiSU-Ultra (v4.1.3, 基于 KernelSU main, 面向 5.x API) 在 Linux 4.14 上的适配。

两个文件需要打补丁:

1) drivers/kernelsu/feature/sucompat.c
   - 删除 '#include <linux/pgtable.h>'  (4.14 无此头且 sucompat.c 不用页表符号,
     mm.h 已通过 asm/pgtable.h 间接提供所需)
   - strncpy_from_user_nofault -> strncpy_from_user  (4.14 等价安全拷贝)

2) drivers/kernelsu/include/util.h   <-- run#17 漏掉的关键文件!
   - 宏 '#define ksu_close_fd ksys_close' : ksys_close 是 5.x 才有的 syscall wrapper,
     sucompat.c:232 通过宏 ksu_close_fd(tmp_fd) 展开成 ksys_close(...) -> 4.14 报
     implicit declaration. 4.14 有 sys_close (include/linux/syscalls.h:555 已声明),
     故把宏的映射目标改成 sys_close 即可.
   - 同时为 util.h 补 #include <linux/syscalls.h> 保证 sys_close 可见
     (sucompat.c 编译时该头已间接包含, 但 util.h 可能被其他文件引入).

用法: python3 fix_sucompat_414.py <kernel_tree_root>
"""
import os
import sys

FILES = {
    "drivers/kernelsu/feature/sucompat.c": [
        ("#include <linux/pgtable.h>", None),        # None => 整行删除
        ("strncpy_from_user_nofault", "strncpy_from_user"),
    ],
    "drivers/kernelsu/include/util.h": [
        ("ksys_close", "sys_close"),
    ],
}


def patch_file(root, rel, rules):
    path = os.path.join(root, rel)
    if not os.path.isfile(path):
        print("[fix_sucompat_414] skip (not found):", rel)
        return
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        lines = f.readlines()

    out = []
    for ln in lines:
        dropped = False
        for pat, rep in rules:
            if rep is None:
                # 精确整行删除 (基于 strip 后相等)
                if ln.strip() == pat:
                    dropped = True
                    break
            else:
                ln = ln.replace(pat, rep)
        if not dropped:
            out.append(ln)

    # util.h 需要确保 sys_close 声明可见
    if rel.endswith("util.h") and not any("linux/syscalls.h" in l for l in out):
        out.insert(0, "#include <linux/syscalls.h>  // 4.14: sys_close 声明\n")

    # sucompat.c: 5.x 的 strncpy_from_user_nofault 被改名成 4.14 的
    # strncpy_from_user, 但该函数在 4.14 中声明于 <linux/uaccess.h>.
    # 若本文件未(直接/间接)包含该头, 会报
    # "implicit declaration of function 'strncpy_from_user'". 主动补 include.
    if rel.endswith("sucompat.c"):
        text = "".join(out)
        if "strncpy_from_user" in text and not any("linux/uaccess.h" in l for l in out):
            out.insert(0, "#include <linux/uaccess.h>  // 4.14: strncpy_from_user 声明\n")

    with open(path, "w", encoding="utf-8") as f:
        f.writelines(out)
    print("[fix_sucompat_414] patched:", rel)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    for rel, rules in FILES.items():
        patch_file(root, rel, rules)


if __name__ == "__main__":
    main()
