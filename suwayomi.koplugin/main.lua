-- KOReader plugin: Suwayomi library with resume and chapter chaining.
-- Chapters are downloaded as CBZ files, then opened in KOReader's regular reader.

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local socket = require("socket")

local Api = require("suwayomi_api")
local Mosaic = require("suwayomi_mosaic")
local Prefetch = require("suwayomi_prefetch")
local Reader = require("suwayomi_reader")
local SeriesView = require("suwayomi_series")
local _ = require("suwayomi_i18n")

-- KOReader's own catalogue: only for the generic words it already translates in every language.
local gettext = require("gettext")

-- The VPN is an optional add-on (vpn-addon/suwayomi_vpn.lua). Without it the plugin talks to the server
-- directly, and a stand-in with the same interface takes its place.
local has_vpn, Vpn = pcall(require, "suwayomi_vpn")
if not has_vpn then
    if not tostring(Vpn):find("not found", 1, true) then
        logger.warn("Suwayomi: the VPN add-on failed to load:", tostring(Vpn))
    end
    Vpn = { active = false, isConfigured = function() return false end, stop = function() end }
end

local KEEP_BEHIND = 2 -- chapters already read that are kept on the device (besides the current one)
local DEFAULT_AHEAD = 3 -- following chapters downloaded in advance (setting "prefetch_ahead")

-- State shared between the plugin's instances (FileManager and ReaderUI each have one).
local settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/suwayomi.lua")
local library_menu, series_menu, series_view
local startup_handled = false -- the library opens automatically only when KOReader starts

local function downloadDir()
    local dir = settings:readSetting("download_dir")
    if dir then return dir end
    if lfs.attributes("/mnt/ext1", "mode") == "directory" then -- PocketBook's internal storage
        return "/mnt/ext1/Manga/_Suwayomi"
    end
    local data_dir = DataStorage:getDataDir()
    if data_dir:sub(1, 1) ~= "/" then -- relative path (emulator)
        data_dir = lfs.currentdir() .. "/" .. data_dir:gsub("^%./", "")
    end
    return data_dir .. "/suwayomi_downloads"
end

--- Address of the Suwayomi server as entered by the user (nil until the first setup).
local function homeUrl()
    return settings:readSetting("server_url")
end

local function applySettings()
    -- VPN tunnel active (away from home): every instance of the plugin goes through it.
    local url = Vpn.active and Vpn.url or homeUrl()
    if url then Api:setServer(url) end
end

--- Chooses the route to Suwayomi: the local network if the server answers there, otherwise the VPN tunnel
--- (if it is configured and enabled). Returns true, or false and an error message.
local function ensureServer()
    local home = homeUrl()
    if not home then return false, _("No server address is set.") end
    Api:setServer(home)
    if settings:readSetting("vpn") == false or not Vpn:isConfigured() then
        Vpn.active, Vpn.url, Vpn.network = false, nil, nil
        return true
    end
    return Vpn:ensureRoute(Api, home)
end

local function mkdirs(path)
    local current = ""
    for part in path:gmatch("[^/]+") do
        current = current .. "/" .. part
        if lfs.attributes(current, "mode") == nil then
            lfs.mkdir(current)
        end
    end
end

--- Sends a chapter's progress; when offline, keeps it pending (sent later).
local function saveProgress(chapter_id, last_page, is_read)
    if Api:updateProgress(chapter_id, last_page, is_read) then return true end
    local pending = settings:readSetting("pending_progress") or {}
    local key = tostring(chapter_id)
    local previous = pending[key]
    pending[key] = { page = last_page, read = (is_read or (previous and previous.read)) and true or false }
    settings:saveSetting("pending_progress", pending)
    settings:flush()
    logger.info("Suwayomi: progress kept pending for chapter", chapter_id)
    return false
end

--- Is there progress waiting to be sent to the server?
local function hasPendingProgress()
    local pending = settings:readSetting("pending_progress")
    return type(pending) == "table" and next(pending) ~= nil
end

--- Sends the progress that stayed pending (called when the server is reachable).
local function flushPendingProgress()
    if not hasPendingProgress() then return end
    local pending = settings:readSetting("pending_progress")
    local sent, left = 0, 0
    for key, p in pairs(pending) do
        if Api:updateProgress(tonumber(key), p.page, p.read or nil) then
            pending[key] = nil
            sent = sent + 1
        else
            left = left + 1
        end
    end
    settings:saveSetting("pending_progress", pending)
    settings:flush()
    logger.info("Suwayomi: pending progress sent:", sent, "| left:", left)
end

local function numberText(n)
    return string.format("%g", n or 0)
end

local function chapterTitle(chapter)
    local base = _("Ch.") .. " " .. numberText(chapter.chapterNumber)
    local name = chapter.name or ""
    if name ~= "" and not name:lower():match("^chapter%s*" .. numberText(chapter.chapterNumber) .. "$") then
        return base .. " — " .. name
    end
    return base
end

local function safeName(s)
    return (s:gsub('[/\\:*?"<>|%c]', "_"):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function chapterPath(series_title, chapter)
    return string.format("%s/%s/Ch %s [%d].cbz",
        downloadDir(), safeName(series_title), numberText(chapter.chapterNumber), chapter.id)
end

--- Start page (1-based) to resume a chapter, from the server's progress.
local function startPage(chapter)
    local last = chapter.lastPageRead or 0
    if chapter.isRead or last <= 0 then return 1 end
    if chapter.pageCount and last >= chapter.pageCount - 1 then return 1 end
    return last + 1
end

--- Shows a message while `fn` runs (blocking call), then closes it.
local function withMessage(text, fn)
    local message = InfoMessage:new({ text = text })
    UIManager:show(message)
    UIManager:forceRePaint()
    local a, b = fn()
    UIManager:close(message)
    return a, b
end

local function showError(text)
    UIManager:show(InfoMessage:new({ text = text, icon = "notice-warning" }))
end

--- Trailer of the error messages: which server was being used.
local function serverFooter()
    return "\n\n" .. _("Server:") .. " " .. Api.server_url
end

local function closeMenus()
    if series_menu then UIManager:close(series_menu); series_menu = nil end
    if series_view then UIManager:close(series_view); series_view = nil end
    if library_menu then UIManager:close(library_menu); library_menu = nil end
end

-- Index of the chapter to resume in `chapters` (sorted from oldest to newest): the most recently started
-- chapter after the last read one, otherwise the first unread chapter after the last read one (or the very
-- first chapter if nothing is read).
local function resumeIndex(chapters)
    local last_read = 0
    for i, c in ipairs(chapters) do
        if c.isRead then last_read = i end
    end
    local started, started_at
    for i = last_read + 1, #chapters do
        local c = chapters[i]
        if (c.lastPageRead or 0) > 0 then
            local at = tonumber(c.lastReadAt) or 0
            if not started or at >= started_at then started, started_at = i, at end
        end
    end
    if started then return started end
    if chapters[last_read + 1] then return last_read + 1 end
    return math.max(last_read, 1)
end

--- Number of following chapters to keep / prefetch.
local function aheadCount()
    local n = tonumber(settings:readSetting("prefetch_ahead"))
    if n and n >= 1 and n <= 10 then return math.floor(n) end
    return DEFAULT_AHEAD
end

-- Deletes the series' CBZ files that are no longer in the window [index - KEEP_BEHIND, index + ahead].
local function cleanup(ctx, index)
    local keep = {}
    for i = math.max(1, index - KEEP_BEHIND), math.min(#ctx.chapters, index + aheadCount()) do
        keep[ctx.chapters[i].id] = true
    end
    local dir = string.format("%s/%s", downloadDir(), safeName(ctx.series.title))
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    for name in lfs.dir(dir) do
        local id = name:match("%[(%d+)%]%.cbz$")
        if id and not keep[tonumber(id)] then
            logger.info("Suwayomi: deleting", name)
            os.remove(dir .. "/" .. name)
            -- Matching KOReader settings folder (reading position, etc.).
            local sidecar = dir .. "/" .. name:gsub("%.cbz$", ".sdr")
            if lfs.attributes(sidecar, "mode") == "directory" then
                ffiutil.purgeDir(sidecar)
            end
        end
    end
end

-- Prefetching of the next chapters while reading (see suwayomi_prefetch.lua): one download at a time in a
-- subprocess. It wakes the Wi-Fi up itself if it was turned off, and then rechecks the route to Suwayomi
-- (home or VPN tunnel), because the network may have changed.
local prefetcher = Prefetch.new({
    NetworkMgr = NetworkMgr,
    UIManager = UIManager,
    ffiutil = ffiutil,
    lfs = lfs,
    logger = logger,
    chapterPath = chapterPath,
    mkdirs = mkdirs,
    aheadCount = aheadCount,
    ensureServer = ensureServer,
    download = function(chapter_id, path) return Api:downloadChapter(chapter_id, path) end,
    hasPendingProgress = hasPendingProgress,
    flushPendingProgress = flushPendingProgress,
})

local Suwayomi = WidgetContainer:extend({
    name = "suwayomi",
    is_doc_only = false,
})

local openChapter, showLibrary, showSeries

--- Downloads if needed, then opens chapter `index` of `ctx.chapters` in the reader.
openChapter = function(ctx, index, start_override, online)
    local chapter = ctx.chapters[index]
    local path = chapterPath(ctx.series.title, chapter)

    -- Chapter not on the device yet: make sure the Wi-Fi is on first.
    if lfs.attributes(path, "mode") ~= "file" and not online then
        NetworkMgr:runWhenOnline(function() openChapter(ctx, index, start_override, true) end)
        return
    end

    if lfs.attributes(path, "mode") ~= "file" and prefetcher:isFetching(chapter.id) then
        withMessage(_("Finalizing the download…"), function()
            prefetcher:wait(chapter.id)
        end)
    end

    if lfs.attributes(path, "mode") ~= "file" then
        mkdirs(path:match("^(.*)/[^/]+$"))
        local ok, err = withMessage(
            _("Downloading…") .. "\n" .. ctx.series.title .. "\n" .. chapterTitle(chapter),
            function()
                local file, e = Api:downloadChapter(chapter.id, path)
                if not file then
                    socket.sleep(1.5) -- try again: the Wi-Fi may have just woken up
                    file, e = Api:downloadChapter(chapter.id, path)
                end
                return file, e
            end)
        if not ok then
            showError(_("Download failed:") .. "\n" .. tostring(err) .. serverFooter())
            return
        end
    end

    closeMenus()
    local function onEndOfBook(finished)
        finished.finished_here = true
        finished.isRead = true
        saveProgress(finished.id, math.max((finished.pageCount or 1) - 1, 0), true)
        cleanup(ctx, index)
        if ctx.chapters[index + 1] then
            openChapter(ctx, index + 1)
        else
            -- Nothing left to read in this series: back to the library, reloaded (unread counters up to date).
            Reader:closeReaderUi(function() showLibrary() end)
        end
    end

    local function onPrevious()
        local previous = ctx.chapters[index - 1]
        if not previous then
            UIManager:show(InfoMessage:new({ text = _("This is the first chapter."), timeout = 2 }))
            return false
        end
        -- Arrive on the last page of the previous chapter to keep going backwards.
        local pages = previous.pageCount or 0
        openChapter(ctx, index - 1, pages > 0 and pages or nil)
        return true
    end

    local function onNext()
        if not ctx.chapters[index + 1] then
            UIManager:show(InfoMessage:new({ text = _("This is the last available chapter."), timeout = 2 }))
            return false
        end
        openChapter(ctx, index + 1)
        return true
    end

    local function nextStatus()
        local upcoming = ctx.chapters[index + 1]
        if not upcoming then return _("last chapter") end
        local ready, total = 0, 0
        for i = index + 1, math.min(#ctx.chapters, index + aheadCount()) do
            total = total + 1
            if lfs.attributes(chapterPath(ctx.series.title, ctx.chapters[i]), "mode") == "file" then
                ready = ready + 1
            end
        end
        local state = _("to download")
        if lfs.attributes(chapterPath(ctx.series.title, upcoming), "mode") == "file" then
            state = _("ready offline")
        elseif prefetcher:isFetching(upcoming.id) then
            state = _("downloading")
        end
        return string.format(_("%s, %d/%d ahead"), state, ready, total)
    end

    Reader:show({
        path = path,
        chapter = chapter,
        start_page = start_override or startPage(chapter),
        on_previous = onPrevious,
        on_next = onNext,
        next_status = nextStatus,
        -- Automatic chaining (setting "chain" = false turns it off).
        on_end_of_book = settings:readSetting("chain") ~= false and onEndOfBook or nil,
        on_close = function(closed, page)
            -- This chapter is left: the prefetch chain stops (unless another chapter takes over, which
            -- it will signal itself once opened).
            prefetcher:endReading(closed.id)
            if closed.finished_here or not page then return end
            -- 1-based page -> 0-based lastPageRead; reaching the last page = chapter read.
            local reached_end = closed.pageCount and page >= closed.pageCount
            saveProgress(closed.id, page - 1, reached_end or nil)
        end,
        on_return = function() showLibrary() end,
        disable_panel_zoom = settings:readSetting("panel_zoom") ~= true,
        on_series = function() showSeries(ctx.series) end,
        on_chapters = function() showSeries(ctx.series, true) end,
    })

    -- Once the page is displayed: clean up old chapters, then prefetch the next ones.
    UIManager:scheduleIn(5, function()
        prefetcher:beginReading(ctx, index, chapter.id)
        cleanup(ctx, index)
        prefetcher:start(ctx, index)
    end)
end

local function seriesContext(series)
    local chapters, err = withMessage(_("Loading chapters…"), function()
        local list, e = Api:getChapters(series.id)
        if not list then
            socket.sleep(1.5) -- try again: the Wi-Fi may have just woken up
            list, e = Api:getChapters(series.id)
        end
        return list, e
    end)
    if not chapters then
        showError(err)
        return nil
    end
    return { series = series, chapters = chapters }
end

--- Applies "read" / "unread" to chapters, then reopens the updated series screen.
local function applyReadState(ctx, read_ids, unread_ids)
    -- The Wi-Fi may have turned off since the list was opened: turn it back on if needed, and retry once
    -- on a transient network failure.
    NetworkMgr:runWhenOnline(function()
        local ok, err = withMessage(_("Updating progress…"), function()
            local last_error
            for attempt = 1, 2 do
                local done, e = Api:setChaptersRead(read_ids, true, false)
                if done then done, e = Api:setChaptersRead(unread_ids, false, true) end
                if done then return true end
                last_error = e
                if attempt == 1 then socket.sleep(1.5) end
            end
            return nil, last_error
        end)
        if not ok then
            showError(_("Update failed:") .. "\n" .. tostring(err) .. serverFooter())
            return
        end
        showSeries(ctx.series)
    end)
end

--- Actions on a chapter (long press in the list): last read, read, unread.
local function chapterActions(ctx, index)
    local chapter = ctx.chapters[index]
    local dialog
    local function close() UIManager:close(dialog) end
    local function ids(from, to)
        local list = {}
        for i = from, to do table.insert(list, ctx.chapters[i].id) end
        return list
    end
    dialog = ButtonDialog:new({
        title = chapterTitle(chapter),
        buttons = {
            {{
                text = _("Set as last read"),
                callback = function()
                    close()
                    local after = #ctx.chapters - index
                    UIManager:show(ConfirmBox:new({
                        text = string.format(_("Mark chapters 1 to %s as read and the following %d as unread?"),
                            numberText(chapter.chapterNumber), after),
                        ok_text = _("Confirm"),
                        ok_callback = function()
                            applyReadState(ctx, ids(1, index), ids(index + 1, #ctx.chapters))
                        end,
                    }))
                end,
            }},
            {{
                text = _("Mark this chapter as read"),
                callback = function() close(); applyReadState(ctx, ids(index, index), {}) end,
            }},
            {{
                text = _("Mark this chapter as unread"),
                callback = function() close(); applyReadState(ctx, {}, ids(index, index)) end,
            }},
            {{ text = gettext("Cancel"), callback = close }},
        },
    })
    UIManager:show(dialog)
end

--- A series' chapter list ("Resume" row on top).
local function showChapterList(ctx, start)
    local items = {}
    local resume = ctx.chapters[start]
    if resume then
        local detail = startPage(resume) > 1 and string.format(_(" (page %d)"), startPage(resume)) or ""
        table.insert(items, {
            text = string.format(_("Resume: %s"), chapterTitle(resume)) .. detail,
            bold = true,
            callback = function() openChapter(ctx, start) end,
        })
    end
    for i, chapter in ipairs(ctx.chapters) do
        local status = ""
        if chapter.isRead then
            status = _("read")
        elseif (chapter.lastPageRead or 0) > 0 then
            status = string.format("%d/%d", chapter.lastPageRead + 1, chapter.pageCount or 0)
        end
        table.insert(items, {
            text = chapterTitle(chapter),
            mandatory = status,
            chapter_index = i,
            callback = function() openChapter(ctx, i) end,
        })
    end

    if series_menu then UIManager:close(series_menu) end
    series_menu = Menu:new({
        title = ctx.series.title,
        subtitle = _("Long press a chapter for options"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        covers_fullscreen = true,
        close_callback = function() series_menu = nil end,
        onMenuHold = function(_, item)
            if item.chapter_index then chapterActions(ctx, item.chapter_index) end
            return true
        end,
    })
    -- The list opens at the top: the "Resume" row is always visible right away.
    UIManager:show(series_menu)
end

--- A series' presentation screen: cover, progress, "Resume".
local function showSeriesOnline(series, open_list)
    if series_menu then UIManager:close(series_menu); series_menu = nil end
    local ctx = seriesContext(series)
    if not ctx then return end
    local start = resumeIndex(ctx.chapters)
    local target = ctx.chapters[start]

    local unread, last_read = 0, nil
    for _i, c in ipairs(ctx.chapters) do
        if not c.isRead then unread = unread + 1 else last_read = c end
    end
    local info = {
        unread > 0 and string.format(_("%d unread chapters"), unread) or _("All read"),
        last_read and string.format(_("Last read: ch. %s"), numberText(last_read.chapterNumber)) or _("Not started yet"),
        string.format(_("%d chapters in total"), #ctx.chapters),
    }

    local resume_text = _("Resume")
    if target then
        local page = startPage(target)
        local verb = (last_read or page > 1) and _("Resume") or _("Start")
        resume_text = string.format(_("%s: ch. %s"), verb, numberText(target.chapterNumber)) ..
            (page > 1 and string.format(_(", page %d"), page) or "")
    end

    if series_view then UIManager:close(series_view) end
    series_view = SeriesView:new({
        series = series,
        info_text = table.concat(info, "\n"),
        resume_text = resume_text,
        chapters_text = _("All chapters"),
        on_resume = function() if target then openChapter(ctx, start) end end,
        on_chapters = function() showChapterList(ctx, start) end,
        on_close = function() series_view = nil end,
    })
    UIManager:show(series_view)
    if open_list then showChapterList(ctx, start) end
end

showSeries = function(series, open_list)
    NetworkMgr:runWhenOnline(function() showSeriesOnline(series, open_list) end)
end

local function setView(view)
    settings:saveSetting("view", view)
    settings:flush()
    showLibrary()
end

local function showServerDialog()
    local dialog
    dialog = InputDialog:new({
        title = _("Suwayomi server address"),
        description = _("Example: http://192.168.1.10:4567"),
        input = settings:readSetting("server_url") or "http://",
        buttons = {{
            { text = gettext("Cancel"), callback = function() UIManager:close(dialog) end },
            {
                text = gettext("Save"),
                is_enter_default = true,
                callback = function()
                    local url = (dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", ""))
                    if url == "" or url == "http://" then return end
                    if not url:match("^%a+://") then url = "http://" .. url end
                    settings:saveSetting("server_url", url)
                    settings:flush()
                    applySettings()
                    UIManager:close(dialog)
                    showLibrary()
                end,
            },
        }},
    })
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Deletes the chapters downloaded by the plugin (never anything but its own folder).
local function clearDownloads()
    local dir = downloadDir()
    if not (dir:match("/_Suwayomi$") or dir:match("/suwayomi_downloads$")) then
        showError(_("Unexpected folder, nothing was deleted:") .. "\n" .. dir)
        return
    end
    local count, bytes = 0, 0
    if lfs.attributes(dir, "mode") == "directory" then
        for series in lfs.dir(dir) do
            local series_dir = dir .. "/" .. series
            if series ~= "." and series ~= ".." and lfs.attributes(series_dir, "mode") == "directory" then
                for name in lfs.dir(series_dir) do
                    local path = series_dir .. "/" .. name
                    if name:match("%.cbz$") then
                        count = count + 1
                        bytes = bytes + (lfs.attributes(path, "size") or 0)
                    end
                end
                ffiutil.purgeDir(series_dir)
            end
        end
    end
    UIManager:show(InfoMessage:new({
        text = string.format(_("%d chapter(s) deleted, %d MB freed."), count, math.floor(bytes / 1048576)),
    }))
end

--- Settings rows for the optional VPN add-on: on/off switch and network diagnostic.
local function vpnRows(close)
    return {
        {{
            text = (not Vpn:isConfigured() and _("VPN away from home: not set up"))
                or (settings:readSetting("vpn") == false and _("VPN away from home: off"))
                or (_("VPN away from home: on") .. (Vpn.active and _(" (tunnel active)") or "")),
            callback = function()
                close()
                if not Vpn:isConfigured() then
                    UIManager:show(InfoMessage:new({
                        text = _("To reach Suwayomi away from home you need the wireproxy program and a WireGuard profile of your home network in KOReader's suwayomi_vpn folder (see vpn-addon/README.md)."),
                    }))
                    return
                end
                settings:saveSetting("vpn", settings:readSetting("vpn") == false)
                settings:flush()
                if settings:readSetting("vpn") == false then Vpn:stop() end
                UIManager:show(InfoMessage:new({
                    text = _("Applies the next time the library is opened."),
                    timeout = 3,
                }))
            end,
        }},
        {{
            text = _("Network diagnostic (VPN)"),
            callback = function()
                close()
                UIManager:show(InfoMessage:new({ text = Vpn:diagnose() }))
            end,
        }},
    }
end

--- Settings: mosaic / list switch, startup, VPN (if the add-on is installed), server address.
local function showSettings()
    local dialog
    local function close() UIManager:close(dialog) end
    local mosaic = (settings:readSetting("view") or "mosaic") == "mosaic"

    local buttons = {
        {{
            text = mosaic and _("Switch to list view") or _("Switch to mosaic view"),
            callback = function()
                close()
                setView(mosaic and "list" or "mosaic")
            end,
        }},
        {{
            text = (settings:readSetting("panel_zoom") == true
                and _("Panel zoom (long press): on")
                or _("Panel zoom (long press): off")),
            callback = function()
                close()
                settings:saveSetting("panel_zoom", settings:readSetting("panel_zoom") ~= true)
                settings:flush()
                UIManager:show(InfoMessage:new({
                    text = _("Applies to the next chapter you open."),
                    timeout = 3,
                }))
            end,
        }},
        {{
            text = (settings:readSetting("autostart") ~= false
                and _("Open the library when KOReader starts: yes")
                or _("Open the library when KOReader starts: no")),
            callback = function()
                close()
                settings:saveSetting("autostart", settings:readSetting("autostart") == false)
                settings:flush()
                UIManager:show(InfoMessage:new({
                    text = _("Applies the next time KOReader starts."),
                    timeout = 3,
                }))
            end,
        }},
    }
    if has_vpn then
        for _i, row in ipairs(vpnRows(close)) do table.insert(buttons, row) end
    end
    table.insert(buttons, {{
        text = _("Delete downloaded chapters"),
        callback = function()
            close()
            UIManager:show(ConfirmBox:new({
                text = _("Delete all chapters downloaded on this device?\nThey will be downloaded again on demand."),
                ok_text = gettext("Delete"),
                ok_callback = clearDownloads,
            }))
        end,
    }})
    table.insert(buttons, {{
        text = _("Server:") .. " " .. Api.server_url,
        callback = function()
            close()
            showServerDialog()
        end,
    }})
    table.insert(buttons, {{ text = gettext("Close"), callback = close }})

    dialog = ButtonDialog:new({ buttons = buttons })
    UIManager:show(dialog)
end

local function fetchLibrary()
    local series, err = Api:getLibrary()
    if not series then return nil, err end
    local by_manga, latest = Api:getLastRead()
    if not by_manga then return nil, err end
    local library = { series = series, by_manga = by_manga, latest = latest }
    library.categories = Api:getCategories() or {}

    -- Chapter to resume in the series read last (one more request, done once).
    if latest then
        for _i, s in ipairs(series) do
            if s.id == latest.mangaId then
                local chapters = Api:getChapters(s.id)
                if chapters and #chapters > 0 then
                    library.resume = { series = s, chapters = chapters, index = resumeIndex(chapters) }
                end
                break
            end
        end
    end
    return library
end

--- Resumes reading where it stopped, across all series.
local function resumeLatest(library)
    local resume = library.resume
    if not resume then
        showError(_("No reading to resume."))
        return
    end
    openChapter({ series = resume.series, chapters = resume.chapters }, resume.index)
end

local renderLibrary

--- Category tabs: "All" then each non-empty category, with its number of series.
local function categoryTabs(library)
    local tabs = { { id = "all", label = string.format(_("All (%d)"), #library.series) } }
    for _i, c in ipairs(library.categories or {}) do
        local count = 0
        for _i, s in ipairs(library.series) do
            if c.ids[s.id] then count = count + 1 end
        end
        if count > 0 then table.insert(tabs, { id = c.id, label = c.name .. " (" .. count .. ")" }) end
    end
    return tabs
end

--- Displayed category: the last chosen one if it still exists, otherwise "All".
local function activeCategory(tabs)
    local saved = settings:readSetting("category")
    for _i, t in ipairs(tabs) do
        if t.id == saved then return saved end
    end
    return "all"
end

local function seriesInCategory(library, id)
    if id == "all" then return library.series end
    for _i, c in ipairs(library.categories or {}) do
        if c.id == id then
            local list = {}
            for _i, s in ipairs(library.series) do
                if c.ids[s.id] then table.insert(list, s) end
            end
            return list
        end
    end
    return library.series
end

local function setCategory(library, id)
    settings:saveSetting("category", id)
    settings:flush()
    renderLibrary(library)
end

--- Category choice in list view.
local function chooseCategory(library, tabs, active)
    local dialog
    local rows = {}
    for _i, tab in ipairs(tabs) do
        table.insert(rows, {{
            text = (tab.id == active and "● " or "") .. tab.label,
            callback = function()
                UIManager:close(dialog)
                setCategory(library, tab.id)
            end,
        }})
    end
    dialog = ButtonDialog:new({ buttons = rows })
    UIManager:show(dialog)
end

renderLibrary = function(library)
    local tabs = categoryTabs(library)
    local active = activeCategory(tabs)
    local list = seriesInCategory(library, active)

    closeMenus()
    if (settings:readSetting("view") or "mosaic") == "mosaic" then
        library_menu = Mosaic:new({
            series = list,
            tabs = tabs,
            active_tab = active,
            on_tab = function(id) setCategory(library, id) end,
            on_select = function(series) showSeries(series) end,
            on_settings = showSettings,
            on_close = function() library_menu = nil end,
        })
        UIManager:show(library_menu)
        return
    end

    local items = {
        {
            text = _("Switch to mosaic view"),
            bold = true,
            callback = function() setView("mosaic") end,
        },
    }
    if #tabs > 1 then
        local label = ""
        for _i, tab in ipairs(tabs) do
            if tab.id == active then label = tab.label end
        end
        table.insert(items, {
            text = string.format(_("Category: %s  (change)"), label),
            bold = true,
            callback = function() chooseCategory(library, tabs, active) end,
        })
    end
    -- No global "Resume" here: resuming is done from the series itself.
    for _i, series in ipairs(list) do
        local last = library.by_manga[series.id]
        -- On the right: last chapter touched, then the number of unread chapters.
        local unread = series.unread > 0 and string.format(_("%d unread"), series.unread) or _("all read")
        table.insert(items, {
            text = series.title,
            mandatory = last and string.format(_("ch. %s, %s"), numberText(last.chapterNumber), unread) or unread,
            callback = function() showSeries(series) end,
        })
    end
    table.insert(items, {
        text = string.format(_("Settings — server: %s"), Api.server_url),
        callback = showSettings,
    })

    library_menu = Menu:new({
        title = "Suwayomi",
        item_table = items,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        covers_fullscreen = true,
        close_callback = function() library_menu = nil end,
    })
    UIManager:show(library_menu)
end

showLibrary = function()
    if not homeUrl() then -- first launch: ask for the server address
        showServerDialog()
        return
    end
    NetworkMgr:runWhenOnline(function()
        local library, err = withMessage(_("Connecting to Suwayomi…"), function()
            local reachable, route_err = ensureServer()
            if not reachable then return nil, route_err end
            flushPendingProgress()
            return fetchLibrary()
        end)
        if not library then
            showError(err .. serverFooter())
            return
        end

        -- Recently read series first, then the rest in alphabetical order.
        table.sort(library.series, function(a, b)
            local la, lb = library.by_manga[a.id], library.by_manga[b.id]
            if la and lb then
                return tonumber(la.lastReadAt) > tonumber(lb.lastReadAt)
            elseif la or lb then
                return la ~= nil
            end
            return a.title:lower() < b.title:lower()
        end)
        renderLibrary(library)
    end)
end

function Suwayomi:init()
    applySettings()
    -- When KOReader starts (once per run), opens the library right away, unless KOReader already starts
    -- inside a book (e.g. a file reopened by the device's own system).
    if not startup_handled then
        startup_handled = true
        if self.ui.name ~= "ReaderUI" and settings:readSetting("autostart") ~= false then
            UIManager:scheduleIn(1, function() showLibrary() end)
        end
    end
    if self.ui.name == "ReaderUI" then
        Reader:initializeFromReaderUI(self.ui)
    else
        self.ui.menu:registerToMainMenu(self)
    end
    Dispatcher:registerAction("suwayomi_library", {
        category = "none", event = "SuwayomiLibrary", title = _("Suwayomi: library"), general = true,
    })
    Dispatcher:registerAction("suwayomi_previous_chapter", {
        category = "none", event = "SuwayomiPreviousChapter", title = _("Suwayomi: previous chapter"),
        reader = true,
    })
    Dispatcher:registerAction("suwayomi_chapter_list", {
        category = "none", event = "SuwayomiChapterList", title = _("Suwayomi: chapter list"),
        reader = true,
    })
    Dispatcher:registerAction("suwayomi_next_chapter", {
        category = "none", event = "SuwayomiNextChapter", title = _("Suwayomi: next chapter"),
        reader = true,
    })
    Dispatcher:registerAction("suwayomi_resume", {
        category = "none", event = "SuwayomiResume", title = _("Suwayomi: resume reading"), general = true,
    })
end

function Suwayomi:addToMainMenu(menu_items)
    menu_items.suwayomi = {
        text = "Suwayomi",
        sorting_hint = "main",
        callback = showLibrary,
    }
end

-- When KOReader closes the VPN tunnel is stopped (otherwise wireproxy would keep running in the background).
function Suwayomi:onExit() Vpn:stop() end
Suwayomi.onRestart = Suwayomi.onExit
Suwayomi.onReboot = Suwayomi.onExit
Suwayomi.onPowerOff = Suwayomi.onExit

function Suwayomi:onSuwayomiLibrary()
    if self.ui.name ~= "ReaderUI" then showLibrary() end
    return true
end

function Suwayomi:onSuwayomiPreviousChapter()
    Reader:goPrevious()
    return true
end

function Suwayomi:onSuwayomiChapterList()
    Reader:goChapters()
    return true
end

function Suwayomi:onSuwayomiNextChapter()
    Reader:goNext()
    return true
end

function Suwayomi:onSuwayomiResume()
    if self.ui.name == "ReaderUI" then return true end
    if not homeUrl() then
        showServerDialog()
        return true
    end
    NetworkMgr:runWhenOnline(function()
        local library, err = withMessage(_("Connecting to Suwayomi…"), function()
            local reachable, route_err = ensureServer()
            if not reachable then return nil, route_err end
            return fetchLibrary()
        end)
        if not library then
            showError(err)
            return
        end
        resumeLatest(library)
    end)
    return true
end

return Suwayomi
