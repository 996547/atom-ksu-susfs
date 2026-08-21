#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
修复 mt6873 gpufreq 结构性双定义 (redefinition of 'struct mt_gpufreq_power_table_info').

根因:
  mt6785/mtk_gpufreq.h 用 guard _MT_GPUFREQ_H_ 定义 struct mt_gpufreq_power_table_info;
  gpufreq_v1/mt6873/mtk_gpufreq_plat.h 用不同 guard (___MT_GPUFREQ_PLAT_H___) 也定义同名 struct.
  二者 include guard 不同, 而 include/mtk_gpufreq.h 又同时 #include 两者, 故任一 TU 同时
  拉入两者即报重定义 (如 pbm_v4/mtk_pbm.c 经 <mtk_gpufreq.h> 与 mtk_thermal.h 链).

修复: 给 plat 头的 struct 定义加上 _MT_GPUFREQ_H_ 共享 guard, 使"谁先被包含谁定义该
(完全相同的) struct, 另一个跳过", 与包含两个头的顺序无关. 对仅包含 plat 头的文件无副作用
(struct 仍会被定义一次).

路径相对内核源码树根: drivers/misc/mediatek/base/power/include/gpufreq_v1/mt6873/mtk_gpufreq_plat.h
"""
import os
import re
import sys

HEADER = "drivers/misc/mediatek/base/power/include/gpufreq_v1/mt6873/mtk_gpufreq_plat.h"
GUARD = "_MT_GPUFREQ_H_"


def main():
    # 允许从内核树根或任意目录调用: 若当前目录无该头, 尝试相对 action-repo 的 kernel 树
    cand = HEADER
    if not os.path.isfile(cand):
        # 由 flash/ 目录调用时, 内核在 ../kernel
        for base in ("", "..", "../kernel", "../.."):
            if os.path.isfile(os.path.join(base, HEADER)):
                cand = os.path.join(base, HEADER)
                break
    if not os.path.isfile(cand):
        print("[i] %s not found, skip" % HEADER)
        return
    try:
        with open(cand, "r", encoding="utf-8", errors="replace") as f:
            s = f.read()
    except OSError as e:
        print("[W] cannot read %s: %s" % (cand, e))
        return

    m = re.search(r"struct\s+mt_gpufreq_power_table_info\s*\{", s)
    if not m:
        print("[i] struct mt_gpufreq_power_table_info not found in %s, skip" % cand)
        return

    # 已加过 guard 则跳过
    if "#ifndef %s" % GUARD in s[: m.start()]:
        print("[skip] %s already guarded by %s" % (cand, GUARD))
        return

    # 找 struct 的匹配右花括号
    i = s.index("{", m.start())
    depth = 0
    j = i
    while j < len(s):
        if s[j] == "{":
            depth += 1
        elif s[j] == "}":
            depth -= 1
            if depth == 0:
                break
        j += 1
    if depth != 0:
        print("[W] unbalanced braces in %s, skip" % cand)
        return
    # struct 以 '};' 结尾
    end = s.index(";", j) + 1

    guard_open = "#ifndef %s\n#define %s\n" % (GUARD, GUARD)
    guard_close = "\n#endif /* %s */\n" % GUARD
    new = s[: m.start()] + guard_open + s[m.start() : end] + guard_close + s[end:]
    with open(cand, "w", encoding="utf-8") as f:
        f.write(new)
    print("[ok] wrapped mt_gpufreq_power_table_info with %s guard in %s" % (GUARD, cand))


if __name__ == "__main__":
    main()
