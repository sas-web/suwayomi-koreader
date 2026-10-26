-- Optional WireGuard tunnel to reach Suwayomi away from home (e.g. the e-reader on a phone's hotspot).
-- It uses `wireproxy`: a WireGuard client that needs neither special privileges nor a network interface, and
-- opens a local port connected to the server through the tunnel.
--
-- This module is an add-on: the plugin works without it. Copy it next to main.lua (inside suwayomi.koplugin/)
-- to enable it. Files expected in <KOReader data folder>/suwayomi_vpn/ (see vpn-addon/prepare_vpn.py):
--   wireproxy        the program (the build matching the e-reader's CPU, e.g. linux arm)
--   wireproxy.conf   the WireGuard profile of your home router/server + a [TCPClientTunnel] block

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local socket = require("socket")

local _ = require("suwayomi_i18n")

local Vpn = {
    active = false, -- the tunnel is currently the route to Suwayomi
    url = nil,      -- local address of the tunnel when `active`
    network = nil,  -- network (e.g. "192.168.43") on which the tunnel worked, to reuse it as is
}

local function vpnDir()
    local dir = DataStorage:getDataDir()
    if dir:sub(1, 1) ~= "/" then -- relative path (emulator)
        dir = lfs.currentdir() .. "/" .. dir:gsub("^%./", "")
    end
    return dir .. "/suwayomi_vpn"
end

function Vpn:paths()
    local dir = vpnDir()
    return {
        dir = dir,
        bin = dir .. "/wireproxy",
        conf = dir .. "/wireproxy.conf",
        pid = dir .. "/wireproxy.pid",
        log = dir .. "/wireproxy.log",
    }
end

function Vpn:isConfigured()
    local p = self:paths()
    return lfs.attributes(p.bin, "mode") == "file" and lfs.attributes(p.conf, "mode") == "file"
end

--- Local address of a tunnel according to the profile's [TCPClientTunnel] blocks: the one whose Target is
--- on port `target_port`, or the first block if no port is given.
function Vpn:tunnelUrl(target_port)
    local file = io.open(self:paths().conf, "r")
    if not file then return nil end
    local blocks, current = {}, nil
    for line in file:lines() do
        local section = line:match("^%s*%[(.-)%]")
        if section then
            current = (section == "TCPClientTunnel") and {} or nil
            if current then table.insert(blocks, current) end
        elseif current then
            local host, port = line:match("^%s*BindAddress%s*=%s*([%w%.%-]+):(%d+)")
            if host then current.bind = "http://" .. host .. ":" .. port end
            local target = line:match("^%s*Target%s*=%s*[%w%.%-]+:(%d+)")
            if target then current.target_port = tonumber(target) end
        end
    end
    file:close()
    for _i, block in ipairs(blocks) do
        if block.bind and (not target_port or block.target_port == target_port) then return block.bind end
    end
    return nil
end

--- Adds to the profile a tunnel to `target_url` if there is none yet, and returns its local address.
--- wireproxy does not re-read its profile while running: it is stopped here and will restart with the new block.
function Vpn:addTunnel(target_url)
    local host, port = target_url:match("^%a+://([%w%.%-]+):(%d+)")
    if not host then return nil end
    local existing = self:tunnelUrl(tonumber(port))
    if existing then return existing end
    local file = io.open(self:paths().conf, "a")
    if not file then return nil end
    file:write(string.format("\n[TCPClientTunnel]\nBindAddress = 127.0.0.1:%s\nTarget = %s:%s\n", port, host, port))
    file:close()
    logger.info("Suwayomi VPN: tunnel added to the profile for " .. host .. ":" .. port)
    if self:isRunning() then self:stop() end
    return "http://127.0.0.1:" .. port
end

local function readPid(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local pid = tonumber(file:read("*l"))
    file:close()
    return pid
end

function Vpn:isRunning()
    local pid = readPid(self:paths().pid)
    return pid ~= nil and lfs.attributes("/proc/" .. pid, "mode") == "directory"
end

--- Starts wireproxy in the background (no effect if it is already running).
function Vpn:start()
    if self:isRunning() then return true end
    local p = self:paths()
    os.remove(p.pid)
    os.execute(string.format(
        'chmod 755 "%s" 2>/dev/null; cd "%s" && ( ./wireproxy -c wireproxy.conf >wireproxy.log 2>&1 & echo $! > wireproxy.pid )',
        p.bin, p.dir))
    for _attempt = 1, 10 do
        if self:isRunning() then return true end
        socket.sleep(0.2)
    end
    return false
end

--- Stops wireproxy (if the plugin started it) and drops the tunnel.
function Vpn:stop()
    local p = self:paths()
    local pid = readPid(p.pid)
    if pid and lfs.attributes("/proc/" .. pid, "mode") == "directory" then
        os.execute("kill " .. pid)
        logger.info("Suwayomi VPN: tunnel stopped (pid " .. pid .. ")")
    end
    os.remove(p.pid)
    self.active = false
    self.url = nil
    self.network = nil
end

--- Last lines of wireproxy's log (without the timestamp), for error messages.
function Vpn:logTail(count)
    local file = io.open(self:paths().log, "r")
    if not file then return _("(no log)") end
    local lines = {}
    for line in file:lines() do
        line = line:gsub("^%a+: %d+/%d+/%d+ %d+:%d+:%d+ ", "")
        table.insert(lines, line:sub(1, 110))
        if #lines > count then table.remove(lines, 1) end
    end
    file:close()
    if #lines == 0 then return _("(empty log)") end
    return table.concat(lines, "\n")
end

--- Is the loopback (127.0.0.1) usable? The tunnel needs it: some e-readers leave it down.
function Vpn:loopbackUsable()
    local server = socket.tcp()
    local ok = server:bind("127.0.0.1", 0)
    server:close()
    return ok ~= nil
end

local function readFile(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local text = file:read("*a")
    file:close()
    return text
end

--- IPv4 addresses of this device, loopback included (read from the kernel's routing table).
function Vpn:localAddresses()
    local last, seen, addresses = nil, {}, {}
    for line in (readFile("/proc/net/fib_trie") or ""):gmatch("[^\n]+") do
        local ip = line:match("|%-%- (%d+%.%d+%.%d+%.%d+)")
        if ip then last = ip end
        if last and line:find("/32 host LOCAL", 1, true) and not seen[last] then
            seen[last] = true
            table.insert(addresses, last)
        end
    end
    return addresses
end

--- First address of the device that is not the loopback (the Wi-Fi one), or nil if it has none.
function Vpn:localAddress()
    for _i, ip in ipairs(self:localAddresses()) do
        if ip:sub(1, 4) ~= "127." then return ip end
    end
    return nil
end

--- Brings the loopback (127.0.0.1) up if it is down. PocketBook's firmware never does it, but its
--- /etc/sudoers lets the applications' user run /sbin/ifconfig as root without a password: we go through sudo.
--- Returns true if 127.0.0.1 is usable afterwards, and the output of the commands. Devices whose loopback is
--- already up (most of them) never get past the first line.
function Vpn:enableLoopback()
    if self:loopbackUsable() then return true, "" end
    local trace = {}
    local log = "/tmp/suwayomi_loopback.log"
    for _i, cmd in ipairs({
        "/ebrmain/bin/sudo -n /sbin/ifconfig lo 127.0.0.1 netmask 255.0.0.0 up",
        "sudo -n /sbin/ifconfig lo 127.0.0.1 netmask 255.0.0.0 up",
        "/sbin/ifconfig lo 127.0.0.1 netmask 255.0.0.0 up",
    }) do
        os.execute(string.format("%s </dev/null >%s 2>&1", cmd, log))
        local output = (readFile(log) or ""):gsub("%s+$", "")
        table.insert(trace, cmd:match("^%S+") .. ": " .. (output ~= "" and output:sub(1, 80) or _("(no output)")))
        if self:loopbackUsable() then
            logger.info("Suwayomi VPN: loopback brought up by \"" .. cmd .. "\"")
            os.remove(log)
            return true, ""
        end
    end
    os.remove(log)
    logger.warn("Suwayomi VPN: cannot bring the loopback up | " .. table.concat(trace, " | "))
    return false, table.concat(trace, "\n")
end

--- Does a connection to `ip` reach a test server opened on this very device?
local function selfConnect(ip)
    local server = socket.tcp()
    if not server:bind("*", 0) then
        server:close()
        return _("bind failed")
    end
    server:listen(1)
    local _host, port = server:getsockname()
    local client = socket.tcp()
    client:settimeout(2)
    local ok, err = client:connect(ip, port)
    client:close()
    server:close()
    return ok and _("ok") or string.format(_("failed (%s)"), tostring(err))
end

--- Report on the device's local network (interfaces, loopback, addresses), to understand why wireproxy
--- cannot open its port.
function Vpn:diagnose()
    local out = {}
    local names = {}
    for line in (readFile("/proc/net/dev") or ""):gmatch("[^\n]+") do
        local name = line:match("^%s*([%w%._%-]+):")
        if name then table.insert(names, name) end
    end
    table.insert(out, string.format(_("Interfaces: %s"),
        #names > 0 and table.concat(names, ", ") or _("(unreadable)")))
    local flags = (readFile("/sys/class/net/lo/flags") or "?"):gsub("%s+", "")
    local state = (readFile("/sys/class/net/lo/operstate") or "?"):gsub("%s+", "")
    table.insert(out, string.format(_("lo: flags %s (0x9 = up), state %s"), flags, state))
    local before = self:loopbackUsable()
    table.insert(out, string.format(_("127.0.0.1 before: bind %s"), before and _("ok") or _("IMPOSSIBLE")))
    if not before then
        local usable, trace = self:enableLoopback()
        table.insert(out, string.format(_("Bringing it up with sudo ifconfig: %s"),
            usable and _("SUCCEEDED") or (_("FAILED") .. "\n" .. trace)))
    end
    table.insert(out, string.format(_("127.0.0.1: bind %s, connection %s"),
        self:loopbackUsable() and _("ok") or _("IMPOSSIBLE"), selfConnect("127.0.0.1")))

    local addresses = self:localAddresses()
    for _i, ip in ipairs(addresses) do
        if ip:sub(1, 4) ~= "127." then
            table.insert(out, string.format(_("%s (this device): connection %s"), ip, selfConnect(ip)))
        end
    end
    table.insert(out, string.format(_("Local addresses: %s"),
        #addresses > 0 and table.concat(addresses, ", ") or _("none")))
    local text = table.concat(out, "\n")
    logger.info("Suwayomi VPN diagnostic: " .. text:gsub("\n", " | "))
    return text
end

--- Failure: keeps a trace in KOReader's log, stops the tunnel, returns nil and the message to display.
function Vpn:failure(reason)
    local state = (self:isRunning() and _("wireproxy: running") or _("wireproxy: stopped")) ..
        (self:loopbackUsable() and "" or ("\n" .. _("127.0.0.1 is unusable on this device")))
    local tail = self:logTail(4)
    logger.warn("Suwayomi VPN: " .. reason .. " | " .. state .. " | " .. (tail:gsub("\n", " / ")))
    self:stop()
    return nil, reason .. "\n\n" .. state .. "\n" .. tail
end

--- Starts the tunnel and waits until it lets traffic through to `target_url` (the Suwayomi server; the matching
--- tunnel is added to the profile if it is missing). `api:ping(url, timeout)` is used to check.
--- Returns the tunnel's local address, or nil and an error message.
function Vpn:connect(api, target_url)
    local port = target_url and tonumber(target_url:match("^%a+://[%w%.%-]+:(%d+)"))
    local url = self:tunnelUrl(port)
    if not url and target_url then url = self:addTunnel(target_url) end
    if not url then
        return nil, string.format(_("The VPN profile has no [TCPClientTunnel] block for %s."),
            tostring(target_url or _("this server")))
    end
    local usable, trace = self:enableLoopback()
    if not usable then
        return self:failure(_("The loopback (127.0.0.1) is down and could not be brought up.") .. "\n" .. trace)
    end
    local was_running = self:isRunning()
    if not self:start() then
        return self:failure(_("The wireproxy program does not start."))
    end
    if not was_running then
        -- Cold start: give the program a second before judging that it holds.
        socket.sleep(1)
        if not self:isRunning() then
            return self:failure(_("wireproxy stopped right after starting."))
        end
    end
    for _attempt = 1, 6 do
        if api:ping(url, 3) then
            logger.info("Suwayomi VPN: tunnel ready on " .. url)
            return url
        end
        socket.sleep(1)
    end
    return self:failure(_("The VPN tunnel does not answer: check the WireGuard profile, or the server is unreachable from this network."))
end

--- Network of an IPv4 address: its first three numbers ("192.168.43.7" -> "192.168.43").
local function networkOf(address)
    return address and (address:match("^(%d+%.%d+%.%d+)%.") or address) or "?"
end

--- Is the device (possibly) on the home network?
---   true  = possibly: the home server is tested (3 s lost if it is absent);
---   false = surely not: go straight to the VPN tunnel, without that test.
--- `local_address`: the device's IPv4 address, e.g. "192.168.1.159" (nil if it has none);
--- `server_host`:   host part of the server's address, e.g. "192.168.1.10" (or a machine name).
--- A wrong `true` only costs 3 s; a wrong `false` sends traffic through the tunnel although the home network
--- was reachable (the tunnel works too, but for nothing). Rule: same "/24" network as the server (first three
--- numbers identical); at the slightest doubt (no address, machine name, unexpected format) answer `true`.
function Vpn.isOnHomeNetwork(local_address, server_host)
    if not local_address or not server_host then return true end
    local mine = local_address:match("^(%d+%.%d+%.%d+)%.%d+$")
    local home = server_host:match("^(%d+%.%d+%.%d+)%.%d+$")
    if not mine or not home then return true end
    return mine == home
end

--- Route to `target_url`, a server at home: its direct address if the device can reach it, otherwise the
--- local address of the VPN tunnel. `api:ping(url, timeout)` tests whether the server answers at an address.
--- Returns the address to use, or nil and an error message.
function Vpn:routeTo(api, target_url)
    local address = self:localAddress()
    local network = networkOf(address)
    local maybe_home = Vpn.isOnHomeNetwork(address, target_url:match("^%a+://([^:/]+)"))
    if maybe_home then
        if api:ping(target_url, 3) then
            logger.info("Suwayomi VPN: " .. target_url .. " reachable directly (network " .. network .. ")")
            return target_url
        end
    else
        logger.info("Suwayomi VPN: network " .. network .. " is not home, direct test skipped")
    end

    local url, err = self:connect(api, target_url)
    if not url then
        -- The home test was skipped: last chance before giving up.
        if not maybe_home and api:ping(target_url, 3) then return target_url end
        return nil, err
    end
    return url
end

--- Chooses the route to Suwayomi and sets it on `api`: the local network if the server answers there,
--- otherwise the VPN tunnel (reused as is while the network does not change and the tunnel answers).
--- Returns true, or false and an error message.
function Vpn:ensureRoute(api, home_url)
    api:setServer(home_url)
    local network = networkOf(self:localAddress())

    -- Tunnel already open on this same network: reuse it without testing the home server again.
    if self.active and self.network == network and self:isRunning() and api:ping(self.url, 4) then
        api:setServer(self.url)
        logger.info("Suwayomi VPN: tunnel reused (network " .. network .. ")")
        return true
    end
    self.active, self.url, self.network = false, nil, nil

    local url, err = self:routeTo(api, home_url)
    if not url then return false, err end
    if url == home_url then
        self:stop() -- back home: the tunnel is no longer needed
        return true
    end
    self.active, self.url, self.network = true, url, network
    api:setServer(url)
    return true
end

return Vpn
