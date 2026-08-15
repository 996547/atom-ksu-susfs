#!/usr/bin/env python3
"""批量修复 Clang 严格性错误: 把 #include <foo.h> (头文件 foo.h 就在同一目录) 改成 #include "foo.h".

MTK 4.14 内核树大量用尖括号引用同目录头文件, GCC 通过 -I. 容忍, Clang 报
'file not found with <angled> include; use "quotes" instead'. 只处理纯文件名
(无 '/') 且同目录真实存在的 include, 不动 <linux/...>/<asm/...> 等系统头.
"""
import os, re, sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
INC_RE = re.compile(r'#\s*include\s*<([^>]+)>')
total = 0
for dirpath, dirs, files in os.walk(ROOT):
    if ".git" in dirs:
        dirs.remove(".git")
    h_files = {f for f in files if f.endswith(".h")}
    if not h_files:
        continue
    for fn in files:
        if not fn.endswith((".c", ".h")):
            continue
        fp = os.path.join(dirpath, fn)
        try:
            text = open(fp, encoding="utf-8", errors="replace").read()
        except Exception:
            continue
        def repl(m):
            name = m.group(1)
            if '/' not in name:
                # 纯文件名: 仅当同目录真实存在时改引号 (原逻辑)
                if name in h_files:
                    return '#include "%s"' % name
                return m.group(0)
            # 相对路径尖括号包含 (如 <../../gpio/gpiolib.h>): Clang 要求改用引号
            if name.startswith('.') or '..' in name:
                cand = os.path.normpath(os.path.join(dirpath, name))
                if os.path.isfile(cand):
                    return '#include "%s"' % name
            return m.group(0)
        new = INC_RE.sub(repl, text)
        if new != text:
            open(fp, "w", encoding="utf-8").write(new)
            total += 1
            print("fixed", os.path.relpath(fp, ROOT))
print("TOTAL fixed:", total)
