-- Translations for the plugin's own texts.
--
-- KOReader has a single global translation catalogue and no per-plugin catalogues, so the texts of a
-- third-party plugin are never translated by gettext. This module fills the gap: texts are written in English
-- in the code, keyed by their English text, and looked up in `suwayomi_lang_<code>.lua` for the language
-- selected in KOReader (Settings > Language). A text with no translation is shown in English.
--
--   local _ = require("suwayomi_i18n")
--   _("Loading chapters…")                          --> "Chargement des chapitres…" in French
--   string.format(_("%d unread"), 3)                --> keep format specifiers inside the translated text
--
-- To add a language, copy suwayomi_lang_fr.lua to suwayomi_lang_<code>.lua (two-letter code, e.g. "de")
-- and translate the values.

local cache = {} -- language code -> translation table (false when there is none)

--- Two-letter code of the language selected in KOReader ("fr_FR" -> "fr"), "en" if unknown or English.
local function currentCode()
    local ok, gettext = pcall(require, "gettext")
    local lang = ok and type(gettext) == "table" and gettext.current_lang or "C"
    return tostring(lang):match("^(%a%a)") or "en"
end

local function tableFor(code)
    if cache[code] == nil then
        local ok, translations = pcall(require, "suwayomi_lang_" .. code)
        cache[code] = ok and type(translations) == "table" and translations or false
    end
    return cache[code]
end

return setmetatable({}, {
    __call = function(_, text)
        local translations = tableFor(currentCode())
        return translations and translations[text] or text
    end,
})
