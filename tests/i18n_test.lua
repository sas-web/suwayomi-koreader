-- Checks the translation layer: language selection, English fallback, and that every translatable text in the
-- sources has a French entry with the same format specifiers (a mismatch would crash string.format on the device).
-- Run from KOReader's base folder with the plugin AND the VPN add-on installed in plugins/suwayomi.koplugin
-- (see tests/README.md):
--   ./luajit /path/to/tests/i18n_test.lua

local DIR = os.getenv("SUWAYOMI_PLUGIN_DIR") or "plugins/suwayomi.koplugin"
package.path = DIR .. "/?.lua;?.lua;common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;libs/?.so;" .. package.cpath
require("setupkoenv")

local gettext = require("gettext")
local _ = require("suwayomi_i18n")
local fr = require("suwayomi_lang_fr")

local failures = 0
local function check(name, cond, detail)
    print(string.format("%s  %s%s", cond and "OK  " or "FAIL", name, (not cond and detail) and ("  -> " .. detail) or ""))
    if not cond then failures = failures + 1 end
end

-- Language selection
gettext.current_lang = "C"
check("English (C): the text is returned as is", _("Loading chapters…") == "Loading chapters…")
gettext.current_lang = "fr_FR"
check("French (fr_FR): the text is translated", _("Loading chapters…") == "Chargement des chapitres…")
gettext.current_lang = "fr"
check("French (fr): the text is translated", _("Resume") == "Reprendre")
gettext.current_lang = "de_DE"
check("Language without a table: English fallback", _("Resume") == "Resume")
gettext.current_lang = "fr_FR"
check("Unknown text: returned as is", _("A text nobody translated") == "A text nobody translated")

-- Every text used in the code (_("...") calls) against the French table
local files = {}
local listing = io.popen('ls "' .. DIR .. '"/*.lua')
for path in listing:lines() do files[#files + 1] = path end
listing:close()

local used, count = {}, 0
for _i, path in ipairs(files) do
    local name = path:match("[^/]+$")
    if not name:match("^suwayomi_lang_") and name ~= "suwayomi_i18n.lua" and name ~= "_meta.lua" then
        local handle = io.open(path, "r")
        local source = handle:read("*a")
        handle:close()
        for raw in (" " .. source):gmatch('[^%w_.]_%("([^"]*)"%)') do
            local text = loadstring('return "' .. raw .. '"')() -- unescape \n like the Lua compiler does
            if not used[text] then used[text] = name; count = count + 1 end
        end
    end
end
check("the sources contain translatable texts", count > 50, tostring(count))

local function specifiers(text)
    local found = {}
    for spec in text:gmatch("%%[%d%.%-]*[sd]") do found[#found + 1] = spec end
    return table.concat(found, " ")
end

local missing, stale, mismatched = {}, {}, {}
for text, name in pairs(used) do
    if not fr[text] then
        missing[#missing + 1] = name .. ": " .. text
    elseif specifiers(text) ~= specifiers(fr[text]) then
        mismatched[#mismatched + 1] = text .. "  ->  " .. fr[text]
    end
end
for text in pairs(fr) do
    if not used[text] then stale[#stale + 1] = text end
end
check("every text has a French translation", #missing == 0, table.concat(missing, " | "))
check("no French entry for a text that no longer exists", #stale == 0, table.concat(stale, " | "))
check("translations keep the same format specifiers", #mismatched == 0, table.concat(mismatched, " | "))

print(failures == 0 and "\nALL TRANSLATION CHECKS PASS" or ("\n" .. failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
