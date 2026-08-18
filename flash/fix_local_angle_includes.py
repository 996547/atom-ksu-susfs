#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
将 '#include <name>' 改写为 '#include "name"'，当且仅当 name 为单段文件名
(不含 '/') 且与包含它的源文件位于同一目录 (即该头文件物理存在于同目录)。

背景: 上游 MTK 树中, 部分驱动用尖括号包含同目录本地头
(如 helio-dvfsrc-v3/helio-dvfsrc-qos.c:33  '#include <helio-dvfsrc-qos.h>'),
但对应 Makefile 未把源目录加入尖括号搜索路径 (无 -I$(src)), Clang 报
'file not found with <angled> include; use quotes instead'。
改写为引号后, 编译器先搜当前源目录, 正确解析本地头; 契合内核规范(同目录头用引号)。

安全性:
- 仅作用于单段 name (不含 '/'), 绝不碰 <linux/...>/<asm/...>/<spm/mtk_spm.h> 等路径包含。
- 仅当该 name 在源文件同目录真实存在时才改写, 不会无中生有。
- 同目录本地头本就该用引号, 改写不改变语义, 只是让 Clang 能解析到。
"""
import os
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."

# 仅匹配单段尖括号包含: #include <name>  (name 不含 '/' )
PAT = re.compile(r'^(\s*#\s*include\s*)<([^/>]+)>(\s*)$')

changed_files = 0
for dirpath, dirs, files in os.walk(ROOT):
    for fn in files:
        if not fn.endswith(('.c', '.h')):
            continue
        path = os.path.join(dirpath, fn)
        try:
            with open(path, 'r', encoding='utf-8', errors='replace') as f:
                lines = f.readlines()
        except OSError:
            continue
        dirty = False
        for i, line in enumerate(lines):
            m = PAT.match(line)
            if m:
                name = m.group(2)
                local = os.path.join(dirpath, name)
                if os.path.isfile(local):
                    lines[i] = '%s"%s"%s' % (m.group(1), name, m.group(3))
                    dirty = True
                    print("local-angle:", os.path.relpath(path, ROOT), "->", name)
        if dirty:
            try:
                with open(path, 'w', encoding='utf-8') as f:
                    f.writelines(lines)
                changed_files += 1
            except OSError as e:
                print("WARN write failed:", path, e)

print("local-angle: %d files changed" % changed_files)
