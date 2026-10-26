-- Cover mosaic (Suwayomi web UI style): a screen full of tiles, each with the cover, the title and a badge
-- showing the number of unread chapters.

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")

local Covers = require("suwayomi_covers")
local _ = require("suwayomi_i18n")
local Screen = Device.screen

local Mosaic = InputContainer:extend({
    name = "suwayomi_mosaic",
    covers_fullscreen = true,
    cols = 4,
    rows = 3,
    series = nil,   -- series, already sorted: { id, title, unread, total }
    on_select = nil, -- function(series)
    on_settings = nil,
    on_close = nil,
    page = 1,
    tabs = nil,       -- category tabs: { { id, label }, ... }
    active_tab = nil, -- id of the displayed tab
    on_tab = nil,     -- function(id)
})

function Mosaic:init()
    self.dimen = Geom:new({ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() })
    self.ges_events = {
        Tap = { GestureRange:new({ ges = "tap", range = self.dimen }) },
        Swipe = { GestureRange:new({ ges = "swipe", range = self.dimen }) },
    }
    -- Physical page-turn buttons (as in KOReader's lists).
    self.key_events = {
        NextPage = { { Device.input.group.PgFwd } },
        PrevPage = { { Device.input.group.PgBack } },
    }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    self.per_page = self.cols * self.rows
    self.page_count = math.max(1, math.ceil(#self.series / self.per_page))
    self.page = math.min(math.max(self.page, 1), self.page_count)
    self:buildPage()
end

function Mosaic:makeTile(series, tile_w, cover_h, title_h)
    local cover = Covers.widget(series, tile_w, cover_h)
    local cover_frame
    if cover then
        cover_frame = CenterContainer:new({ dimen = Geom:new({ w = tile_w, h = cover_h }), cover })
    else
        -- No cover: a frame with the title.
        cover_frame = FrameContainer:new({
            width = tile_w,
            height = cover_h,
            bordersize = Screen:scaleBySize(1),
            padding = Screen:scaleBySize(4),
            TextBoxWidget:new({
                text = series.title,
                face = Font:getFace("cfont", 16),
                width = tile_w - Screen:scaleBySize(10),
                alignment = "center",
            }),
        })
    end

    local stack = OverlapGroup:new({
        dimen = Geom:new({ w = tile_w, h = cover_h }),
        allow_mirroring = false,
        cover_frame,
    })
    if series.unread and series.unread > 0 then
        local badge = FrameContainer:new({
            background = Blitbuffer.COLOR_BLACK,
            bordersize = 0,
            padding = Screen:scaleBySize(3),
            TextWidget:new({
                text = tostring(series.unread),
                face = Font:getFace("cfont", 16),
                bold = true,
                fgcolor = Blitbuffer.COLOR_WHITE,
            }),
        })
        badge.overlap_align = "right"
        table.insert(stack, badge)
    end

    return VerticalGroup:new({
        align = "left",
        stack,
        TextBoxWidget:new({
            text = series.title,
            face = Font:getFace("cfont", 15),
            width = tile_w,
            height = title_h,
            height_adjust = true,
            height_overflow_show_ellipsis = true,
            alignment = "center",
        }),
    })
end

function Mosaic:buildPage()
    local W, H = self.dimen.w, self.dimen.h
    local first = (self.page - 1) * self.per_page + 1
    local visible = {}
    for i = first, math.min(first + self.per_page - 1, #self.series) do
        table.insert(visible, self.series[i])
    end
    Covers.ensure(visible)

    -- Compact header on ONE line: settings | category tabs | close.
    local bar_h = Screen:scaleBySize(40)
    local icon_w = Screen:scaleBySize(56)
    local header_h = bar_h
    local tabs_h = 0 -- the tabs are in the header: no separate row

    local margin = math.floor(W * 0.025)
    local gap = math.floor(W * 0.016)
    local footer_h = Screen:scaleBySize(44)
    local title_h = Screen:scaleBySize(42)
    local tile_w = math.floor((W - 2 * margin - (self.cols - 1) * gap) / self.cols)
    local grid_h = H - header_h - footer_h - margin
    local tile_h = math.floor((grid_h - (self.rows - 1) * gap) / self.rows)
    local cover_h = tile_h - title_h

    local root = OverlapGroup:new({ dimen = Geom:new({ w = W, h = H }), allow_mirroring = false })

    local icon_size = Screen:scaleBySize(24)
    local settings_icon = CenterContainer:new({
        dimen = Geom:new({ w = icon_w, h = bar_h }),
        IconWidget:new({ icon = "appbar.settings", width = icon_size, height = icon_size }),
    })
    local close_icon = CenterContainer:new({
        dimen = Geom:new({ w = icon_w, h = bar_h }),
        IconWidget:new({ icon = "close", width = icon_size, height = icon_size }),
    })
    close_icon.overlap_align = "right"
    table.insert(root, settings_icon)
    table.insert(root, close_icon)
    self.settings_rect = { x = 0, y = 0, w = icon_w, h = bar_h }
    self.close_rect = { x = W - icon_w, y = 0, w = icon_w, h = bar_h }

    -- Category tabs (as in Suwayomi's web UI), between the two icons.
    self.tab_rects = {}
    if self.tabs and #self.tabs > 1 then
        local area_w = W - 2 * icon_w
        local tab_w = math.floor(area_w / #self.tabs)
        local pad = Screen:scaleBySize(4)
        for i, tab in ipairs(self.tabs) do
            local active = tab.id == self.active_tab
            local frame = FrameContainer:new({
                width = tab_w - pad,
                height = bar_h - 2 * pad,
                bordersize = Screen:scaleBySize(1),
                radius = Screen:scaleBySize(8),
                padding = 0,
                margin = 0,
                background = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
                CenterContainer:new({
                    dimen = Geom:new({ w = tab_w - pad - 2, h = bar_h - 2 * pad - 2 }),
                    TextWidget:new({
                        text = tab.label,
                        face = Font:getFace("cfont", 16),
                        bold = active,
                        fgcolor = active and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
                        max_width = tab_w - pad - Screen:scaleBySize(6),
                    }),
                }),
            })
            frame.overlap_offset = { icon_w + (i - 1) * tab_w + math.floor(pad / 2), pad }
            table.insert(root, frame)
            self.tab_rects[i] = { x = icon_w + (i - 1) * tab_w, y = 0, w = tab_w, h = bar_h, id = tab.id }
        end
    else
        local title = CenterContainer:new({
            dimen = Geom:new({ w = W - 2 * icon_w, h = bar_h }),
            TextWidget:new({ text = "Suwayomi", face = Font:getFace("cfont", 20), bold = true }),
        })
        title.overlap_offset = { icon_w, 0 }
        table.insert(root, title)
    end
    local line = LineWidget:new({ dimen = Geom:new({ w = W, h = Screen:scaleBySize(1) }) })
    line.overlap_offset = { 0, bar_h - 1 }
    table.insert(root, line)

    self.tile_rects = {}
    for idx, series in ipairs(visible) do
        local col = (idx - 1) % self.cols
        local row = math.floor((idx - 1) / self.cols)
        local x = margin + col * (tile_w + gap)
        local y = header_h + tabs_h + margin + row * (tile_h + gap)
        local tile = self:makeTile(series, tile_w, cover_h, title_h)
        tile.overlap_offset = { x, y }
        table.insert(root, tile)
        self.tile_rects[idx] = { x = x, y = y, w = tile_w, h = tile_h, series = series }
    end

    -- Footer: left arrow at the left edge, right arrow at the right edge, page in the middle.
    -- The whole left (or right) half of the footer turns the page.
    local arrow_face = Font:getFace("cfont", 30)
    local footer = OverlapGroup:new({
        dimen = Geom:new({ w = W, h = footer_h }),
        allow_mirroring = false,
        CenterContainer:new({
            dimen = Geom:new({ w = W, h = footer_h }),
            TextWidget:new({
                text = string.format(_("%d / %d  (%d series)"), self.page, self.page_count, #self.series),
                face = Font:getFace("cfont", 20),
            }),
        }),
    })
    local left_arrow = CenterContainer:new({
        dimen = Geom:new({ w = math.floor(W * 0.2), h = footer_h }),
        TextWidget:new({ text = "<", face = arrow_face, bold = true }),
    })
    local right_arrow = CenterContainer:new({
        dimen = Geom:new({ w = math.floor(W * 0.2), h = footer_h }),
        TextWidget:new({ text = ">", face = arrow_face, bold = true }),
    })
    right_arrow.overlap_align = "right"
    table.insert(footer, left_arrow)
    table.insert(footer, right_arrow)
    footer.overlap_offset = { 0, H - footer_h }
    table.insert(root, footer)
    self.footer_rect = { y = H - footer_h, h = footer_h }
    self.header_h = header_h
    self.tabs_h = tabs_h

    if self[1] then self[1]:free() end
    self[1] = FrameContainer:new({
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        width = W,
        height = H,
        root,
    })
end

function Mosaic:goToPage(page)
    page = math.min(math.max(page, 1), self.page_count)
    if page == self.page then return end
    self.page = page
    self:buildPage()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function Mosaic:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end

function Mosaic:onTap(_, ges)
    local pos = ges.pos
    if pos.y > self.footer_rect.y then
        if pos.x < self.dimen.w / 2 then
            self:goToPage(self.page - 1)
        else
            self:goToPage(self.page + 1)
        end
        return true
    end
    if pos.y < self.header_h then
        local r = self.settings_rect
        if pos.x >= r.x and pos.x < r.x + r.w then
            if self.on_settings then self.on_settings() end
            return true
        end
        r = self.close_rect
        if pos.x >= r.x and pos.x < r.x + r.w then
            self:onClose()
            return true
        end
    end
    for _i, rect in ipairs(self.tab_rects or {}) do
        if pos.x >= rect.x and pos.x < rect.x + rect.w and pos.y >= rect.y and pos.y < rect.y + rect.h then
            if rect.id ~= self.active_tab and self.on_tab then self.on_tab(rect.id) end
            return true
        end
    end
    for _i, rect in ipairs(self.tile_rects) do
        if pos.x >= rect.x and pos.x < rect.x + rect.w and pos.y >= rect.y and pos.y < rect.y + rect.h then
            if self.on_select then self.on_select(rect.series) end
            return true
        end
    end
    return true
end

function Mosaic:onNextPage()
    self:goToPage(self.page + 1)
    return true
end

function Mosaic:onPrevPage()
    self:goToPage(self.page - 1)
    return true
end

function Mosaic:onSwipe(_, ges)
    if ges.direction == "west" then
        self:goToPage(self.page + 1)
        return true
    elseif ges.direction == "east" then
        self:goToPage(self.page - 1)
        return true
    end
end

function Mosaic:onClose()
    UIManager:close(self)
    if self.on_close then self.on_close() end
    return true
end

function Mosaic:onCloseWidget()
    UIManager:setDirty(nil, "ui")
end

return Mosaic
