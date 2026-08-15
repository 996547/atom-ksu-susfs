#!/usr/bin/env python3
"""AES 汇编 Clang IAS 兼容补丁 (看雪配方第4点)
将 68 位立即数加载 `ldr q8, =0x30000000200000001` 改为 adrp+ldr 间接加载。
原值 = (0x3 << 64) | 0x000200000001, 作为 128 位小端 q8 = v8.4s[1,2,3,0]。
等价于两个 64 位 .quad (.Lrfc4106)。必须在内核树根目录 (kernel/) 下运行。
"""
import os

P = 'arch/arm64/crypto/aes-modes.S'
assert os.path.exists(P), f"未在内核树找到 {P}, 请在 kernel/ 目录下运行"

s = open(P).read()
out = []
patched = False
for ln in s.split('\n'):
    if '0x30000000200000001' in ln and 'ldr' in ln:
        out.append('\tadrp\tx9, .Lrfc4106')
        out.append('\tldr\tq8, [x9, :lo12:.Lrfc4106]')
        patched = True
    else:
        out.append(ln)

if not patched:
    print("WARN: 未找到 ldr q8, =0x30000000200000001 模式, 可能已修复或源码不同")
else:
    s = '\n'.join(out)
    s += ('\n\n\t.pushsection .rodata, "a"\n'
          '.Lrfc4106:\n'
          '\t.quad\t0x000200000001\n'
          '\t.quad\t0x3\n'
          '\t.popsection\n')
    open(P, 'w').write(s)
    print("OK: patched aes-modes.S (AES addends 常量改用 .Lrfc4106 标签间接加载)")
