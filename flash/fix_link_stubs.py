#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fix_link_stubs.py -- 为被禁用子系统(ION/charger/SWPM/PPM)的悬空引用提供链接期桩.

这些子系统按"缩减内核"策略在 defconfig 中关闭, 但其调用方( Mali GPU /
apusys / USB-PD / boost / thermal )仍编入 vmlinux, 链接期报 undefined reference.
本脚本:
  1) 把 action-repo/flash/atom_link_shims.c 拷贝到
     <root>/drivers/misc/mediatek/atom_link_shims.c
  2) 在 <root>/drivers/misc/mediatek/Makefile 注册 obj-y += atom_link_shims.o
幂等: 已存在则跳过拷贝; Makefile 已含标记则跳过.
非致命: Makefile 缺失时仅告警(桩文件仍在, 由调用方确保 Makefile 存在).
"""
import os, sys, shutil

MARKER = "# atom-build: link shims (disabled subsystem stubs)"
SRC_REL = os.path.join("flash", "atom_link_shims.c")
DST_REL = os.path.join("drivers", "misc", "mediatek", "atom_link_shims.c")
MK_REL  = os.path.join("drivers", "misc", "mediatek", "Makefile")

def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    # action-repo 的根(含 flash/)通过第二个参数传入, 默认取 root 的父级
    repo_root = sys.argv[2] if len(sys.argv) > 2 else os.path.dirname(os.path.abspath(root))

    src = os.path.join(repo_root, SRC_REL)
    dst = os.path.join(root, DST_REL)
    mk  = os.path.join(root, MK_REL)

    # 1) 拷贝桩源
    if not os.path.isfile(src):
        print("[link_stub] WARN: template %s not found, skip copy" % src)
    elif os.path.isfile(dst):
        print("[link_stub] %s already exists, skip copy" % DST_REL)
    else:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src, dst)
        print("[link_stub] copied %s -> %s" % (SRC_REL, DST_REL))

    # 2) 注册到 Makefile
    if not os.path.isfile(mk):
        print("[link_stub] WARN: %s not found, cannot register obj-y (non-fatal)" % MK_REL)
        return 0
    txt = open(mk, encoding="utf-8", errors="replace").read()
    if MARKER in txt:
        print("[link_stub] Makefile already registers shim, skip")
        return 0
    with open(mk, "a", encoding="utf-8") as f:
        f.write("\n%s\n" % MARKER)
        f.write("obj-y += atom_link_shims.o\n")
    print("[link_stub] registered obj-y += atom_link_shims.o in %s" % MK_REL)
    return 0

if __name__ == "__main__":
    sys.exit(main())
