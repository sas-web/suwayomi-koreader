-- Series presentation screen: cover, title, progress, a big "Resume" button and access to the chapter list.

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")

local Covers = require("suwayomi_covers")
local _ = require("suwayomi_i18n")
local Screen = Device.screen

local SeriesView = InputContainer:extend({
    name = "suwayomi_series",
    covers_fullscreen = true,
    series = nil,       -- { id, title, unread, total }
    info_text = nil,    -- lines shown under the title
    resume_text = nil,  -- text of the big button
    chapters_text = nil,
    on_resume = nil,
    on_chapters = nil,
    on_close = nil,
})

function SeriesView:init()
    self.dimen = Geom:new({ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() })
    self.ges_events = { Tap = { GestureRange:new({ ges = "tap", range = self.dimen }) } }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self:build()
end

local function button(text, w, h, inverted)
    local face = Font:getFace("cfont", 22)
    return FrameContainer:new({
        width = w,
        height = h,
        bordersize = Screen:scaleBySize(2),
        padding = 0,
        margin = 0,
        background = inverted and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        CenterContainer:new({
            dimen = Geom:new({ w = w - 2 * Screen:scaleBySize(2), h = h - 2 * Screen:scaleBySize(2) }),
            TextWidget:new({
                text = text,
                face = face,
                bold = true,
                fgcolor = inverted and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
                max_width = w - Screen:scaleBySize(20),
            }),
        }),
    })
end

function SeriesView:build()
    local W, H = self.dimen.w, self.dimen.h
    Covers.ensure({ self.series })

    local title_bar = TitleBar:new({
        width = W,
        fullscreen = true,
        title = "Suwayomi",
        with_bottom_line = true,
        close_callback = function() self:onClose() end,
    })
    local header_h = title_bar:getHeight()
    local margin = math.floor(W * 0.04)

    local root = OverlapGroup:new({ dimen = Geom:new({ w = W, h = H }), allow_mirroring = false })
    table.insert(root, title_bar)

    -- Cover on the left, text on the right.
    local cover_w = math.floor(W * 0.38)
    local cover_h = math.floor(cover_w * 1.5)
    local cover = Covers.widget(self.series, cover_w, cover_h)
    if cover then
        cover.overlap_offset = { margin, header_h + margin }
        table.insert(root, cover)
    end
    local text_x = margin * 2 + cover_w
    local text_w = W - text_x - margin
    local title = TextBoxWidget:new({
        text = self.series.title,
        face = Font:getFace("cfont", 28),
        bold = true,
        width = text_w,
        height = math.floor(cover_h * 0.5),
        height_adjust = true,
        height_overflow_show_ellipsis = true,
    })
    title.overlap_offset = { text_x, header_h + margin }
    table.insert(root, title)
    local info = TextBoxWidget:new({
        text = self.info_text or "",
        face = Font:getFace("cfont", 20),
        width = text_w,
    })
    info.overlap_offset = { text_x, header_h + margin + title:getSize().h + margin }
    table.insert(root, info)

    -- Buttons under the cover.
    local btn_w = W - 2 * margin
    local y = header_h + margin + cover_h + margin * 2
    local resume_h = Screen:scaleBySize(90)
    local chapters_h = Screen:scaleBySize(72)
    local resume = button(self.resume_text or _("Resume"), btn_w, resume_h, true)
    resume.overlap_offset = { margin, y }
    table.insert(root, resume)
    local chapters = button(self.chapters_text or _("All chapters"), btn_w, chapters_h, false)
    chapters.overlap_offset = { margin, y + resume_h + margin }
    table.insert(root, chapters)
    self.resume_rect = { x = margin, y = y, w = btn_w, h = resume_h }
    self.chapters_rect = { x = margin, y = y + resume_h + margin, w = btn_w, h = chapters_h }
    self.header_h = header_h

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

function SeriesView:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end

local function inside(rect, pos)
    return pos.x >= rect.x and pos.x < rect.x + rect.w and pos.y >= rect.y and pos.y < rect.y + rect.h
end

function SeriesView:onTap(_, ges)
    local pos = ges.pos
    if inside(self.resume_rect, pos) then
        if self.on_resume then self.on_resume() end
        return true
    elseif inside(self.chapters_rect, pos) then
        if self.on_chapters then self.on_chapters() end
        return true
    end
    return pos.y > self.header_h -- taps on the header are handled by the title bar
end

function SeriesView:onClose()
    UIManager:close(self)
    if self.on_close then self.on_close() end
    return true
end

function SeriesView:onCloseWidget()
    UIManager:setDirty(nil, "ui")
end

return SeriesView
