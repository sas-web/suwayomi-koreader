-- Series covers: on-device cache and image widget creation.

local DataStorage = require("datastorage")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local RenderImage = require("ui/renderimage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Api = require("suwayomi_api")
local _ = require("suwayomi_i18n")

local Covers = {}

local function mkdirs(path)
    local current = ""
    for part in path:gmatch("[^/]+") do
        current = current .. "/" .. part
        if lfs.attributes(current, "mode") == nil then lfs.mkdir(current) end
    end
end

local function cacheDir()
    local dir = DataStorage:getDataDir()
    if dir:sub(1, 1) ~= "/" then -- relative path (emulator)
        dir = lfs.currentdir() .. "/" .. dir:gsub("^%./", "")
    end
    return dir .. "/cache/suwayomi_covers"
end

--- Path of a series' cached cover file.
function Covers.path(series)
    return string.format("%s/%d.cover", cacheDir(), series.id)
end

--- Downloads the covers of `list` that are not cached yet (with a message while it runs).
function Covers.ensure(list)
    local missing = {}
    for _i, s in ipairs(list) do
        if lfs.attributes(Covers.path(s), "mode") ~= "file" then table.insert(missing, s) end
    end
    if #missing == 0 then return end

    mkdirs(cacheDir())
    local message = InfoMessage:new({ text = _("Loading covers…") })
    UIManager:show(message)
    UIManager:forceRePaint()
    for _i, s in ipairs(missing) do
        local ok, err = pcall(function() return Api:downloadCover(s.id, Covers.path(s)) end)
        if not ok then logger.warn("Suwayomi: cover", s.id, err) end
    end
    UIManager:close(message)
end

--- Cover image widget (fits in w x h), or nil if the cover is missing or unreadable.
function Covers.widget(series, w, h)
    local path = Covers.path(series)
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    local ok, bb = pcall(RenderImage.renderImageFile, RenderImage, path, false, w, h)
    if not ok or not bb then
        logger.info("Suwayomi: unreadable cover for", series.title)
        return nil
    end
    return ImageWidget:new({
        image = bb,
        image_disposable = true,
        width = w,
        height = h,
        scale_factor = 0, -- fit the cell while keeping the proportions
    })
end

return Covers
