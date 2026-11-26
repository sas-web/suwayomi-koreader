-- Series presentation screen: cover and title with the beginning of the summary flowing beside and below the cover
-- (tap it to read it all), then a big "Resume" button, access to the chapter list and the reading progress.

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
local util = require("util")

local Covers = require("suwayomi_covers")
local _ = require("suwayomi_i18n")
local Screen = Device.screen

local SeriesView = InputContainer:extend({
    name = "suwayomi_series",
    covers_fullscreen = true,
    series = nil,       -- { id, title, unread, total }
    info_text = nil,    -- reading progress, one line shown under the buttons
    resume_text = nil,  -- text of the big button
    chapters_text = nil,
    summary_text = nil, -- optional
    on_resume = nil,
    on_chapters = nil,
    on_summary = nil,
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

-- The progress on one centred line, in the largest of a few font sizes that fits the width (numbers and
-- translations vary in length). If none fits, it wraps instead of being cut.
local function progressLine(text, width)
    for size = 20, 16, -1 do
        local line = TextWidget:new({ text = text, face = Font:getFace("cfont", size) })
        if line:getSize().w <= width then return line end
        line:free()
    end
    return TextBoxWidget:new({ text = text, face = Font:getFace("cfont", 18), width = width, alignment = "center" })
end

-- The summary flows around the cover: beside it, under the title, then across the whole width below it. KOReader
-- has no widget for that, so there are two text boxes: the second one starts where the first line that the first one
-- cannot show begins (TextBoxWidget lays out all the lines and keeps where each starts, as a character index).
-- `area`: beside = { x, y (highest point allowed), w }, below = { x, w }, cover_bottom, bottom (lowest point
-- allowed), gap (under the cover). Returns the boxes with their place, or an empty list when fewer than three
-- lines would fit.
local function flowedSummary(text, face, area)
    local probe = TextBoxWidget:new({ text = "A", face = face, width = area.beside.w })
    local line_h = probe.line_height_px -- not getSize().h, which adds room under the last line
    probe:free()

    -- The full width starts at the "seam", just under the cover. The lines beside the cover end exactly there, so
    -- that the spacing stays even: the room left over goes between the title and the summary.
    local seam = area.cover_bottom + area.gap
    local beside_y, beside, below_y = area.beside.y, 0, math.max(seam, area.beside.y)
    if seam > area.bottom then -- screen too short to go under the cover
        beside = math.max(math.floor((area.bottom - beside_y) / line_h), 0)
    elseif seam - beside_y >= line_h then
        beside = math.floor((seam - beside_y) / line_h)
        beside_y, below_y = seam - beside * line_h, seam
    end
    local below = math.max(math.floor((area.bottom - below_y) / line_h), 0)
    if beside + below < 3 then return {} end

    local boxes = {}
    local function add(content, x, y, width, lines, ellipsis)
        local box = TextBoxWidget:new({
            text = content,
            face = face,
            width = width,
            height = lines * line_h,
            height_adjust = true,
            height_overflow_show_ellipsis = ellipsis,
        })
        table.insert(boxes, { widget = box, x = x, y = y, w = width, h = box:getSize().h })
        return box
    end

    local rest = text
    if beside > 0 then
        local first = add(text, area.beside.x, beside_y, area.beside.w, beside, below == 0)
        local next_line = first.vertical_string_list and first.vertical_string_list[beside + 1]
        rest = next_line and table.concat(util.splitToChars(text), "", next_line.offset) or ""
        rest = (rest:gsub("^%s+", ""))
    end
    if below > 0 and rest ~= "" then
        add(rest, area.below.x, below_y, area.below.w, below, true)
    end
    return boxes
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

    -- Cover on the left; title and the beginning of the summary on the right.
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

    -- Buttons and the progress line sit at the bottom of the screen, to leave as much room as possible to the
    -- summary; on a screen too short for that, right under the cover.
    local btn_w = W - 2 * margin
    local resume_h = Screen:scaleBySize(90)
    local chapters_h = Screen:scaleBySize(72)
    local info = progressLine(self.info_text or "", btn_w)
    local info_size = info:getSize()
    local from_bottom = H - margin * 3 - info_size.h - chapters_h - resume_h
    local y = math.max(from_bottom, header_h + margin + cover_h + margin * 2)
    local resume = button(self.resume_text or _("Resume"), btn_w, resume_h, true)
    resume.overlap_offset = { margin, y }
    table.insert(root, resume)
    local chapters = button(self.chapters_text or _("All chapters"), btn_w, chapters_h, false)
    chapters.overlap_offset = { margin, y + resume_h + margin }
    table.insert(root, chapters)
    info.overlap_offset = { margin + math.floor((btn_w - info_size.w) / 2), y + resume_h + chapters_h + margin * 2 }
    table.insert(root, info)
    self.resume_rect = { x = margin, y = y, w = btn_w, h = resume_h }
    self.chapters_rect = { x = margin, y = y + resume_h + margin, w = btn_w, h = chapters_h }
    self.header_h = header_h

    -- The summary, between the title and the buttons.
    self.summary_rects = {}
    if self.summary_text then
        local boxes = flowedSummary(self.summary_text, Font:getFace("cfont", 19), {
            beside = { x = text_x, y = header_h + margin + title:getSize().h + math.floor(margin / 2), w = text_w },
            below = { x = margin, w = btn_w },
            cover_bottom = header_h + margin + cover_h,
            bottom = y - math.floor(margin / 2),
            gap = math.floor(margin / 4),
        })
        for _index, box in ipairs(boxes) do
            box.widget.overlap_offset = { box.x, box.y }
            table.insert(root, box.widget)
            table.insert(self.summary_rects, box)
        end
    end

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
    for _index, rect in ipairs(self.summary_rects) do
        if inside(rect, pos) then
            if self.on_summary then self.on_summary() end
            return true
        end
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
