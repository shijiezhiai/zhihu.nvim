---carrying a body away: the quote block, the note and its file name
local function repo_root()
  local src = (debug.getinfo(1, "S").source:gsub("^@", ""))
  return src:match("^(.*)/tests/[^/]+$") or "."
end

local REPO = repo_root()
package.path = REPO .. "/lua/?.lua;" .. REPO .. "/lua/?/init.lua;" .. package.path

local browse = require("zhihu.nvim.browse")

local item = {
  tag = "回答",
  title = "钱学森的实力如何？",
  meta = "@作者 · 12 赞",
  uri = "zhihu://www.zhihu.com/question/442792862/answer/1989060695120160613.md",
}

local function join(lines)
  return table.concat(lines, "\n")
end

return {
  name = "carry away",
  run = function(t)
    local body = { "第一段", "", "第二段" }

    t.eq("a quote block opens with the title and what backs it up",
      browse.quote_lines(item, body)[1], "> 钱学森的实力如何？ · @作者 · 12 赞")
    t.eq("then the empty quote line", browse.quote_lines(item, body)[2], ">")
    t.eq("blank body lines stay quoted so the block does not break",
      join(browse.quote_lines(item, body)),
      "> 钱学森的实力如何？ · @作者 · 12 赞\n>\n> 第一段\n>\n> 第二段\n>\n" ..
      "> —— https://www.zhihu.com/question/442792862/answer/1989060695120160613")
    t.eq("no meta means no trailing separator",
      browse.quote_lines({ title = "t", url = "https://x" }, { "a" })[1], "> t")
    t.eq("an item with no address ends on the body",
      browse.quote_lines({ title = "t" }, { "a" })[3], "> a")

    local note = browse.md_lines(item, { "第一段", "", "第二段", "", "" })
    t.eq("a note starts with the title", note[1], "# 钱学森的实力如何？")
    t.eq("then what it is", note[3], "回答 · @作者 · 12 赞")
    t.eq("the whole note reads well",
      join(note),
      "# 钱学森的实力如何？\n\n回答 · @作者 · 12 赞\n\n第一段\n\n第二段\n\n---\n\n" ..
      "来源：https://www.zhihu.com/question/442792862/answer/1989060695120160613")
    t.eq("the blank lines a body ends with are dropped", #note, 11)

    local with_excerpt = browse.md_lines({ title = "t", excerpt = "摘要" }, { "b" })
    t.eq("an excerpt is quoted under the facts", with_excerpt[3], "> 摘要")
    t.eq("a body without an address has no source section",
      browse.md_lines({ title = "t" }, { "b" })[3], "b")

    t.eq("a file name keeps the words", browse.md_name("钱学森的实力如何？"), "钱学森的实力如何？.md")
    t.eq("the characters a file system refuses become spaces",
      browse.md_name("如何评价<钱学森>/第二季?*"), "如何评价 钱学森 第二季.md")
    t.eq("an empty title falls back to the kind",
      browse.md_name("", "回答"), "回答.md")
    t.eq("no title and no kind still leaves a name", browse.md_name(nil, nil), "知乎.md")
    t.eq("a long title is cut to a workable name",
      browse.md_name(string.rep("字", 80)),
      string.rep("字", 29) .. ".md")
  end,
}
