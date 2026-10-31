local fs = require "nixio.fs"
local sys = require "luci.sys"
local uci = luci.model.uci.cursor()

local m = Map("ups_manager", translate("UPS 智能供电与网络安全关机中心"),
    translate("一站式接管 APC Back-UPS 实时供电遥测、多设备 NUT 访问账户表、断电防抖倒计时与 ESXi 虚拟机分级安全下电。"))
m.apply_on_parse = false

-- =========================================================================
-- 1. 现代化动态图形遥测仪表盘
-- =========================================================================
local s_dashboard = m:section(NamedSection, "main", "settings", translate("UPS 实时供电遥测仪表盘"))
s_dashboard.anonymous = true

local dash_view = s_dashboard:option(DummyValue, "_dash_view")
dash_view.rawhtml = true
function dash_view.cfgvalue(self, section)
    local u = luci.model.uci.cursor()
    local n_host = u:get("ups_manager", "main", "nut_host") or "127.0.0.1"
    local n_port = u:get("ups_manager", "main", "nut_port") or "3493"
    local n_ups  = u:get("ups_manager", "main", "nut_upsname") or "ups"
    local target = string.format("%s@%s:%s", n_ups, n_host, n_port)

    local stat_charge = tonumber((sys.exec("upsc " .. target .. " battery.charge 2>/dev/null"):gsub("%s+", ""))) or 0
    local stat_voltage = sys.exec("upsc " .. target .. " battery.voltage 2>/dev/null"):gsub("%s+", "")
    if stat_voltage == "" then stat_voltage = "0.0" end
    local stat_in_volt = sys.exec("upsc " .. target .. " input.voltage 2>/dev/null"):gsub("%s+", "")
    if stat_in_volt == "" then stat_in_volt = "0.0" end
    local stat_status = sys.exec("upsc " .. target .. " ups.status 2>/dev/null"):gsub("%s+", "")
    local stat_model = sys.exec("upsc " .. target .. " device.model 2>/dev/null"):gsub("[\r\n]+", "")
    local stat_load = tonumber((sys.exec("upsc " .. target .. " ups.load 2>/dev/null"):gsub("%s+", ""))) or 0
    local stat_runtime = tonumber((sys.exec("upsc " .. target .. " battery.runtime 2>/dev/null"):gsub("%s+", ""))) or 0
    
    local runtime_str = "计算中..."
    if stat_runtime > 0 then
        local hours = math.floor(stat_runtime / 3600)
        local mins = math.floor((stat_runtime % 3600) / 60)
        if hours > 0 then
            runtime_str = string.format("%d 小时 %d 分", hours, mins)
        else
            runtime_str = string.format("%d 分钟", mins)
        end
    end

    local upsmon_pid = sys.exec("pgrep -f '/usr/sbin/upsmon' 2>/dev/null | head -n 1"):gsub("%s+", "")
    local is_online = stat_status:match("OL") and not stat_status:match("OB")

    return string.format([[
<style type="text/css">
.ups-dash-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(210px, 1fr));
    gap: 16px;
    margin-bottom: 20px;
}
.ups-card {
    background: #ffffff;
    border: 1px solid #e2e8f0;
    border-radius: 10px;
    padding: 16px;
    box-shadow: 0 2px 6px rgba(0,0,0,0.04);
    display: flex;
    flex-direction: column;
    align-items: center;
    position: relative;
    transition: all 0.25s ease;
}
.ups-card:hover {
    box-shadow: 0 4px 12px rgba(0,0,0,0.08);
}
.ups-card-title {
    font-size: 13px;
    font-weight: 600;
    color: #64748b;
    margin-bottom: 12px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
}
.ups-gauge-box {
    position: relative;
    width: 120px;
    height: 120px;
}
.ups-gauge-svg {
    transform: rotate(-90deg);
}
.ups-gauge-val {
    position: absolute;
    top: 50%%;
    left: 50%%;
    transform: translate(-50%%, -50%%);
    text-align: center;
}
.ups-big-num {
    font-size: 26px;
    font-weight: bold;
    color: #1e293b;
    line-height: 1;
}
.ups-unit {
    font-size: 12px;
    color: #94a3b8;
}
.ups-subtext {
    margin-top: 10px;
    font-size: 12px;
    color: #475569;
    font-weight: 500;
}
.ups-badge {
    display: inline-flex;
    align-items: center;
    padding: 4px 10px;
    border-radius: 20px;
    font-size: 12px;
    font-weight: 600;
}
.badge-online { background: #dcfce7; color: #15803d; border: 1px solid #bbf7d0; }
.badge-onbatt { background: #fee2e2; color: #b91c1c; border: 1px solid #fecaca; animation: pulse-red 1.5s infinite; }
@keyframes pulse-red {
    0%% { box-shadow: 0 0 0 0 rgba(239, 68, 68, 0.4); }
    70%% { box-shadow: 0 0 0 8px rgba(239, 68, 68, 0); }
    100%% { box-shadow: 0 0 0 0 rgba(239, 68, 68, 0); }
}
.ups-pulse-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%%;
    margin-right: 6px;
    display: inline-block;
}
.dot-green { background: #22c55e; }
.dot-red { background: #ef4444; }
.ups-bar-track {
    width: 100%%;
    height: 10px;
    background: #e2e8f0;
    border-radius: 5px;
    overflow: hidden;
    margin-top: 15px;
}
.ups-bar-fill {
    height: 100%%;
    background: linear-gradient(90deg, #3b82f6, #6366f1);
    transition: width 0.4s ease;
}
</style>

<div class="ups-dash-grid">
    <!-- 卡片 1: 电池剩余电量 -->
    <div class="ups-card">
        <div class="ups-card-title">🔋 电池剩余电量</div>
        <div class="ups-gauge-box">
            <svg class="ups-gauge-svg" width="120" height="120">
                <circle cx="60" cy="60" r="48" stroke="#f1f5f9" stroke-width="10" fill="none"></circle>
                <circle id="dash_gauge_charge" cx="60" cy="60" r="48" stroke="%s" stroke-width="10" fill="none"
                        stroke-dasharray="301.6" stroke-dashoffset="%f" stroke-linecap="round" style="transition: stroke-dashoffset 0.6s ease;"></circle>
            </svg>
            <div class="ups-gauge-val">
                <div class="ups-big-num" id="dash_txt_charge">%d<span class="ups-unit">%%</span></div>
            </div>
        </div>
        <div class="ups-subtext" id="dash_txt_batt_volt">端电压: %sV (标称 12V)</div>
    </div>

    <!-- 卡片 2: 供电模式与电网质量 -->
    <div class="ups-card">
        <div class="ups-card-title">⚡ 供电电网遥测</div>
        <div style="margin: 10px 0;">
            <span id="dash_badge_status" class="ups-badge %s">
                <span class="ups-pulse-dot %s"></span>
                <span id="dash_txt_status">%s</span>
            </span>
        </div>
        <div class="ups-big-num" style="margin-top: 10px;" id="dash_txt_in_volt">%s <span class="ups-unit">VAC</span></div>
        <div class="ups-subtext">市电输入实时电压</div>
    </div>

    <!-- 卡片 3: 预计可用续航 -->
    <div class="ups-card">
        <div class="ups-card-title">⏱ 预计可用续航时间</div>
        <div style="font-size: 32px; margin: 10px 0;">⏳</div>
        <div class="ups-big-num" style="font-size: 22px; color: #2563eb;" id="dash_txt_runtime">%s</div>
        <div class="ups-subtext" id="dash_txt_load_sub">当前负载率: %d%%</div>
        <div class="ups-bar-track">
            <div id="dash_bar_load" class="ups-bar-fill" style="width: %d%%;"></div>
        </div>
    </div>

    <!-- 卡片 4: 硬件设备与守护哨兵 -->
    <div class="ups-card">
        <div class="ups-card-title">🛡 守护哨兵与硬件</div>
        <div style="text-align: left; width: 100%%; font-size: 13px; line-height: 1.8; margin-top: 5px;">
            <div><b>设备型号:</b> <span id="dash_txt_model" style="color:#0f172a;">%s</span></div>
            <div><b>监控哨兵:</b> <span id="dash_txt_upsmon" style="color:%s;">%s</span></div>
            <div><b>关机倒计时:</b> <span id="dash_txt_counting" style="color:%s;">%s</span></div>
        </div>
        <div style="margin-top: 12px; width: 100%%;">
            <button type="button" class="cbi-button cbi-button-action" style="width: 100%%;" onclick="triggerReloadUpsd()">🔄 热重载 NUT 服务与哨兵</button>
        </div>
    </div>
</div>

<script type="text/javascript">
function pollUpsStatus() {
    fetch('%s')
        .then(function(r) { return r.json(); })
        .then(function(d) {
            if (!d) return;
            var charge = d.charge || 0;
            var txtCharge = document.getElementById('dash_txt_charge');
            if (txtCharge) txtCharge.innerHTML = charge + '<span class="ups-unit">%%</span>';

            var circle = document.getElementById('dash_gauge_charge');
            if (circle) {
                var total = 301.6;
                var offset = total - (total * (charge / 100));
                circle.setAttribute('stroke-dashoffset', offset);
                if (charge > 50) circle.setAttribute('stroke', '#22c55e');
                else if (charge > 20) circle.setAttribute('stroke', '#f59e0b');
                else circle.setAttribute('stroke', '#ef4444');
            }

            var txtVolt = document.getElementById('dash_txt_batt_volt');
            if (txtVolt) txtVolt.innerText = '端电压: ' + d.voltage + 'V (标称 12V)';

            var badge = document.getElementById('dash_badge_status');
            var txtStatus = document.getElementById('dash_txt_status');
            var isOnline = (d.status_raw && d.status_raw.indexOf('OL') !== -1 && d.status_raw.indexOf('OB') === -1);
            if (badge && txtStatus) {
                if (isOnline) {
                    badge.className = 'ups-badge badge-online';
                    badge.innerHTML = '<span class="ups-pulse-dot dot-green"></span>市电正常在线 (ONLINE)';
                } else {
                    badge.className = 'ups-badge badge-onbatt';
                    badge.innerHTML = '<span class="ups-pulse-dot dot-red"></span>⚡ 电池供电中 (' + d.status_raw + ')';
                }
            }

            var txtInVolt = document.getElementById('dash_txt_in_volt');
            if (txtInVolt) txtInVolt.innerHTML = d.input_voltage + ' <span class="ups-unit">VAC</span>';

            var txtRuntime = document.getElementById('dash_txt_runtime');
            if (txtRuntime) txtRuntime.innerText = d.runtime_str || '计算中...';

            var txtLoadSub = document.getElementById('dash_txt_load_sub');
            if (txtLoadSub) txtLoadSub.innerText = '当前负载率: ' + (d.load || 0) + '%%';

            var barLoad = document.getElementById('dash_bar_load');
            if (barLoad) barLoad.style.width = (d.load || 0) + '%%';

            var txtUpsmon = document.getElementById('dash_txt_upsmon');
            if (txtUpsmon) {
                if (d.upsmon_pid && d.upsmon_pid !== '') {
                    txtUpsmon.style.color = '#16a34a';
                    txtUpsmon.innerText = '✔ 运行中 (PID: ' + d.upsmon_pid + ')';
                } else {
                    txtUpsmon.style.color = '#dc2626';
                    txtUpsmon.innerText = '✖ 未运行 (异常)';
                }
            }

            var txtCounting = document.getElementById('dash_txt_counting');
            if (txtCounting) {
                if (d.is_counting) {
                    txtCounting.style.color = '#dc2626';
                    txtCounting.innerText = '⚡ 断电防抖倒计时进行中';
                } else {
                    txtCounting.style.color = '#475569';
                    txtCounting.innerText = '正常巡检 (待命中)';
                }
            }
        })
        .catch(function(e) {});
}
setInterval(pollUpsStatus, 3500);

function triggerReloadUpsd() {
    if (!confirm('确定要平滑重载 NUT 服务端 (upsd) 与监控哨兵 (upsmon) 吗？')) return;
    var btn = event.target;
    btn.disabled = true;
    btn.innerText = '正在重载服务...';
    fetch('%s')
        .then(function(r) { return r.json(); })
        .then(function(d) {
            alert(d.message || '重载指令已下发！');
            location.reload();
        })
        .catch(function(e) {
            alert('重载失败: ' + e);
            btn.disabled = false;
            btn.innerText = '🔄 热重载 NUT 服务与哨兵';
        });
}
</script>
]], 
    (stat_charge > 50 and "#22c55e" or (stat_charge > 20 and "#f59e0b" or "#ef4444")),
    (301.6 - (301.6 * (stat_charge / 100))),
    stat_charge,
    stat_voltage,
    (is_online and "badge-online" or "badge-onbatt"),
    (is_online and "dot-green" or "dot-red"),
    (is_online and "市电正常在线 (ONLINE)" or ("⚡ 电池供电中 (" .. stat_status .. ")")),
    stat_in_volt,
    runtime_str,
    stat_load,
    stat_load,
    stat_model ~= "" and stat_model or "APC Back-UPS XS 650CI",
    (upsmon_pid ~= "" and "#16a34a" or "#dc2626"),
    (upsmon_pid ~= "" and ("✔ 运行中 (PID: " .. upsmon_pid .. ")") or "✖ 未运行 (异常)"),
    "#475569",
    "正常巡检 (待命中)",
    luci.dispatcher.build_url("admin", "services", "ups_wrt_vm", "status_json"),
    luci.dispatcher.build_url("admin", "services", "ups_wrt_vm", "reload_upsd"))
end

-- =========================================================================
-- 2. 表格式 NUT 访问凭据管理（双向同步 /etc/config/nut_server 与 nut_monitor）
-- =========================================================================
local s_user_table = m:section(NamedSection, "main", "settings", translate("网络 UPS 访问凭据表格 (支持局域网多设备接入与一键测试)"))
s_user_table.anonymous = true

local user_tbl_view = s_user_table:option(DummyValue, "_user_tbl_view")
user_tbl_view.rawhtml = true
function user_tbl_view.cfgvalue(self, section)
    local u = luci.model.uci.cursor()
    local users = {}
    u:foreach("nut_server", "user", function(s)
        table.insert(users, {
            username = s.username or "",
            password = s.password or "",
            actions = table.concat(s.actions or {}, " "),
            instcmd = table.concat(s.instcmd or {}, " "),
            upsmon = s.upsmon or "slave"
        })
    end)

    local main_user = u:get("ups_manager", "main", "nut_user") or "monuser"

    local rows_html = ""
    for idx, usr in ipairs(users) do
        local is_primary = (usr.username == main_user)
        local is_admin = (usr.instcmd:match("ALL") or usr.actions:match("fsd"))
        local role_desc = is_admin and "<span style='color:#7c3aed; font-weight:600;'>👑 管理员 (全权控制)</span>" or "<span style='color:#059669; font-weight:500;'>🔒 从机监控 (只读受电)</span>"
        
        rows_html = rows_html .. string.format([[
<tr style="border-bottom: 1px solid #f1f5f9;">
    <td style="padding:10px 12px; text-align:center;">
        <input type="radio" name="ups_primary_user_select" value="%s" %s onchange="selectPrimaryUser(this.value, '%s')" />
    </td>
    <td style="padding:10px 12px; font-weight:600; color:#1e293b;">%s</td>
    <td style="padding:10px 12px;">
        <div style="display:inline-flex; align-items:center;">
            <input type="password" id="pwd_show_%d" value="%s" readonly style="width:110px; border:none; background:transparent; font-family:monospace;" />
            <button type="button" class="cbi-button" style="padding:1px 6px; font-size:11px;" onclick="togglePwdMask(%d)">👁</button>
        </div>
    </td>
    <td style="padding:10px 12px;">%s</td>
    <td style="padding:10px 12px; text-align:center;">
        <button type="button" class="cbi-button cbi-button-action" style="padding:3px 8px; font-size:12px; margin-right:4px;" onclick="testSingleUser('%s', '%s')">⚡ 握手测试</button>
        <button type="button" class="cbi-button cbi-button-remove" style="padding:3px 8px; font-size:12px;" onclick="removeNutUser('%s')">🗑 删除</button>
    </td>
</tr>
]], usr.username, (is_primary and "checked" or ""), usr.password, usr.username, idx, usr.password, idx, role_desc, usr.username, usr.password, usr.username)
    end

    return string.format([[
<div style="background:#ffffff; border:1px solid #e2e8f0; border-radius:8px; overflow:hidden; margin-bottom:15px; box-shadow:0 1px 3px rgba(0,0,0,0.03);">
    <table style="width:100%%; border-collapse:collapse; font-size:13px;">
        <thead>
            <tr style="background:#f8fafc; border-bottom:2px solid #e2e8f0; color:#475569; text-align:left;">
                <th style="padding:10px 12px; width:100px; text-align:center;">主监控凭据</th>
                <th style="padding:10px 12px;">连接用户名</th>
                <th style="padding:10px 12px;">访问密码</th>
                <th style="padding:10px 12px;">权限角色</th>
                <th style="padding:10px 12px; width:180px; text-align:center;">操作管理</th>
            </tr>
        </thead>
        <tbody id="nut_user_table_body">
            %s
        </tbody>
    </table>
    <div style="padding:12px; background:#f8fafc; border-top:1px solid #e2e8f0; display:flex; justify-content:space-between; align-items:center;">
        <div>
            <span style="font-size:12px; color:#64748b;">💡 勾选【主监控凭据】的账号将直接作为本软路由 upsmon 哨兵与 ESXi 关机调度的通讯凭据。</span>
        </div>
        <div>
            <button type="button" class="cbi-button cbi-button-add" onclick="showAddUserModal()">➕ 新增 NUT 接入账户</button>
        </div>
    </div>
</div>

<!-- 隐藏传输字段，随 CBI 一并提交 -->
<input type="hidden" id="raw_nut_user_json" name="cbid.ups_manager.main._raw_nut_users" value="" />

<!-- 诊断结果浮层面板 -->
<div id="diag_result_box" style="display:none; padding:12px; border-radius:6px; font-size:13px; line-height:22px; margin-bottom:15px;"></div>

<!-- 新增用户轻量弹窗 -->
<div id="addUserModal" style="display:none; position:fixed; top:0; left:0; width:100%%; height:100%%; background:rgba(0,0,0,0.4); z-index:9999; align-items:center; justify-content:center;">
    <div style="background:#fff; width:360px; padding:20px; border-radius:10px; box-shadow:0 10px 25px rgba(0,0,0,0.15);">
        <h3 style="margin-top:0; font-size:16px; color:#1e293b;">➕ 添加 NUT 接入用户</h3>
        <div style="margin-bottom:12px;">
            <label style="font-size:12px; font-weight:600; display:block; margin-bottom:4px;">用户名:</label>
            <input type="text" id="new_usr_name" class="cbi-input-text" style="width:100%%;" placeholder="例如: nas 或 pc_win" />
        </div>
        <div style="margin-bottom:12px;">
            <label style="font-size:12px; font-weight:600; display:block; margin-bottom:4px;">访问密码:</label>
            <input type="text" id="new_usr_pwd" class="cbi-input-text" style="width:100%%;" placeholder="请输入连接密码" />
        </div>
        <div style="margin-bottom:16px;">
            <label style="font-size:12px; font-weight:600; display:block; margin-bottom:4px;">角色权限:</label>
            <select id="new_usr_role" class="cbi-input-select" style="width:100%%;">
                <option value="slave">🔒 从机监控 (slave - 适合普通 NAS/PC)</option>
                <option value="admin">👑 管理员全权 (admin - 支持远程 FSD 关机与控制)</option>
            </select>
        </div>
        <div style="display:flex; justify-content:flex-end; gap:8px;">
            <button type="button" class="cbi-button cbi-button-reset" onclick="hideAddUserModal()">取消</button>
            <button type="button" class="cbi-button cbi-button-save" onclick="submitAddUser()">确认添加</button>
        </div>
    </div>
</div>

<script type="text/javascript">
function togglePwdMask(idx) {
    var inp = document.getElementById('pwd_show_' + idx);
    if (!inp) return;
    inp.type = (inp.type === 'password') ? 'text' : 'password';
}

function showAddUserModal() {
    var modal = document.getElementById('addUserModal');
    if (modal) {
        modal.style.display = 'flex';
        document.getElementById('new_usr_name').value = '';
        document.getElementById('new_usr_pwd').value = '';
    }
}

function hideAddUserModal() {
    var modal = document.getElementById('addUserModal');
    if (modal) modal.style.display = 'none';
}

function selectPrimaryUser(user, pass) {
    var inputUser = document.getElementById('cbid.ups_manager.main.nut_user');
    var inputPass = document.getElementById('cbid.ups_manager.main.nut_password');
    if (inputUser) inputUser.value = user;
    if (inputPass) inputPass.value = pass;
}

function submitAddUser() {
    var u = document.getElementById('new_usr_name').value.trim();
    var p = document.getElementById('new_usr_pwd').value.trim();
    var r = document.getElementById('new_usr_role').value;
    if (!u || !p) {
        alert('用户名和密码均不能为空！');
        return;
    }
    
    var tbody = document.getElementById('nut_user_table_body');
    var idx = tbody.getElementsByTagName('tr').length + 1;
    var roleDesc = (r === 'admin') ? "<span style='color:#7c3aed; font-weight:600;'>👑 管理员 (全权控制)</span>" : "<span style='color:#059669; font-weight:500;'>🔒 从机监控 (只读受电)</span>";
    
    var tr = document.createElement('tr');
    tr.style.borderBottom = '1px solid #f1f5f9';
    tr.innerHTML = '<td style="padding:10px 12px; text-align:center;"><input type="radio" name="ups_primary_user_select" value="' + u + '" onchange="selectPrimaryUser(this.value, \'' + p + '\')" /></td>' +
                   '<td style="padding:10px 12px; font-weight:600; color:#1e293b;">' + u + '</td>' +
                   '<td style="padding:10px 12px;"><div style="display:inline-flex; align-items:center;"><input type="password" id="pwd_show_' + idx + '" value="' + p + '" readonly style="width:110px; border:none; background:transparent; font-family:monospace;" /><button type="button" class="cbi-button" style="padding:1px 6px; font-size:11px;" onclick="togglePwdMask(' + idx + ')">👁</button></div></td>' +
                   '<td style="padding:10px 12px;">' + roleDesc + '</td>' +
                   '<td style="padding:10px 12px; text-align:center;"><button type="button" class="cbi-button cbi-button-action" style="padding:3px 8px; font-size:12px; margin-right:4px;" onclick="testSingleUser(\'' + u + '\', \'' + p + '\')">⚡ 握手测试</button><button type="button" class="cbi-button cbi-button-remove" style="padding:3px 8px; font-size:12px;" onclick="removeNutUser(\'' + u + '\')">🗑 删除</button></td>';
    tbody.appendChild(tr);
    hideAddUserModal();
    serializeUserTable();
    alert('已添加用户 [' + u + ']！请点击页面底部的【保存并应用】使其在后台立即生效。');
}

function removeNutUser(username) {
    if (!confirm('确定要从 NUT 服务端移除账户 [' + username + '] 吗？')) return;
    var tbody = document.getElementById('nut_user_table_body');
    var trs = tbody.getElementsByTagName('tr');
    for (var i = 0; i < trs.length; i++) {
        if (trs[i].children[1].innerText.trim() === username) {
            tbody.removeChild(trs[i]);
            break;
        }
    }
    serializeUserTable();
    alert('已从表格中移除该用户，请点击页面底部【保存并应用】以彻底删除并重载配置。');
}

function serializeUserTable() {
    var list = [];
    var tbody = document.getElementById('nut_user_table_body');
    var trs = tbody.getElementsByTagName('tr');
    for (var i = 0; i < trs.length; i++) {
        var u = trs[i].children[1].innerText.trim();
        var p = trs[i].querySelector('input[type="password"], input[type="text"]').value.trim();
        var isAdm = trs[i].children[3].innerText.indexOf('管理员') !== -1;
        list.push({ username: u, password: p, role: (isAdm ? 'admin' : 'slave') });
    }
    var rawInput = document.getElementById('raw_nut_user_json');
    if (rawInput) rawInput.value = JSON.stringify(list);
}

function testSingleUser(u, p) {
    var box = document.getElementById('diag_result_box');
    box.style.display = 'block';
    box.style.background = '#f8fafc';
    box.style.border = '1px solid #cbd5e1';
    box.style.color = '#334155';
    box.innerHTML = '正在对账户 [' + u + '] 建立 TCP 3493 协议握手测试，并核验 ESXi 通路...';

    var host = document.getElementById('cbid.ups_manager.main.nut_host') ? document.getElementById('cbid.ups_manager.main.nut_host').value : '127.0.0.1';
    var port = document.getElementById('cbid.ups_manager.main.nut_port') ? document.getElementById('cbid.ups_manager.main.nut_port').value : '3493';
    var esxi = document.getElementById('cbid.ups_manager.main.esxi_host') ? document.getElementById('cbid.ups_manager.main.esxi_host').value : '192.168.1.100';

    var url = '%s?host=' + encodeURIComponent(host) + '&port=' + encodeURIComponent(port) + '&user=' + encodeURIComponent(u) + '&pass=' + encodeURIComponent(p) + '&esxi_host=' + encodeURIComponent(esxi);

    fetch(url)
        .then(function(res) { return res.json(); })
        .then(function(data) {
            if (data.success && data.esxi_ok) {
                box.style.background = '#ecfdf5';
                box.style.border = '1px solid #a7f3d0';
                box.style.color = '#065f46';
            } else if (data.success && !data.esxi_ok) {
                box.style.background = '#fffbeb';
                box.style.border = '1px solid #fde68a';
                box.style.color = '#92400e';
            } else {
                box.style.background = '#fef2f2';
                box.style.border = '1px solid #fecaca';
                box.style.color = '#991b1b';
            }
            box.innerHTML = '<b>[NUT 认证状态]</b> ' + data.message + '<br/>' +
                            '<b>[服务版本信息]</b> ' + data.detail + '<br/>' +
                            '<b>[ESXi 通信链路]</b> ' + data.esxi_detail + '<br/>' +
                            '<small style="color:#64748b;">提示：本次诊断结果已自动记入下方持久化审计日志。</small>';
        })
        .catch(function(err) {
            box.style.background = '#fef2f2';
            box.style.border = '1px solid #fecaca';
            box.style.color = '#991b1b';
            box.innerHTML = '<b>[请求异常]</b> 握手测试异常: ' + err;
        });
}

setTimeout(serializeUserTable, 500);
</script>
]], rows_html, luci.dispatcher.build_url("admin", "services", "ups_wrt_vm", "test_auth"))
end

-- =========================================================================
-- 3. 网络服务与主监控凭据隐藏字段绑定
-- =========================================================================
local s_net = m:section(NamedSection, "main", "settings", translate("底层通讯与主监控凭据配置"))
s_net.anonymous = true

local o_host = s_net:option(Value, "nut_host", translate("NUT 监听地址"), translate("本地默认为 127.0.0.1"))
o_host.default = "127.0.0.1"
o_host.rmempty = false

local o_port = s_net:option(Value, "nut_port", translate("NUT 端口"), translate("默认 3493"))
o_port.default = "3493"
o_port.rmempty = false

local o_ups = s_net:option(Value, "nut_upsname", translate("UPS 标识名称"), translate("APC 默认驱动标识为 ups"))
o_ups.default = "ups"
o_ups.rmempty = false

local o_user = s_net:option(Value, "nut_user", translate("主监控用户"), translate("选定用于本机 upsmon 监控与关机调度的账号"))
o_user.default = "monuser"
o_user.rmempty = false

local o_pass = s_net:option(Value, "nut_password", translate("主监控密码"), translate("与主监控用户对应的通信密码"))
o_pass.password = true
o_pass.default = "secret123"
o_pass.rmempty = false

-- =========================================================================
-- 4. 业务关机编排参数
-- =========================================================================
local s_cfg = m:section(NamedSection, "main", "settings", translate("ESXi 宿主机与虚拟机分级关机编排"))
s_cfg.anonymous = true

local o_en = s_cfg:option(Flag, "enabled", translate("启用智能联动保护"),
    translate("开启后，断电将触发防抖倒计时并执行分级关机；关闭则暂停保护，日常维护防误关。"))
o_en.default = "1"
o_en.rmempty = false

local o_wait = s_cfg:option(Value, "onbatt_wait_seconds", translate("市电恢复等待时间 (秒)"),
    translate("断电持续超过此秒数未恢复时触发分级关机。当前设置为 185 秒。"))
o_wait.datatype = "uinteger"
o_wait.default = "185"
o_wait.rmempty = false

local o_vm_wait = s_cfg:option(Value, "vm_shutdown_timeout", translate("业务虚拟机落盘超时 (秒)"),
    translate("向虚拟机发送正常关机信号后的最大轮询等待时间，超时后强制断电保底。"))
o_vm_wait.datatype = "uinteger"
o_vm_wait.default = "150"
o_vm_wait.rmempty = false

local o_lowbatt = s_cfg:option(Flag, "lowbatt_instant_shutdown", translate("低电量即时触发"),
    translate("检测到 UPS 电池告竭 (LOWBATT) 时，跳过防抖倒计时立即紧急关机。"))
o_lowbatt.default = "1"
o_lowbatt.rmempty = false

local o_ip = s_cfg:option(Value, "esxi_host", translate("ESXi 宿主机 IP 地址"),
    translate("执行远程分级关机命令的 ESXi 管理接口地址。"))
o_ip.datatype = "ip4addr"
o_ip.default = "192.168.1.100"
o_ip.rmempty = false

-- =========================================================================
-- 5. 持久化审计日志展示区域
-- =========================================================================
local s_log = m:section(NamedSection, "main", "settings", translate("运行与关机审计日志 (持久化存储: /etc/ups_manager/ups_events.log)"))
s_log.anonymous = true

local log_view = s_log:option(DummyValue, "_log_view")
log_view.rawhtml = true
function log_view.cfgvalue(self, section)
    local cur_uci = luci.model.uci.cursor()
    local log_path = cur_uci:get("ups_manager", "main", "log_file") or "/etc/ups_manager/ups_events.log"
    local log_data = fs.readfile(log_path)
    if not log_data or log_data == "" then
        log_data = "暂无日志记录。"
    end
    return string.format([[
<textarea id="ups_audit_log_box" style="width:100%%; height:240px; font-family:monospace; background:#0f172a; color:#f8fafc; padding:12px; border-radius:6px; box-sizing:border-box; line-height:20px;" readonly="readonly">%s</textarea>
<div style="margin-top:10px; display:flex; justify-content:space-between;">
  <div>
    <a class="cbi-button cbi-button-reset" href="%s">%s</a>
  </div>
  <div>
    <a class="cbi-button cbi-button-action" href="javascript:location.reload();">%s</a>
  </div>
</div>
<script type="text/javascript">
var box = document.getElementById('ups_audit_log_box');
if (box) { box.scrollTop = box.scrollHeight; }
</script>
]], log_data, 
        luci.dispatcher.build_url("admin", "services", "ups_wrt_vm", "clear_log"),
        translate("清空运行日志"),
        translate("刷新日志"))
end

-- =========================================================================
-- 6. 保存时的全量联动回调：同步更新 /etc/config/nut_server 与 nut_monitor
-- =========================================================================
local function sync_and_log_config(self)
    if self and self._ups_synced then
        return
    end
    if self then
        self._ups_synced = true
    end

    if self and self.uci then
        self.uci:commit("ups_manager")
    end

    local u = luci.model.uci.cursor()

    -- 1. 处理表格中的用户列表更新
    local raw_users_json = luci.http.formvalue("cbid.ups_manager.main._raw_nut_users")
    if raw_users_json and raw_users_json ~= "" then
        local users = luci.jsonc and luci.jsonc.parse(raw_users_json)
        if users and type(users) == "table" and #users > 0 then
            local old_users = {}
            u:foreach("nut_server", "user", function(s)
                table.insert(old_users, s[".name"])
            end)
            for _, sname in ipairs(old_users) do
                u:delete("nut_server", sname)
            end

            for _, usr in ipairs(users) do
                local sname = u:add("nut_server", "user")
                u:set("nut_server", sname, "username", usr.username)
                u:set("nut_server", sname, "password", usr.password)
                u:set("nut_server", sname, "upsmon", "slave")
                if usr.role == "admin" then
                    u:set("nut_server", sname, "instcmd", { "ALL" })
                    u:set("nut_server", sname, "actions", { "set", "fsd" })
                else
                    u:set("nut_server", sname, "actions", { "set", "fsd" })
                end
            end
            u:commit("nut_server")
            sys.exec("/etc/init.d/nut-server restart >/dev/null 2>&1")
        end
    end

    local enabled = u:get("ups_manager", "main", "enabled") or "1"
    local wait_sec = u:get("ups_manager", "main", "onbatt_wait_seconds") or "185"
    local vm_timeout = u:get("ups_manager", "main", "vm_shutdown_timeout") or "150"
    local lowbatt = u:get("ups_manager", "main", "lowbatt_instant_shutdown") or "1"
    local esxi_host = u:get("ups_manager", "main", "esxi_host") or "192.168.1.100"
    local host = u:get("ups_manager", "main", "nut_host") or "127.0.0.1"
    local port = u:get("ups_manager", "main", "nut_port") or "3493"
    local upsname = u:get("ups_manager", "main", "nut_upsname") or "ups"
    local user = u:get("ups_manager", "main", "nut_user") or "monuser"
    local pass = u:get("ups_manager", "main", "nut_password") or "secret123"

    -- 同步兼容字段
    u:set("ups_manager", "main", "onbatt_delay", wait_sec)
    u:set("ups_manager", "main", "lowbatt_shutdown", lowbatt)
    u:set("ups_manager", "main", "esxi_ip", esxi_host)
    u:set("ups_manager", "main", "log_file", "/etc/ups_manager/ups_events.log")
    u:commit("ups_manager")

    -- 同步生成 /etc/config/nut_monitor
    local nut_mon_cfg = string.format([[
config upsmon 'upsmon'
	option runas 'root'
	option minsupplies '1'
	option notifycmd '/etc/nut/ups_scheduler.sh'
	option pollfreq '2'
	option pollfreqalert '2'
	option hostsync '15'
	option deadtime '15'
	list defaultnotify 'SYSLOG'
	list defaultnotify 'EXEC'
	list onlinenotify 'SYSLOG'
	list onlinenotify 'EXEC'
	list onbattnotify 'SYSLOG'
	list onbattnotify 'EXEC'
	list lowbatnotify 'SYSLOG'
	list lowbatnotify 'EXEC'
	list lowbattnotify 'SYSLOG'
	list lowbattnotify 'EXEC'
	list fsdnotify 'SYSLOG'
	list fsdnotify 'EXEC'
	list commoknotify 'SYSLOG'
	list commoknotify 'EXEC'
	list commbadnotify 'SYSLOG'
	list commbadnotify 'EXEC'
	list shutdownnotify 'SYSLOG'
	list shutdownnotify 'EXEC'

config slave 'ups_slave'
	option upsname '%s'
	option hostname '%s'
	option port '%s'
	option powervalue '1'
	option username '%s'
	option password '%s'
]], upsname, host, port, user, pass)

    fs.writefile("/etc/config/nut_monitor", nut_mon_cfg)
    sys.exec("/etc/init.d/nut-monitor restart >/dev/null 2>&1")

    -- 记录全字段配置变更审计日志
    fs.mkdirr("/etc/ups_manager")
    local logfile = "/etc/ups_manager/ups_events.log"
    local now = os.date("%Y-%m-%d %H:%M:%S")
    local en_str = (enabled == "1") and "开启" or "已暂停"
    local lb_str = (lowbatt == "1") and "开启" or "关闭"
    local target = string.format("%s@%s:%s", upsname, host, port)
    local line = string.format(
        "[%s] [CONFIG] 【参数与账户配置变更】管理员更新了设置: 联动保护=[%s], 市电恢复等待时间=[%s秒], 虚拟机落盘超时=[%s秒], 低电量即时关机=[%s], ESXi宿主机=[%s], NUT监控目标=[%s], 主监控账户=[%s] (nut-server用户表与upsmon哨兵已全部同步生效)\n",
        now, en_str, wait_sec, vm_timeout, lb_str, esxi_host, target, user
    )
    local f = io.open(logfile, "a")
    if f then
        f:write(line)
        f:close()
    end
    sys.exec("ln -sf /etc/ups_manager/ups_events.log /var/log/ups_events.log 2>/dev/null")
end

m.on_after_save = sync_and_log_config
m.on_after_commit = sync_and_log_config

return m

