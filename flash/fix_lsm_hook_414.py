#!/usr/bin/env python3
"""
SukiSU-Ultra lsm_hook.c 在 Linux 4.14 上的适配.

4.14 的 struct security_hook_list / security_hook_heads 用 list_head (有 .next/.prev),
而 5.x 用 hlist (有 .first/.pprev). SukiSU 的 <6.12 分支按 hlist 写, 在 4.14 全不成立.
但 4.14 的 security_hook_heads 成员同样是 list_head, 故把 hlist 用法机械改写为
list_head 用法即可编译通过 (标准 4.14 移植):

  struct hlist_head           -> struct list_head
  hlist_for_each_entry(...)   -> list_for_each_entry(...)
  hlist_entry(...)            -> list_entry(...)
  if (head->first)            -> if (!list_empty(head))   (空表判断, list_head 下必须改)
  hook->list.list.pprev       -> hook->list.list.prev

list_empty / list_entry / list_for_each_entry 均由 <linux/list.h> (经 lsm_hooks.h) 提供.

【关键陷阱】hlist 版的 pprev 是二级指针 (struct hlist_node **), 所以
    hook->list.list.pprev = &head->first;    (hlist 版, & 是对的)
但 list_head 版的 prev 是一级指针 (struct list_head *), 不能用 &:
    hook->list.list.prev = head;             (list_head 版, 去掉 &, head->first 直接取 head)
因此 pprev 赋值行必须作为整行精确替换, 且必须放在 "head->first -> head->next" 规则之前,
否则 "&head->first" 会被先改成 "&head->next" (保留了错误的 &) 而报错:
    incompatible pointer types assigning to 'struct list_head *' from 'struct list_head **'; remove &

其余出现 "head->first" 的地方 (hlist_entry 参数 / selected_slot = &head->first) 仍按
head->first -> head->next 处理 (那些场景下 next 是一级指针, & 取地址是二级指针, 类型正确).

幂等, 可重复运行.
"""
import os
import sys

TARGET_REL = "drivers/kernelsu/hook/lsm_hook.c"

# 替换规则 (顺序重要: pprev 整行精确替换必须最先, 否则 & 被规则6保留而报错)
RULES = [
    # 1) pprev 赋值行: list_head 版 prev 是一级指针, 去 &, head->first 直接取 head
    ("hook->list.list.pprev = &head->first", "hook->list.list.prev = head"),
    # 2) 空表判断特例
    ("if (head->first)", "if (!list_empty(head))"),
    # 3) 类型名
    ("struct hlist_head", "struct list_head"),
    # 4) 遍历宏
    ("hlist_for_each_entry", "list_for_each_entry"),
    # 5) 取容器宏
    ("hlist_entry(", "list_entry("),
    # 6) 兜底: 任何残留的 pprev -> prev
    ("hook->list.list.pprev", "hook->list.list.prev"),
    # 7) 其余 head->first -> head->next (hlist_entry 参数 / selected_slot 的 &head->first 等)
    ("head->first", "head->next"),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    path = os.path.join(root, TARGET_REL)
    if not os.path.isfile(path):
        print("[fix_lsm_hook_414] skip (not found):", path)
        return
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        text = f.read()

    orig = text
    for old, new in RULES:
        text = text.replace(old, new)

    if text == orig:
        print("[fix_lsm_hook_414] no change (already adapted or hlist absent)")
        return

    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    print("[fix_lsm_hook_414] lsm_hook.c hlist->list_head 适配完成 (4.14)")


if __name__ == "__main__":
    main()
