module("luci.controller.ups_wrt_vm", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/ups_manager") then
        return
    end

    local page = entry({"admin", "services", "ups_wrt_vm"}, cbi("ups_wrt_vm"), _("UPS-WRT-VM 智能联动"), 55)
    page.dependent = true

    entry({"admin", "services", "ups_wrt_vm", "status_json"}, call("action_status_json"))
    entry({"admin", "services", "ups_wrt_vm", "clear_log"}, call("action_clear_log"))
    entry({"admin", "services", "ups_wrt_vm", "test_auth"}, call("action_test_auth"))
    entry({"admin", "services", "ups_wrt_vm", "reload_upsd"}, call("action_reload_upsd"))
end

local function append_audit_log(level, msg)
    local uci = luci.model.uci.cursor()
    local logfile = uci:get("ups_manager", "main", "log_file") or "/etc/ups_manager/ups_events.log"
    nixio.fs.mkdirr("/etc/ups_manager")
    local now = os.date("%Y-%m-%d %H:%M:%S")
    local line = string.format("[%s] [%s] %s\n", now, level, msg)
    
    local f = io.open(logfile, "a")
    if f then
        f:write(line)
        f:close()
    end
    luci.sys.exec(string.format("ln -sf '%s' /var/log/ups_events.log 2>/dev/null", logfile))
    luci.sys.exec(string.format("logger -t UPS_AUDIT '[%s] %s'", level, msg:gsub("'", "")))
end

function action_clear_log()
    local logfile = luci.model.uci.cursor():get("ups_manager", "main", "log_file") or "/etc/ups_manager/ups_events.log"
    nixio.fs.mkdirr("/etc/ups_manager")
    nixio.fs.writefile(logfile, "")
    append_audit_log("CONFIG", "【日志清理】管理员手动清空了运行与关机审计日志。")
    luci.http.redirect(luci.dispatcher.build_url("admin", "services", "ups_wrt_vm"))
end

function action_reload_upsd()
    local res = { success = false, message = "" }
    luci.sys.exec("/etc/init.d/nut-server restart >/dev/null 2>&1")
    luci.sys.exec("sleep 1")
    luci.sys.exec("/etc/init.d/nut-monitor restart >/dev/null 2>&1")
    luci.sys.exec("sleep 1")
    
    local check_upsd = luci.sys.exec("ps | grep -v grep | grep '/usr/sbin/upsd'")
    local check_upsmon = luci.sys.exec("ps | grep -v grep | grep '/usr/sbin/upsmon'")
    if check_upsd ~= "" then
        res.success = true
        res.message = string.format("✔ UPSD 服务端与监控哨兵已成功重载！(upsd: 运行中, upsmon: %s)", check_upsmon ~= "" and "运行中" or "待命")
        append_audit_log("CONFIG", "【服务重载】管理员手动触发重载 UPSD 服务端配置: 守护进程与 upsmon 监控哨兵已同步刷新。")
    else
        res.success = false
        res.message = "✖ UPSD 重启异常，请检查 nut-server 配置是否合规。"
        append_audit_log("WARN", "【服务异常】管理员触发重载 UPSD 服务端配置: 守护进程未检测到运行状态。")
    end

    luci.http.prepare_content("application/json")
    luci.http.write_json(res)
end

function action_status_json()
    local uci = luci.model.uci.cursor()
    local host = uci:get("ups_manager", "main", "nut_host") or "127.0.0.1"
    local port = uci:get("ups_manager", "main", "nut_port") or "3493"
    local upsname = uci:get("ups_manager", "main", "nut_upsname") or "ups"
    local target = string.format("%s@%s:%s", upsname, host, port)

    local f = io.popen("upsc " .. target .. " 2>/dev/null")
    local data = {}
    if f then
        for line in f:lines() do
            local k, v = line:match("^([^:]+):%s*(.*)$")
            if k and v then
                data[k] = v:gsub("[\r\n]+", "")
            end
        end
        f:close()
    end

    local charge = tonumber(data["battery.charge"]) or 0
    local runtime = tonumber(data["battery.runtime"]) or 0
    local runtime_str = "计算中..."
    if runtime > 0 then
        local hours = math.floor(runtime / 3600)
        local mins = math.floor((runtime % 3600) / 60)
        if hours > 0 then
            runtime_str = string.format("%d 小时 %d 分钟", hours, mins)
        else
            runtime_str = string.format("%d 分钟", mins)
        end
    end

    local upsmon_pid = luci.sys.exec("pgrep -f '/usr/sbin/upsmon' 2>/dev/null | head -n 1"):gsub("%s+", "")
    local countdown_pid = luci.sys.exec("cat /var/run/ups_countdown.pid 2>/dev/null"):gsub("%s+", "")
    local is_counting = false
    if countdown_pid ~= "" and nixio.fs.access("/proc/" .. countdown_pid) then
        is_counting = true
    end

    local res = {
        connected = (data["device.model"] ~= nil),
        model = data["device.model"] or "APC / 通用 USB-HID UPS",
        serial = data["device.serial"] or "N/A",
        status_raw = data["ups.status"] or "UNKNOWN",
        charge = charge,
        voltage = data["battery.voltage"] or "0.0",
        input_voltage = data["input.voltage"] or "0.0",
        load = tonumber(data["ups.load"]) or 0,
        runtime_sec = runtime,
        runtime_str = runtime_str,
        upsmon_pid = upsmon_pid,
        is_counting = is_counting
    }

    luci.http.prepare_content("application/json")
    luci.http.write_json(res)
end

function action_test_auth()
    local uci = luci.model.uci.cursor()
    local host = luci.http.formvalue("host")
    if not host or host == "" or host == "undefined" or host == "null" then
        host = uci:get("ups_manager", "main", "nut_host") or "127.0.0.1"
    end

    local port_str = luci.http.formvalue("port")
    local port = tonumber(port_str)
    if not port or port <= 0 then
        port = tonumber(uci:get("ups_manager", "main", "nut_port") or 3493) or 3493
    end

    local upsname = luci.http.formvalue("upsname")
    if not upsname or upsname == "" or upsname == "undefined" or upsname == "null" then
        upsname = uci:get("ups_manager", "main", "nut_upsname") or "ups"
    end

    local user = luci.http.formvalue("user")
    if not user or user == "" or user == "undefined" or user == "null" then
        user = uci:get("ups_manager", "main", "nut_user") or "monuser"
    end

    local pass = luci.http.formvalue("pass")
    if not pass or pass == "" or pass == "undefined" or pass == "null" then
        pass = uci:get("ups_manager", "main", "nut_password") or "secret123"
    end

    local esxi_host = luci.http.formvalue("esxi_host")
    if not esxi_host or esxi_host == "" or esxi_host == "undefined" or esxi_host == "null" then
        esxi_host = uci:get("ups_manager", "main", "esxi_host") or "192.168.1.100"
    end

    local result = {
        success = false,
        message = "",
        detail = "",
        nut_ver = "",
        esxi_ok = false,
        esxi_detail = ""
    }

    -- 1. 独立检测 ESXi 通路
    local ssh_cmd = string.format("ssh -y -i /etc/dropbear/id_dropbear_rsa root@%s 'echo SSH_OK' 2>/dev/null", esxi_host)
    local f = io.popen(ssh_cmd)
    local ssh_out = f and f:read("*a"):gsub("[\r\n]+", "") or ""
    if f then f:close() end

    if ssh_out:match("SSH_OK") then
        result.esxi_ok = true
        result.esxi_detail = string.format("✔ ESXi 宿主机 (%s) SSH RSA 免密通路正常", esxi_host)
    else
        result.esxi_ok = false
        result.esxi_detail = string.format("✖ ESXi 宿主机 (%s) SSH 连通异常: %s (请检查免密配置)", esxi_host, ssh_out ~= "" and ssh_out or "连接失败")
    end

    -- 2. 检测 NUT 连通性与凭据
    local socket = nixio.socket("inet", "stream")
    if not socket then
        result.message = "无法初始化本地网络套接字"
        append_audit_log("DIAG", string.format("【诊断失败】无法创建网络套接字, 目标=%s:%d", host, port))
        luci.http.prepare_content("application/json")
        luci.http.write_json(result)
        return
    end

    socket:setopt("socket", "rcvtimeo", 3)
    socket:setopt("socket", "sndtimeo", 3)

    local ok, err = socket:connect(host, port)
    if not ok then
        result.message = string.format("连接 NUT 服务端失败: 无法连接至 %s:%d (%s)", host, port, tostring(err or "连接被拒绝"))
        result.detail = "请检查 NUT 服务端是否正常运行，或尝试点击上方【重载 UPSD 服务端配置】按钮。"
        append_audit_log("DIAG", string.format("【诊断失败】目标=%s:%d 无法建立 TCP 连接 (%s)", host, port, tostring(err or "连接被拒绝")))
        luci.http.prepare_content("application/json")
        luci.http.write_json(result)
        return
    end

    local function send_cmd(cmd)
        socket:send(cmd .. "\n")
        local res = socket:recv(1024)
        return res and res:gsub("[\r\n]+", "") or ""
    end

    local r_user = send_cmd("USERNAME " .. user)
    local r_pass = send_cmd("PASSWORD " .. pass)
    local r_login = send_cmd("LOGIN " .. upsname)
    local r_ver = send_cmd("VER")
    socket:close()

    result.nut_ver = r_ver ~= "" and r_ver or "Network UPS Tools upsd"

    local upsmon_chk = luci.sys.exec("ps | grep -v grep | grep '/usr/sbin/upsmon'")
    local upsmon_state = (upsmon_chk ~= "") and "运行中" or "未运行"

    if r_login == "OK" then
        result.success = true
        result.message = string.format("✔ 验证通过！成功连接 %s:%d 并通过账户 [%s] 认证 (LOGIN OK)", host, port, user)
        result.detail = string.format("服务端就绪: %s | 设备标识: %s | 监控哨兵(upsmon): %s", result.nut_ver, upsname, upsmon_state)
        append_audit_log("DIAG", string.format("【凭据诊断通过】目标=%s:%d, 用户=[%s], 握手=LOGIN OK, upsmon=[%s], ESXi链路=[%s]", 
            host, port, user, upsmon_state, result.esxi_ok and "畅通" or "异常"))
    elseif r_login:match("ACCESS%-DENIED") then
        result.success = false
        result.message = string.format("✖ 认证失败: 用户名 [%s] 或密码错误！(ERR ACCESS-DENIED)", user)
        result.detail = "密码与当前 NUT 内存用户表不匹配。若刚修改过用户，请先点击【重载 UPSD 服务端配置】按钮使内存刷新。"
        append_audit_log("DIAG", string.format("【凭据认证被拒】目标=%s:%d, 尝试用户=[%s], 服务端返回=ERR ACCESS-DENIED", host, port, user))
    elseif r_login:match("UNKNOWN%-UPS") then
        result.success = false
        result.message = string.format("✖ 设备未找到: NUT 服务端未定义 UPS 设备 [%s]", upsname)
        result.detail = "请检查 NUT 服务端 driver 配置中的 UPS 命名。"
        append_audit_log("DIAG", string.format("【设备未找到】目标=%s:%d, 未定义设备=[%s]", host, port, upsname))
    else
        result.success = false
        result.message = string.format("✖ 认证返回异常: %s", r_login ~= "" and r_login or "无有效握手响应")
        result.detail = string.format("交互回执: USER=%s, PASS=%s, LOGIN=%s", r_user, r_pass, r_login)
        append_audit_log("DIAG", string.format("【诊断返回异常】目标=%s:%d, 回执=%s", host, port, r_login))
    end

    luci.http.prepare_content("application/json")
    luci.http.write_json(result)
end

