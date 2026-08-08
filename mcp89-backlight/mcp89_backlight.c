// SPDX-License-Identifier: GPL-2.0
/*
 * Panel backlight for a GeForce 320M (MCP89 / NVAF) driven by nvidia-340.
 *
 * nvidia-340 registers no backlight of its own -- its X driver only ever *reads* one
 * (nvidia_drv.so carries "Unable to find the brightness file path under" and
 * "EnableACPIBrightnessHotkeys", and no EnableBrightnessControl at all). nouveau does
 * register nv_backlight, but installing nvidia-340 takes the GPU away from it. apple_bl
 * matches the APP0002 ACPI device on this machine, but its nvidia path drives legacy I/O
 * port 0x52f and apple_bl_add() ends with a live-hardware check that returns -ENODEV,
 * silently, when that port does not answer -- "this may not work under EFI" is its own
 * comment, and this machine boots via EFI. So the panel ends up with no backlight device
 * at all and the F1/F2 keys have nothing to act on.
 *
 * This drives the PWM directly. The registers were not taken from nouveau's headers --
 * nouveau's Tesla constant is 0x61c880 with the divisor at +0x84, and both read 0 here.
 * They were identified by running under nouveau, changing nv_backlight, and diffing the
 * BAR (see nv-backlight.py --diff):
 *
 *   0x61c080   period   (2966 under nouveau, 24557 under nvidia-340 -- read, never written)
 *   0x61c084   bit 31   write-only latch: a write without it stores the word but never
 *                       reaches the PWM, which is why reads agreed with nv_backlight
 *                       while writes did nothing
 *              bit 30   maintained by the hardware, reads back set on its own
 *              bits 0.. duty
 *
 * Brightness is a percentage of whatever period the register currently holds, so the
 * same code works under either driver despite the two different periods.
 */

#include <linux/backlight.h>
#include <linux/fb.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/pci.h>

#define NVAF_CHIPSET	0xaf		/* MCP89, the 320M */
#define PMC_BOOT_0	0x000000
#define BL_PAGE		0x61c000
#define BL_PERIOD	0x080		/* within BL_PAGE */
#define BL_DUTY		0x084
#define BL_ENABLE	0x80000000u	/* latch */
#define BL_LEVEL_MASK	0x00ffffffu
#define BL_MAX		100

static bool force;
module_param(force, bool, 0444);
MODULE_PARM_DESC(force, "load even if the chipset is not MCP89/NVAF");

static struct pci_dev *gpu;
static void __iomem *regs;
static struct backlight_device *bl;

static u32 bl_period(void)
{
	return ioread32(regs + BL_PERIOD) & BL_LEVEL_MASK;
}

static int mcp89_get_brightness(struct backlight_device *bd)
{
	u32 period = bl_period();
	u32 duty;

	if (!period)
		return 0;
	duty = ioread32(regs + BL_DUTY) & BL_LEVEL_MASK;
	if (duty > period)
		duty = period;
	return DIV_ROUND_CLOSEST(duty * BL_MAX, period);
}

static int mcp89_update_status(struct backlight_device *bd)
{
	u32 period = bl_period();
	int level = bd->props.brightness;
	u32 duty;

	if (!period)
		return -ENODEV;

	if (bd->props.power != FB_BLANK_UNBLANK ||
	    bd->props.state & (BL_CORE_SUSPENDED | BL_CORE_FBBLANK))
		level = 0;

	if (level < 0)
		level = 0;
	else if (level > BL_MAX)
		level = BL_MAX;

	duty = DIV_ROUND_CLOSEST((u32)level * period, BL_MAX);
	iowrite32(BL_ENABLE | (duty & BL_LEVEL_MASK), regs + BL_DUTY);
	return 0;
}

static const struct backlight_ops mcp89_bl_ops = {
	.options	= BL_CORE_SUSPENDRESUME,
	.get_brightness	= mcp89_get_brightness,
	.update_status	= mcp89_update_status,
};

static struct pci_dev *find_gpu(void)
{
	struct pci_dev *pdev = NULL;

	/* pci_get_class drops the reference on the device passed in, so the loop
	 * leaks nothing and the survivor is the one reference held. */
	while ((pdev = pci_get_class(PCI_CLASS_DISPLAY_VGA << 8, pdev)))
		if (pdev->vendor == PCI_VENDOR_ID_NVIDIA)
			return pdev;
	return NULL;
}

static int check_chipset(void)
{
	void __iomem *pmc;
	u32 boot0, chipset;

	pmc = pci_iomap_range(gpu, 0, 0, 0x1000);
	if (!pmc)
		return -ENOMEM;
	boot0 = ioread32(pmc + PMC_BOOT_0);
	pci_iounmap(gpu, pmc);

	if (!boot0) {
		pr_err("mcp89_backlight: PMC_BOOT_0 reads 0, BAR0 is not live\n");
		return -ENODEV;
	}
	chipset = (boot0 & 0x1ff00000) >> 20;
	if (chipset != NVAF_CHIPSET && !force) {
		pr_info("mcp89_backlight: chipset 0x%02x is not NVAF; pass force=1 to override\n",
			chipset);
		return -ENODEV;
	}
	pr_info("mcp89_backlight: PMC_BOOT_0 0x%08x, chipset 0x%02x\n", boot0, chipset);
	return 0;
}

static int __init mcp89_bl_init(void)
{
	struct backlight_properties props;
	u32 period;
	int ret;

	gpu = find_gpu();
	if (!gpu) {
		pr_info("mcp89_backlight: no NVIDIA VGA device\n");
		return -ENODEV;
	}

	/* Under nouveau the panel already has nv_backlight, and a second device for the
	 * same panel only confuses the desktop about which one to drive. */
	if (gpu->driver && !strcmp(gpu->driver->name, "nouveau")) {
		pr_info("mcp89_backlight: nouveau owns the GPU and provides nv_backlight\n");
		ret = -ENODEV;
		goto err_put;
	}

	ret = check_chipset();
	if (ret)
		goto err_put;

	regs = pci_iomap_range(gpu, 0, BL_PAGE, 0x1000);
	if (!regs) {
		ret = -ENOMEM;
		goto err_put;
	}

	/* The period is programmed by whatever brought the panel up; this driver only
	 * ever reads it. Zero means there is no PWM running to ride on. */
	period = bl_period();
	if (!period) {
		pr_err("mcp89_backlight: period at 0x%06x is 0, nothing to drive\n",
		       BL_PAGE + BL_PERIOD);
		ret = -ENODEV;
		goto err_unmap;
	}
	pr_info("mcp89_backlight: period %u, current brightness %d%%\n",
		period, mcp89_get_brightness(NULL));

	memset(&props, 0, sizeof(props));
	props.type = BACKLIGHT_RAW;
	props.max_brightness = BL_MAX;
	props.brightness = mcp89_get_brightness(NULL);
	props.power = FB_BLANK_UNBLANK;

	bl = backlight_device_register("mcp89_backlight", &gpu->dev, NULL,
				       &mcp89_bl_ops, &props);
	if (IS_ERR(bl)) {
		ret = PTR_ERR(bl);
		goto err_unmap;
	}
	return 0;

err_unmap:
	pci_iounmap(gpu, regs);
	regs = NULL;
err_put:
	pci_dev_put(gpu);
	gpu = NULL;
	return ret;
}

static void __exit mcp89_bl_exit(void)
{
	if (bl)
		backlight_device_unregister(bl);
	if (regs)
		pci_iounmap(gpu, regs);
	if (gpu)
		pci_dev_put(gpu);
}

module_init(mcp89_bl_init);
module_exit(mcp89_bl_exit);

MODULE_DESCRIPTION("Panel backlight for GeForce 320M (MCP89) under nvidia-340");
MODULE_LICENSE("GPL");
MODULE_VERSION("1.0");
