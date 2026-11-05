---uri parsing for zhihu list pages: plain luajit, no vim, no network
local function repo_root()
  local src = (debug.getinfo(1, "S").source:gsub("^@", ""))
  return src:match("^(.*)/tests/[^/]+$") or "."
end

local REPO = repo_root()
package.path = REPO .. "/lua/?.lua;" .. REPO .. "/lua/?/init.lua;" .. package.path

local List = require("zhihu.list").List

return {
  name = "list uri parsing",
  run = function(t)
    -- 1. a question's answers, first page
    local answers = List.from_url("zhihu://www.zhihu.com/question/19550517/answers.md")
    t.eq("answers uri is a list", answers and answers.kind, "answers")
    t.eq("answers uri keeps the question id", answers and answers.id, "19550517")
    t.eq("answers uri starts at offset 0", answers and answers.offset, 0)
    t.eq("offset is a number", type(answers and answers.offset), "number")
    t.eq("answers uri is rendered back unchanged", answers:path(),
      "zhihu://www.zhihu.com/question/19550517/answers.md")

    -- 2. a later page carries its offset
    local page = List.from_url("zhihu://www.zhihu.com/question/19550517/answers-40.md")
    t.eq("paged answers uri is a list", page and page.kind, "answers")
    t.eq("paged answers uri keeps the question id", page and page.id, "19550517")
    t.eq("paged answers uri reads the offset", page and page.offset, 40)
    t.eq("paged answers uri is rendered back", page:path(),
      "zhihu://www.zhihu.com/question/19550517/answers-40.md")

    -- 3. an explicit zero offset is canonicalised away
    local zero = List.from_url("zhihu://www.zhihu.com/question/19550517/answers-0.md")
    t.eq("answers-0 parses as offset 0", zero and zero.offset, 0)
    t.eq("answers-0 renders without the suffix", zero:path(),
      "zhihu://www.zhihu.com/question/19550517/answers.md")

    -- 4. a column's articles
    local column = List.from_url("zhihu://www.zhihu.com/column/c_1234567890.md")
    t.eq("column uri is a list", column and column.kind, "articles")
    t.eq("column uri keeps the slug", column and column.id, "c_1234567890")
    t.eq("column uri starts at offset 0", column and column.offset, 0)
    t.eq("column uri is rendered back", column:path(), "zhihu://www.zhihu.com/column/c_1234567890.md")

    -- 5. a later column page
    local column_page = List.from_url("zhihu://www.zhihu.com/column/c_1234567890-20.md")
    t.eq("paged column uri keeps the slug", column_page and column_page.id, "c_1234567890")
    t.eq("paged column uri reads the offset", column_page and column_page.offset, 20)
    t.eq("paged column uri is rendered back", column_page:path(),
      "zhihu://www.zhihu.com/column/c_1234567890-20.md")

    -- 6. the article uris must keep going to the article path
    t.eq("a question uri is not a list", List.from_url("zhihu://www.zhihu.com/question/19550517.md"), nil)
    t.eq("an answer uri is not a list", List.from_url("zhihu://www.zhihu.com/question/19550517/answer/123.md"),
      nil)
    t.eq("a zhuanlan uri is not a list", List.from_url("zhihu://zhuanlan.zhihu.com/p/123.md"), nil)

    -- 7. garbage is rejected instead of guessed at
    t.eq("no scheme is not a list", List.from_url("https://www.zhihu.com/question/19550517/answers.md"), nil)
    t.eq("a non numeric question id is not a list", List.from_url("zhihu://www.zhihu.com/question/abc/answers.md"),
      nil)
    t.eq("a missing page name is not a list", List.from_url("zhihu://www.zhihu.com/question/19550517/.md"), nil)
    t.eq("nil is not a list", List.from_url(nil), nil)

    -- 8. a pager target keeps kind and id
    t.eq("path_at keeps the list and moves the offset", answers:path_at(60),
      "zhihu://www.zhihu.com/question/19550517/answers-60.md")
    t.eq("path_at(0) falls back to the bare uri", answers:path_at(0),
      "zhihu://www.zhihu.com/question/19550517/answers.md")
    t.eq("path_at works for a column too", column:path_at(20), "zhihu://www.zhihu.com/column/c_1234567890-20.md")
  end,
}
