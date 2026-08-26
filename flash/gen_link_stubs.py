#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_link_stubs.py -- 从链接日志自动生成 weak 链接期桩, 实现"同一次 CI 内自愈重链".

背景与动机
----------
本内核按"缩减内核"策略禁用了若干 vendor 独占子系统 (ION / MTK_CHARGER /
AUDIODSP / SWPM / ppm_v3 等), 但公开树里这些子系统的【调用方】仍被编入 vmlinux,
于是链接期出现大量 `undefined symbol`.

手写桩 (flash/atom_link_shims.c) 覆盖了已知符号, 但 lld 每轮只会报出当前可见的
一批; 过去的做法是"链接 -> 看错误 -> 手动补桩 -> 再推一次 CI", 每轮 ~20 分钟,
即典型的打地鼠. 本脚本把这个循环搬进【同一次构建】: 首次链接失败后解析日志,
为所有残余未定义符号生成 weak 桩, 注册进 Makefile, 立即重链.

关键设计
--------
1) weak: 若真实子系统其实被编入(强定义存在), 强定义胜出, 桩被忽略 -> 不会
   multiple definition; 仅当符号真缺失时桩才生效.
2) 数据 vs 函数必须区分. 例如 ppm_main_info 是 `extern struct ppm_data ppm_main_info;`
   -- 若错误地桩成函数, 调用方会把函数【代码字节】当结构体字段读, 属静默数据损坏.
   本脚本用 git grep 在内核树头文件里查声明形态来判定:
     - 命中 `extern ... NAME ;` / `extern ... NAME[...] ;`  -> 数据
     - 命中 `NAME (`                                        -> 函数
   两者都没命中时按函数处理(绝大多数未定义符号是函数), 但会打印告警.
3) 函数桩统一 `long NAME(void) { return 0; }`. AArch64 下返回值走 x0、被调者不负责
   清理参数, 因此桩不必匹配真实参数表; 返回 0 同时覆盖 int 0 / false / NULL 三种
   语义, 让调用方的 `if (ret)` `if (!ptr)` 检查走安全分支.
   (注意: 需要 ERR_PTR 或非 0 语义的符号应写进手写桩 atom_link_shims.c, 精确控制.)
4) 数据桩给零填充数组 -> 落在 .bss, 不增加镜像体积; 字段读到 0 通常等价"功能关闭".
5) 幂等与防死循环: Makefile 注册用 marker 去重; 多次调用把符号集【累计】合并后重写
   生成文件; 若本轮没有任何新符号可补(说明补桩没能推进), 返回非 0 让 CI 循环立刻
   终止, 避免无意义地反复重链.
   注: 手写桩里已有的符号若【仍被报未定义】, 说明手写桩那份没能解析它(签名或
   编入问题), 此时仍会补一份自动桩兜底, 并打印 NOTE 提示.

用法
----
    python3 gen_link_stubs.py <build_log> <kernel_root>

退出码: 0 = 已生成/更新桩(可重链); 1 = 日志里没有未定义符号(无事可做或另有错误).
"""

import os
import re
import subprocess
import sys

# 生成文件落点: 与手写桩同目录, 复用同一个 Makefile 注册点
GEN_REL = os.path.join("drivers", "misc", "mediatek", "atom_link_stubs_auto.c")
MK_REL = os.path.join("drivers", "misc", "mediatek", "Makefile")
HAND_SHIM_REL = os.path.join("drivers", "misc", "mediatek", "atom_link_shims.c")
MK_MARKER = "# atom-build: auto link stubs"
OBJ_LINE = "obj-y += atom_link_stubs_auto.o"

UNDEF_RE = re.compile(r"undefined symbol:\s*([A-Za-z_][A-Za-z0-9_]*)")
# 生成文件里已有的符号(便于累计合并)
GEN_SYM_RE = re.compile(r"^/\* @sym (?P<kind>data|func) (?P<name>[A-Za-z_][A-Za-z0-9_]*) \*/$", re.M)


def parse_undefined(log_path):
    """从链接日志提取全部未定义符号(去重, 保持稳定顺序)."""
    syms = []
    seen = set()
    with open(log_path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = UNDEF_RE.search(line)
            if m:
                name = m.group(1)
                if name not in seen:
                    seen.add(name)
                    syms.append(name)
    return syms


def hand_shim_symbols(root):
    """读手写桩已覆盖的符号, 避免重复定义(虽然 weak 重复合法, 但保持生成物干净)."""
    p = os.path.join(root, HAND_SHIM_REL)
    if not os.path.isfile(p):
        return set()
    txt = open(p, encoding="utf-8", errors="replace").read()
    out = set()
    # 函数定义: `type NAME(` ; 数据定义: `type NAME[` 或 `type NAME =`
    for m in re.finditer(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*(\(|\[|__attribute__|=)", txt):
        out.add(m.group(1))
    return out


def git_grep(root, pattern):
    """在内核树头文件里搜声明. 内核是 git clone, git grep 比 os.walk 快一个数量级."""
    try:
        r = subprocess.run(
            ["git", "grep", "-h", "-E", pattern, "--", "*.h"],
            cwd=root, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=90,
        )
        return r.stdout.decode("utf-8", "replace")
    except Exception:
        return ""


def classify(root, name):
    """判定符号是数据还是函数. 返回 'data' / 'func'."""
    # 1) 明确的数据声明: extern <type> NAME;  /  extern <type> NAME[..];
    data_pat = r"^\s*extern\s+[^;()]*\b%s\s*(\[[^]]*\])?\s*;" % re.escape(name)
    if git_grep(root, data_pat).strip():
        return "data"
    # 2) 函数形态: NAME(
    func_pat = r"\b%s\s*\(" % re.escape(name)
    if git_grep(root, func_pat).strip():
        return "func"
    print("[gen_stub] WARN: %s 未在头文件中找到声明, 按函数处理" % name)
    return "func"


def load_existing(root):
    """读回上一次生成的符号集(kind, name), 支持多轮累计."""
    p = os.path.join(root, GEN_REL)
    if not os.path.isfile(p):
        return {}
    txt = open(p, encoding="utf-8", errors="replace").read()
    return {m.group("name"): m.group("kind") for m in GEN_SYM_RE.finditer(txt)}


HEADER = """/*
 * atom_link_stubs_auto.c -- 【自动生成, 请勿手工编辑】
 *
 * 由 flash/gen_link_stubs.py 依据 ld.lld 链接日志中的 undefined symbol 自动生成.
 * 全部符号为 weak: 真实子系统若被编入则强定义胜出, 桩自动让位, 不会重复定义.
 *
 * 函数桩返回 0 (覆盖 int 0 / false / NULL 三种语义), 数据桩为零填充对象(落 .bss).
 * 若某符号需要更精确的语义(例如必须返回 ERR_PTR, 或结构体需要真实尺寸),
 * 请把它写进手写桩 flash/atom_link_shims.c -- 那里的定义会被本文件自动跳过.
 */

#include <linux/types.h>

"""


def emit(root, symbols):
    """写出生成文件. symbols: dict name -> kind"""
    parts = [HEADER]
    for name in sorted(symbols):
        kind = symbols[name]
        # @sym 标记行用于下次运行时回读累计
        parts.append("/* @sym %s %s */\n" % (kind, name))
        if kind == "data":
            # 4KB 零填充 + 64 字节对齐: 足够覆盖常见 vendor 配置结构体
            parts.append("extern unsigned char %s[];\n" % name)
            parts.append("__attribute__((weak))\n"
                         "unsigned char %s[4096] __attribute__((aligned(64)));\n\n" % name)
        else:
            parts.append("long %s(void);\n" % name)
            parts.append("__attribute__((weak))\n"
                         "long %s(void) { return 0; }\n\n" % name)
    out = os.path.join(root, GEN_REL)
    with open(out, "w", encoding="utf-8") as f:
        f.write("".join(parts))
    print("[gen_stub] wrote %s (%d symbols)" % (GEN_REL, len(symbols)))


def register_makefile(root):
    mk = os.path.join(root, MK_REL)
    if not os.path.isfile(mk):
        print("[gen_stub] ERROR: %s not found" % mk)
        return False
    txt = open(mk, encoding="utf-8", errors="replace").read()
    if MK_MARKER in txt:
        print("[gen_stub] Makefile already registers auto stubs, skip")
        return True
    with open(mk, "a", encoding="utf-8") as f:
        f.write("\n%s\n%s\n" % (MK_MARKER, OBJ_LINE))
    print("[gen_stub] registered '%s' in %s" % (OBJ_LINE, MK_REL))
    return True


def main():
    if len(sys.argv) < 3:
        print("usage: gen_link_stubs.py <build_log> <kernel_root>")
        return 2
    log, root = sys.argv[1], sys.argv[2]
    if not os.path.isfile(log):
        print("[gen_stub] ERROR: log %s not found" % log)
        return 2

    undef = parse_undefined(log)
    if not undef:
        print("[gen_stub] 日志中没有 undefined symbol -- 失败原因不是链接缺符号")
        return 1

    print("[gen_stub] 日志中未定义符号 %d 个: %s" % (len(undef), ", ".join(undef)))

    covered = hand_shim_symbols(root)
    symbols = load_existing(root)  # 累计上一轮
    added = 0
    for name in undef:
        if name in symbols:
            continue
        if name in covered:
            # 手写桩已定义却仍报未定义 -> 说明手写桩没被编进来, 属另一类问题
            print("[gen_stub] NOTE: %s 已在手写桩中定义但仍未解析, 一并补自动桩" % name)
        symbols[name] = classify(root, name)
        added += 1

    if added == 0:
        print("[gen_stub] 没有新符号可补 (上一轮已全部覆盖) -- 停止重试避免死循环")
        return 1

    emit(root, symbols)
    if not register_makefile(root):
        return 2
    print("[gen_stub] 新增 %d 个桩, 可以重新链接" % added)
    return 0


if __name__ == "__main__":
    sys.exit(main())
