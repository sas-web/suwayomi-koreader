-- Minimal Suwayomi API client (GraphQL + CBZ download).
-- Every call is blocking and returns (result) or (nil, error message).

local http = require("socket.http")
local json = require("json")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")

local _ = require("suwayomi_i18n")

local Api = {
    server_url = "http://localhost:4567",
}

local function trimSlash(url)
    return (url:gsub("/+$", ""))
end

function Api:setServer(url)
    self.server_url = trimSlash(url)
end

--- Quick test: does the server at this address answer? (used to choose between the local network and the VPN)
function Api:ping(url, timeout)
    socketutil:set_timeout(timeout or 3, (timeout or 3) + 2)
    local code = socket.skip(1, http.request({
        url = trimSlash(url) .. "/api/v1/settings/about",
        method = "GET",
        sink = ltn12.sink.null(),
    }))
    socketutil:reset_timeout()
    return code == 200
end

--- Runs a GraphQL request. Returns the `data` table, or nil and an error message.
function Api:graphql(query, variables)
    local body = json.encode({ query = query, variables = variables or {} })
    local sink = {}
    socketutil:set_timeout(10, 30)
    local code, _headers, status = socket.skip(1, http.request({
        url = self.server_url .. "/api/graphql",
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(sink),
    }))
    socketutil:reset_timeout()

    if code ~= 200 then
        return nil, _("Server unreachable: ") .. tostring(status or code)
    end
    local ok, decoded = pcall(json.decode, table.concat(sink))
    if not ok or type(decoded) ~= "table" then
        return nil, _("Unreadable server response")
    end
    if decoded.errors and not decoded.data then
        return nil, tostring(decoded.errors[1] and decoded.errors[1].message or "GraphQL error")
    end
    return decoded.data
end

--- Library series: { id, title, unread, total }.
function Api:getLibrary()
    local data, err = self:graphql([[
        { mangas(condition: {inLibrary: true}) {
            nodes { id title unreadCount chapters { totalCount } }
        } }
    ]])
    if not data then return nil, err end
    local series = {}
    for _index, m in ipairs(data.mangas.nodes) do
        table.insert(series, {
            id = m.id,
            title = m.title,
            unread = m.unreadCount or 0,
            total = m.chapters and m.chapters.totalCount or 0,
        })
    end
    return series
end

--- Library categories in Suwayomi's order: { id, name, ids = { [series_id] = true } }.
function Api:getCategories()
    local data, err = self:graphql([[
        { categories { nodes { id name order mangas { nodes { id } } } } }
    ]])
    if not data then return nil, err end
    local nodes = data.categories.nodes
    table.sort(nodes, function(a, b) return a.order < b.order end)
    local categories = {}
    for _index, c in ipairs(nodes) do
        local ids = {}
        for _index2, m in ipairs(c.mangas.nodes) do ids[m.id] = true end
        table.insert(categories, { id = c.id, name = c.name, ids = ids })
    end
    return categories
end

--- Last chapter touched in each series: table mangaId -> chapter, plus `latest` = the most recently
--- touched chapter across all series.
function Api:getLastRead()
    local data, err = self:graphql([[
        { chapters(filter: {lastReadAt: {greaterThan: "0"}},
                   orderBy: LAST_READ_AT, orderByType: DESC, first: 1000) {
            nodes { id name chapterNumber isRead lastPageRead pageCount mangaId lastReadAt }
        } }
    ]])
    if not data then return nil, err end
    local by_manga, latest = {}, nil
    for _index, c in ipairs(data.chapters.nodes) do
        local seen = by_manga[c.mangaId]
        -- Equal timestamps (bulk update): keep the oldest chapter.
        if not seen or (c.lastReadAt == seen.lastReadAt and c.chapterNumber < seen.chapterNumber) then
            by_manga[c.mangaId] = c
        end
        latest = latest or c
    end
    return by_manga, latest
end

--- Chapters of a series, oldest first.
function Api:getChapters(manga_id)
    local data, err = self:graphql([[
        query($id: Int!) { chapters(condition: {mangaId: $id},
                                    orderBy: SOURCE_ORDER, orderByType: ASC) {
            nodes { id name chapterNumber sourceOrder isRead lastPageRead lastReadAt pageCount mangaId }
        } }
    ]], { id = manga_id })
    if not data then return nil, err end
    local chapters = data.chapters.nodes
    table.sort(chapters, function(a, b)
        if a.chapterNumber ~= b.chapterNumber then
            return a.chapterNumber < b.chapterNumber
        end
        return a.sourceOrder < b.sourceOrder
    end)
    return chapters
end

--- Saves a chapter's progress. `last_page` is 0-based, like in Suwayomi.
function Api:updateProgress(chapter_id, last_page, is_read)
    local patch = { lastPageRead = last_page }
    if is_read then patch.isRead = true end
    local data, err = self:graphql([[
        mutation($id: Int!, $patch: UpdateChapterPatchInput!) {
            updateChapter(input: {id: $id, patch: $patch}) { chapter { id isRead lastPageRead } }
        }
    ]], { id = chapter_id, patch = patch })
    if not data then
        logger.warn("Suwayomi: updateProgress failed:", err)
        return nil, err
    end
    return true
end

--- Marks several chapters read or unread in a single request.
--- `reset_page` also resets the reading page to 0 (for chapters set back to "unread").
function Api:setChaptersRead(ids, is_read, reset_page)
    if #ids == 0 then return true end
    local patch = { isRead = is_read }
    if reset_page then patch.lastPageRead = 0 end
    local data, err = self:graphql([[
        mutation($ids: [Int!]!, $patch: UpdateChapterPatchInput!) {
            updateChapters(input: {ids: $ids, patch: $patch}) { chapters { id } }
        }
    ]], { ids = ids, patch = patch })
    if not data then return nil, err end
    return true
end

--- Downloads `url` to `path` (through a .part file, renamed at the end).
function Api:downloadFile(url, path, block_timeout, total_timeout)
    local part = path .. ".part"
    local file = io.open(part, "wb")
    if not file then
        return nil, _("Cannot write to ") .. part
    end
    socketutil:set_timeout(block_timeout or socketutil.FILE_BLOCK_TIMEOUT,
        total_timeout or socketutil.FILE_TOTAL_TIMEOUT)
    local code, _headers, status = socket.skip(1, http.request({
        url = url,
        headers = { ["Accept-Encoding"] = "identity" },
        sink = ltn12.sink.file(file),
    }))
    socketutil:reset_timeout()

    if code ~= 200 then
        os.remove(part)
        return nil, _("Download failed: ") .. tostring(status or code)
    end
    local ok, rename_err = os.rename(part, path)
    if not ok then
        os.remove(part)
        return nil, tostring(rename_err)
    end
    return path
end

--- Downloads a chapter as a CBZ to `path`.
function Api:downloadChapter(chapter_id, path)
    local file, err = self:downloadFile(string.format("%s/api/v1/chapter/%d/download", self.server_url, chapter_id), path)
    if not file and err and err:find("400", 1, true) then
        -- Suwayomi answers 400 when the chapter is not (or no longer) downloaded on the server.
        return nil, _("This chapter is not downloaded on the Suwayomi server (the download failed or is still queued on the server).")
    end
    return file, err
end

--- Downloads a series' cover to `path` (original format: JPEG, PNG, WebP or GIF).
function Api:downloadCover(manga_id, path)
    return self:downloadFile(string.format("%s/api/v1/manga/%d/thumbnail", self.server_url, manga_id), path, 10, 30)
end

return Api
