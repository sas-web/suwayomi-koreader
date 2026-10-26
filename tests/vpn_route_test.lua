-- Scenarios for the VPN add-on's route choice (vpn-addon/suwayomi_vpn.lua): home network, hotspot, tunnel reuse...
-- The add-on must be copied into plugins/suwayomi.koplugin first. Run from KOReader's base folder
-- (see tests/README.md):
--   ./luajit /path/to/tests/vpn_route_test.lua

package.path = "?.lua;common/?.lua;frontend/?.lua;plugins/suwayomi.koplugin/?.lua;" .. package.path
package.cpath = "common/?.so;libs/?.so;" .. package.cpath
require("setupkoenv")
local Vpn = require("suwayomi_vpn")

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
        return w.reachable[u] == true
    end
    Vpn.active, Vpn.url, Vpn.network = false, nil, nil
    Vpn.localAddress = function() return w.address end
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
