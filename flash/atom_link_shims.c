/*
 * atom_link_shims.c -- 链接期桩模块 (link-time stubs, weak)
 *
 * 本内核按"缩减内核"策略禁用了若干 vendor 独占子系统:
 *   ION / MTK_CHARGER / MTK_SWPM / 以及 ppm_v3 平台功耗模块
 * (ppm_v3 在公开源码树缺少 mtk_ppm_platform.h, 无法编译).
 * 但公开树中这些子系统的调用方 -- Mali GPU、apusys、USB-PD(tcpc_mt6360)、
 * boost_manager、thermal/PPM 消费者 -- 仍被编入 vmlinux, 并在链接期引用
 * 上述子系统的符号, 导致 undefined reference.
 *
 * 此处提供安全的 no-op 桩实现使链接通过. 所有符号标记为 weak:
 *   - 若真实子系统被编入(符号已存在), 强定义胜出, 本弱定义被忽略, 不冲突;
 *   - 若子系统被禁用(符号缺失), 本弱定义补上, 链接通过.
 * 指针型 API 返回 ERR_PTR(-ENODEV), 标量型返回 0/-ENODEV; 调用方以
 * IS_ERR()/NULL 检查优雅降级(功能关闭但不崩溃). DISP 显示路径独立于
 * Mali/ION, 设备仍可从 DISP 出 logo 并启动.
 *
 * 仅当对应子系统被禁用时才需要本文件; 若将来重新启用相关子系统, 可整文件移除.
 */

#include <linux/err.h>
#include <linux/types.h>
#include <linux/device.h>

/* 不完整类型声明, 避免引入缺失的 vendor 头文件 */
struct ion_device;
struct ion_client;
struct ion_handle;
struct dma_buf;
struct charger_device;
struct charger_operations;
struct charger_properties;
struct mt_ppm_table_info;
struct mt_ppm_client_req;

/* ---------------- ION 桩 (weak) ---------------- */
void *g_ion_device __attribute__((weak)) = NULL;

__attribute__((weak))
struct ion_handle *ion_alloc(struct ion_client *client, size_t len,
        size_t align, unsigned int heap_id_mask, unsigned int flags)
{
    return ERR_PTR(-ENODEV);
}
__attribute__((weak))
void ion_free(struct ion_client *client, struct ion_handle *handle) { }
__attribute__((weak))
struct ion_client *ion_client_create(struct ion_device *dev, const char *name)
{
    return ERR_PTR(-ENODEV);
}
__attribute__((weak))
void ion_client_destroy(struct ion_client *client) { }
__attribute__((weak))
void *ion_map_kernel(struct ion_client *client, struct ion_handle *handle)
{
    return ERR_PTR(-ENODEV);
}
__attribute__((weak))
void ion_unmap_kernel(struct ion_client *client, struct ion_handle *handle) { }
__attribute__((weak))
long ion_kernel_ioctl(struct ion_client *client, unsigned int cmd, unsigned long arg)
{
    return -ENODEV;
}
__attribute__((weak))
struct ion_handle *ion_import_dma_buf(struct ion_client *client, struct dma_buf *dmabuf)
{
    return ERR_PTR(-ENODEV);
}
__attribute__((weak))
struct ion_handle *ion_import_dma_buf_fd(struct ion_client *client, int fd)
{
    return ERR_PTR(-ENODEV);
}
__attribute__((weak))
struct ion_handle *ion_drv_get_handle(struct ion_client *client,
        struct ion_handle *handle, void **kernel_handle, size_t *len)
{
    return ERR_PTR(-ENODEV);
}
__attribute__((weak))
int ion_get_trust_mem_type(unsigned int mmu_flag)
{
    return 0;
}

/* ---------------- Charger 桩 (weak) ---------------- */
__attribute__((weak))
struct charger_device *charger_device_register(const char *name,
        struct device *dev, void *drvdata,
        const struct charger_operations *ops,
        const struct charger_properties *props)
{
    return ERR_PTR(-ENODEV);
}
__attribute__((weak))
void charger_device_unregister(struct charger_device *dev) { }
__attribute__((weak))
void charger_dev_notify(struct charger_device *dev, int event) { }

__attribute__((weak))
struct charger_device *get_charger_by_name(const char *name)
{
    return ERR_PTR(-ENODEV);
}

/* ---------------- SWPM 桩 (weak) ---------------- */
__attribute__((weak))
phys_addr_t swpm_mem_addr_request(void)
{
    return 0;
}

/* ---------------- PPM 桩 (ppm_v3 平台模块公开树缺失) (weak) ---------------- */
__attribute__((weak))
struct mt_ppm_client_req *mt_ppm_register_client(int client)
{
    return ERR_PTR(-ENODEV);
}
__attribute__((weak))
int mt_ppm_set_dvfs_table(struct mt_ppm_table_info *info)
{
    return -ENODEV;
}
__attribute__((weak))
unsigned int mt_ppm_get_leakage_mw(int domain)
{
    return 0;
}
