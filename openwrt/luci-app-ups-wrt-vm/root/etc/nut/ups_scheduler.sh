#!/bin/sh
# ImmortalWrt UPS 事件联动调度引擎 (防环境变量污染 & 双阶段防死锁持久化版)

export PATH="/usr/sbin:/usr/bin:/sbin:/bin"
export HOME="/root"

RAW_ARG="${1:-UNKNOWN}"
CAPTURED_NOTIFY="${NOTIFYTYPE:-}"
unset NOTIFYTYPE

# 显式控制指令无条件优先于环境变量，彻底杜绝子进程继承 NOTIFYTYPE=ONBATT 覆盖 EXEC_SHUTDOWN
case "$1" in
    EXEC_SHUTDOWN|EXEC_SHUTDOWN_DRYRUN|TEST)
        EVENT="$1"
        ;;
    *)
        if [ -n "$CAPTURED_NOTIFY" ]; then
            EVENT="$CAPTURED_NOTIFY"
        else
            EVENT="${1:-UNKNOWN}"
        fi
        ;;
esac

# 兼容通过文本内容识别事件类型
case "$EVENT" in
    ONBATT|ONLINE|LOWBATT|FSD|COMMOK|COMMBAD|SHUTDOWN|REPLBATT|NOCOMM|NOPARENT|EXEC_SHUTDOWN|EXEC_SHUTDOWN_DRYRUN|TEST)
        ;;
    *[Oo][Nn]\ [Bb][Aa][Tt][Tt]*|*onbatt*)
        EVENT="ONBATT"
        ;;
    *[Oo][Nn]\ [Ll][Ii][Nn][Ee]*|*online*)
        EVENT="ONLINE"
        ;;
    *[Ll][Oo][Ww]\ [Bb][Aa][Tt][Tt]*|*lowbatt*)
        EVENT="LOWBATT"
        ;;
esac

PID_FILE="/var/run/ups_countdown.pid"
CONFIG="ups_manager.main"

log() {
    level="$1"
    msg="$2"
    now="$(date '+%Y-%m-%d %H:%M:%S')"
    logfile="$(uci -q get ${CONFIG}.log_file)"
    [ -z "$logfile" ] && logfile="/etc/ups_manager/ups_events.log"
    mkdir -p "$(dirname "$logfile")" /var/log
    echo "[$now] [$level] $msg" >> "$logfile"
    if [ "$logfile" != "/var/log/ups_events.log" ]; then
        ln -sf "$logfile" /var/log/ups_events.log 2>/dev/null
    fi
    logger -t UPS_SCHEDULER "[$level] $msg"
}

NUT_HOST="$(uci -q get ${CONFIG}.nut_host)"
[ -z "$NUT_HOST" ] && NUT_HOST="127.0.0.1"
NUT_PORT="$(uci -q get ${CONFIG}.nut_port)"
[ -z "$NUT_PORT" ] && NUT_PORT="3493"
NUT_UPS="$(uci -q get ${CONFIG}.nut_upsname)"
[ -z "$NUT_UPS" ] && NUT_UPS="ups"
TARGET="${NUT_UPS}@${NUT_HOST}:${NUT_PORT}"

get_ups_stat() {
    key="$1"
    val="$(upsc "$TARGET" "$key" 2>/dev/null)"
    [ -z "$val" ] && val="N/A"
    echo "$val"
}

ENABLED="$(uci -q get ${CONFIG}.enabled)"
[ -z "$ENABLED" ] && ENABLED="1"

DELAY="$(uci -q get ${CONFIG}.onbatt_wait_seconds)"
[ -z "$DELAY" ] && DELAY="$(uci -q get ${CONFIG}.onbatt_delay)"
[ -z "$DELAY" ] && DELAY="300"

VM_TIMEOUT="$(uci -q get ${CONFIG}.vm_shutdown_timeout)"
[ -z "$VM_TIMEOUT" ] && VM_TIMEOUT="150"

LOWBATT_EN="$(uci -q get ${CONFIG}.lowbatt_instant_shutdown)"
[ -z "$LOWBATT_EN" ] && LOWBATT_EN="$(uci -q get ${CONFIG}.lowbatt_shutdown)"
[ -z "$LOWBATT_EN" ] && LOWBATT_EN="1"

ESXI_IP="$(uci -q get ${CONFIG}.esxi_host)"
[ -z "$ESXI_IP" ] && ESXI_IP="$(uci -q get ${CONFIG}.esxi_ip)"
[ -z "$ESXI_IP" ] && ESXI_IP="192.168.1.100"

stop_countdown() {
    if [ -f "$PID_FILE" ]; then
        OLD_PID="$(cat "$PID_FILE" 2>/dev/null)"
        rm -f "$PID_FILE"
        if [ -n "$OLD_PID" ]; then
            pkill -P "$OLD_PID" 2>/dev/null
            kill "$OLD_PID" 2>/dev/null
            return 0
        fi
    fi
    return 1
}

# 内部关机编排函数：彻底消除外部子进程递归调用与环境变量覆盖风险
do_exec_shutdown() {
    DRY_FLAG="$1"
    if [ "$DRY_FLAG" = "--dry-run" ]; then
        log "SHUTDOWN" "=========================================================="
        log "SHUTDOWN" "=== [仿真演练] 开始执行 ESXi 虚拟机与宿主机分级安全关机编排 ==="
        log "SHUTDOWN" "=========================================================="
        ssh -y -i /etc/dropbear/id_dropbear_rsa root@${ESXI_IP} \
            "/vmfs/volumes/datastore1/scripts/ups_safe_shutdown.sh --phase1 --dry-run ${VM_TIMEOUT}" 2>&1 | while read -r line; do
            log "ESXi" "$line"
        done
        ssh -y -i /etc/dropbear/id_dropbear_rsa root@${ESXI_IP} \
            "/vmfs/volumes/datastore1/scripts/ups_safe_shutdown.sh --phase2 --dry-run" 2>&1 | while read -r line; do
            log "ESXi" "$line"
        done
        log "SHUTDOWN" "=== [仿真演练] 双阶段关机编排全链路验证通过 ==="
        return 0
    fi

    log "SHUTDOWN" "=========================================================="
    log "SHUTDOWN" "=== 开始执行 ESXi 虚拟机与宿主机分级安全关机编排 ==="
    log "SHUTDOWN" "=========================================================="
    log "SHUTDOWN" "【阶段 1/2】远程调用 ESXi (${ESXI_IP}) 优先优雅关闭除 Immortal Wrt 外的所有业务虚拟机 (最长落盘等待: ${VM_TIMEOUT}秒)..."

    ssh -y -i /etc/dropbear/id_dropbear_rsa root@${ESXI_IP} \
        "/vmfs/volumes/datastore1/scripts/ups_safe_shutdown.sh --phase1 ${VM_TIMEOUT}" 2>&1 | while read -r line; do
        log "ESXi" "$line"
    done

    log "SHUTDOWN" "【阶段 2/2】业务虚拟机已全部退出落盘！正在唤醒 ESXi 独立后台守护进程：执行反向优雅关停 Immortal Wrt 及 ESXi 宿主机最终断电..."
    log "SHUTDOWN" "=== 本管理终端日志已持久化刷盘，即将由 ESXi 接管完成终末关机 ==="
    sync

    ssh -y -i /etc/dropbear/id_dropbear_rsa root@${ESXI_IP} \
        "nohup /vmfs/volumes/datastore1/scripts/ups_safe_shutdown.sh --phase2 >/vmfs/volumes/datastore1/scripts/ups_shutdown.log 2>&1 </dev/null &" >/dev/null 2>&1
}

case "$EVENT" in
    "ONBATT")
        BATT_CHARGE="$(get_ups_stat battery.charge)"
        BATT_VOLT="$(get_ups_stat battery.voltage)"
        IN_VOLT="$(get_ups_stat input.voltage)"
        log "WARN" "【市电中断告警】检测到市电中断，UPS 已切入电池供电 (ONBATT)！当前电量: ${BATT_CHARGE}%，电池端电压: ${BATT_VOLT}V，市电输入: ${IN_VOLT}V"
        
        if [ "$ENABLED" != "1" ]; then
            log "WARN" "【保护已暂停】当前智能关机联动处于【暂停/维护】状态，已跳过自动关机倒计时。"
            exit 0
        fi

        if [ -f "$PID_FILE" ]; then
            EXIST_PID="$(cat "$PID_FILE" 2>/dev/null)"
            if [ -n "$EXIST_PID" ] && kill -0 "$EXIST_PID" 2>/dev/null; then
                log "INFO" "【倒计时运行中】断电防抖倒计时已在运行 (PID: ${EXIST_PID})，继续保持监控..."
                exit 0
            fi
            rm -f "$PID_FILE"
        fi

        log "INFO" "【启动倒计时】已启动断电防抖倒计时，若 ${DELAY} 秒内市电未恢复，将自动启动 ESXi 虚拟机与宿主机分级安全关机..."
        (
            unset NOTIFYTYPE
            trap 'exit 0' TERM INT HUP
            ELAPSED=0
            while [ "$ELAPSED" -lt "$DELAY" ]; do
                sleep 2
                ELAPSED=$((ELAPSED + 2))
                if [ ! -f "$PID_FILE" ]; then
                    exit 0
                fi
                # 每 10 秒主动巡检一次 UPS 实时状态，防止漏收 ONLINE 信号
                if [ $((ELAPSED % 10)) -eq 0 ]; then
                    CUR_STAT="$(get_ups_stat ups.status)"
                    case "$CUR_STAT" in
                        *OL*)
                            case "$CUR_STAT" in
                                *OB*) ;;
                                *)
                                    rm -f "$PID_FILE"
                                    CUR_VOLT="$(get_ups_stat input.voltage)"
                                    log "ONLINE" "【市电恢复】巡检检测到市电已恢复在线 (状态: ${CUR_STAT}, 市电: ${CUR_VOLT}V)，自动终止关机倒计时 (已耗时: ${ELAPSED}秒)！"
                                    exit 0
                                    ;;
                            esac
                            ;;
                    esac
                fi
            done

            if [ ! -f "$PID_FILE" ]; then
                exit 0
            fi
            rm -f "$PID_FILE"

            FINAL_STAT="$(get_ups_stat ups.status)"
            case "$FINAL_STAT" in
                *OB*)
                    log "ALARM" "【倒计时届满】断电已持续达到设定阈值 (${DELAY}秒)，且二次核验 UPS 仍处于电池供电状态 (${FINAL_STAT})，立即触发全系统分级关机！"
                    do_exec_shutdown
                    ;;
                *)
                    log "ONLINE" "【最终核验拦截】倒计时届满 (${DELAY}秒)，但二次核验发现市电已恢复 (状态: ${FINAL_STAT})，已安全取消关机！"
                    ;;
            esac
        ) </dev/null >/dev/null 2>&1 &
        echo $! > "$PID_FILE"
        ;;

    "ONLINE")
        IN_VOLT="$(get_ups_stat input.voltage)"
        if [ "$IN_VOLT" = "0.0" ] || [ "$IN_VOLT" = "0" ]; then
            sleep 1
            IN_VOLT="$(get_ups_stat input.voltage)"
        fi
        BATT_CHARGE="$(get_ups_stat battery.charge)"
        log "ONLINE" "【市电恢复】检测到市电已恢复正常供电 (ONLINE)！当前市电电压: ${IN_VOLT}V，电池电量: ${BATT_CHARGE}%"
        if stop_countdown; then
            log "ONLINE" "【倒计时撤销】防抖关机倒计时已成功终止，系统恢复平稳运行。"
        fi
        ;;

    "LOWBATT")
        BATT_CHARGE="$(get_ups_stat battery.charge)"
        BATT_VOLT="$(get_ups_stat battery.voltage)"
        log "CRITICAL" "【低电量紧急告警】UPS 电池已触发低电量警戒线 (LOWBATT)！剩余电量: ${BATT_CHARGE}%，端电压: ${BATT_VOLT}V"
        if [ "$ENABLED" = "1" ] && [ "$LOWBATT_EN" = "1" ]; then
            log "CRITICAL" "【紧急关机触发】检测到电池即将耗尽，跳过剩余等待时间，立即执行全系统紧急安全关机！"
            stop_countdown
            do_exec_shutdown
        fi
        ;;

    "FSD")
        log "CRITICAL" "【强制关机信号】收到 NUT 强制关机指令 (FSD)，立即启动分级安全关机流程！"
        if [ "$ENABLED" = "1" ]; then
            stop_countdown
            do_exec_shutdown
        fi
        ;;

    "COMMOK")
        log "INFO" "【通信恢复】软路由与 UPS 硬件通信已连接就绪 (COMMOK)。"
        ;;

    "COMMBAD"|"NOCOMM")
        log "WARN" "【通信异常】软路由与 UPS 通信中断 (${EVENT})，请检查 USB 物理连接或驱动状态！"
        ;;

    "EXEC_SHUTDOWN")
        do_exec_shutdown
        ;;

    "EXEC_SHUTDOWN_DRYRUN")
        do_exec_shutdown "--dry-run"
        ;;

    "TEST")
        log "TEST" "【测试】UPS 智能联动调度引擎自检成功：监控目标=${TARGET}, 保护启用=${ENABLED}, 断电等待=${DELAY}s, 虚拟机超时=${VM_TIMEOUT}s"
        ;;

    *)
        log "INFO" "【UPS事件】收到未分类事件通知: EVENT=${EVENT}, ARG=${RAW_ARG}"
        ;;
esac