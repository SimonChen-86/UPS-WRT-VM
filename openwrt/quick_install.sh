#!/bin/sh
# ==============================================================================
# UPS-WRT-VM - OpenWrt / ImmortalWrt 软路由端一键极速安装脚本
# 支持零编译直装，自动校验依赖、分发核心组件与打通服务
# ==============================================================================

set -e

echo "=========================================================="
echo "    UPS-WRT-VM - 软路由一键安装与服务自愈向导"
echo "=========================================================="

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="${SCRIPT_DIR}/luci-app-ups-wrt-vm"

# 1. 智能硬件直通检测与友好提醒
echo "正在检测 USB UPS 物理硬件直通状态..."
if ls /dev/usb/hiddev* 1>/dev/null 2>&1 || dmesg | grep -qi "American Power Conversion\|HID.*UPS\|Power-Device"; then
    echo "✔ 成功检测到 USB HID UPS 供电设备在线！"
else
    echo "----------------------------------------------------------"
    echo "⚠️  [温馨提示] 当前软路由未检测到 USB UPS 设备节点 (/dev/usb/hiddev*)"
    echo "    若您使用的是 VMware ESXi 宿主机，请确保已完成以下两步："
    echo "    1. 在 ESXi 软路由虚拟机设置中【添加 USB 设备】并直通 UPS；"
    echo "    2. 在虚拟机【高级设置】➔【配置参数】中添加: usb.generic.allowHID = TRUE"
    echo "    (安装过程将继续进行，硬件直通后插上即可热识别)"
    echo "----------------------------------------------------------"
fi

# 2. 自动检测并补齐底层依赖 (NUT 服务端、驱动与监控客户端，原生兼容 Dropbear)
echo "正在检查底层软件包依赖..."
NEED_UPDATE=0
for pkg in nut-server nut-driver-usbhid-ups nut-monitor; do
    if ! opkg list-installed | grep -q "^${pkg} -"; then
        echo " -> 缺失软件包: ${pkg}，准备自动安装..."
        if [ "$NEED_UPDATE" -eq 0 ]; then
            echo "正在更新软件包索引 (opkg update)..."
            opkg update >/dev/null 2>&1 || true
            NEED_UPDATE=1
        fi
        opkg install "$pkg" || echo "⚠️ 警告: ${pkg} 安装返回非0，请稍后检查网络或源状态。"
    else
        echo "✔ 依赖组件已就绪: ${pkg}"
    fi
done

# 3. 分发核心源码与配置文件
echo "正在分发 LuCI Web 控制台与后台调度核心组件..."
mkdir -p /usr/lib/lua/luci/controller
mkdir -p /usr/lib/lua/luci/model/cbi
mkdir -p /etc/config
mkdir -p /etc/nut
mkdir -p /etc/ups_manager

# 兼容从源码目录或安装目录拉取
if [ -d "${APP_SRC}/luasrc" ]; then
    cp -f "${APP_SRC}/luasrc/controller/ups_wrt_vm.lua" /usr/lib/lua/luci/controller/ups_wrt_vm.lua
    cp -f "${APP_SRC}/luasrc/model/cbi/ups_wrt_vm.lua" /usr/lib/lua/luci/model/cbi/ups_wrt_vm.lua
    cp -f "${APP_SRC}/root/etc/nut/ups_scheduler.sh" /etc/nut/ups_scheduler.sh
    if [ ! -f /etc/config/ups_manager ]; then
        cp -f "${APP_SRC}/root/etc/config/ups_manager" /etc/config/ups_manager
    fi
elif [ -f "${SCRIPT_DIR}/ups_wrt_vm.lua" ]; then
    cp -f "${SCRIPT_DIR}/ups_wrt_vm.lua" /usr/lib/lua/luci/controller/ups_wrt_vm.lua
fi

chmod +x /etc/nut/ups_scheduler.sh 2>/dev/null || true
echo "✔ 控制器、SVG 动态仪表盘与事件调度守护脚本安装完成！"

# 4. SSH RSA 密钥自愈与一键配对指令生成 (基于原生 Dropbear)
echo "正在检查 SSH RSA 免密密钥对..."
mkdir -p /etc/dropbear
KEY_PATH="/etc/dropbear/id_dropbear_rsa"
PUB_KEY=""

if [ ! -f "$KEY_PATH" ]; then
    echo " -> 正在生成软路由 Dropbear RSA 密钥对..."
    dropbearkey -t rsa -f "$KEY_PATH" >/dev/null 2>&1
fi

PUB_KEY="$(dropbearkey -y -f "$KEY_PATH" 2>/dev/null | grep "^ssh-rsa")"

# 5. 清理 LuCI 缓存并平滑重启服务
echo "正在清除 LuCI 视图缓存并刷新服务..."
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true

echo "=========================================================="
echo "🎉 软路由端安装与初始化已圆满完成！"
echo ""
echo "👉 下一步操作向导："
echo "1. 浏览器打开软路由后台：【服务】➔【UPS-WRT-VM 智能联动】；"
echo "2. 若尚未配置 ESXi 免密，请在 ESXi 终端粘贴执行以下一行指令即可："
if [ -n "$PUB_KEY" ]; then
    echo ""
    echo "   sh /vmfs/volumes/datastore1/scripts/quick_install.sh \"${PUB_KEY}\""
    echo ""
fi
echo "=========================================================="
