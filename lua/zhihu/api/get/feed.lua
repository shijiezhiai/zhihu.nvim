---the three front page feeds: 热榜, 推荐, 关注
---@diagnostic disable: undefined-global
-- luacheck: ignore 111 113
local requests = require "requests"
local set_cookie_header = require 'zhihu.api'.set_cookie_header

local M = {
  ---how many rows a picker gets; the story feeds page ten rows at a time, so
  ---this needs a couple of round trips
  limit = 30,
  ---a session never holds more rows than this
  max_items = 200,
  ---pages one more() call may fetch: a single cursor move must never turn into
  ---an unbounded number of requests
  pages_per_call = 3,
  ---pages in a row that add nothing new end the session
  empty_pages = 3,
  ---@type table<string, string>
  url = {
    hot = "https://www.zhihu.com/api/v3/feed/topstory/hot-lists/total?limit=50&desktop=true",
    recommend = "https://www.zhihu.com/api/v3/feed/topstory/recommend?action=down&ad_interval=-1&desktop=true&page_number=1&limit=10",
    follow = "https://www.zhihu.com/api/v3/moments?desktop=true&page_number=1",
  },
  ---@type table<string, string>
  tag = { hot = "热榜", recommend = "推荐", follow = "关注" },
  headers = {
    ["User-Agent"] =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Safari/537.36",
    ["Accept"] = "application/json",
    ["accept-language"] = "zh-CN,zh;q=0.8,zh-TW;q=0.7,zh-HK;q=0.5,en-US;q=0.3,en;q=0.2",
    ["x-requested-with"] = "XMLHttpRequest",
  },
}

---decode a response body, kept in one place so tests can swap it out
---@param text string
---@return table
function M.decode(text)
  return vim.json.decode(text)
end

---@param url string
---@return table api
local function page_request(url)
  local api = { url = url, headers = vim.deepcopy(M.headers) }
  set_cookie_header(api)
  return api
end

---one page of a feed
---@param url string
---@return table page
function M.page(url)
  local api = page_request(url)
  local response = requests.get(api)
  if response.status_code ~= 200 then
    error(("zhihu: 请求失败 %d，cookie 可能过期（在浏览器重新登录知乎后重启 nvim）"):format(response.status_code), 0)
  end
  local ok, body = pcall(M.decode, response.text or "")
  if not ok then
    error("zhihu: 接口返回的不是 JSON，cookie 可能需要重新登录", 0)
  end
  return body
end

---one page of a feed, fetched off the main loop
---@param url string
---@param cb fun(err: string?, body: table?)
function M.page_async(url, cb)
  local api = page_request(url)
  require("zhihu.nvim.http").get(api.url, api.headers, function(err, text)
    if err then
      return cb(err)
    end
    local ok, body = pcall(M.decode, text or "")
    if not ok then
      return cb "zhihu: 接口返回的不是 JSON，cookie 可能需要重新登录"
    end
    if type(body) ~= "table" then
      return cb "zhihu: 接口返回的不是 JSON"
    end
    -- curl only reports transport failures, so an expired cookie lands here as a
    -- json error body
    if body.data == nil and body.error then
      return cb(("zhihu: 请求失败 %s，cookie 可能过期（在浏览器重新登录知乎后重启 nvim）"):format(
        tostring(body.error.code or "?")))
    end
    cb(nil, body)
  end)
end

---ids arrive as strings when they exceed what a double holds exactly (the new
---zhihu ids are 19 digits), and as numbers for the old ones; both must land in
---a uri verbatim
---@param id string|number
---@return string
local function id_text(id)
  if type(id) == "number" then
    return ("%.0f"):format(id)
  end
  return tostring(id)
end

---feed excerpts are html snippets (<strong>…</strong>, entities); the list wants
---their words, on one line
---@param text string?
---@return string?
local function plain(text)
  if type(text) ~= "string" then
    return nil
  end
  -- search results wrap the matched words in <em>: joining them with a space
  -- would split 上帝<em>公式</em> into two words
  local flat = text:gsub("<em[^>]*>", ""):gsub("</em>", ""):gsub("<[^>]*>", " "):gsub("&nbsp;", " "):gsub("&lt;", "<"):gsub("&gt;", ">")
    :gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&amp;", "&")
  flat = flat:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  -- "[视频]" and "[图片]" are markers, not a summary
  if flat == "" or flat:match "^%[[^%]]*%]$" then
    return nil
  end
  return flat
end

---turn one raw feed entry into a row the picker can open; nil when the entry
---carries nothing the reader understands
---@param raw table
---@return table? item
function M.item(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local target = raw.target or {}
  local meta = {}
  -- the excerpt doubles as the last resort for a title, so strip it once, first
  local excerpt = plain(target.excerpt)
  -- search results highlight the matched words inside the title itself
  local title = plain(target.title) or plain(target.question and target.question.title)
  local item = { title = title or excerpt or "", excerpt = excerpt }
  local kind = target.type
  if kind == "answer" then
    local qid = target.question and target.question.id
    if qid == nil or target.id == nil then
      return nil
    end
    item.tag = "回答"
    item.uri = ("zhihu://www.zhihu.com/question/%s/answer/%s.md"):format(id_text(qid), id_text(target.id))
  elseif kind == "article" then
    if target.id == nil then
      return nil
    end
    item.tag = "文章"
    item.uri = ("zhihu://zhuanlan.zhihu.com/p/%s.md"):format(id_text(target.id))
  elseif kind == "question" then
    if target.id == nil then
      return nil
    end
    local id = id_text(target.id)
    if #id > 12 then
      -- 热榜 hands out the 19 digit question ids; api/v4 knows no such question
      -- (10003 on the question, 4041 on its answers), so the browser it is
      item.tag = "问题·浏览器"
      item.url = ("https://www.zhihu.com/question/%s"):format(id)
      item.reason = "新式问题 id 在 api 里查不到，答案列表只能到浏览器看。"
    else
      -- an old style id still serves its answer list through
      -- api/v4/questions/<id>/answers, which zhihu.list renders page by page
      item.tag = "问题"
      item.uri = ("zhihu://www.zhihu.com/question/%s/answers.md"):format(id)
    end
    if target.answer_count then
      meta[#meta + 1] = ("%d 回答"):format(target.answer_count)
    end
  elseif target.id ~= nil then
    -- 想法 and anything else the reader cannot render: hand it to the browser
    item.tag = "想法"
    item.url = target.url or ("https://www.zhihu.com/pin/%s"):format(id_text(target.id))
    item.reason = "想法没有可渲染的正文，按 o 到浏览器看。"
  else
    return nil
  end
  -- the feeds name anonymous authors "用户", which says nothing
  local author = target.author and target.author.name
  if author and author ~= "用户" and author ~= "知乎用户" then
    meta[#meta + 1] = "@" .. author
  end
  if target.voteup_count and target.voteup_count > 0 then
    meta[#meta + 1] = ("%d 赞"):format(target.voteup_count)
  end
  if raw.detail_text then
    meta[#meta + 1] = raw.detail_text
  end
  item.meta = table.concat(meta, " · ")
  -- an entry without a title of its own falls back to its excerpt: one line of
  -- it is enough, and repeating it would cost a whole row
  if item.excerpt == item.title then
    item.excerpt = nil
  end
  if item.title == "" then
    item.title = "(无标题)"
  end
  return item
end

---one feed, pulled a page at a time so a view can grow while the user scrolls
---@class FeedSession
---@field kind string
---@field url string
---@field items table[]
---@field done boolean
local Session = {}
Session.__index = Session

---pull at least count rows more; the rows that did arrive come back even when
---the page after them failed, so a half loaded feed stays usable
---@param count integer?
---@return table[] added
---@return string? err
---fold one page into the session: the bookkeeping of more() without its
---network work, so a page fetched in the background lands here
---@param body table
---@return table[] added
function Session:take(body)
  local added = {}
  local fresh = 0
  for _, raw in ipairs((type(body) == "table" and body.data) or {}) do
    local item = (self.item or M.item)(raw)
    local key = item and (item.uri or item.url)
    if key and not self.seen[key] then
      self.seen[key] = true
      self.items[#self.items + 1] = item
      added[#added + 1] = item
      fresh = fresh + 1
    end
  end
  -- the count spans calls: a feed that repeats itself ends even when the
  -- requests are spread over many cursor moves
  if fresh == 0 then
    self.empty = (self.empty or 0) + 1
    if self.empty >= M.empty_pages then
      self.done = true
    end
  else
    self.empty = 0
  end
  local paging = type(body) == "table" and body.paging or nil
  local next_url = paging and paging.next
  -- an empty or repeated link ends the walk: some feeds answer with the same
  -- url again instead of an empty page
  if (paging and paging.is_end == true) or next_url == nil or next_url == "" or next_url == self.url then
    self.done = true
  else
    self.url = next_url
  end
  if #self.items >= M.max_items then
    self.done = true
  end
  return added
end

---@param count integer?
---@return table[] added
---@return string? err
function Session:more(count)
  count = count or 10
  local added = {}
  local pages = 0
  -- the recommend feed never sets is_end and starts repeating entries at depth:
  -- a walk that only stops on an empty next link never stops at all
  while not self.done and #added < count and pages < M.pages_per_call do
    if #self.items >= M.max_items then
      self.done = true
      break
    end
    pages = pages + 1
    local ok, body = pcall(M.page, self.url)
    if not ok then
      if #self.items == 0 then
        error(body, 0)
      end
      self.done = true
      return added, tostring(body)
    end
    for _, item in ipairs(self:take(body)) do
      added[#added + 1] = item
    end
  end
  return added
end

---open a walk at one url; the same bookkeeping serves any paged list
---@param url string
---@param kind string
---@return table session
function M.session_at(url, kind)
  return setmetatable({ kind = kind, url = url, items = {}, seen = {}, empty = 0, done = false }, Session)
end

---open one feed for paging
---@param kind "hot"|"recommend"|"follow"
---@return table session
function M.session(kind)
  local url = M.url[kind]
  if url == nil then
    error(("zhihu: 未知的 feed %s"):format(tostring(kind)), 0)
  end
  return M.session_at(url, kind)
end

---collect up to limit rows in one go
---@param kind "hot"|"recommend"|"follow"
---@return table[] items
function M.fetch(kind)
  local session = M.session(kind)
  while not session.done and #session.items < M.limit do
    session:more(M.limit - #session.items)
  end
  return session.items
end

return M
