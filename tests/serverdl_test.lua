-- Scenarios for suwayomi_serverdl.lua (asking the server to download a chapter and waiting for it), with a fake
-- scheduler, clock and API (no server). Run from KOReader's base folder with the plugin installed in
-- plugins/suwayomi.koplugin (see tests/README.md):
--   ./luajit /path/to/tests/serverdl_test.lua

package.path = "plugins/suwayomi.koplugin/?.lua;" .. package.path
local ServerDownload = require("suwayomi_serverdl")

local w, queue, sd, done, updates

local function world(opts)
    opts = opts or {}
    w = {
        clock = 0, request_ok = opts.request_ok ~= false, requests = {}, starts = 0,
        script = opts.script or {}, polls = 0,
    }
    queue, done, updates = {}, nil, {}
    sd = ServerDownload.new({
        UIManager = { scheduleIn = function(_, delay, fn) table.insert(queue, { delay = delay, fn = fn }) end },
        now = function() return w.clock end,
        api = {
            requestDownloads = function(_, ids, urgent)
                table.insert(w.requests, table.concat(ids, ",") .. (urgent and " urgent" or ""))
                if not w.request_ok then return nil, "NO ROUTE" end
                return true
            end,
            -- the script lists the answers of successive checks ("SILENT" = no answer); the last one repeats
            serverDownloadState = function()
                w.polls = w.polls + 1
                local answer = w.script[math.min(w.polls, #w.script)]
                if answer == nil or answer == "SILENT" then return nil, "SILENT" end
                return answer
            end,
            startDownloader = function() w.starts = w.starts + 1; return true end,
        },
    })
end

-- runs the scheduled checks one after the other (2 s apart), up to `limit` of them
local function run(limit)
    local count = 0
    while #queue > 0 and count < (limit or 1000) and not done do
        count = count + 1
        local item = table.remove(queue, 1)
        w.clock = w.clock + item.delay
        item.fn()
    end
end

local function request()
    return sd:request(11, {
        on_update = function(info) table.insert(updates, info.state .. ":" .. string.format("%.1f", info.progress)) end,
        on_done = function(ok, reason, detail) done = { ok = ok, reason = reason, detail = detail } end,
    })
end

local failures = 0
local function check(name, cond, detail)
    print(string.format("%s  %s%s", cond and "OK  " or "FAIL", name, (not cond and detail) and ("  -> " .. detail) or ""))
    if not cond then failures = failures + 1 end
end
local function queued(progress) return { downloaded = false, manager = "STARTED", entry = { state = "DOWNLOADING", progress = progress, tries = 0 } } end
local function ready() return { downloaded = true, manager = "STARTED" } end

-- D1: the nominal case
world({ script = { { downloaded = false, manager = "STARTED", entry = { state = "QUEUED", progress = 0, tries = 0 } }, queued(0.4), queued(0.8), ready() } })
request(); run()
check("D1 requested once, urgently", #w.requests == 1 and w.requests[1] == "11 urgent", w.requests[1])
check("D1 done and ready", done and done.ok == true)
check("D1 progress reported (queued, then downloading)", table.concat(updates, " ") == "QUEUED:0.0 DOWNLOADING:0.4 DOWNLOADING:0.8", table.concat(updates, " "))

-- D2: the request itself fails
world({ request_ok = false })
request()
check("D2 request failed: reported at once, nothing scheduled", done and done.ok == false and done.reason == "request" and done.detail == "NO ROUTE" and #queue == 0)

-- D3: the server tried too many times
world({ script = { queued(0.1), { downloaded = false, manager = "STARTED", entry = { state = "QUEUED", progress = 0, tries = 3 } } } })
request(); run()
check("D3 3 tries: failure reported with the number of tries", done and done.reason == "failed" and done.detail == 3, tostring(done and done.reason))

-- D4: the queue entry is in error
world({ script = { { downloaded = false, manager = "STARTED", entry = { state = "ERROR", progress = 0, tries = 1 } } } })
request(); run()
check("D4 error state: failure reported", done and done.reason == "failed")

-- D5: time-out
world({ script = { queued(0.1) } })
request(); run()
check("D5 never finishes: time-out after 5 minutes", done and done.reason == "timeout" and w.clock >= 300, tostring(done and done.reason) .. " at " .. w.clock)

-- D6: the chapter is neither downloaded nor in the queue
world({ script = { { downloaded = false, manager = "STARTED" } } })
request(); run()
check("D6 dropped from the queue: reported after 10 checks", done and done.reason == "idle" and w.polls == 10, tostring(done and done.reason) .. " / " .. w.polls)

-- D7: the server stops answering
world({ script = { queued(0.1), "SILENT" } })
request(); run()
check("D7 silent server: reported after 3 failed checks", done and done.reason == "unreachable" and w.polls == 4, tostring(done and done.reason) .. " / " .. w.polls)

-- D8: one failed check among good ones does not stop the wait
world({ script = { queued(0.1), "SILENT", queued(0.5), ready() } })
request(); run()
check("D8 a single failed check is tolerated", done and done.ok == true and w.polls == 4, tostring(done and done.reason) .. " / " .. w.polls)

-- D9: cancellation
world({ script = { queued(0.1), queued(0.2), ready() } })
local handle = request(); run(1)
handle:cancel(); run()
check("D9 cancelled: no further check, no result reported", done == nil and w.polls == 1, tostring(done) .. " / " .. w.polls)

-- D10: the download manager is stopped: it is restarted (not at every check)
world({ script = { { downloaded = false, manager = "STOPPED", entry = { state = "QUEUED", progress = 0, tries = 0 } },
                   { downloaded = false, manager = "STOPPED", entry = { state = "QUEUED", progress = 0, tries = 0 } },
                   { downloaded = false, manager = "STOPPED", entry = { state = "QUEUED", progress = 0, tries = 0 } },
                   queued(0.3), ready() } })
request(); run()
check("D10 stopped manager: restarted once, then left alone while the checks continue", w.starts == 1 and done and done.ok == true, tostring(w.starts))

print(failures == 0 and "\nALL SERVER-DOWNLOAD SCENARIOS PASS" or ("\n" .. failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
