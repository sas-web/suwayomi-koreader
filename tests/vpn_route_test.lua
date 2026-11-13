-- Scenarios for the VPN add-on's route choice (vpn-addon/suwayomi_vpn.lua): home network, hotspot, tunnel reuse...
-- The add-on must be copied into plugins/suwayomi.koplugin first. Run from KOReader's base folder
-- (see tests/README.md):
--   ./luajit /path/to/tests/vpn_route_test.lua

package.path = "?.lua;common/?.lua;frontend/?.lua;plugins/suwayomi.koplugin/?.lua;" .. package.path
package.cpath = "common/?.so;libs/?.so;" .. package.cpath
require("setupkoenv")
local Vpn = require("suwayomi_vpn")
local socket = require("socket")
socket.sleep = function() end -- the pauses between tries are not worth waiting for in a test
local real = { identity = Vpn.networkIdentity, home = Vpn.homeNetwork, remember = Vpn.rememberHomeNetwork }

local HOME, TUNNEL = "http://192.168.1.10:4567", "http://127.0.0.1:4567"
local OTHER = "http://192.168.1.10:8765" -- another service on the same home machine
-- The rule tested here is the one shipped with the add-on (Vpn.isOnHomeNetwork), not a replacement.

local w, api
local function world(address)
    w = { reachable = {}, calls = {}, running = false, connects = 0, stops = 0, address = address, connect_ok = true }
    api = { server = nil }
    function api:setServer(u) self.server = u end
    function api:ping(u, t)
        table.insert(w.calls, "ping " .. ((u == HOME or u == OTHER) and "home" or "tunnel") .. " " .. t)
        local reachable = w.reachable[u]
        if type(reachable) == "function" then reachable = reachable(#w.calls) end -- answers depending on the try
        return reachable == true
    end
    Vpn.active, Vpn.url, Vpn.network = false, nil, nil
    Vpn.localAddress = function() return w.address end
    -- The router's identity and the remembered home network (unknown unless a scenario sets them)
    Vpn.networkIdentity = function() return w.identity end
    Vpn.homeNetwork = function() return w.home end
    Vpn.rememberHomeNetwork = function(_, id) if id and id ~= w.home then w.home = id; w.remembered = id end end
    Vpn.isRunning = function() return w.running end
    Vpn.stop = function(self) w.stops = w.stops + 1; w.running = false; self.active, self.url, self.network = false, nil, nil end
    Vpn.connect = function(self, a, target)
        w.connects = w.connects + 1
        w.last_target = target
        table.insert(w.calls, "connect")
        if not w.connect_ok then return nil, "TUNNEL FAILED" end
        w.running = true
        return (target and target:match(":8765$")) and "http://127.0.0.1:8765" or TUNNEL
    end
end

local failures = 0
local function check(name, cond, detail)
    print(string.format("%s  %s%s", cond and "OK  " or "FAIL", name, (not cond and detail) and ("  -> " .. detail) or ""))
    if not cond then failures = failures + 1 end
end
local function calls() return table.concat(w.calls, " | ") end

-- S1: at home
world("192.168.1.159"); w.reachable[HOME] = true
local ok = Vpn:ensureRoute(api, HOME)
check("S1 home: direct server, only the home test is done", ok and api.server == HOME and calls() == "ping home 3" and w.connects == 0, calls())
check("S1 home: any tunnel is stopped", w.stops == 1)

-- S2: away from home, first opening
world("192.168.43.7"); w.reachable[TUNNEL] = true
ok = Vpn:ensureRoute(api, HOME)
check("S2 away, 1st opening: home test SKIPPED, tunnel started", ok and api.server == TUNNEL and calls() == "connect" and Vpn.network == "192.168.43", calls())

-- S3: away from home, 2nd opening, same network
w.calls = {}
ok = Vpn:ensureRoute(api, HOME)
check("S3 2nd opening: tunnel reused, a single test (tunnel), no new start", ok and api.server == TUNNEL and calls() == "ping tunnel 4" and w.connects == 1, calls())

-- S4: the network changes (another hotspot)
w.calls = {}; w.address = "172.20.10.2"
ok = Vpn:ensureRoute(api, HOME)
check("S4 network changed: not reused blindly, goes through connect", ok and calls() == "connect" and Vpn.network == "172.20.10", calls())

-- S5: the tunnel fails but the home server answers (unexpected route)
world("192.168.43.7"); w.connect_ok = false; w.reachable[HOME] = true
ok = Vpn:ensureRoute(api, HOME)
check("S5 tunnel down but home reachable: falls back to home", ok and api.server == HOME and calls() == "connect | ping home 3", calls())

-- S6: everything fails
world("192.168.43.7"); w.connect_ok = false
local ok6, err6 = Vpn:ensureRoute(api, HOME)
check("S6 all down: the tunnel's error is returned", ok6 == false and err6 == "TUNNEL FAILED", tostring(err6))

-- S7: someone else's Wi-Fi also in 192.168.1.x (ambiguous): home is tested, then the tunnel
world("192.168.1.200"); w.reachable[TUNNEL] = true
ok = Vpn:ensureRoute(api, HOME)
check("S7 ambiguous network: home test (3 s) then tunnel", ok and api.server == TUNNEL and calls() == "ping home 3 | connect", calls())

-- S8: back home with a tunnel open on another network
world("192.168.43.7"); w.reachable[TUNNEL] = true
Vpn:ensureRoute(api, HOME)
w.calls = {}; w.address = "192.168.1.159"; w.reachable[HOME] = true
ok = Vpn:ensureRoute(api, HOME)
check("S8 back home: home test, tunnel stopped, direct server", ok and api.server == HOME and calls() == "ping home 3" and w.running == false and Vpn.active == false, calls())

-- S9: tunnel supposed to work but dead (same network)
world("192.168.43.7"); w.reachable[TUNNEL] = true
Vpn:ensureRoute(api, HOME)
w.calls = {}; w.reachable[TUNNEL] = false
local before = w.connects
ok = Vpn:ensureRoute(api, HOME)
check("S9 stale tunnel: short tunnel test, then reconnection", calls() == "ping tunnel 4 | connect" and w.connects == before + 1, calls())

-- S10: the rule alone, on a table of addresses (expected: maybe home? true/false)
local rule_cases = {
    { "192.168.1.159", "192.168.1.10", true,  "home Wi-Fi" },
    { "192.168.1.200", "192.168.1.10", true,  "someone else's Wi-Fi also in 192.168.1.x (ambiguous)" },
    { "192.168.43.7",  "192.168.1.10", false, "classic Android hotspot" },
    { "192.168.212.9", "192.168.1.10", false, "random Android hotspot 192.168.x" },
    { "172.20.10.2",   "192.168.1.10", false, "iPhone hotspot" },
    { "10.12.0.4",     "192.168.1.10", false, "10.x network" },
    { nil,             "192.168.1.10", true,  "device without an address: test" },
    { "192.168.1.159", "suwayomi.local", true, "server given by name: test" },
    { "192.168.1.159", nil,            true,  "unknown host: test" },
    { "fe80::1",       "192.168.1.10", true,  "unexpected address: test" },
    { "192.168.1.159", "192.168.2.10", false, "server in another /24" },
}
for _, c in ipairs(rule_cases) do
    local got = Vpn.isOnHomeNetwork(c[1], c[2])
    check(string.format("S10 rule: %-55s -> %s", c[4], tostring(c[3])), got == c[3], "got " .. tostring(got))
end

-- N: the home network is recognised by its router
local HOME_NET, OTHER_NET = "192.168.1.254@aa:bb:cc:dd:ee:01", "10.0.0.1@aa:bb:cc:dd:ee:02"

world("192.168.1.159"); w.identity, w.home = HOME_NET, HOME_NET
w.reachable[HOME] = function(n) return n >= 2 end -- the network is still settling: the first try fails
ok = Vpn:ensureRoute(api, HOME)
check("N1 home network, first try fails: tried again, no tunnel", ok and api.server == HOME and w.connects == 0 and calls() == "ping home 2 | ping home 2", calls())

world("192.168.1.159"); w.identity, w.home = HOME_NET, HOME_NET
local okn, errn = Vpn:ensureRoute(api, HOME)
check("N2 home network, server silent: three tries, an error, never a tunnel", okn == false and w.connects == 0 and calls() == "ping home 2 | ping home 2 | ping home 2", calls())

world("192.168.1.200"); w.identity, w.home = OTHER_NET, HOME_NET; w.reachable[TUNNEL] = true
ok = Vpn:ensureRoute(api, HOME)
check("N3 another network (even with a similar address): home test skipped, straight to the tunnel", ok and api.server == TUNNEL and calls() == "connect", calls())

world("192.168.1.159"); w.identity = HOME_NET; w.reachable[HOME] = true
ok = Vpn:ensureRoute(api, HOME)
check("N4 home reached directly on an unknown network: the router is remembered", ok and w.remembered == HOME_NET and w.home == HOME_NET)

world("192.168.43.7"); w.identity, w.home = OTHER_NET, HOME_NET; w.connect_ok = false; w.reachable[HOME] = true
ok = Vpn:ensureRoute(api, HOME)
check("N5 new router at home (tunnel fails, direct works): the new router is remembered",
    ok and api.server == HOME and w.remembered == OTHER_NET and calls() == "connect | ping home 3", calls())

world("192.168.1.159"); w.identity, w.home = HOME_NET, HOME_NET; w.reachable[HOME] = true
ok = Vpn:ensureRoute(api, HOME, true)
check("N6 background check at home: a single short try", ok and calls() == "ping home 2", calls())

world("192.168.43.7"); w.identity, w.home = OTHER_NET, HOME_NET
okn = Vpn:ensureRoute(api, HOME, true)
check("N7 background check elsewhere without a tunnel: nothing tried, no tunnel started", okn == false and calls() == "" and w.connects == 0, calls())

world("192.168.43.7"); w.reachable[HOME] = false
okn = Vpn:ensureRoute(api, HOME, true)
check("N8 background check on an unknown network: one short try, no tunnel", okn == false and calls() == "ping home 2" and w.connects == 0, calls())

world("192.168.43.7"); w.reachable[TUNNEL] = true
Vpn:ensureRoute(api, HOME)
w.calls = {}
ok = Vpn:ensureRoute(api, HOME, true)
check("N9 background check with the tunnel already open: reused after a short test", ok and api.server == TUNNEL and calls() == "ping tunnel 2" and w.connects == 1, calls())

-- N9b: a background check reuses a working tunnel even if the Wi-Fi network changed (another hotspot)...
world("192.168.43.7"); w.reachable[TUNNEL] = true
Vpn:ensureRoute(api, HOME)
w.calls = {}; w.address = "172.20.10.2"
ok = Vpn:ensureRoute(api, HOME, true)
check("N9b background check, network changed: the working tunnel is reused, no new tunnel",
    ok and api.server == TUNNEL and calls() == "ping tunnel 2" and w.connects == 1 and Vpn.network == "172.20.10", calls())
-- ... while an interactive check does not trust it blindly (see S4)
w.calls = {}; w.address = "10.5.0.9"
ok = Vpn:ensureRoute(api, HOME)
check("N9b interactive check, network changed again: goes through connect", ok and calls() == "connect", calls())

-- N10: reading the router's identity from (fake) kernel tables
local function writeFile(path, text) local f = io.open(path, "w"); f:write(text); f:close() end
local routes, arps = os.tmpname(), os.tmpname()
Vpn.route_table, Vpn.arp_table = routes, arps
local function identity() return real.identity(Vpn) end
writeFile(routes, "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n" ..
    "eth0\t00000000\tFE01A8C0\t0003\t0\t0\t0\t00000000\t0\t0\t0\n" ..
    "eth0\t0001A8C0\t00000000\t0001\t0\t0\t0\t00FFFFFF\t0\t0\t0\n")
writeFile(arps, "IP address       HW type     Flags       HW address            Mask     Device\n" ..
    "192.168.1.254    0x1         0x2         A4:B1:C2:D3:E4:F5     *        eth0\n")
check("N10 the router is read from the routing and ARP tables", identity() == "192.168.1.254@a4:b1:c2:d3:e4:f5", tostring(identity()))
writeFile(arps, "IP address       HW type     Flags       HW address            Mask     Device\n" ..
    "192.168.1.254    0x1         0x0         00:00:00:00:00:00     *        eth0\n")
check("N10 an unresolved ARP entry gives no identity", identity() == nil, tostring(identity()))
writeFile(arps, "IP address       HW type     Flags       HW address            Mask     Device\n" ..
    "192.168.1.77     0x1         0x2         A4:B1:C2:D3:E4:AA     *        eth0\n")
check("N10 a router that is not in the ARP table gives no identity", identity() == nil, tostring(identity()))
writeFile(routes, "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n" ..
    "eth0\t0001A8C0\t00000000\t0001\t0\t0\t0\t00FFFFFF\t0\t0\t0\n")
check("N10 no default route gives no identity", identity() == nil, tostring(identity()))
os.remove(routes); os.remove(arps)

-- N11: the home network is remembered in a file, written only when it changes
local paths_home = Vpn:paths()
os.execute("mkdir -p '" .. paths_home.dir .. "'")
os.remove(paths_home.home)
check("N11 nothing remembered at first", real.home(Vpn) == nil)
real.remember(Vpn, HOME_NET)
check("N11 the home router is remembered", real.home(Vpn) == HOME_NET, tostring(real.home(Vpn)))
real.remember(Vpn, OTHER_NET)
check("N11 a new home router replaces it", real.home(Vpn) == OTHER_NET, tostring(real.home(Vpn)))
real.remember(Vpn, nil)
check("N11 an unknown identity is never remembered", real.home(Vpn) == OTHER_NET)
os.remove(paths_home.home)

-- N12: what the tunnel costs (age, CPU time, memory) is read from /proc
local fake = os.tmpname(); os.remove(fake); os.execute("mkdir -p '" .. fake .. "/4242'")
Vpn.proc_dir = fake
writeFile(fake .. "/uptime", "5000.50 9000.00\n")
-- stat: pid (name) state ppid pgrp session tty tpgid flags minflt cminflt majflt cmajflt utime stime cutime cstime
--       priority nice threads itrealvalue starttime ...
writeFile(fake .. "/4242/stat", "4242 (wire) proxy) S 1 4242 4242 0 -1 4194560 100 0 0 0 1234 567 0 0 20 0 8 0 200000 12345678 3000\n")
writeFile(fake .. "/4242/status", "Name:\twireproxy\nVmRSS:\t   20480 kB\n")
writeFile(paths_home.dir .. "/wireproxy.pid", "4242\n")
local minutes, cpu, memory = Vpn:usage()
check("N12 age, CPU time and memory of the tunnel (even if the process name holds a parenthesis)",
    minutes == 50 and math.abs(cpu - 18.01) < 0.001 and memory == 20, tostring(minutes) .. " | " .. tostring(cpu) .. " | " .. tostring(memory))
os.remove(paths_home.dir .. "/wireproxy.pid")
check("N12 no pid file: not running", Vpn:usage() == nil)
writeFile(paths_home.dir .. "/wireproxy.pid", "9999\n")
check("N12 a process that has no /proc entry: not running", Vpn:usage() == nil)
os.remove(paths_home.dir .. "/wireproxy.pid")
Vpn.proc_dir = "/proc"
os.execute("rm -rf '" .. fake .. "'")

-- T: one tunnel per server in the profile (real tunnelUrl / addTunnel on a fake profile)
local paths = Vpn:paths()
os.execute("mkdir -p '" .. paths.dir .. "'")
local function writeConf(text) local f = io.open(paths.conf, "w"); f:write(text); f:close() end
local function confText() local f = io.open(paths.conf, "r"); local t = f:read("*a"); f:close(); return t end
local function blocks() return select(2, confText():gsub("%[TCPClientTunnel%]", "")) end
writeConf("[Interface]\nPrivateKey = X\nAddress = 10.0.0.2/32\n\n[Peer]\nPublicKey = Y\nEndpoint = 1.2.3.4:51820\nAllowedIPs = 192.168.1.0/24\n\n[TCPClientTunnel]\nBindAddress = 127.0.0.1:4567\nTarget = 192.168.1.10:4567\n")
check("T1 tunnelUrl(): first block", Vpn:tunnelUrl() == "http://127.0.0.1:4567")
check("T1 tunnelUrl(4567): the Suwayomi block", Vpn:tunnelUrl(4567) == "http://127.0.0.1:4567")
check("T1 tunnelUrl(8765): absent", Vpn:tunnelUrl(8765) == nil)
world("192.168.1.159"); w.running = true
local added = Vpn:addTunnel(OTHER)
check("T2 addTunnel returns the new tunnel's local address", added == "http://127.0.0.1:8765", tostring(added))
check("T2 the profile now has 2 blocks", blocks() == 2)
check("T2 wireproxy stopped so that it re-reads the profile", w.stops == 1)
check("T2 each port finds its block", Vpn:tunnelUrl(8765) == added and Vpn:tunnelUrl(4567) == "http://127.0.0.1:4567")
w.running = true; w.stops = 0
check("T3 addTunnel is idempotent (no duplicate, no stop)", Vpn:addTunnel(OTHER) == added and blocks() == 2 and w.stops == 0)
check("T3 the rest of the profile is untouched", confText():find("PrivateKey = X", 1, true) ~= nil and confText():find("Endpoint = 1.2.3.4:51820", 1, true) ~= nil)
writeConf("[TCPClientTunnel]\nBindAddress = 127.0.0.1:9000\nTarget = 192.168.1.10:8765\n")
check("T4 local port different from the target's port", Vpn:tunnelUrl(8765) == "http://127.0.0.1:9000")
os.remove(paths.conf)

-- U: route to another service on the home machine (same rules as for Suwayomi, without touching its state)
world("192.168.1.159"); w.reachable[OTHER] = true
local u1 = Vpn:routeTo(api, OTHER)
check("U1 home: direct address", u1 == OTHER and calls() == "ping home 3", calls())
world("192.168.43.7")
local u2 = Vpn:routeTo(api, OTHER)
check("U2 away: that service's own tunnel (home test skipped)", u2 == "http://127.0.0.1:8765" and calls() == "connect" and w.last_target == OTHER, calls())
check("U2 the Suwayomi route is not modified", Vpn.active == false and Vpn.url == nil)
world("192.168.43.7"); w.connect_ok = false; w.reachable[OTHER] = true
check("U3 tunnel down but machine reachable: direct fallback", Vpn:routeTo(api, OTHER) == OTHER and calls() == "connect | ping home 3", calls())
world("192.168.43.7"); w.connect_ok = false
local u4, e4 = Vpn:routeTo(api, OTHER)
check("U4 all down: error returned", u4 == nil and e4 == "TUNNEL FAILED", tostring(e4))

print(failures == 0 and "\nALL VPN ROUTE SCENARIOS PASS" or ("\n" .. failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
