---turning feed pages into picker rows: pure shapes, no network
local function repo_root()
  local src = (debug.getinfo(1, "S").source:gsub("^@", ""))
  return src:match("^(.*)/tests/[^/]+$") or "."
end

local REPO = repo_root()
package.path = REPO .. "/lua/?.lua;" .. REPO .. "/lua/?/init.lua;" .. package.path

-- page() copies the header table; the plain luajit runner has no vim
_G.vim = _G.vim or {
  deepcopy = function(source)
    local copy = {}
    for key, value in pairs(source) do
      copy[key] = value
    end
    return copy
  end,
}

local responses = {}
local requested = {}
package.preload["requests"] = function()
  return {
    get = function(api)
      requested[#requested + 1] = api.url
      local response = responses[api.url]
      if response == nil then
        return { status_code = 404, text = "" }
      end
      return response
    end,
  }
end

package.preload["zhihu.api"] = function()
  return { set_cookie_header = function(api) return api end }
end

local feed = require("zhihu.api.get.feed")
-- the body is decoded by the same function in production; here the fake
-- response carries the url so a fixture can be selected by url
feed.decode = function(text)
  local body = responses[text] and responses[text].decoded
  if body == nil then
    error("no fixture for " .. tostring(text))
  end
  return body
end

---shape of api/v3/feed/topstory/hot-lists/total
local function hot_question()
  return {
    type = "hot_list_feed",
    detail_text = "1234 万热度",
    target = { type = "question", id = 19550517, title = "Instagram 有多少用户？", answer_count = 6 },
  }
end

---shape of api/v3/feed/topstory/recommend
local function recommend_answer()
  return {
    type = "feed",
    target = {
      type = "answer",
      id = 14204568,
      question = { id = 19550517, title = "Instagram 有多少用户？" },
      author = { name = "黄继新" },
      voteup_count = 12,
      excerpt = "1500 万。",
    },
  }
end

return {
  name = "feed rows",
  run = function(t)
    local hot = feed.item(hot_question())
    t.eq("a question entry opens the answer list of its question", hot.uri,
      "zhihu://www.zhihu.com/question/19550517/answers.md")
    t.eq("a hot entry is labeled as a question", hot.tag, "问题")
    t.ok("a hot entry keeps its heat and answer count",
      hot.meta:find("1234 万热度", 1, true) ~= nil and hot.meta:find("6 回答", 1, true) ~= nil)

    local answer = feed.item(recommend_answer())
    t.eq("an answer entry opens the answer itself", answer.uri,
      "zhihu://www.zhihu.com/question/19550517/answer/14204568.md")
    t.eq("an answer entry is titled with its question", answer.title, "Instagram 有多少用户？")
    t.ok("an answer entry carries author and votes",
      answer.meta:find("@黄继新", 1, true) ~= nil and answer.meta:find("12 赞", 1, true) ~= nil)
    t.eq("an answer entry keeps its excerpt", answer.excerpt, "1500 万。")

    -- the feeds hand out excerpts as html: the list wants the words
    local rich = feed.item({ target = {
      type = "answer",
      id = 1,
      question = { id = 2, title = "标题" },
      excerpt = "<strong>契约精神</strong>的核心要义之一，&nbsp;是…&amp;more",
    } })
    t.eq("an html excerpt is reduced to its words", rich.excerpt, "契约精神 的核心要义之一， 是…&more")

    -- an entry with no title of its own is titled by its excerpt: it must not
    -- then repeat that excerpt on a second row
    local untitled = feed.item({ target = {
      type = "answer",
      id = 1,
      question = { id = 2 },
      excerpt = "只有摘要",
    } })
    t.eq("an untitled entry is titled by its excerpt", untitled.title, "只有摘要")
    t.eq("and does not repeat it", untitled.excerpt, nil)

    local blank = feed.item({ target = { type = "answer", id = 1, question = { id = 2 }, title = "t", excerpt = "  " } })
    t.eq("a blank excerpt is no excerpt", blank.excerpt, nil)

    -- "[视频]" is the feed's marker for a video post, not something to read
    local marker = feed.item({ target = { type = "answer", id = 1, question = { id = 2 }, title = "t", excerpt = "[视频]" } })
    t.eq("a bare bracket marker is no excerpt", marker.excerpt, nil)

    -- the feeds name anonymous authors "用户", which is noise in a meta line
    local anon = feed.item({ target = {
      type = "answer",
      id = 1,
      question = { id = 2, title = "t" },
      author = { name = "用户" },
      voteup_count = 12,
    } })
    t.eq("an anonymous author is left out of the meta line", anon.meta, "12 赞")

    local article = feed.item({ target = { type = "article", id = 1234, title = "标题" } })
    t.eq("an article entry opens the column post", article.uri, "zhihu://zhuanlan.zhihu.com/p/1234.md")

    -- 热榜 now hands out 19 digit question ids, which api/v4 does not serve
    local hot_new = feed.item({ target = {
      type = "question",
      id = "2101274789797282816",
      title = "如何评价…",
      answer_count = 42,
    } })
    t.eq("a 19 digit question goes to the browser", hot_new.url,
      "https://www.zhihu.com/question/2101274789797282816")
    t.eq("a 19 digit question has no reader uri", hot_new.uri, nil)
    t.ok("a 19 digit question says why it needs the browser",
      tostring(hot_new.reason):find("浏览器", 1, true) ~= nil)

    -- 19 digit ids come back as json strings; they must reach the uri verbatim
    local pin = feed.item({ target = {
      type = "pin",
      id = "2101669831598675329",
      url = "https://www.zhihu.com/pin/2101669831598675329?native=0",
    } })
    t.eq("a pin opens the api url in the browser", pin.url,
      "https://www.zhihu.com/pin/2101669831598675329?native=0")
    t.eq("a pin has no reader uri", pin.uri, nil)

    local new_answer = feed.item({ target = {
      type = "answer",
      id = "2101454010653979264",
      question = { id = "2101619797695754508", title = "AI 零代码手写算子" },
    } })
    t.eq("a 19 digit answer id is not rounded", new_answer.uri,
      "zhihu://www.zhihu.com/question/2101619797695754508/answer/2101454010653979264.md")

    t.eq("an entry without a target is dropped", feed.item({ type = "feed" }), nil)

    -- pagination: the second page repeats the first one's next link, which must
    -- end the walk instead of looping forever
    local first = feed.url.hot
    local second = "https://www.zhihu.com/api/v3/feed/topstory/recommend?after_id=5"
    responses[first] = {
      status_code = 200,
      text = first,
      decoded = { data = { hot_question() }, paging = { next = second } },
    }
    responses[second] = {
      status_code = 200,
      text = second,
      decoded = {
        data = { hot_question(), recommend_answer() },
        paging = { next = second },
      },
    }
    local items = feed.fetch("hot")
    t.eq("the walk follows the next link", #requested, 2)
    t.eq("a repeated entry is dropped", #items, 2)
    t.ok("both rows survive the walk", items[2].uri:find("answer/14204568", 1, true) ~= nil)

    -- a stale cookie answers 403 and must say what to do about it
    local expired = "https://www.zhihu.com/api/v3/feed/topstory/recommend?expired=1"
    responses[expired] = { status_code = 403, text = expired }
    local ok, message = pcall(feed.page, expired)
    t.ok("a 403 says the cookie expired", not ok and tostring(message):find("cookie", 1, true) ~= nil)
  end,
}
