-- Interface with KOReader's regular reader (ReaderUI): opening a file, detecting the end of a chapter,
-- tracking the current page.
-- Technique: an event listener inserted at the head of ReaderUI's children, so that it receives EndOfBook
-- before the other widgets.
--
-- Adapted from MangaReader.lua of Rakuyomi (https://github.com/hanatsumi/rakuyomi, AGPL-3.0): the singleton
-- wrapping ReaderUI, the EndOfBook listener inserted in ReaderUI's children and the way the reader is closed
-- back to the file manager come from there. Chapter chaining, page tracking, the previous-chapter hook and
-- the menu entries were added here. This file is distributed under the same license as the rest of the
-- project (AGPL-3.0, see LICENSE).

local Event = require("ui/event")
local ReaderUI = require("apps/reader/readerui")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local _ = require("suwayomi_i18n")

local Reader = {
    is_showing = false,
    token = 0,
    current_page = nil,
    -- Filled in by `show`:
    chapter = nil,
    start_page = nil,
    on_end_of_book = nil,
    on_close = nil,
    on_return = nil,
}

--- @class SuwayomiReaderOptions
--- @field path string CBZ file to display.
--- @field chapter table Chapter being read (passed as is to the callbacks).
--- @field start_page? number Start page (1-based).
--- @field on_end_of_book fun(chapter: table) Called when the page is turned after the last one.
--- @field on_close fun(chapter: table, page: number|nil) Called when the reader closes.
--- @field on_return fun() Called by "Back to library".

--- Shows `options.path`. If a chapter is already showing, simply switches document.
function Reader:show(options)
    local switching = self.is_showing and ReaderUI.instance ~= nil
    if switching then
        -- The chapter being left is closed here, explicitly: the old reader's listener will be ignored
        -- (stale token) so that the two chapters are not mixed up.
        self:onReaderClosed()
        self.is_showing = true
    end
    self.token = self.token + 1

    self.chapter = options.chapter
    self.start_page = options.start_page
    self.on_end_of_book = options.on_end_of_book
    self.on_previous = options.on_previous
    self.on_next = options.on_next
    self.next_status = options.next_status
    self.on_close = options.on_close
    self.on_return = options.on_return
    self.disable_panel_zoom = options.disable_panel_zoom
    self.on_series = options.on_series
    self.on_chapters = options.on_chapters
    self.current_page = nil

    if switching then
        ReaderUI.instance:switchDocument(options.path)
    else
        UIManager:broadcastEvent(Event:new("SetupShowReader"))
        ReaderUI:showReader(options.path)
    end
    self.is_showing = true
end

--- Called from the plugin's init when it is loaded inside a ReaderUI.
function Reader:initializeFromReaderUI(ui)
    if self.is_showing then
        ui.menu:registerToMainMenu(self)
    end
    ui:registerPostInitCallback(function()
        self:hookOntoReaderUi(ui)
    end)
end

function Reader:hookOntoReaderUi(ui)
    if not self.is_showing then return end

    local token = self.token
    local listener = WidgetContainer:new({})
    listener.onEndOfBook = function()
        if not self.is_showing or not self.on_end_of_book then return end
        -- KOReader may emit the event twice (page turned twice in a row): only one end is handled
        -- per displayed chapter.
        if self.end_token == token then return true end
        self.end_token = token
        -- The handler and the chapter are frozen here: after the chapter change, `self.on_end_of_book`
        -- will already point to the next chapter.
        local handler, chapter = self.on_end_of_book, self.chapter
        UIManager:nextTick(function()
            handler(chapter)
        end)
        return true
    end
    listener.onPageUpdate = function(_, pageno)
        self.current_page = pageno
        -- no `return true`: the other widgets must receive the event too
    end
    listener.onCloseWidget = function()
        if token == self.token then
            self:onReaderClosed()
        end
    end
    -- Must come before ReaderUI's other children to intercept EndOfBook.
    table.insert(ui, 2, listener)

    -- No panel zoom on long press (KOReader's "Panel zoom", on by default for CBZ files): we only want to
    -- turn pages. Without the zoom a long press would start KOReader's text selection / OCR: ignore it.
    if self.disable_panel_zoom and ui.highlight then
        ui.highlight.panel_zoom_enabled = false
        ui.highlight.onHold = function() return true end
    end

    -- Previous page from page 1: previous chapter (on its last page).
    -- Taps on the edges call `onGotoViewRel` directly (no event): the method is therefore replaced on this
    -- reader instance.
    local paging = ui.paging
    if paging and paging.onGotoViewRel then
        local original = paging.onGotoViewRel
        paging.onGotoViewRel = function(this, diff, ...)
            if type(diff) == "number" and diff < 0 and token == self.token
                and self.is_showing and self.on_previous and this.current_page == 1 then
                if self.prev_token ~= token then
                    self.prev_token = token
                    local handler = self.on_previous
                    UIManager:nextTick(function()
                        -- No previous chapter: allow another attempt.
                        if not handler() then self.prev_token = nil end
                    end)
                end
                return true
            end
            return original(this, diff, ...)
        end
    end

    if self.start_page and self.start_page > 1 then
        local page = self.start_page
        self.start_page = nil
        UIManager:nextTick(function()
            ui:handleEvent(Event:new("GotoPage", page))
        end)
    else
        self.start_page = nil
    end
end

function Reader:onReaderClosed()
    local chapter, page = self.chapter, self.current_page
    self.is_showing = false
    if self.on_close and chapter then
        local ok, err = pcall(self.on_close, chapter, page)
        if not ok then logger.warn("Suwayomi: on_close failed:", err) end
    end
end

--- Previous / next chapter on request (reader menu or gesture).
function Reader:goPrevious()
    if self.is_showing and self.on_previous then
        UIManager:nextTick(self.on_previous)
    end
end

function Reader:goNext()
    if self.is_showing and self.on_next then
        UIManager:nextTick(self.on_next)
    end
end

--- Closes the reader and opens the series' chapter list.
function Reader:goChapters()
    if self.is_showing and self.on_chapters then
        self:closeReaderUi(self.on_chapters)
    end
end

--- Adds the Suwayomi entries to the reader menu.
function Reader:addToMainMenu(menu_items)
    menu_items.suwayomi_previous = {
        text = _("Previous chapter"),
        sorting_hint = "main",
        callback = function() self:goPrevious() end,
    }
    menu_items.suwayomi_next = {
        -- Shows whether the next chapter is already on the device (prefetching).
        text_func = function()
            local status = self.next_status and self.next_status()
            return _("Next chapter") .. (status and (" (" .. status .. ")") or "")
        end,
        sorting_hint = "main",
        callback = function() self:goNext() end,
    }
    menu_items.suwayomi_chapters = {
        text = _("Chapter list"),
        sorting_hint = "main",
        callback = function() self:goChapters() end,
    }
    menu_items.suwayomi_series = {
        text = _("Back to series"),
        sorting_hint = "main",
        callback = function() self:closeReaderUi(self.on_series) end,
    }
    menu_items.go_back_to_suwayomi = {
        text = _("Back to library"),
        sorting_hint = "main",
        callback = function() self:closeReaderUi(self.on_return) end,
    }
end

--- Closes the reader and goes back to the file manager, then calls `done`.
function Reader:closeReaderUi(done)
    UIManager:nextTick(function()
        local FileManager = require("apps/filemanager/filemanager")
        if ReaderUI.instance then
            ReaderUI.instance:onClose()
        end
        if FileManager.instance then
            FileManager.instance:reinit()
        else
            FileManager:showFiles()
        end
        if done then done() end
    end)
end

return Reader
