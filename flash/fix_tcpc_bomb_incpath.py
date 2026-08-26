#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""修复 tcpc_bomb (USB Type-C PD) 驱动缺失 include path 的问题.

问题 (run 32681731399 唯一剩余错误):
  drivers/misc/mediatek/typec/tcpc_bomb/inc/pd_dpm_pdo_select.h:18
      #include "inc/tcpci.h"
  fatal error: 'inc/tcpci.h' file not found

该驱动内大量头文件用 #include "inc/xxx.h" 形式, 期望编译时 -I 含
drivers/misc/mediatek/typec/tcpc_bomb (父目录), 从而 "inc/tcpci.h" ->
.../tcpc_bomb/inc/tcpci.h (该文件在公开树中确实存在, HTTP 200 验证过).
但本仓 tcpc_bomb/Makefile 未设置任何 ccflags, 父级 typec/Makefile 仅
subdir-ccflags-y += -I$(srctree)/drivers/misc/mediatek/typec/inc, 不含
.../tcpc_bomb -> Clang 报 file not found.

修复: 给 tcpc_bomb/Makefile 追加 ccflags-y += -I$(srctree)/.../tcpc_bomb,
  一次性让所有 "inc/..." 包含都解析到 tcpc_bomb/inc/. 幂等 (已加 marker 则跳过).
"""
import os, sys

MARKER = "# atom-build: tcpc_bomb inc path"
# tcpc_bomb 目录 (含 inc/ 子目录); 注意 -I 必须指向【目录】, 不是 Makefile 文件
TARGET_DIR = os.path.join("drivers", "misc", "mediatek", "typec", "tcpc_bomb")
TARGET_MK = os.path.join(TARGET_DIR, "Makefile")

def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    mk = os.path.join(root, TARGET_MK)
    if not os.path.isfile(mk):
        print("[tcpc_inc] %s not found, skip (non-fatal)" % mk)
        return 0
    txt = open(mk, encoding="utf-8", errors="replace").read()
    if MARKER in txt:
        print("[tcpc_inc] already patched, skip")
        return 0
    with open(mk, "a", encoding="utf-8") as f:
        f.write("\n%s\n" % MARKER)
        f.write("ccflags-y += -I$(srctree)/%s\n" % TARGET_DIR.replace("\\", "/"))
    print("[tcpc_inc] appended '-I$(srctree)/%s' to %s"
          % (TARGET_MK.replace("\\", "/"), mk))
    return 0

if __name__ == "__main__":
    sys.exit(main())
