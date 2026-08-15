#!/usr/bin/env python3
"""批量修复 Clang 严格性 include 错误。

MTK 4.14 内核树在子目录里大量用尖括号引用相对路径头文件, 例如:
  #include <idles/mt6873_mcusys.h>
  #include <../../gpio/gpiolib.h>
GCC 经 -I. 容忍, Clang 报
  'xxx.h' file not found with <angled> include; use "quotes" instead

本脚本把"目标文件真实存在于被包含文件所在目录的相对位置"的尖括号包含
统一改成引号包含。规则:
  - 绝对路径 (<linux/...>、<asm/...> 等系统头) 不动;
  - 相对路径: 以被包含文件目录为基准解析, 若真实存在则改引号;
  - 系统头 (linux/asm/uapi 等) 在树内无对应相对文件, 自然不会被转换。
"""
import os, re, sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
INC_RE = re.compile(r'#\s*include\s*<([^>]+)>')
total = 0
for dirpath, dirs, files in os.walk(ROOT):
    if ".git" in dirs:
        dirs.remove(".git")
    if not any(f.endswith((".c", ".h")) for f in files):
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
            if name.startswith("/"):
                return m.group(0)  # 绝对路径, 不动
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
