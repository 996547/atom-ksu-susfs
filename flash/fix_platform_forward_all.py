#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""全面修复 atom(mt6873) 构建中的"平台头错位"问题 (Class A 根因的系统性解法)。

背景:
  公开 MTK 4.14 树几乎每个平台相关头文件都存在 mt6785/mt6853/mt6873/mt6885 多份变体,
  本应由构建系统 -I 按 MTK_PLATFORM 正确选择。但有两处例外会破坏该机制, 导致每次编译
  都冒出新的"宏重定义 / 类型冲突 / 隐式声明"类错误 (已遇到: gpufreq mt6785, larb-port mt6853):
    1) 共享头硬编码了错误平台 include (如 include/mtk_gpufreq.h 强制 include ../mt6785/...).
    2) 部分 -I 默认解析到 mt6853 (公开树以 mt6853 为缺省), 如 <smi_port.h> 拉进 mt6853 头.
  既往是"编译->报一个->改一个"的打地鼠。本脚本一次性系统性消除这一类。

做法 (与 gpufreq/larb-port 转发同构, 但全自动覆盖全部家族):
  遍历整棵树, 对每个路径含非 mt6873 平台 token 的 .h 文件:
    - 计算其 mt6873 等价路径 (把平台段替换为 mt6873);
    - 仅当该 mt6873 等价文件【真实存在】时才改写 (绝不臆测/创建不存在的头);
    - 改写为薄转发层: 用【与本仓其它头绝不冲突的唯一 guard】包裹, 仅 #include 等价 mt6873 头;
      (关键: 不能用原文件自身的 guard —— 同源家族的 mt6853/mt6873 头往往共用同名 guard,
       复用会导致 mt6873 真内容被 guard 短路跳过, 符号凭空消失. 故 guard 由路径 md5 派生, 全局唯一.)
    - 原文件备份为 .orig; 已转发则跳过 (幂等).
  效果: 无论 -I 顺序或硬编码 include 把非 mt6873 头解析到哪, 最终都落到 mt6873 的
         guarded 内容, 同名宏/类型只定义一次, 免疫搜索顺序与硬编码。
  安全性:
    - 本仓只构建 mt6873, 非 mt6873 平台代码不被编译, 转发到 mt6873 语义正确;
    - 仅改 .h, 不碰 .c; 仅当 mt6873 等价头存在; 全部备份可回滚;
    - gpufreq 的 mt6785/mtk_gpufreq.h 无 mt6873 等价 (其等价在 gpufreq_v1/mt6873/),
      本脚本自动跳过, 仍由 fix_gpufreq_mt6785_shim.py 专门处理。
"""
import os, re, sys, hashlib

ROOTS = [a for a in sys.argv[1:] if not a.startswith("--")]
DRY = ("--dry" in sys.argv)
if not ROOTS:
    ROOTS = ["."]
PLAT_RE = re.compile(r'(mt6785|mt6853|mt6885|mt6833|mt6893)')

def first_guard(txt):
    m = re.search(r'#\s*ifndef\s+(\S+)', txt)
    if m:
        return m.group(1)
    return None

def main():
    total = 0
    skipped_no_equiv = 0
    skipped_nonth = 0
    for ROOT in ROOTS:
        for dp, dirs, fns in os.walk(ROOT):
            if ".git" in dp.split(os.sep):
                continue
            for fn in fns:
                if not fn.endswith(".h"):
                    continue
                p = os.path.join(dp, fn)
                m = PLAT_RE.search(p)
                if not m:
                    continue
                plat = m.group(1)
                eq = p.replace(plat, "mt6873", 1)
                if not os.path.isfile(eq):
                    skipped_no_equiv += 1
                    continue
                txt = open(p, encoding="utf-8", errors="replace").read()
                # 已是转发层 (非 mt6873 文件却 include 了 mt6873 路径) -> 跳过 (幂等)
                if re.search(r'#\s*include\s+["<][^">]*mt6873', txt):
                    continue
                rel = os.path.relpath(eq, dp).replace("\\", "/")
                # 唯一 guard: 由文件相对路径 md5 派生, 保证与任何(含目标 mt6873 头)的
                # 手写 guard 都不冲突, 从而避免 mt6873 真内容被 guard 短路跳过.
                uid = hashlib.md5(os.path.relpath(p, ROOT).encode("utf-8")).hexdigest()[:16].upper()
                guard = "_PLATFWD_%s_" % uid
                fwd = ("#ifndef %s\n#define %s\n"
                       "#include \"%s\"\n"
                       "#endif /* %s */\n") % (guard, guard, rel, guard)
                if DRY:
                    print("[dry] would forward %s -> %s" % (os.path.relpath(p, ROOT), rel))
                    total += 1
                    continue
                bak = p + ".orig"
                if not os.path.exists(bak):
                    open(bak, "w", encoding="utf-8").write(txt)
                open(p, "w", encoding="utf-8").write(fwd)
                total += 1
                print("forward %s -> %s" % (os.path.relpath(p, ROOT), rel))
    print("TOTAL forwarded: %d  (skipped: no-mt6873-equiv=%d, non-.h=%d)"
          % (total, skipped_no_equiv, skipped_nonth))

if __name__ == "__main__":
    main()
