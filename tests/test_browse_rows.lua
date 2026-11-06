---list rows and the web address of a feed entry: pure shapes, no nvim
local function repo_root()
  local src = (debug.getinfo(1, "S").source:gsub("^@", ""))
  return src:match("^(.*)/tests/[^/]+$") or "."
end

local REPO = repo_root()
package.path = REPO .. "/lua/?.lua;" .. REPO .. "/lua/?/init.lua;" .. package.path

local browse = require("zhihu.nvim.browse")
local han = "字"

return {
  name = "feed rows",
  run = function(t)
    t.eq("a short title is only collapsed", browse.truncate("a  b\nc", 40), "a b c")
    -- 字 takes two cells, so a width of ten holds four of them and the ellipsis
    t.eq("a long title is cut without splitting a character", browse.truncate(string.rep(han, 40), 10),
      string.rep(han, 4) .. "…")
    t.eq("an empty title stays empty", browse.truncate(nil, 10), "")

    local row = browse.row_text(3, { tag = "回答", title = "x" }, 80)
    t.eq("a row carries its number, its kind and its title", row, "  3 [回答] x")
    t.eq("a wide tag is kept as a whole", browse.row_text(1, { tag = "问题·浏览器", title = "标题" }, 80),
      "  1 [问题·浏览器] 标题")
    t.ok("a long row is cut instead of overflowing",
      browse.truncate(string.rep(han, 60), 20):find("…", 1, true) ~= nil)

    -- the second line of an entry: what it says, then what backs it up
    t.eq("a detail line pairs the excerpt with the meta",
      browse.detail_text({ excerpt = "摘要", meta = "@作者 · 12 赞" }, 80), "    摘要 · @作者 · 12 赞")
    t.eq("meta alone still gets a line", browse.detail_text({ meta = "@作者" }, 80), "    @作者")
    t.eq("an excerpt alone is not padded", browse.detail_text({ excerpt = "摘要" }, 80), "    摘要")
    t.eq("an entry with nothing more has no detail line", browse.detail_text({}, 80), "")
    t.eq("a narrow pane cuts the excerpt, not the meta",
      browse.detail_text({ excerpt = string.rep(han, 40), meta = "@x" }, 20), "    " .. string.rep(han, 4) .. "… · @x")

    local lines, row_item = browse.rows({
      { tag = "回答", title = "t1", excerpt = "e1", meta = "m1" },
      { tag = "文章", title = "t2" },
    }, 80)
    t.eq("an entry with a detail line owns two rows", #lines, 3)
    t.eq("the title row comes first", lines[1], "  1 [回答] t1")
    t.eq("then the detail row", lines[2], "    e1 · m1")
    t.eq("the next entry follows", lines[3], "  2 [文章] t2")
    t.eq("both rows of the first entry map back to it",
      table.concat(row_item, ","), "1,1,2")

    -- browser-only rows are folded out, and a folded row keeps the numbering of
    -- the entry behind it: row two is entry three, not entry two
    local folded, folded_map = browse.rows({
      { tag = "回答", title = "t1", uri = "zhihu://www.zhihu.com/question/1/answer/1.md" },
      { tag = "问题·浏览器", title = "t2", url = "https://www.zhihu.com/question/9" },
      { tag = "回答", title = "t3", uri = "zhihu://www.zhihu.com/question/3/answer/3.md" },
    }, 80, function(item)
      return not browse.dead(item)
    end)
    t.eq("a folded row is gone from the list", #folded, 2)
    t.eq("the rows after it keep their entry numbers", folded[2], "  3 [回答] t3")
    t.eq("and map back to the entries they came from", table.concat(folded_map, ","), "1,3")
    t.eq("an entry with a body is not dead", browse.dead { uri = "zhihu://a/b.md" }, false)
    t.eq("an entry only a browser can open is dead", browse.dead { url = "https://example.test/x" }, true)

    -- the pane before the body has been asked for: everything the feed already said
    local function has(lines, needle)
      for _, line in ipairs(lines) do
        if line:find(needle, 1, true) ~= nil then
          return true
        end
      end
      return false
    end
    local card = browse.card { tag = "回答", title = "标题", excerpt = "摘要", meta = "@作者 · 12 赞",
      uri = "zhihu://www.zhihu.com/question/1/answer/2.md" }
    t.eq("a card opens with the title as its heading", card[1], "# 标题")
    t.eq("then the kind and the numbers", card[3], "回答 · @作者 · 12 赞")
    t.ok("the excerpt is quoted", has(card, "> 摘要"))
    t.ok("and the card says how to get the body", has(card, "按 <CR> 拉这一条的正文。"))
    t.ok("a card never claims the body is here", not has(card, "<!DOCTYPE"))
    t.eq("a card without a title falls back to its kind", browse.card { tag = "想法" }[1], "# 想法")
    local dead_card = browse.card { tag = "问题·浏览器", title = "t", url = "https://www.zhihu.com/question/9" }
    t.ok("a dead card offers the browser instead", has(dead_card, "按 o 打开。"))
    t.ok("and names the address it would open", has(dead_card, "https://www.zhihu.com/question/9"))

    t.eq("an answer uri maps to its question page",
      browse.web_url { uri = "zhihu://www.zhihu.com/question/1/answer/2.md" }, "https://www.zhihu.com/question/1/answer/2")
    t.eq("a column uri maps to its article page",
      browse.web_url { uri = "zhihu://zhuanlan.zhihu.com/p/207.md" }, "https://zhuanlan.zhihu.com/p/207")
    t.eq("a feed url wins over the uri", browse.web_url { url = "https://example.test/x", uri = "zhihu://a/b.md" },
      "https://example.test/x")
    t.eq("an entry with neither has no address", browse.web_url {}, nil)

    -- where a row sits: every entry owns a row plus a detail row, so the keys
    -- of row_item are 1, 3, 5… and the plain ipairs walk would stop early
    local row_item = { [1] = 1, [3] = 2, [5] = 3 }
    local items = {
      { uri = "zhihu://a.md" },
      { uri = "zhihu://b.md" },
      { uri = "zhihu://c.md" },
    }
    t.eq("the row of a remembered entry is found past its detail row",
      browse.row_of(row_item, items, "zhihu://c.md"), 5)
    t.eq("the first row is found too", browse.row_of(row_item, items, "zhihu://a.md"), 1)
    t.eq("an entry that is gone has no row", browse.row_of(row_item, items, "zhihu://gone.md"), nil)
    t.eq("nothing remembered has no row", browse.row_of(row_item, items, nil), nil)
    t.eq("an empty list has no row", browse.row_of({}, items, "zhihu://a.md"), nil)

    -- a winbar is a statusline: a bare % in a title is a format character and
    -- nvim answers E539, which used to break the pane on any "5.52%" headline
    t.eq("a percent in a title is escaped for the winbar", browse.bar("暴跌 5.52%"), "暴跌 5.52%%")
    t.eq("every percent is escaped", browse.bar("%d%%"), "%%d%%%%")
    t.eq("a control character becomes a space", browse.bar("a\tb"), "a b")
    t.eq("nothing becomes nothing", browse.bar(nil), "")
  end,
}
