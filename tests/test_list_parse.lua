---decoding zhihu api pages into rows: plain luajit, the fixtures are hand written
local function repo_root()
  local src = (debug.getinfo(1, "S").source:gsub("^@", ""))
  return src:match("^(.*)/tests/[^/]+$") or "."
end

local REPO = repo_root()
package.path = REPO .. "/lua/?.lua;" .. REPO .. "/lua/?/init.lua;" .. package.path

local state = { requests = 0, response = nil }

package.preload["requests"] = function()
  return {
    get = function()
      state.requests = state.requests + 1
      return state.response
    end,
  }
end

package.preload["zhihu.api"] = function()
  return { set_cookie_header = function(api) return api end }
end

package.preload["zhihu.api.get.list"] = function()
  return {
    API = {
      from_list = function()
        return {
          request = function()
            state.requests = state.requests + 1
            return state.response
          end,
        }
      end,
    },
  }
end

local List = require("zhihu.list").List

---shape of api/v4/questions/<qid>/answers: data is the page, paging the counts
local function answers_page()
  return {
    data = {
      {
        type = "answer",
        id = 40211301,
        excerpt = "先说结论。\n剩下的部分不该出现在列表里。",
        author = { name = "张三", id = "abc" },
        voteup_count = 1234,
        comment_count = 56,
        question = { id = 19550517, title = "如何评价测试驱动开发？" },
        url = "https://www.zhihu.com/question/19550517/answer/40211301",
      },
      {
        type = "answer",
        id = 40211302,
        excerpt = "匿名用户的回答",
        voteup_count = 7,
        question = { id = 19550517, title = "如何评价测试驱动开发？" },
      },
      { type = "answer", excerpt = "这条脏数据没有 id" },
    },
    paging = { totals = 137, next = "https://www.zhihu.com/api/v4/questions/19550517/answers?offset=20" },
  }
end

---shape of api/v4/columns/<slug>/items: items carry a title, no question
local function items_page()
  return {
    data = {
      {
        type = "article",
        id = 98765,
        title = "线性代数应该这样学",
        excerpt = "从向量空间开始。",
        author = { name = "李四" },
        voteup_count = 12,
        comment_count = 3,
        url = "https://zhuanlan.zhihu.com/p/98765",
      },
    },
    paging = { totals = 1 },
  }
end

local function list_of(kind, offset)
  return List({ kind = kind, id = kind == "answers" and "19550517" or "c_1234567890", offset = offset or 0 })
end

return {
  name = "list page decoding",
  run = function(t)
    local answers = list_of("answers")
    local rows = answers:parse(answers_page())

    t.eq("a page without id is dropped", #rows, 2)
    t.eq("the first row keeps its id as a string", rows[1].id, "40211301")
    t.eq("the excerpt is folded to one line", rows[1].title, "先说结论。 剩下的部分不该出现在列表里。")
    t.eq("the excerpt is kept beside the title", rows[1].excerpt, "先说结论。 剩下的部分不该出现在列表里。")
    t.eq("the author name is kept", rows[1].author, "张三")
    t.eq("the vote count is a number", rows[1].votes, 1234)
    t.eq("the comment count is a number", rows[1].comments, 56)
    t.eq("the row points at the answer uri", rows[1].url,
      "zhihu://www.zhihu.com/question/19550517/answer/40211301.md")
    t.eq("a missing author stays nil", rows[2].author, nil)
    t.eq("a missing comment count degrades to 0", rows[2].comments, 0)
    t.eq("a missing comment count keeps the votes", rows[2].votes, 7)
    t.eq("paging.totals rides along", rows.totals, 137)
    t.eq("the question title rides along", rows.question_title, "如何评价测试驱动开发？")

    local empty = answers:parse({ data = {}, paging = { totals = 0 } })
    t.eq("an empty page has no rows", #empty, 0)
    t.eq("an empty page keeps the total", empty.totals, 0)
    t.eq("an empty page has no question title", empty.question_title, "")
    local nothing = answers:parse(nil)
    t.eq("a missing body has no rows", #nothing, 0)
    t.eq("a missing body has no total", nothing.totals, nil)

    local articles = list_of("articles")
    local items = articles:parse(items_page())
    t.eq("a column item keeps its title", items[1].title, "线性代数应该这样学")
    t.eq("a column item points at zhuanlan", items[1].url, "zhihu://zhuanlan.zhihu.com/p/98765.md")
    t.eq("a column page has no question title", items.question_title, "")

    -- the error string is assembled from the status and the body
    t.eq("403 with a zhihu error body is spelled out", List.error_of(403, {
      error = { code = 10003, message = "请求参数异常，请升级客户端后重试。" },
    }), "zhihu: 403 / code=10003 / 请求参数异常，请升级客户端后重试。")
    t.eq("an error body on a 200 is still an error", List.error_of(200, { error = { code = 10003 } }),
      "zhihu: 200 / code=10003")
    t.eq("a clean 200 is not an error", List.error_of(200, { data = {} }), nil)
    t.eq("a 403 without a body keeps the status", List.error_of(403, nil), "zhihu: 403")
    t.eq("an undecodable 200 says so", List.error_of(200, nil), "zhihu: 200 / 响应不是 JSON")

    -- fetch and get_lines are the only entry points that touch the api
    t.eq("parse never requests", state.requests, 0)
    t.eq("lines never requests", (function()
      answers:lines(rows)
      return state.requests
    end)(), 0)

    state.response = { status_code = 200, json = function() return answers_page() end }
    local fetched = answers:fetch()
    t.eq("fetch goes through the api once", state.requests, 1)
    t.eq("fetch returns the decoded page", fetched.paging.totals, 137)
    local lines = answers:get_lines()
    t.eq("get_lines renders the fetched page", lines[1], "# 如何评价测试驱动开发？")
    t.eq("get_lines asks for the page once", state.requests, 2)

    state.response = {
      status_code = 403,
      text = "",
      json = function()
        error("not json")
      end,
    }
    local ok, err = pcall(function() return answers:fetch() end)
    t.eq("a 403 without a decodable body raises", ok, false)
    t.eq("the raised message keeps the status", err, "zhihu: 403")
    state.response = { status_code = 200, text = "<html>反爬</html>" }
    local ok2, err2 = pcall(function() return answers:fetch() end)
    t.eq("an html body raises instead of rendering nothing", ok2, false)
    t.eq("the html body error is readable", err2, "zhihu: 200 / 响应不是 JSON")
  end,
}
