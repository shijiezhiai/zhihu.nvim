---the page of what was read lately: how it groups the days and writes the rows
local function repo_root()
  local src = (debug.getinfo(1, "S").source:gsub("^@", ""))
  return src:match("^(.*)/tests/[^/]+$") or "."
end

local REPO = repo_root()
package.path = REPO .. "/lua/?.lua;" .. REPO .. "/lua/?/init.lua;" .. package.path

local journal = require("zhihu.nvim.journal")

local NOW = os.time { year = 2026, month = 11, day = 6, hour = 12, min = 0, sec = 0 }

local function at(offset)
  return NOW - offset
end

local function find(lines, text)
  for index, line in ipairs(lines) do
    if line == text then
      return index
    end
  end
  return nil
end

return {
  name = "journal",
  run = function(t)
    local entries = {
      { uri = "zhihu://a.md", at = at(60), title = "今天读的", tag = "回答", meta = "@甲 · 3 赞" },
      { uri = "zhihu://b.md", at = at(86400 + 60), title = "昨天读的" },
      { uri = "zhihu://c.md", at = at(3 * 86400), tag = "文章" },
    }

    local lines = journal.lines(entries, NOW, 7)
    t.eq("the page opens with how much and how far back", lines[1], "# 最近 7 天读了 3 条")
    t.ok("today has its own group", find(lines, "## 今天") ~= nil)
    t.ok("so does yesterday", find(lines, "## 昨天") ~= nil)
    t.ok("anything older is grouped by its date",
      find(lines, "## " .. os.date("%Y-%m-%d", at(3 * 86400))) ~= nil)
    t.eq("a row carries the title, what it is and the entry address",
      lines[5], "- [今天读的](zhihu://a.md) · 回答 · @甲 · 3 赞")
    t.eq("a row without a title shows the address instead",
      lines[#lines], "- [zhihu://c.md](zhihu://c.md) · 文章")
    t.eq("the first group opens after a blank line", lines[3], "## 今天")
    t.eq("and the head has a blank line under it", lines[2], "")
    t.eq("and the page ends on a row, not on a blank", lines[#lines]:sub(1, 2), "- ")

    local empty = journal.lines({}, NOW, 7)
    t.eq("an empty window still says how far back it looked", empty[1], "# 最近 7 天读了 0 条")
    t.ok("and how to fill it", empty[3]:find("<CR>", 1, true) ~= nil)

    t.eq("the window is what the caller asked for", journal.lines(entries, NOW, 30)[1], "# 最近 30 天读了 3 条")
    t.ok("a page with no arguments still reads as a week",
      journal.lines(entries)[1]:find("7 天", 1, true) ~= nil, journal.lines(entries)[1])

    local long = { uri = "zhihu://d.md", at = NOW, title = string.rep("字", 80) }
    local short = journal.lines({ long }, NOW, 7)
    t.ok("a long title is cut with an ellipsis", short[5]:find("…", 1, true) ~= nil, short[5])
    t.eq("and stays at the 60 cell budget", short[5]:match("^%- %[([^%]]*)%]"), string.rep("字", 29) .. "…")
  end,
}
