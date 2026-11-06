---search rows: the payload shape and the paging it shares with a feed
local function repo_root()
  local src = (debug.getinfo(1, "S").source:gsub("^@", ""))
  return src:match("^(.*)/tests/[^/]+$") or "."
end

local REPO = repo_root()
package.path = REPO .. "/lua/?.lua;" .. REPO .. "/lua/?/init.lua;" .. package.path

_G.vim = _G.vim or {
  deepcopy = function(source)
    local copy = {}
    for key, value in pairs(source) do
      copy[key] = value
    end
    return copy
  end,
}

package.preload["requests"] = function()
  return { get = function() return { status_code = 404, text = "" } end }
end

package.preload["zhihu.api"] = function()
  return { set_cookie_header = function(api) return api end }
end

local search = require("zhihu.api.get.search")

local function entry(object)
  return { type = "search_result", object = object }
end

return {
  name = "search_v3 rows",
  run = function(t)
    t.eq("a query is percent encoded byte by byte", search.escape("公式"), "%E5%85%AC%E5%BC%8F")
    t.eq("a space becomes %20", search.escape("a b"), "a%20b")
    t.eq("a plus is encoded too", search.escape("C++"), "C%2B%2B")
    t.eq("the url is the one the site itself calls", search.url("公式"),
      "https://www.zhihu.com/api/v4/search_v3?t=general&q=%E5%85%AC%E5%BC%8F&correction=1")

    local answer = search.item(entry {
      type = "answer",
      -- the json decoder keeps 19 digit ids as strings: a double cannot hold them
      id = "1910970916533433365",
      question = { id = 286269519 },
      title = "你所见过的最美的<em>公式</em>是什么？",
      excerpt = "我先说一个：<em>欧拉</em>公式",
      voteup_count = 18,
      author = { name = "湫啾儿" },
      content = "<p>full body</p>",
    })
    t.eq("an answer row keeps its question", answer.tag, "回答")
    t.eq("and opens through the reader", answer.uri,
      "zhihu://www.zhihu.com/question/286269519/answer/1910970916533433365.md")
    t.eq("the highlight markup is not shown", answer.title, "你所见过的最美的公式是什么？")
    t.eq("and its words stay together", answer.excerpt, "我先说一个：欧拉公式")
    t.eq("meta names the author and the votes", answer.meta, "@湫啾儿 · 18 赞")

    local article = search.item(entry {
      type = "article",
      id = 16628901797,
      title = "两个<em>公式</em>",
      excerpt = "摘录",
    })
    t.eq("an article row", article.tag, "文章")
    t.eq("opens as a column", article.uri, "zhihu://zhuanlan.zhihu.com/p/16628901797.md")

    local paper = search.item(entry {
      type = "scholar",
      id = 1981455297303291750,
      title = "Green公式的证明",
      url = "https://www.zhihu.com/kvip/sku/paper/1981455297303291750",
    })
    t.eq("a paper row is browser only", paper.tag, "论文")
    t.eq("and carries no uri", paper.uri, nil)
    t.eq("but knows where it goes", paper.url, "https://www.zhihu.com/kvip/sku/paper/1981455297303291750")
    t.ok("and says why", (paper.reason or ""):find("浏览器", 1, true) ~= nil)

    -- a section separator: an entry with an id but no object
    t.eq("a section separator is not a row", search.item { type = "search_result", id = 7, query_list = {} }, nil)
    t.eq("a people card is not a row either",
      search.item(entry { type = "people", id = 123, title = "某用户" }), nil)

    local question = search.item(entry {
      type = "question",
      id = 2101274789797282816,
      title = "十九位的问题",
    })
    t.eq("a new style question is browser only", question.tag, "问题·浏览器")
    t.eq("and points at its page", question.url, "https://www.zhihu.com/question/2101274789797282816")

    -- paging: search_v3 hands out the next page as an absolute url
    local session = search.session("公式")
    t.eq("a session starts at the query url", session.url, search.url("公式"))
    local added = session:take {
      data = {
        entry { type = "answer", id = 1, question = { id = 2 }, title = "a", excerpt = "x" },
        { type = "search_result", id = 9 },
        entry { type = "people", id = 5 },
        entry { type = "article", id = 3, title = "b" },
      },
      paging = { is_end = false, next = "https://api.zhihu.com/search_v3?offset=20" },
    }
    t.eq("only the rows the reader understands land", #added, 2)
    t.eq("and the walk follows paging.next", session.url, "https://api.zhihu.com/search_v3?offset=20")
    local again = session:take {
      data = { entry { type = "answer", id = 1, question = { id = 2 }, title = "a" } },
      paging = { is_end = true },
    }
    t.eq("a repeated row is not added twice", #again, 0)
    t.ok("is_end closes the walk", session.done == true)
  end,
}
