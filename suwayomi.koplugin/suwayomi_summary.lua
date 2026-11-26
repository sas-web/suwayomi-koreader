-- Turns the description of a series, as Suwayomi sends it, into a plain-text summary.
-- Sources often add blocks after the story ("Associated Name(s):", "Tracker(s):", "Related Series(s):"...),
-- Markdown links and sometimes a bit of HTML: none of that is wanted on the series screen.

local Summary = {}

-- A line starting one of these blocks ends the story.
local APPENDIX = {
    "^alternative names?[%(%)s]*:",
    "^alternative titles?[%(%)s]*:",
    "^associated names?[%(%)s]*:",
    "^related series[%(%)s]*:",
    "^trackers?[%(%)s]*:",
    "^official links?:",
    "^links?:",
    "^notes?:",
}

local ENTITIES = { ["&quot;"] = '"', ["&apos;"] = "'", ["&#39;"] = "'", ["&lt;"] = "<", ["&gt;"] = ">",
    ["&nbsp;"] = " " }

local function startsAppendix(line)
    local text = (line:gsub("^[%s%*_#>%-]+", "")):lower()
    for _index, pattern in ipairs(APPENDIX) do
        if text:find(pattern) then return true end
    end
    return false
end

--- Returns the summary as plain text (paragraphs separated by an empty line), or nil if there is none.
function Summary.clean(description)
    if type(description) ~= "string" then return nil end -- a JSON null is not a string
    local text = description:gsub("\r\n?", "\n")
    text = text:gsub("<[bB][rR]%s*/?>", "\n")
    text = text:gsub("</?%a[^<>]*>", "")
    text = text:gsub("&[#%w]+;", ENTITIES)
    text = text:gsub("&amp;", "&")
    text = text:gsub("!?%[([^%[%]]*)%]%b()", "%1") -- [label](address) -> label
    text = text:gsub("https?://%S+", "")
    text = text:gsub("%*%*", ""):gsub("__", "")

    local lines, pending_blank = {}, false
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        -- Only cut once some story has been read: a header in first position is not an appendix.
        if #lines > 0 and startsAppendix(line) then break end
        if line == "" or line:find("^[%-%*_][%-%*_][%-%*_]+$") then
            pending_blank = #lines > 0
        else
            if pending_blank then table.insert(lines, "") end
            pending_blank = false
            table.insert(lines, line)
        end
    end
    if #lines == 0 then return nil end
    return table.concat(lines, "\n")
end

--- The same summary without empty lines between paragraphs, for the small space of the series screen.
function Summary.compact(summary)
    if not summary then return nil end
    return (summary:gsub("\n\n+", "\n"))
end

return Summary
