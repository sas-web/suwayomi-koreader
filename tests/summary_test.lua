-- Checks the cleanup of series descriptions (suwayomi_summary.lua) on the shapes seen on a real server.
-- Run from KOReader's base folder with the plugin installed in plugins/suwayomi.koplugin (see tests/README.md):
--   ./luajit /path/to/tests/summary_test.lua

local DIR = os.getenv("SUWAYOMI_PLUGIN_DIR") or "plugins/suwayomi.koplugin"
package.path = DIR .. "/?.lua;" .. package.path

local Summary = require("suwayomi_summary")

local failures = 0
local function check(name, got, expected)
    local ok = got == expected
    print(string.format("%s  %s%s", ok and "OK  " or "FAIL", name,
        ok and "" or string.format("  -> got %q, expected %q", tostring(got), tostring(expected))))
    if not ok then failures = failures + 1 end
end

check("no description", Summary.clean(nil), nil)
check("a JSON null (not a string)", Summary.clean(function() end), nil)
check("empty description", Summary.clean("  \n\n "), nil)
check("plain text is kept", Summary.clean("A story."), "A story.")
check("paragraphs are kept, extra empty lines dropped",
    Summary.clean("One.\r\n\r\n\r\n\r\nTwo.\n"), "One.\n\nTwo.")

check("trackers block and its links are cut",
    Summary.clean("The story.\n\nTracker(s):\n- [Official Source](https://example.org/a)\n- [AniList](https://x.y/1)"),
    "The story.")
check("associated names block is cut",
    Summary.clean("The story.\n\nAssociated Name(s):\n- Another Title"), "The story.")
check("related series block is cut",
    Summary.clean("The story.\n\nRelated Series(s):\n- [Spin-off](https://example.org/s) (Side Story)"), "The story.")
check("bold alternative names line is cut",
    Summary.clean("The story.\n\n**Alternative Names:** One; Two"), "The story.")
check("final note is cut", Summary.clean("The story.\nNote: it won an award."), "The story.")
check("a header in first position does not empty the summary",
    Summary.clean("Note: a one-shot.\nThe story."), "Note: a one-shot.\nThe story.")
check("an introduction such as \"From Shueisha:\" is kept",
    Summary.clean("From Shueisha: Young Chihiro trains."), "From Shueisha: Young Chihiro trains.")
check("a sentence that merely starts like a header is kept",
    Summary.clean("He hunts.\nTracker Ryu never sleeps.\nLinks between worlds open."),
    "He hunts.\nTracker Ryu never sleeps.\nLinks between worlds open.")

check("Markdown link inside the story keeps its label",
    Summary.clean("A sequel to [Gantz](https://example.org/g_(manga))."), "A sequel to Gantz.")
check("bare address removed", Summary.clean("See https://example.org/page"), "See")
check("bold marks removed", Summary.clean("**Bold** and __strong__ words"), "Bold and strong words")
check("HTML breaks, tags and entities",
    Summary.clean("<p>Tom &amp; &quot;Jerry&quot;<br/>again, it&#39;s fun <3</p>"),
    "Tom & \"Jerry\"\nagain, it's fun <3")
check("separator lines dropped", Summary.clean("One.\n---\nTwo."), "One.\n\nTwo.")

check("compact version has no empty lines", Summary.compact("One.\n\nTwo.\nThree."), "One.\nTwo.\nThree.")
check("compact of nothing", Summary.compact(nil), nil)

print(failures == 0 and "\nALL SUMMARY CHECKS PASS" or ("\n" .. failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
