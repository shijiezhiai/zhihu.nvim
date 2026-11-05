---the request a list page turns into: the url shape and its include fields
local function repo_root()
  local src = (debug.getinfo(1, "S").source:gsub("^@", ""))
  return src:match("^(.*)/tests/[^/]+$") or "."
end

local REPO = repo_root()
package.path = REPO .. "/lua/?.lua;" .. REPO .. "/lua/?/init.lua;" .. package.path

-- the module requires the http client and the cookie helper at load time;
-- neither request nor cookie is exercised here, so stub both
local calls = 0
package.preload["requests"] = function()
  return {
    get = function()
      calls = calls + 1
      return { status_code = 200, json = function() return {} end }
    end,
  }
end

package.preload["zhihu.api"] = function()
  return { set_cookie_header = function(api) return api end }
end

local list_api = require("zhihu.api.get.list")
local List = require("zhihu.list").List

local ANSWERS_INCLUDE =
  "data[*].excerpt,author.name,voteup_count,comment_count,question.id,question.title"
local ARTICLES_INCLUDE =
  "data[*].title,excerpt,author.name,voteup_count,comment_count"

local function url_of(kind, id, offset)
  return list_api.API.from_list(List({ kind = kind, id = id, offset = offset })).url
end

local function has(text, needle)
  return text:find(needle, 1, true) ~= nil
end

return {
  name = "list request shape",
  run = function(t)
    local answers = url_of("answers", "19550517", 0)
    local articles = url_of("articles", "c_1234567890", 0)

    t.eq("an answers page asks the answers endpoint", answers,
      "https://www.zhihu.com/api/v4/questions/19550517/answers?include=" ..
      ANSWERS_INCLUDE .. "&offset=0&limit=20")
    t.eq("an articles page asks the items endpoint", articles,
      "https://www.zhihu.com/api/v4/columns/c_1234567890/items?include=" ..
      ARTICLES_INCLUDE .. "&offset=0&limit=20")

    t.ok("answers stay under api/v4", has(answers, "https://www.zhihu.com/api/v4/"))
    t.ok("articles stay under api/v4", has(articles, "https://www.zhihu.com/api/v4/"))
    t.ok("the answers include carries the excerpt", has(answers, "excerpt"))
    t.ok("the answers include carries the author", has(answers, "author.name"))
    t.ok("the answers include carries the counters", has(answers, "voteup_count,comment_count"))
    t.ok("the answers include carries the question title",
      has(answers, "question.id,question.title"))
    t.ok("the articles include carries the title", has(articles, "data[*].title"))
    t.ok("the articles include carries the author", has(articles, "author.name"))

    t.ok("neither include asks for the bodies", not has(answers, "content")
      and not has(articles, "content"))
    t.ok("the brackets are left as they are, not percent encoded",
      has(answers, "data[*]") and not has(answers, "%5B") and not has(answers, "%2A"))
    t.ok("the include comes before the paging", answers:find("?include=", 1, true) <
      answers:find("&offset=", 1, true))

    local second = url_of("answers", "19550517", 40)
    t.ok("a later page carries its offset", has(second, "&offset=40&limit=20"))
    t.ok("a later page keeps the same include", has(second, ANSWERS_INCLUDE))

    local page = list_api.API.from_list(List({ kind = "articles", id = "c_1", offset = 0 }))
    t.eq("the headers are inherited from the api table", page.headers.Accept, "application/json")
    t.eq("the request announces itself as xmlhttprequest", page.headers["x-requested-with"],
      "XMLHttpRequest")
    t.eq("the page size agrees with the pager", list_api.page_size, require("zhihu.list").page_size)
    t.eq("building a request sends nothing", calls, 0)
  end,
}
