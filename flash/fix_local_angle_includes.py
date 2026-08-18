#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
将 '#include <name>' 改写为相对路径引号包含 '#include "rel/path/name"', 当且仅当
name 为单段文件名 (不含 '/') 且在树内 drivers/ (及 techpack/ vendor/) 下能找到对应
本地头文件。

背景: 上游 MTK 树中, 部分驱动用尖括号包含本地头 (同目录或兄弟/父目录),
但对应 Makefile 未把这些目录加入尖括号搜索路径 (无 -I$(src)), 且跨目录时
同目录也不行, Clang 报 'file not found with <angled> include; use quotes instead'。

改写为相对路径引号包含后, 编译器先搜包含文件所在目录的相对路径, 正确解析本地头;
契合内核规范, 且一次性覆盖同目录 + 跨目录 (如 sspm/mt6873/*.h 包含 v2/*.h) 整类问题。

安全性:
- 仅作用于单段 name (不含 '/'), 绝不碰 <linux/...>/<asm/...>/<spm/mtk_spm.h> 等路径包含。
- 候选仅限 drivers/ techpack/ vendor/ 下的 .h, 不触碰 include/ arch/ usr/ 等系统包含根,
  避免把 <xxx.h> 误改写成指向系统根的歧义文件。
- 仅当树内确实能定位到本地头时才改写; 选最近 (路径深度差最小) 的候选, 改写不改变语义。
"""
import os
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."

# 候选头文件搜索根 (本地 MTK 驱动所在, 不碰系统包含根)
CAND_ROOTS = ['drivers', 'techpack', 'vendor']

# 仅匹配单段尖括号包含: #include <name>  (name 不含 '/' )
PAT = re.compile(r'([ \t]*#\s*include\s*)<([^/>]+)>')

def build_map():
    """basename -> list of absolute paths (under CAND_ROOTS)."""
    m = {}
    for cand in CAND_ROOTS:
        base = os.path.join(ROOT, cand)
        if not os.path.isdir(base):
            continue
        for dp, _, fns in os.walk(base):
            for fn in fns:
                if fn.endswith('.h'):
                    m.setdefault(fn, []).append(os.path.join(dp, fn))
    return m

def best_candidate(cands, from_dir):
    """选路径深度差最小 (最近) 的候选, 其次路径最短。"""
    def key(p):
        d = os.path.dirname(p)
        try:
            rel = os.path.relpath(d, from_dir)
            depth = 0 if rel == '.' else len(rel.split(os.sep))
        except ValueError:
            depth = 999
        return (depth, len(p))
    return sorted(cands, key=key)[0]

def main():
    hmap = build_map()
    changed_files = 0
    rewrite_count = 0
    for dirpath, dirs, files in os.walk(ROOT):
        for fn in files:
            if not fn.endswith(('.c', '.h', '.S')):
                continue
            path = os.path.join(dirpath, fn)
            try:
                with open(path, 'r', encoding='utf-8', errors='replace') as f:
                    content = f.read()
            except OSError:
                continue
            file_rewrites = [0]
            def repl(m):
                name = m.group(2)
                if '/' in name:
                    return m.group(0)
                cands = hmap.get(name)
                if not cands:
                    return m.group(0)
                target = best_candidate(cands, dirpath)
                rel = os.path.relpath(target, dirpath).replace(os.sep, '/')
                file_rewrites[0] += 1
                return '%s"%s"' % (m.group(1), rel)
            new_content = PAT.sub(repl, content)
            if file_rewrites[0] > 0:
                try:
                    with open(path, 'w', encoding='utf-8') as f:
                        f.write(new_content)
                    changed_files += 1
                    rewrite_count += file_rewrites[0]
                    print("local-angle: %s  (%d rewrites)" % (os.path.relpath(path, ROOT), file_rewrites[0]))
                except OSError as e:
                    print("WARN write failed:", path, e)
    print("local-angle: %d files changed, %d includes rewritten" % (changed_files, rewrite_count))

if __name__ == '__main__':
    main()
