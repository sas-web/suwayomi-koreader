-- Scenarios for suwayomi_prefetch.lua, with every dependency replaced by a stand-in (no device, no server).
-- Run from KOReader's base folder with the plugin installed in plugins/suwayomi.koplugin (see tests/README.md):
--   ./luajit /path/to/tests/prefetch_test.lua

package.path = "plugins/suwayomi.koplugin/?.lua;" .. package.path
local Prefetch = require("suwayomi_prefetch")

local w, pf, queue
local function ctxFor(n)
    local chapters = {}
    for i = 1, n do chapters[i] = { id = i } end
    return { series = { title = "S" }, chapters = chapters }
end
local function pathOf(id) return "/m/S/Ch " .. id .. ".cbz" end

local function world(opts)
    opts = opts or {}
    w = {
        online = opts.online ~= false, files = {}, downloads = {}, warns = {}, wake_calls = 0,
        ensure_calls = 0, route_ok = opts.route_ok ~= false, fail = opts.fail or {}, wake_result = opts.wake_result,
        wake_interactive = nil, pending_cb = nil, pid = 0,
        pending = opts.pending == true, flush_ok = opts.flush_ok ~= false, flush_calls = 0,
        server = opts.server, server_error = opts.server_error, server_calls = 0, requests = {},
        request_ok = opts.request_ok ~= false, now = 0, busy_shown = 0, busy_hidden = 0, ensure_quiet = nil,
    }
    for _, id in ipairs(opts.present or {}) do w.files[pathOf(id)] = true end
    queue = {}
    pf = Prefetch.new({
        NetworkMgr = {
            isOnline = function() return w.online end,
            enableWifi = function(_, cb, interactive)
                w.wake_calls = w.wake_calls + 1
                w.wake_interactive = interactive
                if w.wake_result == false then return false end
                w.pending_cb = cb
                return true
            end,
        },
        UIManager = { scheduleIn = function(_, delay, fn) table.insert(queue, { delay = delay, fn = fn }) end },
        ffiutil = {
            runInSubProcess = function(fn) w.pid = w.pid + 1; fn(); return w.pid end, -- the "child" runs right away
            isSubProcessDone = function() return true end,
        },
        lfs = { attributes = function(path) return w.files[path] and "file" or nil end },
        logger = { info = function() end, warn = function(...) table.insert(w.warns, table.concat({ ... }, " ")) end },
        chapterPath = function(_, chapter) return pathOf(chapter.id) end,
        mkdirs = function() end,
        aheadCount = function() return 3 end,
        lowCount = function() return opts.low or 1 end, -- the Wi-Fi is woken up when 1 chapter or fewer is ready ahead
        showBusy = function()
            w.busy_shown = w.busy_shown + 1
            return function() w.busy_hidden = w.busy_hidden + 1 end
        end,
        ensureServer = function(quiet)
            w.ensure_quiet = quiet
            w.ensure_calls = w.ensure_calls + 1
            return w.route_ok, (not w.route_ok) and "SERVER DOWN\nline 2" or nil
        end,
        hasPendingProgress = function() return w.pending end,
        flushPendingProgress = function()
            w.flush_calls = w.flush_calls + 1
            if w.flush_ok then w.pending = false end
        end,
        -- Server side (only when the scenario describes what the server has): { [chapter_id] = boolean }
        serverHas = opts.server and function(ids)
            w.server_calls = w.server_calls + 1
            if w.server_error then return nil end
            local answer = {}
            for _, id in ipairs(ids) do
                if w.server[id] ~= nil then answer[id] = w.server[id] end
            end
            return answer
        end or nil,
        requestServer = opts.server and function(ids)
            table.insert(w.requests, table.concat(ids, ","))
            return w.request_ok
        end or nil,
        now = function() return w.now end,
        download = function(id, path)
            table.insert(w.downloads, id)
            if w.fail[id] then return nil, "HTTP 500" end
            w.files[path] = true
            return path
        end,
    })
end
local function drain() local n = 0; while #queue > 0 and n < 300 do n = n + 1; table.remove(queue, 1).fn() end end
local function list(t) return table.concat(t, ",") end

local failures = 0
local function check(name, cond, detail)
    print(string.format("%s  %s%s", cond and "OK  " or "FAIL", name, (not cond and detail) and ("  -> " .. detail) or ""))
    if not cond then failures = failures + 1 end
end

local ctx = ctxFor(10)

-- P1: online, nothing ahead yet: the next three chain one after the other
world(); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3); drain()
check("P1 online: chapters 4, 5, 6 downloaded in order", list(w.downloads) == "4,5,6", list(w.downloads))
check("P1 no Wi-Fi wake-up, no route recheck", w.wake_calls == 0 and w.ensure_calls == 0)

-- P2: Wi-Fi turned off when the chapter was opened
world({ online = false }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3)
check("P2 Wi-Fi off: one wake-up requested, without any interface", w.wake_calls == 1 and w.wake_interactive == false and #w.downloads == 0)
pf:start(ctx, 3)
check("P2 a second call during the wake-up does not start another one", w.wake_calls == 1, tostring(w.wake_calls))
w.online = true; w.pending_cb(); drain()
check("P2 once online: route rechecked once, then 4, 5, 6 downloaded", w.ensure_calls == 1 and list(w.downloads) == "4,5,6", w.ensure_calls .. " | " .. list(w.downloads))

-- P3: the wake-up fails right away
world({ online = false, wake_result = false }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3); pf:start(ctx, 3)
check("P3 wake-up refused: no deadlock, another attempt is possible", w.wake_calls == 2 and #w.downloads == 0, tostring(w.wake_calls))

-- P4: a chapter always fails
world({ fail = { [4] = true } }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3); drain()
local tries4 = 0; for _, id in ipairs(w.downloads) do if id == 4 then tries4 = tries4 + 1 end end
check("P4 failing chapter: only 2 attempts", tries4 == 2, tostring(tries4))
check("P4 the following ones (5, 6) are still downloaded", w.files[pathOf(5)] and w.files[pathOf(6)] and not w.files[pathOf(4)])
check("P4 failures are logged", #w.warns >= 2, tostring(#w.warns))

-- P5: the chapter is left while the Wi-Fi is waking up
world({ online = false }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3); pf:endReading(3)
w.online = true; w.pending_cb(); drain()
check("P5 reading ended before the connection: nothing is downloaded", #w.downloads == 0, list(w.downloads))

-- P6: the route to Suwayomi cannot be found after the wake-up
world({ online = false, route_ok = false }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3)
w.online = true; w.pending_cb(); drain()
check("P6 server unreachable: no download, a single-line error", #w.downloads == 0 and w.warns[1] and not w.warns[1]:find("\n", 1, true), tostring(w.warns[1]))

-- P7: everything is already there, even offline
world({ online = false, present = { 4, 5, 6 } }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3)
check("P7 full window offline: the Wi-Fi is not woken up for nothing", w.wake_calls == 0 and #w.downloads == 0)

-- P8: the user opens a chapter that is being downloaded
world(); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3)
check("P8 running download detected", pf:isFetching(4) == true and pf:isFetching(5) == false)
pf:wait(4)
check("P8 after waiting, nothing is running any more", pf:isFetching(4) == false)

-- P9: end of the series: nothing past the last chapter
world(); local short = ctxFor(5); pf:beginReading(short, 4, 4); pf:start(short, 4); drain()
check("P9 last chapter: only chapter 5 is downloaded", list(w.downloads) == "5", list(w.downloads))

-- P10: pending progress, full window, Wi-Fi off: the Wi-Fi is not woken up just to send it
world({ online = false, present = { 4, 5, 6 }, pending = true }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3)
check("P10 nothing to download, Wi-Fi off: no wake-up, progress still pending",
    w.wake_calls == 0 and w.flush_calls == 0 and w.pending == true, w.wake_calls .. " | " .. w.flush_calls)
w.online = true; pf:start(ctx, 3)
check("P10 as soon as the Wi-Fi is on (for another reason): progress sent, nothing downloaded",
    w.flush_calls == 1 and w.pending == false and #w.downloads == 0, w.flush_calls .. " | " .. list(w.downloads))

-- P10b: pending progress and the buffer is low (1 chapter ready of 3), Wi-Fi off: the wake-up serves both
world({ online = false, present = { 4 }, pending = true }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3)
check("P10b buffer low: the Wi-Fi is woken up (once)", w.wake_calls == 1 and w.flush_calls == 0)
w.online = true; w.pending_cb(); drain()
check("P10b once online: route rechecked, progress sent, then chapters 5 and 6 downloaded",
    w.ensure_calls == 1 and w.flush_calls == 1 and w.pending == false and list(w.downloads) == "5,6",
    w.ensure_calls .. " | " .. w.flush_calls .. " | " .. list(w.downloads))

-- P10c: pending progress but enough chapters ahead (2 of 3 ready), Wi-Fi off: no wake-up just to send it
world({ online = false, present = { 4, 5 }, pending = true }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3)
check("P10c buffer fine: the Wi-Fi is left alone, progress waits", w.wake_calls == 0 and w.pending == true, tostring(w.wake_calls))

-- P11: online with pending progress and chapters to download: send first, then 4, 5, 6
world({ pending = true }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3); drain()
check("P11 online: progress sent once, then 4, 5, 6 downloaded",
    w.flush_calls == 1 and list(w.downloads) == "4,5,6", w.flush_calls .. " | " .. list(w.downloads))
check("P11 no needless wake-up", w.wake_calls == 0)

-- P12: the server refuses the upload: one attempt per opportunity (no stall at every chapter)
world({ pending = true, flush_ok = false }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3); drain()
check("P12 failing upload: one attempt only, prefetching goes on", w.flush_calls == 1 and list(w.downloads) == "4,5,6", w.flush_calls .. " | " .. list(w.downloads))
pf:beginReading(ctx, 3, 3); pf:start(ctx, 3)
check("P12 at the next chapter a new attempt is allowed", w.flush_calls == 2, tostring(w.flush_calls))

-- P13: server unreachable after the wake-up: nothing is sent or downloaded
world({ online = false, pending = true, route_ok = false }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3)
w.online = true; w.pending_cb(); drain()
check("P13 server unreachable: nothing sent, progress still pending", w.flush_calls == 0 and w.pending == true)

-- P14: nothing pending, full window, offline: the Wi-Fi stays off (non-regression of P7)
world({ online = false, present = { 4, 5, 6 }, pending = false }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3)
check("P14 nothing to send or download: Wi-Fi left off", w.wake_calls == 0 and w.flush_calls == 0)

-- P15: the server has chapters 5 and 6 but not 4: it is asked for 4 (once), 5 and 6 are fetched meanwhile
world({ server = { [4] = false, [5] = true, [6] = true } }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3); drain()
check("P15 server lacks chapter 4: asked once for it", list(w.requests) == "4", list(w.requests))
check("P15 the chapters the server has (5, 6) are fetched meanwhile", list(w.downloads) == "5,6", list(w.downloads))

-- P16: the server has none of them: all three are requested, nothing is fetched, a check is scheduled in 10 s
world({ server = { [4] = false, [5] = false, [6] = false } }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3)
check("P16 server lacks everything: one request for 4, 5, 6", list(w.requests) == "4,5,6", list(w.requests))
check("P16 nothing is fetched yet", #w.downloads == 0)
check("P16 a check of the server is scheduled in 10 s", queue[1] and queue[1].delay == 10, queue[1] and tostring(queue[1].delay) or "none")
w.server[4] = true; drain()
check("P16 once the server has chapter 4, it is fetched by the scheduled check", list(w.downloads) == "4", list(w.downloads))

-- P17: the server does not answer: the usual attempt is made (as without server-side support)
world({ server = {}, server_error = true }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3); drain()
check("P17 server silent: chapters are simply attempted", list(w.downloads) == "4,5,6" and #w.requests == 0, list(w.downloads))

-- P18: the same chapters are not requested again before the delay, but are after it
-- (the server has none of them, so no download is running and every start() reaches the server)
world({ server = { [4] = false, [5] = false, [6] = false } }); pf:beginReading(ctx, 3, 3); w.now = 0; pf:start(ctx, 3)
w.now = 100; pf:start(ctx, 3)
check("P18 no new request after 100 s", #w.requests == 1, tostring(#w.requests))
w.now = 700; pf:start(ctx, 3)
check("P18 asked again after 700 s", #w.requests == 2, tostring(#w.requests))

-- P19: a scheduled check never wakes the Wi-Fi up
world({ server = { [4] = false, [5] = false, [6] = false } }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3)
w.online = false; drain()
check("P19 Wi-Fi turned off while waiting: no wake-up, no request", w.wake_calls == 0 and #w.requests == 1, w.wake_calls .. " | " .. #w.requests)

-- P20: the checks stop after a while (about ten minutes of waiting)
world({ server = { [4] = false, [5] = false, [6] = false } }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3); drain()
check("P20 at most 20 scheduled checks (21 questions to the server in all)", w.server_calls == 21, tostring(w.server_calls))

-- P21: reading ends while a check is scheduled: nothing more happens
world({ server = { [4] = false, [5] = false, [6] = false } }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3)
pf:endReading(3); w.server[4] = true; drain()
check("P21 reading ended: the scheduled check does nothing", #w.downloads == 0 and w.server_calls == 1, #w.downloads .. " | " .. w.server_calls)

-- P22: the request itself fails (network): the chapters are not marked as requested, so they are asked again next time
world({ server = { [4] = false, [5] = false, [6] = false }, request_ok = false }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3)
check("P22 the first request failed", #w.requests == 1)
w.request_ok = true; pf:start(ctx, 3)
check("P22 failed request: asked again at the next opportunity", #w.requests == 2, tostring(#w.requests))
pf:start(ctx, 3)
check("P22 and, once it went through, not asked a third time", #w.requests == 2, tostring(#w.requests))

-- P23: enough chapters ahead: the Wi-Fi is left alone; running low wakes it up; already on: the window is filled
world({ online = false, present = { 4, 5 } }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3)
check("P23 two of three chapters ready: no wake-up", w.wake_calls == 0 and #w.downloads == 0, tostring(w.wake_calls))
world({ online = false, present = { 4 } }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3)
check("P23 only one of three ready (low): the Wi-Fi is woken up", w.wake_calls == 1, tostring(w.wake_calls))
world({ online = true, present = { 4, 5 } }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3); drain()
check("P23 Wi-Fi already on: the window is filled whatever the buffer", list(w.downloads) == "6", list(w.downloads))

-- P24: waking the Wi-Fi up explains the frozen screen with a message
world({ online = false }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3)
check("P24 waking the Wi-Fi up shows the message once and hides it when the call returns",
    w.busy_shown == 1 and w.busy_hidden == 1, w.busy_shown .. " | " .. w.busy_hidden)
world({ online = true }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3); drain()
check("P24 no message when the Wi-Fi is already on", w.busy_shown == 0)
world({ online = false, wake_result = false }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3)
check("P24 refused wake-up: the message is hidden as well", w.busy_shown == 1 and w.busy_hidden == 1)

-- P25: the route to the server is checked quietly (the VPN add-on never starts a tunnel in the background)
world({ online = false }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3); w.online = true; w.pending_cb(); drain()
check("P25 route checked in quiet mode", w.ensure_quiet == true and w.ensure_calls == 1, tostring(w.ensure_quiet))

-- P26: route unreachable after the wake-up: checked again soon, then the chapters are fetched
world({ online = false, route_ok = false }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3); w.online = true; w.pending_cb()
local rechecking = false
for _, item in ipairs(queue) do if item.delay == 10 then rechecking = true end end
check("P26 route unreachable: a new check is scheduled in 10 s", rechecking and #w.downloads == 0)
w.route_ok = true; drain()
check("P26 once the server answers, the chapters are fetched", list(w.downloads) == "4,5,6", list(w.downloads))

-- P27: the checks of the server come after 10 s, then 20 s, then every 30 s
world({ server = { [4] = false, [5] = false, [6] = false } }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3)
local delays = {}
for _ = 1, 5 do
    local item = table.remove(queue, 1)
    if not item then break end
    delays[#delays + 1] = item.delay
    item.fn()
end
check("P27 checks after 10 s, 20 s, then 30 s", list(delays) == "10,20,30,30,30", list(delays))

-- P28: a failed download is retried without waking the Wi-Fi up
world({ fail = { [4] = true } }); pf:beginReading(ctx, 3, 3); pf:start(ctx, 3); w.online = false; drain()
check("P28 retry after a failure never wakes the Wi-Fi up", w.wake_calls == 0, tostring(w.wake_calls))

print(failures == 0 and "\nALL PREFETCH SCENARIOS PASS" or ("\n" .. failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
