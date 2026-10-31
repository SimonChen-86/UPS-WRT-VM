# UPS-WRT-VM 硬件兼容清单与疑难排错手册

---

## 一、 已实测与推荐兼容 UPS 硬件清单

本项目底层依托标准成熟的开源工业级驱动 `usbhid-ups`，理论上支持所有符合 USB HID 供电管理规范（Power Device Class）的 UPS 硬件。

### 1. 重点推荐与实装型号
| 品牌厂商 | 型号系列 | 驱动协议 | 实测表现 |
| :--- | :--- | :---: | :--- |
| **APC (施耐德)** | **Back-UPS XS 650CI**（标杆测试机型） | `usbhid-ups` | 🟢 完美支持：电量、端电压、市电输入、负载率、放电续航全部精准遥测 |
| **APC (施耐德)** | **Back-UPS BK650M2-CH / BK650-CH** | `usbhid-ups` | 🟢 完美支持：经典 NAS 伴侣，即插即用 |
| **APC (施耐德)** | **Back-UPS BR1000G-CN / BR1500G-CN** | `usbhid-ups` | 🟢 完美支持：带液晶屏型号，全协议遥测对齐 |
| **山特 (SANTAK)** | **TG-BOX 850 / TG-BOX 600** | `usbhid-ups` | 🟢 完美支持：USB 接口版本开箱即用 |
| **雷迪司 (LADIS)** | **H1000 / H2000 互动式系列** | `usbhid-ups` | 🟢 完美支持：标准 USB HID 协议兼容 |
| **硕天 (CyberPower)** | **CP1000PFCLCD / CP1500EPFCLCD** | `usbhid-ups` | 🟢 完美支持：纯正弦波系列兼容 |

---

## 二、 高频踩坑与疑难故障排查 (Troubleshooting FAQ)

### 故障 1：ESXi 宿主机为软路由添加 USB 设备时找不到 UPS 或选项变灰
- **现象**：
  物理 USB 数据线已插好，但在 ESXi 网页后台编辑虚拟机添加【USB 设备】时，下拉列表中没有 APC UPS，或者显示为灰色不可选。
- **根因分析**：
  VMware ESXi 出于宿主机安全考虑，默认独占并隐藏了标准 HID 人机接口类设备（认为 USB 鼠标键盘不应直通给客户机）。而绝大部分 APC/山特 UPS 的 USB 芯片在握手时被识别为 HID 供电设备。
- **解决方案**：
  1. 必须在 ESXi 虚拟机中先添加 **【USB 控制器】**（建议选择 `USB 3.0 (xHCI)` 或 `USB 2.0 (EHCI+UHCI)`）；
  2. 彻底关闭软路由虚拟机电源；
  3. 点击虚拟机【编辑设置】➔【虚拟机选项】➔【高级】➔【配置参数】➔【编辑配置】；
  4. 点击【添加参数】，填入：
     - **名称**：`usb.generic.allowHID`
     - **值**：`TRUE`
  5. 保存后重新开机，再次添加【USB 设备】，即可正常勾选直通 UPS！

---

### 故障 2：软路由上 `upsc` 查询显示连接被拒绝 (Connection Refused)
- **现象**：
  Web 界面仪表盘显示无法连接，控制台执行 `upsc ups@127.0.0.1` 报错 `Connection refused`。
- **排查步骤**：
  1. 检查软路由内核是否生成了设备节点：
     ```sh
     ls -la /dev/usb/hiddev*
     ```
     若无此节点，说明 ESXi USB 直通未生效，请参考故障 1 检查。
  2. 检查 `nut-server` 是否正在运行：
     ```sh
     ps | grep upsd
     ```
     若未运行，手动拉起查看具体报错：
     ```sh
     /etc/init.d/nut-server restart
     ```
  3. 确认 `/etc/nut/ups.conf` 中的驱动配置为 `driver = usbhid-ups`。

---

### 故障 3：业务虚拟机未装 VMware Tools，分级关机会不会卡死？
- **现象**：
  宿主机上运行了某些轻量级 Linux 或精简测试机，未安装或启动 `open-vm-tools`。
- **容灾机制保障**：
  不用担心卡死！我们的 `ups_safe_shutdown.sh` 脚本内置了**多重保底机制**：
  1. 脚本在向虚拟机发送 `vim-cmd vmsvc/power.shutdown` 优雅关机请求的同时，建立了以秒为单位的递增超时轮询；
  2. 如果虚拟机未安装 Tools，`power.shutdown` 可能会被系统忽略；
  3. 此时脚本在轮询达到您在后台设定的【业务机落盘超时】（默认 150 秒）后，会自动触发保底的 **`vim-cmd vmsvc/power.off` 强制断电**！
  4. 绝不会无限死等耗尽 UPS 电池电量。

---

### 故障 4：APC Back-UPS 绿灯节能模式（Green Mode）导致宿主机异常断电
- **现象**：
  市电正常时，主机偶尔突然断电，UPS 上的绿色节能灯熄灭。
- **根因分析**：
  部分 APC Back-UPS 型号出厂默认启用了“节能插座（Green Mode）”功能。当插在主插座上的设备处于待机低功耗（小于 15W）时，UPS 会误判电脑已关闭，从而自动切断附属插座电源。
- **解决操作**：
  1. 确保物理宿主机的电源插头插入标有 **“Battery Backup（电池备份 + 防浪涌）”** 的主力插座，避免插入受控的纯节能插座；
  2. 长按机身电源键约 2~3 秒直至听到哔声，即可永久关闭机身 Green Mode 节能联动切断功能。

---

### 故障 5：SSH RSA 免密连接测试失败 (Permission Denied)
- **现象**：
  在 Web 控制台点击【⚡ 握手测试】时，提示 `ESXi 宿主机 SSH 连通异常: Permission denied`。
- **排查步骤**：
  1. 检查 ESXi 宿主机上的公钥权限：
     ```sh
     ls -la /etc/ssh/keys-root/authorized_keys
     ```
     Linux SSH 规范对密钥文件权限有极度严格的要求：
     - `/etc/ssh/keys-root` 目录权限必须为 `0700`；
     - `authorized_keys` 文件权限必须为 `0600`。
  2. 修复权限命令：
     ```sh
     chmod 0700 /etc/ssh/keys-root
     chmod 0600 /etc/ssh/keys-root/authorized_keys
     ```
  3. 确认软路由私钥 `/etc/dropbear/id_dropbear_rsa` 存在且格式正确。

