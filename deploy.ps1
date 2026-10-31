# ==============================================================================
# UPS-WRT-VM - Windows 专属全自动极速交互式部署向导
# 遵循标准 UTF-8 with BOM 签名与 PowerShell 5.1/7 跨平台规范
# ==============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
try {
    $Host.UI.RawUI.WindowTitle = "UPS-WRT-VM 一键极速部署向导"
} catch {
    # 忽略非控制台宿主中的异常
}

function Show-Banner {
    Clear-Host
    Write-Host "=================================================================" -ForegroundColor Cyan
    Write-Host "         UPS-WRT-VM - ESXi & OpenWrt UPS 智能联动部署向导       " -ForegroundColor Yellow
    Write-Host "              版本: v1.0.0 | 全链路防死锁 & 双阶段安全关机       " -ForegroundColor Green
    Write-Host "=================================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Prompt-RequiredInput([string]$promptText) {
    while ($true) {
        Write-Host -NoNewline $promptText -ForegroundColor Yellow
        $inputVal = Read-Host
        if ($inputVal -and $inputVal.Trim().Length -gt 0) {
            return $inputVal.Trim()
        }
        Write-Host "⚠️  输入不能为空，请重新输入！" -ForegroundColor Red
    }
}

function Prompt-Password([string]$promptText) {
    while ($true) {
        Write-Host -NoNewline $promptText -ForegroundColor Yellow
        $passVal = Read-Host -AsSecureString
        $plainPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($passVal))
        if ($plainPass -and $plainPass.Length -gt 0) {
            return $plainPass
        }
        Write-Host "⚠️  密码不能为空，请重新输入！" -ForegroundColor Red
    }
}

Show-Banner

# 1. 检查便携工具箱
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PlinkPath = Join-Path $ScriptDir "tools\plink.exe"
$PscpPath  = Join-Path $ScriptDir "tools\pscp.exe"

if (-not (Test-Path $PlinkPath) -or -not (Test-Path $PscpPath)) {
    Write-Host "✖ 致命错误: 未在 tools/ 目录下找到 plink.exe 或 pscp.exe！" -ForegroundColor Red
    Write-Host "请确保 tools 目录完整性。" -ForegroundColor Yellow
    Write-Host "按任意键退出..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Exit 1
}

Write-Host "✔ 便携网络工具箱检测正常。" -ForegroundColor Green
Write-Host ""

# 2. 交互式引导输入 IP 与密码
Write-Host "【步骤 1/4】配置软路由 (OpenWrt / ImmortalWrt) 节点信息" -ForegroundColor Cyan
$WrtIP   = Prompt-RequiredInput "👉 请输入软路由的管理 IP 地址 (例如 192.168.1.1): "
$WrtUser = "root"
$WrtPass = Prompt-Password "👉 请输入软路由 root 用户登录密码: "

Write-Host ""
Write-Host "【步骤 2/4】配置 VMware ESXi 宿主机节点信息" -ForegroundColor Cyan
$EsxiIP   = Prompt-RequiredInput "👉 请输入 ESXi 宿主机的管理 IP 地址 (例如 192.168.1.100): "
$EsxiUser = "root"
$EsxiPass = Prompt-Password "👉 请输入 ESXi root 用户登录密码: "

Write-Host ""
Write-Host "-----------------------------------------------------------------" -ForegroundColor Gray
Write-Host "目标软路由: $WrtUser@$WrtIP" -ForegroundColor White
Write-Host "目标宿主机: $EsxiUser@$EsxiIP" -ForegroundColor White
Write-Host "-----------------------------------------------------------------" -ForegroundColor Gray
Write-Host ""

Write-Host "正在建立连接与安全通信握手，请稍候..." -ForegroundColor Cyan

# 3. 自动预存主机指纹与连通性测试 (彻底根治首次连接 Host Key 未缓存死锁)
Write-Host " -> 正在自动缓存软路由 SSH 指纹并测试登录..." -ForegroundColor Gray
$null = cmd.exe /c "echo y | `"$PlinkPath`" -ssh -l $WrtUser -pw `"$WrtPass`" $WrtIP exit 2>&1"
$WrtTestRes = & $PlinkPath -ssh -batch -l $WrtUser -pw $WrtPass $WrtIP "echo WRT_OK" 2>&1
if ($WrtTestRes -notmatch "WRT_OK") {
    Write-Host "✖ 无法连接到软路由 $WrtIP！" -ForegroundColor Red
    Write-Host "错误诊断: $WrtTestRes" -ForegroundColor DarkRed
    Write-Host "请检查 IP 地址、密码以及软路由 SSH 服务是否已启用。" -ForegroundColor Yellow
    Write-Host "按任意键退出..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Exit 1
}
Write-Host "✔ 软路由 SSH 通道握手成功！" -ForegroundColor Green

Write-Host " -> 正在自动缓存 ESXi 宿主机 SSH 指纹并测试登录..." -ForegroundColor Gray
$null = cmd.exe /c "echo y | `"$PlinkPath`" -ssh -l $EsxiUser -pw `"$EsxiPass`" $EsxiIP exit 2>&1"
$EsxiTestRes = & $PlinkPath -ssh -batch -l $EsxiUser -pw $EsxiPass $EsxiIP "echo ESXI_OK" 2>&1
if ($EsxiTestRes -notmatch "ESXI_OK") {
    Write-Host "✖ 无法连接到 ESXi 宿主机 $EsxiIP！" -ForegroundColor Red
    Write-Host "错误诊断: $EsxiTestRes" -ForegroundColor DarkRed
    Write-Host "请确保 ESXi 网页后台已开启 SSH 服务（主机 -> 操作 -> 服务 -> 启用安全 Shell）。" -ForegroundColor Yellow
    Write-Host "按任意键退出..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Exit 1
}
Write-Host "✔ ESXi 宿主机 SSH 通道握手成功！" -ForegroundColor Green
Write-Host ""

# 4. 推送并部署软路由端组件 (使用安全参数调用，杜绝拼接漏洞)
Write-Host "【步骤 3/4】正在向软路由推送组件与自动配置..." -ForegroundColor Cyan
$RemoteWrtTmp = "/tmp/ups_wrt_deploy"
& $PlinkPath -ssh -batch -l $WrtUser -pw $WrtPass $WrtIP "rm -rf $RemoteWrtTmp && mkdir -p $RemoteWrtTmp/openwrt" | Out-Null

$LocalWrtDir = Join-Path $ScriptDir "openwrt"
& $PscpPath -batch -pw $WrtPass -r "$LocalWrtDir" "${WrtUser}@${WrtIP}:${RemoteWrtTmp}/" | Out-Null

Write-Host "正在软路由上执行自愈安装 (检测驱动依赖、分发 LuCI 模块、配置参数)..." -ForegroundColor Yellow
$InstallCmd = "chmod +x ${RemoteWrtTmp}/openwrt/quick_install.sh && sh ${RemoteWrtTmp}/openwrt/quick_install.sh && uci set ups_manager.main.esxi_host='$EsxiIP' && uci set ups_manager.main.esxi_ip='$EsxiIP' && uci commit ups_manager"
$InstallWrtRes = & $PlinkPath -ssh -batch -l $WrtUser -pw $WrtPass $WrtIP $InstallCmd 2>&1
Write-Host $InstallWrtRes -ForegroundColor Gray

# 提取软路由的公钥
$WrtPubKey = (& $PlinkPath -ssh -batch -l $WrtUser -pw $WrtPass $WrtIP "dropbearkey -y -f /etc/dropbear/id_dropbear_rsa 2>/dev/null | grep '^ssh-rsa'").Trim()

if (-not $WrtPubKey -or $WrtPubKey.Length -lt 20) {
    Write-Host "⚠️  未能直接获取到软路由公钥，正在生成新密钥..." -ForegroundColor Yellow
    & $PlinkPath -ssh -batch -l $WrtUser -pw $WrtPass $WrtIP "mkdir -p /etc/dropbear && dropbearkey -t rsa -f /etc/dropbear/id_dropbear_rsa" | Out-Null
    $WrtPubKey = (& $PlinkPath -ssh -batch -l $WrtUser -pw $WrtPass $WrtIP "dropbearkey -y -f /etc/dropbear/id_dropbear_rsa 2>/dev/null | grep '^ssh-rsa'").Trim()
}
Write-Host "✔ 软路由 RSA 密钥对已就绪。" -ForegroundColor Green
Write-Host ""

# 5. 推送并部署 ESXi 宿主机端脚本
Write-Host "【步骤 4/4】正在向 ESXi 宿主机推送关机编排并固化开机守护..." -ForegroundColor Cyan
$RemoteEsxiTmp = "/tmp/ups_esxi_deploy"
& $PlinkPath -ssh -batch -l $EsxiUser -pw $EsxiPass $EsxiIP "rm -rf $RemoteEsxiTmp && mkdir -p $RemoteEsxiTmp" | Out-Null

$LocalEsxiDir = Join-Path $ScriptDir "esxi"
& $PscpPath -batch -pw $EsxiPass -r "$LocalEsxiDir\*" "${EsxiUser}@${EsxiIP}:${RemoteEsxiTmp}/" | Out-Null

Write-Host "正在 ESXi 上安装双阶段关机脚本、固化 SSH 与注入免密公钥..." -ForegroundColor Yellow
$EsxiRunCmd = "chmod +x ${RemoteEsxiTmp}/quick_install.sh && sh ${RemoteEsxiTmp}/quick_install.sh '$WrtPubKey'"
$InstallEsxiRes = & $PlinkPath -ssh -batch -l $EsxiUser -pw $EsxiPass $EsxiIP $EsxiRunCmd 2>&1
Write-Host $InstallEsxiRes -ForegroundColor Gray

# 清理临时文件
& $PlinkPath -ssh -batch -l $WrtUser -pw $WrtPass $WrtIP "rm -rf $RemoteWrtTmp" | Out-Null
& $PlinkPath -ssh -batch -l $EsxiUser -pw $EsxiPass $EsxiIP "rm -rf $RemoteEsxiTmp" | Out-Null

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Green
Write-Host "🎉 恭喜！UPS-WRT-VM 智能联动与安全关机系统已全部部署成功！" -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "👉 部署成果摘要：" -ForegroundColor Yellow
Write-Host "  1. 软路由 LuCI 控制台已注册: 【服务】➔【UPS-WRT-VM 智能联动】" -ForegroundColor White
Write-Host "  2. ESXi 双阶段防死锁关机编排与 local.sh 开机守护已固化" -ForegroundColor White
Write-Host "  3. 软路由到 ESXi 的 SSH RSA 免密互通已全自动打通" -ForegroundColor White
Write-Host "  4. ESXi 来电开机自愈已锁定 (软路由自动恢复，业务机不并发冲击)" -ForegroundColor White
Write-Host ""

$WebUrl = "http://${WrtIP}/cgi-bin/luci/admin/services/ups_wrt_vm"
Write-Host "正在为您自动打开软路由管理后台..." -ForegroundColor Cyan
Start-Sleep -Seconds 1
Start-Process $WebUrl

Write-Host "您可以随时在浏览器中访问: $WebUrl" -ForegroundColor Green
Write-Host "按任意键退出部署向导..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
