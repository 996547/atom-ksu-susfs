#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""修复 atom(mt6873) 构建中 larb-port.h 宏重定义问题。

问题背景:
  公开 MTK 4.14 树默认把 MTK_PLATFORM 解析为 mt6853; 因此驱动(如 mmdvfs/mt6873/
  mmdvfs_plat.c 经 smi_pmqos.h -> <smi_port.h>)实际拉进的是
  include/dt-bindings/memory/mt6853-larb-port.h, 而该 .c 又直接包含
  include/dt-bindings/memory/mt6873-larb-port.h。两个头各自有独立文件级 include
  guard (_DTS_IOMMU_PORT_MT6853_H_ / _DTS_IOMMU_PORT_MT6873_H_), 但定义大量同名
  M4U_PORT_* 宏(值不同)且无 per-macro 守卫 -> 同一 TU 同时包含即 -Werror 宏重定义。
  波及 disp/vdec/venc/m4u/iommu 等一切走 <smi_port.h> 链的 mt6873 驱动。

修复(与 gpufreq mt6785 转发同构, 免疫 -I 顺序):
  把 mt6853-larb-port.h 改写为对 mt6873-larb-port.h 的薄转发层:
      #ifndef _DTS_IOMMU_PORT_MT6853_H_
      #define _DTS_IOMMU_PORT_MT6853_H_
      #include <dt-bindings/memory/mt6873-larb-port.h>
      #endif
  - mt6873-larb-port.h 自带 guard _DTS_IOMMU_PORT_MT6873_H_, 故无论 <smi_port.h>
    解析到 mt6853 还是 mt6873 版, 最终都落到 mt6873 的 guarded 内容, 同名宏只定义一次。
  - 本仓仅构建 mt6873, 所有消费方本就该用 mt6873 的 M4U port id, 语义正确。
  - 原文件备份为 .orig, 幂等(已转发则跳过)。
"""
import os, sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
TARGET = "include/dt-bindings/memory/mt6853-larb-port.h"
GUARD = "_DTS_IOMMU_PORT_MT6853_H_"
FWD = (
    "#ifndef %s\n" % GUARD +
    "#define %s\n" % GUARD +
    "#include <dt-bindings/memory/mt6873-larb-port.h>\n" +
    "#endif /* %s */\n" % GUARD
)

def find_target():
    for dp, _, fns in os.walk(ROOT):
        if ".git" in dp.split(os.sep):
            continue
        if "mt6853-larb-port.h" in fns:
            p = os.path.join(dp, "mt6853-larb-port.h")
            if p.replace("\\", "/").endswith(TARGET):
                return p
    return None

def main():
    path = find_target()
    if path is None:
        print("[larb] %s not found, skip" % TARGET)
        return
    txt = open(path, encoding="utf-8", errors="replace").read()
    if "#include <dt-bindings/memory/mt6873-larb-port.h>" in txt:
        print("[larb] already forwarding to mt6873, skip: %s" % path)
        return
    # backup
    bak = path + ".orig"
    if not os.path.exists(bak):
        open(bak, "w", encoding="utf-8").write(txt)
    open(path, "w", encoding="utf-8").write(FWD)
    print("[larb] rewrote %s -> forward to mt6873-larb-port.h" % path)

if __name__ == "__main__":
    main()
