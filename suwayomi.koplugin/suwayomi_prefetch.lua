-- Prefetching of the next chapters while reading: one download at a time, in a subprocess, each one
-- chaining to the next. The dependencies (network, scheduler, file system...) are injected by main.lua, which
-- makes the hard cases (Wi-Fi off, failures) replayable in tests.
--
-- Why a module of its own: the e-reader turns its Wi-Fi off by itself while reading. A chapter that is already
-- on the device opens without any network, so the prefetcher has to wake the Wi-Fi up itself, otherwise the
-- window of chapters kept ahead would never fill up again.
--
-- Waking the Wi-Fi up is expensive: on some e-readers (PocketBook) it freezes the whole screen for 5 to 20 seconds.
-- So it is done as rarely as possible: only when the chapters ready ahead run low (see `lowCount`), and then the
-- whole window is filled in one go while the Wi-Fi is on. Nothing in the background ever starts a VPN tunnel
-- either (`ensureServer(true)`).
--
-- When the Suwayomi server does not have a chapter of the window yet, the prefetcher asks it to download the
-- missing ones (see `serverHas` / `requestServer`), fetches the chapters that are ready in the meantime and
-- checks back shortly after (10 s, then 20 s, then every 30 s), without ever waking the Wi-Fi up just for that.

local MAX_FAILURES = 2    -- a chapter that fails twice is not tried again during this reading session
local RETRY_DELAY = 15    -- seconds before retrying after a failure
local POLL_DELAY = 3      -- seconds between two checks of a running download
local WAKE_TIMEOUT = 90   -- seconds before giving up on a Wi-Fi wake-up that never completes
local RECHECK_DELAYS = { 10, 20, 30 } -- seconds before checking again whether the server has finished (then 30 s)
local MAX_RECHECKS = 20   -- checks per reading session (about ten minutes), then we wait for the next chapter
local REQUEST_TTL = 600   -- seconds before the server is asked again for the same chapter

local Prefetch = {}
Prefetch.__index = Prefetch

--- `deps`: NetworkMgr (isOnline(), enableWifi(callback, interactive)), UIManager, ffiutil, lfs, logger,
--- chapterPath(series_title, chapter), mkdirs(dir), aheadCount(), ensureServer(quiet), download(chapter_id, path)
--- -> file or nil, error, hasPendingProgress() -> boolean, flushPendingProgress() (sends the progress that could
--- not be sent earlier).
--- Optional: lowCount() -> number of chapters ready ahead at or below which the Wi-Fi may be woken up (without it,
--- any missing chapter wakes it), showBusy() -> function that hides the "connecting" message it displays,
--- serverHas(ids) -> { [chapter_id] = boolean } or nil if the server did not answer,
--- requestServer(ids) -> boolean (asks the server to download these chapters), now() -> seconds.
function Prefetch.new(deps)
    return setmetatable({
        d = deps,
        active = nil,           -- running download: { pid, chapter_id, path }
        reading = nil,          -- chapter being read: { ctx, index, chapter_id }
        failures = {},          -- chapter_id -> number of failures during this reading session
        wake_pending = false,   -- the Wi-Fi is being woken up
        route_stale = false,    -- the Wi-Fi was woken up: the route to Suwayomi (home / VPN) must be rechecked
        flush_due = false,      -- pending progress should be sent (one attempt per opportunity)
        requested = {},         -- chapter_id -> time the server was last asked to download it
        recheck_pending = false, -- a check of the server's downloads is scheduled
        rechecks = 0,           -- checks made during this reading session
    }, Prefetch)
end

--- Is a download of this chapter running?
function Prefetch:isFetching(chapter_id)
    return self.active ~= nil and self.active.chapter_id == chapter_id
end

--- Waits for the running download of this chapter to finish (if there is one).
function Prefetch:wait(chapter_id)
    if self:isFetching(chapter_id) then
        self.d.ffiutil.isSubProcessDone(self.active.pid, true)
        self.active = nil
    end
end

--- A chapter starts being read: prefetching targets the chapters that follow it.
function Prefetch:beginReading(ctx, index, chapter_id)
    self.reading = { ctx = ctx, index = index, chapter_id = chapter_id }
    self.failures = {}
    self.rechecks = 0
    self.flush_due = true -- the chapter just finished may have failed to save (Wi-Fi off)
end

--- This chapter is left: the chain stops, unless another chapter has already taken over.
function Prefetch:endReading(chapter_id)
    if self.reading and self.reading.chapter_id == chapter_id then self.reading = nil end
end

--- Wakes the Wi-Fi up, then calls `fn`. On some e-readers (PocketBook) the call blocks until the connection is made
--- and shows nothing by itself: a message is displayed first so that the frozen screen is explained.
function Prefetch:wake(fn)
    if self.wake_pending then return end
    local d = self.d
    local clock = d.now or os.time
    self.wake_pending = true
    d.logger.info("Suwayomi: Wi-Fi is off, waking it up for prefetching")
    local hide = d.showBusy and d.showBusy()
    local began = clock()
    local started = d.NetworkMgr:enableWifi(function()
        self.wake_pending = false
        self.route_stale = true -- the network may have changed while it was off
        self.flush_due = true   -- and now is the time to send what could not be sent
        if d.NetworkMgr:isOnline() then fn() end
    end, false)
    if hide then hide() end
    d.logger.info("Suwayomi: Wi-Fi wake-up call returned after", clock() - began, "s")
    if started == false then self.wake_pending = false end
    -- Safety net: if the connection never completes, release the flag so that a later attempt is possible.
    d.UIManager:scheduleIn(WAKE_TIMEOUT, function() self.wake_pending = false end)
end

function Prefetch:poll()
    if not self.active then return end
    local d = self.d
    if not d.ffiutil.isSubProcessDone(self.active.pid) then
        d.UIManager:scheduleIn(POLL_DELAY, function() self:poll() end)
        return
    end
    local finished = self.active
    self.active = nil
    local failed = d.lfs.attributes(finished.path, "mode") ~= "file"
    if failed then
        self.failures[finished.chapter_id] = (self.failures[finished.chapter_id] or 0) + 1
        d.logger.warn("Suwayomi: prefetch failed, chapter", finished.chapter_id,
            "(attempt " .. self.failures[finished.chapter_id] .. ")")
    else
        d.logger.info("Suwayomi: prefetch done, chapter", finished.chapter_id)
    end
    -- Next chapter to prefetch, as long as we are still reading.
    local reading = self.reading
    if not reading then return end
    if failed then
        d.UIManager:scheduleIn(RETRY_DELAY, function()
            if self.reading == reading then self:start(reading.ctx, reading.index, true) end
        end)
    else
        self:start(reading.ctx, reading.index)
    end
end

--- The upcoming chapters (the window ahead): a list of { chapter, path } for those that are not on the device
--- yet and not given up on, nearest first, and the number of chapters of the window that are already on the device.
function Prefetch:missingChapters(ctx, index)
    local d = self.d
    local missing, ready = {}, 0
    for i = index + 1, math.min(#ctx.chapters, index + d.aheadCount()) do
        local upcoming = ctx.chapters[i]
        local path = d.chapterPath(ctx.series.title, upcoming)
        if d.lfs.attributes(path, "mode") == "file" then
            ready = ready + 1
        elseif (self.failures[upcoming.id] or 0) < MAX_FAILURES then
            missing[#missing + 1] = { chapter = upcoming, path = path }
        end
    end
    return missing, ready
end

--- Chooses the nearest missing chapter that the server has, and asks the server to download the ones it lacks.
--- Without the server-side helpers, or if the server does not answer, the nearest missing chapter is returned
--- and the download is simply attempted. Returns nil when the server has none of them yet.
function Prefetch:pickServerReady(missing)
    local d = self.d
    if not d.serverHas then return missing[1] end
    local ids = {}
    for _index, item in ipairs(missing) do ids[#ids + 1] = item.chapter.id end
    local on_server = d.serverHas(ids)
    if not on_server then return missing[1] end

    local now = (d.now or os.time)()
    local lacking = {}
    for _index, item in ipairs(missing) do
        local id = item.chapter.id
        if on_server[id] == false and now - (self.requested[id] or -REQUEST_TTL) >= REQUEST_TTL then
            lacking[#lacking + 1] = id
        end
    end
    if #lacking > 0 and d.requestServer then
        d.logger.info("Suwayomi: asking the server to download chapters", table.concat(lacking, ","))
        if d.requestServer(lacking) then
            for _index, id in ipairs(lacking) do self.requested[id] = now end
        end
    end
    for _index, item in ipairs(missing) do
        if on_server[item.chapter.id] ~= false then return item end
    end
    return nil
end

--- Checks again soon whether the server has finished (only while still reading): after 10 s, then 20 s, then 30 s.
function Prefetch:scheduleRecheck()
    local reading = self.reading
    if self.recheck_pending or not reading or self.rechecks >= MAX_RECHECKS then return end
    self.recheck_pending = true
    self.rechecks = self.rechecks + 1
    local delay = RECHECK_DELAYS[math.min(self.rechecks, #RECHECK_DELAYS)]
    self.d.UIManager:scheduleIn(delay, function()
        self.recheck_pending = false
        if self.reading == reading then self:start(reading.ctx, reading.index, true) end
    end)
end

--- Is the buffer of chapters ready ahead low enough to be worth waking the Wi-Fi up?
function Prefetch:isBufferLow(ready)
    local low = self.d.lowCount and self.d.lowCount()
    return low == nil or ready <= low
end

--- Sends the pending progress and starts downloading the next missing chapter.
--- The e-reader turns its Wi-Fi off while reading: a chapter finished offline stays "pending" on the device.
--- It is sent when the Wi-Fi is on anyway: the Wi-Fi is never woken up just for this, the next wake-up or the
--- opening of the library takes care of it.
--- The Wi-Fi is woken up only when the buffer of chapters ready ahead is low; if it is already on, the window is
--- filled whatever its state. `quiet` (a scheduled check) never wakes the Wi-Fi up.
function Prefetch:start(ctx, index, quiet)
    if self.active then return end
    local d = self.d
    local missing, ready = self:missingChapters(ctx, index)
    local online = d.NetworkMgr:isOnline()
    local to_flush = self.flush_due and online and d.hasPendingProgress()
    if #missing == 0 and not to_flush then return end
    if quiet and not online then return end

    if not online then
        if not self:isBufferLow(ready) then return end -- enough chapters ahead: leave the Wi-Fi alone
        local current = self.reading and self.reading.chapter_id
        self:wake(function()
            if self.reading and self.reading.chapter_id == current then self:start(ctx, index) end
        end)
        return
    end
    if self.route_stale then
        -- Background check of the route: the home address or an open tunnel only, never a new tunnel.
        local reachable, err = d.ensureServer(true)
        if not reachable then
            d.logger.warn("Suwayomi: prefetch impossible, server unreachable:", tostring(err):match("^[^\n]*"))
            self:scheduleRecheck() -- the route stays to be checked: try again soon
            return
        end
        self.route_stale = false
    end
    if to_flush then
        self.flush_due = false -- one attempt per opportunity: a silent server must not freeze the reading
        d.flushPendingProgress()
    end
    if #missing == 0 then return end

    local chosen = self:pickServerReady(missing)
    if not chosen then
        self:scheduleRecheck() -- the server is still working on them
        return
    end
    local upcoming, path = chosen.chapter, chosen.path

    d.mkdirs(path:match("^(.*)/[^/]+$"))
    local chapter_id = upcoming.id
    local pid = d.ffiutil.runInSubProcess(function()
        -- Child process: network and files only, no user interface.
        local file, err = d.download(chapter_id, path)
        if not file then
            d.logger.warn("Suwayomi: prefetch of chapter", chapter_id, "impossible:", err)
        end
    end)
    if pid then
        self.active = { pid = pid, chapter_id = chapter_id, path = path }
        d.UIManager:scheduleIn(POLL_DELAY, function() self:poll() end)
    end
end

return Prefetch
