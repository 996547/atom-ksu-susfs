#!/usr/bin/env python3
"""批量修复 Clang 严格性 include 错误。

MTK 4.14 内核树在子目录里大量用尖括号引用相对路径头文件, 例如:
  #include <idles/mt6873_mcusys.h>
  #include <../../gpio/gpiolib.h>
GCC 经 -I. 容忍, Clang 报
  'xxx.h' file not found with <angled> include; use "quotes" instead
本脚本处理两类:
  1) 相对路径尖括号包含 (含 '/'): 以被包含文件目录为基准解析, 若存在则改引号;
  2) 裸尖括号包含本地头 (如 <ion.h>): 在被包含文件所在目录的祖先链及其直接子目录
     中查找同名本地头, 若找到(且非系统头 include/ 或 arch/*/include)则改引号并在
     本目录建符号链接指向真实头, 使引号包含可相对解析。
规则:
  - 绝对路径 (<linux/...>、<asm/...> 等系统头) 不动;
  - 系统头 (linux/asm/uapi 等) 在树内无对应相对文件, 自然不会被转换;
  - 裸尖括号仅当在"本地树"(被包含文件邻近目录)找到同名头时才转换, 避免误伤系统头.
"""
import os, re, sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
INC_RE = re.compile(r'#\s*include\s*<([^>]+)>')
SYSTEM_RE = re.compile(r'(^|/)include/')
total = 0


def find_local(dirpath, name):
    """在 dirpath 的祖先链及其直接子目录中查找 name, 返回真实路径(最近优先)或 None。"""
    d = os.path.abspath(dirpath)
    chain = [d]
    parent = os.path.dirname(d)
    while parent and parent != os.path.dirname(parent):
        chain.append(parent)
        parent = os.path.dirname(parent)
    # 祖先自身
    for anc in chain:
        cand = os.path.join(anc, name)
        if os.path.isfile(cand):
            return cand
    # 祖先的直接子目录
    for anc in chain:
        try:
            for entry in os.listdir(anc):
                sub = os.path.join(anc, entry)
                if os.path.isdir(sub):
                    cand = os.path.join(sub, name)
                    if os.path.isfile(cand):
                        return cand
        except OSError:
            continue
    return None


def is_system_header(real):
    """跳过标准系统头(内核主 include/ 或 arch/*/include), 避免误转真正的系统头。

    判定依据: 路径含 /include/linux/、/include/uapi/、/include/asm 或
    /arch/<plat>/include/ —— 这些是内核标准系统头位置; 而 MTK 本地头通常位于
    drivers/... 下(如 drivers/staging/android/ion/ion.h), 不会被误判。
    """
    r = real.replace("\\", "/")
    if "/include/linux/" in r:
        return True
    if "/include/uapi/" in r:
        return True
    if "/include/asm" in r:
        return True
    if re.search(r"/arch/[^/]+/include/", r):
        return True
    return False


# 预构建规范头集合: 树内任一 include/ 目录下的 .h (经 -I 可解析, 不应被本地符号链接遮蔽).
# 裸尖括号包含若命中此处, 说明它是"规范头", 应留给 -I 解析, 不要建本地阴影符号链接.
CANON = set()
for _dp, _dn, _fns in os.walk(ROOT):
    if os.path.basename(_dp) == "include":
        for _f in _fns:
            if _f.endswith(".h"):
                CANON.add(_f)


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
            if "/" in name:
                # 相对路径尖括号: 以被包含文件目录为基准解析
                cand = os.path.normpath(os.path.join(dirpath, name))
                if os.path.isfile(cand):
                    return '#include "%s"' % name
                return m.group(0)
            # 裸尖括号本地头: 一律保留原尖括号包含, 交给编译器经 -I 解析, 绝不建本地符号链接。
            # 历史教训(atom/mt6873): 在此 find_local 就近匹配会选到错误平台(mt6853)同名头,
            # 例如 smi/smi_port.h->mt6853/smi_port.h、base/power/qos/mtk_qos_sram.h->mt6853/...,
            # 把 mt6853 头遮蔽进编译路径, 与 mt6873 平台头(mt6873-larb-port.h、mtk_gpufreq 等)
            # 触发 -Werror 重定义, 卡死 mmdvfs/mdp 等子系统。
            # MTK 各子系统 Makefile 已配好 ccflags -I.../$(MTK_PLATFORM)/, 尖括号本就应由 -I 正确解析。
            return m.group(0)

        new = INC_RE.sub(repl, text)
        if new != text:
            open(fp, "w", encoding="utf-8").write(new)
            total += 1
            print("fixed", os.path.relpath(fp, ROOT))
print("TOTAL fixed:", total)
