-- Asking the Suwayomi server to download a chapter it does not have yet, and waiting until it is ready.
-- The dependencies (scheduler, API client, clock) are injected by main.lua, which makes the waiting logic
-- (progress, failures, time-outs, cancellation) testable without a server.

local POLL_DELAY = 2          -- seconds between two checks of the server
local TIMEOUT = 300           -- seconds after which we stop waiting (the server may still finish by itself)
local MAX_TRIES = 3           -- server-side attempts after which the source is considered unable to deliver
local IDLE_LIMIT = 10         -- consecutive checks with the chapter neither downloaded nor in the server's queue
local MAX_NETWORK_ERRORS = 3  -- consecutive checks that got no answer from the server
local RESTART_EVERY = 5       -- checks between two attempts to restart a stopped download manager

local ServerDownload = {}
ServerDownload.__index = ServerDownload

--- `deps`: UIManager, api { requestDownloads(ids, urgent), serverDownloadState(id), startDownloader() },
--- now() -> seconds.
function ServerDownload.new(deps)
    return setmetatable({ d = deps }, ServerDownload)
end

--- Asks the server to download `chapter_id` (at the front of its queue) and checks on it every few seconds.
--- `callbacks.on_update({ state = "QUEUED" | "DOWNLOADING", progress = 0..1 })` is called after each check, and
--- `callbacks.on_done(ok, reason, detail)` once, when the chapter is ready (ok) or when waiting is pointless:
---   reason "request"     the server could not be asked (detail = error message)
---   reason "failed"      the server tried and failed (detail = number of tries)
---   reason "timeout"     too long (the server may still be working)
---   reason "idle"        the server no longer has the chapter in its queue, yet it is not downloaded
---   reason "unreachable" the server stopped answering (detail = error message)
--- Returns a handle: `handle:cancel()` stops the checks, and `on_done` is not called afterwards.
function ServerDownload:request(chapter_id, callbacks)
    local d = self.d
    local handle = { cancelled = false }
    function handle:cancel() self.cancelled = true end

    local requested, err = d.api:requestDownloads({ chapter_id }, true)
    if not requested then
        callbacks.on_done(false, "request", err)
        return handle
    end

    local started_at = d.now()
    local idle, errors, stopped_checks = 0, 0, 0
    local function check()
        if handle.cancelled then return end
        local state, e = d.api:serverDownloadState(chapter_id)
        if handle.cancelled then return end -- cancelled during the (blocking) request
        if not state then
            errors = errors + 1
            if errors >= MAX_NETWORK_ERRORS then return callbacks.on_done(false, "unreachable", e) end
        else
            errors = 0
            if state.downloaded then return callbacks.on_done(true) end
            local entry = state.entry
            if entry and (entry.state == "ERROR" or entry.tries >= MAX_TRIES) then
                return callbacks.on_done(false, "failed", entry.tries)
            end
            idle = entry and 0 or idle + 1
            if idle >= IDLE_LIMIT then return callbacks.on_done(false, "idle") end
            if state.manager == "STOPPED" then
                if stopped_checks % RESTART_EVERY == 0 then d.api:startDownloader() end
                stopped_checks = stopped_checks + 1
            end
            callbacks.on_update({
                state = entry and entry.state or "QUEUED",
                progress = entry and entry.progress or 0,
            })
        end
        if d.now() - started_at >= TIMEOUT then return callbacks.on_done(false, "timeout") end
        d.UIManager:scheduleIn(POLL_DELAY, check)
    end
    d.UIManager:scheduleIn(POLL_DELAY, check)
    return handle
end

return ServerDownload
