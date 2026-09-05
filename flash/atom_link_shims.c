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

/*
 * 注: 返回 NULL 而非 ERR_PTR -- MTK 调用方普遍写 `if (!chg_dev)`,
 * ERR_PTR 是非 NULL 会被误判为"拿到了设备", 故此处必须给 NULL.
 */
__attribute__((weak))
struct charger_device *get_charger_by_name(const char *name)
{
    return NULL;
}

/* charger_dev_* : 单个 charger 设备操作, 返回 -ENODEV 让调用方走失败分支 */
__attribute__((weak))
int charger_dev_enable_otg(struct charger_device *dev, bool en) { return -ENODEV; }
__attribute__((weak))
int charger_dev_enable_discharge(struct charger_device *dev, bool en) { return -ENODEV; }
__attribute__((weak))
int charger_dev_kick_wdt(struct charger_device *dev) { return -ENODEV; }
__attribute__((weak))
int charger_dev_set_boost_current_limit(struct charger_device *dev, u32 uA)
{
    return -ENODEV;
}
__attribute__((weak))
int charger_dev_get_ctd_dischg_status(struct charger_device *dev, u8 *status)
{
    return -ENODEV;
}

/*
 * charger_manager_* : 充电管理器(consumer)接口, 由 mtk_battery / rt_pd_manager /
 * thermal cooler 引用. 查询型返回 0(= 未挂起 / 温控档位 0 / 速率 0), 设置型返回
 * -ENODEV; 均为"功能关闭"的安全语义, 不会让调用方 panic.
 */
struct charger_consumer;

__attribute__((weak))
int charger_manager_is_input_suspend(struct charger_consumer *c) { return 0; }
__attribute__((weak))
int charger_manager_get_soc_decimal_rate(struct charger_consumer *c) { return 0; }
__attribute__((weak))
int charger_manager_get_prop_system_temp_level(struct charger_consumer *c) { return 0; }
__attribute__((weak))
int charger_manager_get_prop_system_temp_level_max(struct charger_consumer *c) { return 0; }
__attribute__((weak))
int charger_manager_set_input_suspend(struct charger_consumer *c, bool en)
{
    return -ENODEV;
}
__attribute__((weak))
int charger_manager_set_prop_system_temp_level(struct charger_consumer *c, int lvl)
{
    return -ENODEV;
}
__attribute__((weak))
int charger_manager_enable_high_voltage_charging(struct charger_consumer *c, bool en)
{
    return -ENODEV;
}
__attribute__((weak))
int charger_manager_enable_power_path(struct charger_consumer *c, int idx, bool en)
{
    return -ENODEV;
}
__attribute__((weak))
int charger_manager_set_input_current_limit(struct charger_consumer *c, int idx,
        int uA)
{
    return -ENODEV;
}

/* 小米快充扩展 (battery_bomb) */
__attribute__((weak))
int chg_get_fastcharge_mode(void) { return 0; }
__attribute__((weak))
int chg_set_fastcharge_mode(bool en) { return -ENODEV; }

/* USB gadget 通知电池 USB 状态 (mtu3_gadget_ep0.c), 真实实现返回 void */
__attribute__((weak))
void BATTERY_SetUSBState(int usb_state) { }

/* ---------------- 音频 SRAM 桩 (AUDIODSP 已禁用) (weak) ---------------- */
/* 由 xhci-mtk-uac.c (USB Audio offload) 引用 */
__attribute__((weak))
int mtk_audio_request_sram(dma_addr_t *phys, unsigned char **virt,
        unsigned int length, void *user)
{
    return -ENODEV;
}
__attribute__((weak))
int mtk_audio_free_sram(void *user) { return 0; }

/* ---------------- EARA thermal 桩 (weak) ---------------- */
__attribute__((weak))
int eara_pass_perf_first_hint(int hint) { return 0; }

/* ---------------- SWPM 桩 (weak) ---------------- */
__attribute__((weak))
phys_addr_t swpm_mem_addr_request(void)
{
    return 0;
}

/* ---------------- fpsgo / GED 函数指针桩 (weak) ---------------- */
/*
 * 【致命陷阱 - 必须按"数据"而非"函数"提供】
 * ged_kpi_output_gfx_info2_fp 是【函数指针变量】, MTK 以 _fp 后缀标注。
 * 由 drivers/misc/mediatek/performance/fpsgo_v3/fstb/fstb.c 的
 * mtk_fstb_init() 引用, 形态为 `if (fp) fp(...)` 间接调用。
 *
 * 若误桩成函数 `long NAME(void){return 0;}`:
 *   调用方 `ldr x0, [NAME]` 读到的是桩函数的【机器码字节】
 *   (mov w0,#0 / ret 的编码), 而非指针值 -> blr 跳到垃圾地址
 *   -> 静默挂死被硬件看门狗咬, 或指令中止; 且因发生在 ramoops
 *   注册(device_initcall) 之前, 完全没有日志输出 = "零 printk"。
 *
 * 必须提供【存储】且初值 NULL, 让 `if (fp)` 判定为假走安全分支。
 * 注: gen_link_stubs.py 已同步修复(识别 (*NAME)( 形态为数据), 此处
 *     再显式给出精确类型, 两处都是零初始化, 取哪一个都等价安全。
 */
__attribute__((weak))
int (*ged_kpi_output_gfx_info2_fp)(void *, unsigned int, unsigned int,
                                   unsigned int, unsigned int,
                                   unsigned int) = NULL;

/*
 * mtk_notify_gpu_power_change / ged_kpi_set_target_FPS_margin 是普通函数,
 * 返回 0 即可(GPU 已禁用, 调用方忽略返回值或走失败分支)。
 */
__attribute__((weak))
int mtk_notify_gpu_power_change(int power_on) { return 0; }

__attribute__((weak))
int ged_kpi_set_target_FPS_margin(int margin) { return 0; }

/* ---------------- PPM 桩 (ppm_v3 平台模块公开树缺失) (weak) ---------------- */
/* 真实声明 (mtk_ppm_api.h:122) 为 `void mt_ppm_register_client(enum ppm_client,
 * void (*limit)(struct ppm_client_req))` —— 返回 void, 且调用方 (mtk_cpuhp_ppm.c /
 * mtk_cpufreq_main.c) 均忽略返回值。原桩误写成返回 `struct mt_ppm_client_req *`
 * 并 return ERR_PTR, 与真实签名不符 (尽管调用方忽略返回值故功能上 benign)。此处
 * 对齐真实签名, 消费两个入参、返回 void, 消除类型错配隐患。 */
__attribute__((weak))
void mt_ppm_register_client(int client, void *cb) { }
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

/*
 * ppm_main_info 是【数据对象】而非函数:
 *   ppm_v3/inc/mtk_ppm_internal.h:275  extern struct ppm_data ppm_main_info;
 * 调用方(eara_thermal/thermal_budget.c)通过宏访问 .cluster_num / .cluster_info[],
 * 因此必须提供【存储】而不是函数(否则会把代码字节当结构体读).
 * 用足够大的零填充弱对象: cluster_num=0 使 for_each_ppm_clusters() 循环体不执行,
 * cluster_info=NULL 也就不会被解引用. 零初始化 -> 落在 .bss, 不增加内核镜像体积.
 * struct ppm_data 内含 platform_device/platform_driver/mutex/client 数组,
 * 实测量级为数 KB, 这里给 16KB 并按 64 字节对齐, 留足余量避免越界写。
 */
__attribute__((weak))
unsigned char ppm_main_info[16384] __attribute__((aligned(64)));

/*
 * 返回 NULL: 调用方 get_cobra_tbl() 明确写了 `if (!cobra_tbl) return;`,
 * 给 ERR_PTR 会被误判为有效指针并被 memcpy 解引用 -> panic.
 */
__attribute__((weak))
void *ppm_cobra_pass_tbl(void) { return NULL; }

__attribute__((weak))
int ppm_find_pwr_idx(void *cluster_status) { return 0; }

__attribute__((weak))
int ppm_main_freq_to_idx(unsigned int cluster_id, unsigned int freq, int dir)
{
    return 0;
}
