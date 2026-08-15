#!/usr/bin/env python3
"""
修复 SukiSU-Ultra main 分支在 arm64 上 syscall_fn_t 未定义的问题。

SukiSU main 的 kernel/hook/syscall_hook.h 头部:
    #include <asm/syscall.h>
    #if defined(__x86_64__)
    typedef sys_call_ptr_t syscall_fn_t;
    #endif
只在 x86_64 下定义 syscall_fn_t, 且依赖 sys_call_ptr_t。

但在 arm64 + Linux 4.14 上:
  * <asm/syscall.h> 不提供 sys_call_ptr_t (该类型在 5.x 的 <linux/syscalls.h>)。
  * KernelSU/SukiSU 的 syscall 调用约定是 `ksu_syscall_table[nr](regs)`
    (单参数 `struct pt_regs*`, 见 syscall_hook.h 注释与 ksu_syscall_hook_fn),
    所以 syscall_fn_t 必须是 `long (*)(const struct pt_regs *)` —— 与 x86 一致。
  * 不能用 arm64 原生的 6 参数签名, 否则调用点报 'too few arguments'
    (这正是 run#16 暴露的 7 处 too few arguments 错误)。

修复策略 (最小化、保留 x86 行为完全不变):
  * x86_64: 维持原样 `typedef sys_call_ptr_t syscall_fn_t;`
  * aarch64: `typedef long (*syscall_fn_t)(const struct pt_regs *);` (加 struct pt_regs 前向声明)

用法: python3 fix_sukisu_syscall_fn_t.py <kernel_tree_root>
(集成 SukiSU 之后、make 之前运行)
"""
import os
import sys


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    candidates = [
        os.path.join(root, "drivers/kernelsu/hook/syscall_hook.h"),
        os.path.join(root, "kernel/drivers/kernelsu/hook/syscall_hook.h"),
    ]
    path = next((c for c in candidates if os.path.exists(c)), None)
    if not path:
        print("[fix_sukisu_syscall_fn_t] syscall_hook.h not found, skip")
        return

    with open(path, "r", encoding="utf-8", errors="replace") as f:
        content = f.read()

    old_a = "#if defined(__x86_64__)\ntypedef sys_call_ptr_t syscall_fn_t;\n#endif"
    old_b = "#if defined(__x86_64__) || defined(__aarch64__)\ntypedef sys_call_ptr_t syscall_fn_t;\n#endif"
    # run#14 遗留: 曾误写成 6 参数原生 ABI (导致 run#16 的 too few arguments)
    old_c = ("#if defined(__x86_64__)\n"
              "typedef sys_call_ptr_t syscall_fn_t;\n"
              "#elif defined(__aarch64__)\n"
              "typedef long (*syscall_fn_t)(long, long, long, long, long, long);\n"
              "#endif")

    new = (
        "#if defined(__x86_64__)\n"
        "typedef sys_call_ptr_t syscall_fn_t;\n"
        "#elif defined(__aarch64__)\n"
        "struct pt_regs;\n"
        "typedef long (*syscall_fn_t)(const struct pt_regs *);\n"
        "#endif"
    )

    if old_c in content:
        content = content.replace(old_c, new, 1)
        print(f"[fix_sukisu_syscall_fn_t] patched {path}: arm64 -> 单参数 pt_regs (修正 run#14 的 6参数误判)")
    elif old_a in content:
        content = content.replace(old_a, new, 1)
        print(f"[fix_sukisu_syscall_fn_t] patched {path}: x86 保留, 新增 arm64 单参数 pt_regs")
    elif old_b in content:
        content = content.replace(old_b, new, 1)
        print(f"[fix_sukisu_syscall_fn_t] patched {path}: 将 ||-guard 改为 arm64 单参数 pt_regs")
    else:
        print(f"[fix_sukisu_syscall_fn_t] 三种已知形态都不匹配, 打印 syscall_fn_t 上下文:")
        for i, line in enumerate(content.splitlines(), 1):
            if "syscall_fn_t" in line or "__x86_64__" in line or "__aarch64__" in line or "sys_call_ptr_t" in line:
                print(f"  {i}: {line}")
        return

    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


if __name__ == "__main__":
    main()
