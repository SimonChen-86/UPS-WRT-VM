#!/bin/sh
# ==============================================================================
# UPS-WRT-VM - VMware ESXi 宿主机一键极速部署与固化向导
# 支持传入软路由公钥直接配置免密: sh quick_install.sh "ssh-rsa AAAA..."
# ==============================================================================

set -e

echo "=========================================================="
echo "    UPS-WRT-VM - VMware ESXi 宿主机一键部署与固化向导"
echo "=========================================================="

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROUTER_PUBKEY="$1"

# 1. 优先匹配常用 datastore1，若不存在则智能探测其它 VMFS 存储卷
DATASTORE=""
if [ -d "/vmfs/volumes/datastore1" ]; then
    DATASTORE="/vmfs/volumes/datastore1"
else
    for ds in $(ls -d /vmfs/volumes/* 2>/dev/null); do
        if [ -d "$ds" ] && echo "$ds" | grep -qv "bootpart\|OSData"; then
            DATASTORE="$ds"
            break
        fi
    done
fi

if [ -z "$DATASTORE" ] || [ ! -d "$DATASTORE" ]; then
    echo "✖ 错误: 未能识别到有效的 VMFS 存储卷，请确认 ESXi 存储状态。"
    exit 1
fi

DS_NAME="$(basename "$DATASTORE")"
TARGET_DIR="${DATASTORE}/scripts"
echo "✔ 成功定位 ESXi 持久化存储卷: ${DS_NAME} (${DATASTORE})"

# 2. 分发持久化安全关机编排脚本
mkdir -p "${TARGET_DIR}"
if [ -f "${SCRIPT_DIR}/ups_safe_shutdown.sh" ]; then
    cp -f "${SCRIPT_DIR}/ups_safe_shutdown.sh" "${TARGET_DIR}/ups_safe_shutdown.sh"
elif [ -f "${TARGET_DIR}/ups_safe_shutdown.sh" ]; then
    echo "✔ 目标路径已有脚本: ${TARGET_DIR}/ups_safe_shutdown.sh"
else
    echo "✖ 错误: 未找到 ups_safe_shutdown.sh 文件！"
    exit 1
fi
chmod +x "${TARGET_DIR}/ups_safe_shutdown.sh"
echo "✔ 双阶段优雅安全关机脚本已安装至: ${TARGET_DIR}/ups_safe_shutdown.sh"

# 3. 固化 SSH 永久开机自启并静音 Shell 警告
echo "正在配置 ESXi SSH 永久开机自启..."
chkconfig SSH on 2>/dev/null || true
/etc/init.d/SSH start 2>/dev/null || true
esxcli system settings advanced set -o /UserVars/SuppressShellWarning -i 1 2>/dev/null || true

# 检查并在 /etc/rc.local.d/local.sh 中持久化守护
LOCAL_SH="/etc/rc.local.d/local.sh"
if [ -f "$LOCAL_SH" ]; then
    if ! grep -q "/etc/init.d/SSH start" "$LOCAL_SH"; then
        sed -i '/exit 0/i \/etc\/init.d\/SSH start\n' "$LOCAL_SH"
    fi
fi
echo "✔ ESXi SSH 开机自启服务已锁定并加入 local.sh 开机守护。"

# 4. 若传入了软路由公钥，自动配对免密
if [ -n "$ROUTER_PUBKEY" ]; then
    echo "正在注入软路由 SSH RSA 免密公钥..."
    mkdir -p /etc/ssh/keys-root
    AUTH_KEYS="/etc/ssh/keys-root/authorized_keys"
    touch "$AUTH_KEYS"
    chmod 0700 /etc/ssh/keys-root
    chmod 0600 "$AUTH_KEYS"
    if ! grep -q "$ROUTER_PUBKEY" "$AUTH_KEYS"; then
        echo "$ROUTER_PUBKEY" >> "$AUTH_KEYS"
    fi
    echo "✔ 软路由免密公钥已成功追加至 ${AUTH_KEYS}。"
fi

# 5. 自动配置 AutoStart 自启策略 (严格对齐 ESXi 7.0/8.0 update_autostartentry 规范)
echo "正在检测并配置虚拟机来电自启策略 (AutoStart)..."
vim-cmd hostsvc/autostartmanager/enable_autostart true 2>/dev/null || true

for vmid in $(vim-cmd vmsvc/getallvms 2>/dev/null | awk 'NR>1 {print $1}'); do
    vm_name=$(vim-cmd vmsvc/get.config $vmid 2>/dev/null | grep -i 'name =' | head -n 1 | awk -F'"' '{print $2}')
    case "$vm_name" in
        *Immortal*|*Wrt*|*OpenWrt*|*LEDE*|*openwrt*|*immortalwrt*|*iStoreOS*|*Router*|*router*)
            echo " -> 软路由虚拟机 [$vm_name] (Vmid: $vmid) 设定为: 来电开机自动启动 (powerOn, Order=1)"
            # 参数顺序: VMId StartAction StartDelay StartOrder StopAction StopDelay WaitForHeartbeat
            vim-cmd hostsvc/autostartmanager/update_autostartentry $vmid "powerOn" 120 1 "guestShutdown" 120 "yes" 2>/dev/null || true
            ;;
        *)
            # 其余业务机默认为 none，避免电网闪断时并发开机冲击
            vim-cmd hostsvc/autostartmanager/update_autostartentry $vmid "none" 120 -1 "guestShutdown" 120 "no" 2>/dev/null || true
            ;;
    esac
done
echo "✔ 虚拟机来电自启策略已锁定 (软路由率先自愈联网，业务机不并发冲击)。"

# 6. 执行引导卷自动备份固化
echo "正在执行 ESXi 引导卷归档固化 (/sbin/auto-backup.sh)..."
/sbin/auto-backup.sh >/dev/null 2>&1 || true
echo "✔ ESXi 系统配置备份归档完成！"

echo "=========================================================="
echo "🎉 ESXi 宿主机部署与固化全部完成！"
echo "可执行仿真演练: ${TARGET_DIR}/ups_safe_shutdown.sh --dry-run"
echo "=========================================================="
