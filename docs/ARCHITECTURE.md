# UPS-WRT-VM 核心架构设计与双阶段防死锁技术白皮书

---

## 一、 系统架构总览

在单台 x86 物理服务器（如 Dell Precision / 联想工作站 / 自组 NAS）部署虚拟化环境（VMware ESXi）并运行软路由（OpenWrt/ImmortalWrt）的“All-in-One”场景下，外接 UPS 电源的断电保护向来是业界的经典架构难题。

本项目摒弃了传统方案在 ESXi 内部运行笨重群晖虚拟机接管 UPS 的弊端，构建了一套轻量化、高可用、全链路防死锁的现代供电保护架构：

```mermaid
flowchart TD
    UPS["APC / 通用 USB-HID UPS"] -->|"物理 USB 数据线"| ESXi["ESXi 物理服务器 (硬件宿主)"]
    ESXi -->|"USB 设备直通 (VirtualUSB + allowHID)"| WRT["ImmortalWrt / OpenWrt 虚拟机 (常驻常开)"]
    WRT -->|"usbhid-ups 驱动 + nut-server 守护进程"| ENGINE["本地 UPS 调度引擎 (upsmon + ups_scheduler.sh)"]
    ENGINE -->|"数据接口与表格式管理"| WEB["LuCI 现代控制中心 (luci-app-ups-wrt-vm)"]
    ENGINE -->|"SSH 双阶段远程调度"| SCRIPT["ESXi 持久化关机脚本 (ups_safe_shutdown.sh)"]
    SCRIPT -->|"阶段 1 (--phase1 150s 轮询)"| VM["业务虚拟机 (Windows Server / 数据库等)"]
    SCRIPT -->|"阶段 2 (--phase2 脱离终端)"| WRT
    SCRIPT -->|"阶段 2 终局: /sbin/poweroff"| ESXi
```

---

## 二、 传统方案的致命缺陷：为什么会导致“宿主机悬死死锁”？

在常规的双机网络关机方案中，软路由往往在检测到断电超时后，先向宿主机发送关机指令，或者软路由与宿主机同时关机。这会引发一个灾难性的 **SIGHUP 断连自杀死锁**：

```mermaid
sequenceDiagram
    autonumber
    participant WRT as "软路由 (发出关机指令)"
    participant SSH as "SSH 远程会话通道"
    participant ESXi as "ESXi 关机执行进程"

    WRT->>SSH: 发送关机指令: sh shutdown.sh
    SSH->>ESXi: ESXi 开始遍历关闭虚拟机...
    Note over ESXi: 正在优雅关闭软路由虚拟机 (OpenWrt)
    Note over WRT: 软路由系统关机下电！
    Note over SSH: 💥 软路由下电导致 SSH 网络连接瞬间斩断！
    SSH-->>ESXi: SSHD 向子进程发送 SIGHUP 信号并抛出 SIGPIPE
    Note over ESXi: 💥 关机脚本被系统强制终止！根本没走到 /sbin/poweroff！
    Note over ESXi: 终局死锁: 软路由关了，宿主机依然长亮，电量耗尽直接物理断电损坏硬盘！
```

---

## 三、 本项目破局方案：双阶段防死锁关机编排引擎

为了从根本上彻底杜绝此死锁，本项目将安全关机严格解耦为**两个确定性阶段**：

```mermaid
sequenceDiagram
    autonumber
    participant UPS as "APC UPS"
    participant WRT as "软路由 (ups_scheduler.sh)"
    participant ESXi as "ESXi 宿主机 (ups_safe_shutdown.sh)"
    participant VM as "业务虚拟机 (Windows/Linux)"

    Note over UPS,WRT: 停电切入电池 (ONBATT)
    WRT->>WRT: 启动防抖倒计时 (如 180 秒)
    Note over WRT: 倒计时届满，二次核验仍为电池供电 (OB DISCHRG)

    rect rgb(240, 248, 255)
    Note over WRT,ESXi: 【阶段一：前台同步落盘确认】
    WRT->>ESXi: 同步 SSH 调用: ups_safe_shutdown.sh --phase1 150
    ESXi->>VM: 发送 power.shutdown 优雅关机信号
    loop 轮询状态 (最长 150 秒)
        ESXi->>VM: 检测 power.getstate 直至 Powered off
    end
    ESXi-->>WRT: 回执: 所有业务虚拟机均已安全关机落盘
    end

    rect rgb(255, 245, 245)
    Note over WRT,ESXi: 【阶段二：后台异步脱离终端】
    WRT->>WRT: 持久化写入终末日志，执行 sync 刷盘
    WRT->>ESXi: nohup ups_safe_shutdown.sh --phase2 >/dev/null 2>&1 </dev/null &
    Note over WRT,ESXi: 脚本内部开启 trap '' HUP PIPE，彻底免疫断网影响
    ESXi->>WRT: 反向优雅关闭软路由虚拟机
    Note over WRT: 软路由正常关机，SSH 会话断开
    ESXi->>ESXi: ESXi 后台进程持续运行: sync 并在 5 秒后执行 /sbin/poweroff
    Note over ESXi: 宿主机安全断电停机！
    end
```

### 核心防死锁设计要素
1. **信号双重免疫 (`trap '' HUP PIPE`)**：
   在 ESXi 端脚本的头部显式声明忽略挂起信号 `SIGHUP` 与管道破裂信号 `SIGPIPE`，无论前台 SSH 如何断开，后台进程受内核绝对保护；
2. **脱离终端守护 (`nohup ... </dev/null &`)**：
   阶段二以完全脱离标准输入输出的文件描述符后台启动，由 ESXi 本地调度系统托管运行；
3. **反向优雅关闭软路由**：
   业务机完全停稳前，软路由作为监控哨兵绝对不关；业务机全部落盘后，才由 ESXi 宿主机从虚拟化层下发关闭软路由，时序井然有序。

---

## 四、 来电开机自愈防冲击机制 (AutoStart Order)

市电恢复供电时，电网往往伴随短时间的电压波动或多次反复通断电。若所有虚拟机与大容量机械硬盘阵列并发开机，会产生巨大的浪涌电流，甚至因电网再次闪断对磁头造成二次致命敲击。

本项目实施了精密的**单兵自愈机制**：
- **仅拉起软路由**：
  在 ESXi AutoStart 序列中，**唯独将软路由虚拟机标记为 `powerOn`**，其余所有虚拟机默认全部配置为 `none`；
- **自愈收益**：
  1. 物理机来电后，快速且唯一启动低功耗的软路由，率先恢复全屋/全实验室网络与 DNS 解析；
  2. 机械硬盘与业务大负载在电网未完全平稳前保持休眠，避开电网闪断风险；
  3. 用户确认市电彻底稳定后，可通过软路由后台或 ESXi 控制台手动或按需唤醒核心业务机。

