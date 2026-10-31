#!/bin/sh
# ESXi 宿主机 UPS 分级安全优雅关机脚本 (防SIGHUP断连自杀 & 双阶段持久化版)
# 支持参数: --dry-run | --phase1 | --phase2 | <timeout_seconds>

# 关键防灾保护：忽略 SIGHUP 与 SIGPIPE 信号，防止软路由关机断网导致本脚本中途被杀
trap '' HUP PIPE

DRY_RUN=0
PHASE="ALL"
TIMEOUT=150
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PERSIST_LOG="${SCRIPT_DIR}/ups_shutdown.log"

for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=1
            ;;
        --phase1)
            PHASE="PHASE1"
            ;;
        --phase2)
            PHASE="PHASE2"
            ;;
        [0-9]*)
            TIMEOUT="$arg"
            ;;
    esac
done

log() {
    local msg="$1"
    local line="$(date '+%Y-%m-%d %H:%M:%S') [UPS_SHUTDOWN] $msg"
    echo "$line" 2>/dev/null
    echo "$line" >> "$PERSIST_LOG" 2>/dev/null
    logger -t UPS_SHUTDOWN "$msg" 2>/dev/null
}

IMMORTAL_VMID=""
BIZ_VM_LIST=""

scan_vms() {
    IMMORTAL_VMID=""
    BIZ_VM_LIST=""
    for vmid in $(vim-cmd vmsvc/getallvms 2>/dev/null | awk 'NR>1 {print $1}'); do
        vm_name=$(vim-cmd vmsvc/get.config $vmid 2>/dev/null | grep -i 'name =' | head -n 1 | awk -F'"' '{print $2}')
        state=$(vim-cmd vmsvc/power.getstate $vmid 2>/dev/null | grep -i "Powered on")

        case "$vm_name" in
            *Immortal*|*Wrt*|*OpenWrt*|*LEDE*|*openwrt*|*immortalwrt*)
                IMMORTAL_VMID="$vmid"
                if [ "$PHASE" != "PHASE2" ]; then
                    log "识别到管理终端虚拟机: [$vm_name] (Vmid: $vmid)，已加入终末关机保护队列"
                fi
                ;;
            *)
                if [ -n "$state" ]; then
                    log "识别到运行中的业务虚拟机: [$vm_name] (Vmid: $vmid)"
                    BIZ_VM_LIST="$BIZ_VM_LIST $vmid"
                else
                    if [ "$PHASE" != "PHASE2" ]; then
                        log "业务机 [$vm_name] (Vmid: $vmid) 当前处于已关机状态，无需操作"
                    fi
                fi
                ;;
        esac
    done
}

run_phase1() {
    log "=========================================================="
    log "【阶段 1】开始执行 ESXi 业务虚拟机优雅关机 (Dry-Run: $DRY_RUN, 超时限制: ${TIMEOUT}秒)"
    log "=========================================================="
    scan_vms

    if [ -n "$BIZ_VM_LIST" ]; then
        log "【步骤 1】优先向运行中的业务虚拟机发送正常关机信号 (power.shutdown)..."
        for vmid in $BIZ_VM_LIST; do
            log " -> 正在向业务机 (Vmid: $vmid) 发送 Guest OS 优雅关机请求..."
            if [ "$DRY_RUN" -eq 0 ]; then
                vim-cmd vmsvc/power.shutdown $vmid 2>/dev/null || vim-cmd vmsvc/power.off $vmid 2>/dev/null
            fi
        done

        log "进入业务机落盘等待轮询 (最长等待 ${TIMEOUT} 秒)..."
        WAIT_SEC=0
        while [ $WAIT_SEC -lt $TIMEOUT ]; do
            STILL_RUNNING=0
            if [ "$DRY_RUN" -eq 0 ]; then
                for vmid in $BIZ_VM_LIST; do
                    if vim-cmd vmsvc/power.getstate $vmid 2>/dev/null | grep -q "Powered on"; then
                        STILL_RUNNING=1
                        break
                    fi
                done
            fi

            if [ $STILL_RUNNING -eq 0 ]; then
                log "✔ 所有业务虚拟机均已安全关机落盘完成 (耗时: ${WAIT_SEC} 秒)。"
                break
            fi

            sleep 3
            WAIT_SEC=$((WAIT_SEC + 3))
        done

        # 超时强制断电兜底
        if [ "$DRY_RUN" -eq 0 ]; then
            for vmid in $BIZ_VM_LIST; do
                if vim-cmd vmsvc/power.getstate $vmid 2>/dev/null | grep -q "Powered on"; then
                    log "【超时强制下电】业务机 (Vmid: $vmid) 超过 ${TIMEOUT} 秒未关机，执行强制断电 (power.off) 保底！"
                    vim-cmd vmsvc/power.off $vmid 2>/dev/null
                fi
            done
        fi
    else
        log "✔ 当前无正在运行的业务虚拟机需要关停。"
    fi
}

run_phase2() {
    if [ "$PHASE" = "PHASE2" ] && [ "$DRY_RUN" -eq 0 ]; then
        sleep 2
    fi
    log "=========================================================="
    log "【阶段 2】ESXi 独立守护进程接管：反向关闭 Immortal Wrt 并执行宿主机自我关机 (Dry-Run: $DRY_RUN)"
    log "=========================================================="
    scan_vms

    # 二次兜底确认非 WRT 业务机已全部断电
    if [ "$DRY_RUN" -eq 0 ] && [ -n "$BIZ_VM_LIST" ]; then
        for vmid in $BIZ_VM_LIST; do
            log "二次核验发现业务机 (Vmid: $vmid) 仍在运行，立即执行强制下电 (power.off)"
            vim-cmd vmsvc/power.off $vmid 2>/dev/null
        done
    fi

    # 反向优雅关停 Immortal Wrt 管理终端
    if [ -n "$IMMORTAL_VMID" ]; then
        log "【步骤 2】业务机已全部下电，开始反向优雅关停管理终端 Immortal Wrt (Vmid: $IMMORTAL_VMID)..."
        if [ "$DRY_RUN" -eq 0 ]; then
            vim-cmd vmsvc/power.shutdown $IMMORTAL_VMID 2>/dev/null
            
            # 轮询等待最多 35 秒让软路由安全下电
            W=0
            while [ $W -lt 35 ]; do
                if ! vim-cmd vmsvc/power.getstate $IMMORTAL_VMID 2>/dev/null | grep -q "Powered on"; then
                    log "✔ Immortal Wrt 管理终端已安全关机下电 (耗时: ${W} 秒)。"
                    break
                fi
                sleep 2
                W=$((W + 2))
            done
            
            # 保底强制断电
            if vim-cmd vmsvc/power.getstate $IMMORTAL_VMID 2>/dev/null | grep -q "Powered on"; then
                log "【保底断电】Immortal Wrt 超过 35 秒未完全退出，执行 power.off 强制下电。"
                vim-cmd vmsvc/power.off $IMMORTAL_VMID 2>/dev/null
                sleep 2
            fi
        else
            log "[Dry-Run 仿真] 模拟反向优雅关停 Immortal Wrt (Vmid: $IMMORTAL_VMID) 完成"
        fi
    fi

    # 宿主机 ESXi 最终自我断电
    log "【步骤 3】确认所有虚拟机（含 Immortal Wrt）已全部关闭，正在执行 sync 刷盘并切断 ESXi 宿主机电源..."
    if [ "$DRY_RUN" -eq 0 ]; then
        sync
        esxcli system shutdown poweroff -d 10 -r "UPS Power Loss Safe Shutdown" 2>/dev/null || /sbin/poweroff 2>/dev/null || /bin/poweroff 2>/dev/null
        sleep 5
        /sbin/poweroff
    else
        log "[Dry-Run 仿真] 模拟执行 ESXi 宿主机 /sbin/poweroff 自我安全关机完成"
    fi
}

case "$PHASE" in
    "PHASE1")
        run_phase1
        ;;
    "PHASE2")
        run_phase2
        ;;
    *)
        run_phase1
        run_phase2
        ;;
esac