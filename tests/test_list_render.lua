---rendering rows as markdown lines: pure, so the fixtures are plain tables
local function repo_root()
  local src = (debug.getinfo(1, "S").source:gsub("^@", ""))
  return src:match("^(.*)/tests/[^/]+$") or "."
end

local REPO = repo_root()
package.path = REPO .. "/lua/?.lua;" .. REPO .. "/lua/?/init.lua;" .. package.path

local List = require("zhihu.list").List

local function row(id, title, author, votes, comments, url)
  return {
    id = id,
    title = title,
    excerpt = title,
    author = author,
    votes = votes,
    comments = comments,
    url = url,
  }
end

local function answers_rows()
  local rows = {
    row("40211301", "先说结论。", "张三", 1234, 56,
      "zhihu://www.zhihu.com/question/19550517/answer/40211301.md"),
    row("40211302", "匿名用户的回答", nil, 7, 0,
      "zhihu://www.zhihu.com/question/19550517/answer/40211302.md"),
  }
  rows.totals = 137
  rows.question_title = "如何评价测试驱动开发？"
  return rows
end

local ANSWERS = "zhihu://www.zhihu.com/question/19550517/answers.md"

return {
  name = "list rendering",
  run = function(t)
    local first = List.from_url(ANSWERS)
    local lines = first:lines(answers_rows())

    t.eq("line 1 names the question", lines[1], "# 如何评价测试驱动开发？")
    t.eq("line 2 counts the page", lines[2], "答案 1–2 / 共 137 · 第 1 页")
    t.eq("an entry is numbered and summarised", lines[3],
      "1. **先说结论。** — @张三 · 赞 1234 · 评论 56")
    t.eq("an entry links its answer", lines[4],
      "    `zhihu://www.zhihu.com/question/19550517/answer/40211301.md`")
    t.eq("a missing author reads anonymous", lines[5],
      "2. **匿名用户的回答** — @匿名 · 赞 7 · 评论 0")
    t.eq("the last line offers the next page only", lines[7],
      "[下一页](zhihu://www.zhihu.com/question/19550517/answers-20.md)")
    t.eq("two rows and a pager make seven lines", #lines, 7)

    local third = List.from_url("zhihu://www.zhihu.com/question/19550517/answers-40.md")
    local page = third:lines(answers_rows())
    t.eq("the header knows the page number", page[2], "答案 41–42 / 共 137 · 第 3 页")
    t.ok("numbering continues from the offset", page[3]:match("^41%. ") ~= nil)
    t.eq("a middle page offers both directions", page[#page],
      "[上一页](zhihu://www.zhihu.com/question/19550517/answers-20.md) · " ..
      "[下一页](zhihu://www.zhihu.com/question/19550517/answers-60.md)")

    local no_totals = List.from_url(ANSWERS)
    local short = { row("1", "只有一条", "某人", 3.7, 1.2, "zhihu://www.zhihu.com/question/19550517/answer/1.md") }
    local short_lines = no_totals:lines(short)
    t.eq("an unknown total is left out", short_lines[2], "答案 1–1")
    t.eq("a short page without totals has no pager", short_lines[5], nil)
    t.ok("a fractional vote is floored", short_lines[3]:find("赞 3 · 评论 1", 1, true) ~= nil)

    local empty = List.from_url(ANSWERS)
    local empty_lines = empty:lines({ totals = 0, question_title = "" })
    t.eq("an empty page falls back to the question id", empty_lines[1], "# 问题 19550517")
    t.eq("an empty page says so", empty_lines[2], "答案 暂无")
    t.eq("an empty page has no entries", #empty_lines, 2)

    local column = List.from_url("zhihu://www.zhihu.com/column/c_1234567890.md")
    local items = { row("98765", "线性代数应该这样学", "李四", 12, 3, "zhihu://zhuanlan.zhihu.com/p/98765.md") }
    items.totals = 1
    items.question_title = ""
    local item_lines = column:lines(items)
    t.eq("a column falls back to the slug", item_lines[1], "# 专栏 c_1234567890")
    t.eq("a column counts articles", item_lines[2], "文章 1–1 / 共 1 · 第 1 页")
    t.eq("an article entry carries its title", item_lines[3],
      "1. **线性代数应该这样学** — @李四 · 赞 12 · 评论 3")
    t.eq("an article entry links zhuanlan", item_lines[4], "    `zhihu://zhuanlan.zhihu.com/p/98765.md`")
    t.eq("the only article page has no pager", #item_lines, 4)

    local named = List.from_url("zhihu://www.zhihu.com/column/c_1234567890-20.md")
    items.question_title = "我的专栏"
    local named_lines = named:lines(items)
    t.eq("a column keeps a supplied title", named_lines[1], "# 我的专栏")
    t.eq("a column page knows its number", named_lines[2], "文章 21–21 / 共 1 · 第 2 页")
    t.eq("an out of range page still shows the previous link",
      named_lines[#named_lines], "[上一页](zhihu://www.zhihu.com/column/c_1234567890.md)")

    local long = List.from_url(ANSWERS)
    local long_rows = {
      row("1", string.rep("中", 100), "长文作者", 0, 0, "zhihu://www.zhihu.com/question/19550517/answer/1.md"),
    }
    local long_lines = long:lines(long_rows)
    t.ok("a long summary is cut at 80 characters", long_lines[3]:find(string.rep("中", 80) .. "…", 1, true) ~= nil)
    t.ok("a long summary stops at the cut", long_lines[3]:find(string.rep("中", 81), 1, true) == nil)
    t.eq("the cut is visible as one ellipsis", select(2, long_lines[3]:gsub("…", "")) , 1)

    t.eq("rendering loads no http client", package.loaded["requests"], nil)
  end,
}
