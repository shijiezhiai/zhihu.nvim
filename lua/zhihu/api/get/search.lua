---the site search behind :Zhihu search: search_v3 answers with the same
---paging shape as a feed, but its rows wrap the object one level deeper and
---highlight the matched words inside the title itself
---@diagnostic disable: undefined-global
-- luacheck: ignore 111 113
local feed = require "zhihu.api.get.feed"

local M = {}

---kinds the reader can render; feed.item already knows what to do with them
local RENDERABLE = { answer = true, article = true, question = true, pin = true }

---kinds that exist in the results but only make sense in a browser
local BROWSER_ONLY = {
  scholar = { tag = "论文", reason = "论文那条是 k-vip 的入口，读不到正文，按 o 到浏览器看。" },
  zvideo = { tag = "视频", reason = "视频在这里放不了，按 o 到浏览器看。" },
  video = { tag = "视频", reason = "视频在这里放不了，按 o 到浏览器看。" },
}

---percent encode a query: one byte at a time, so utf8 survives untouched
---@param text string
---@return string
function M.escape(text)
  return (tostring(text):gsub("[^%w%-%._~]", function(char)
    return ("%%%02X"):format(char:byte())
  end))
end

---@param query string
---@return string url
function M.url(query)
  return ("https://www.zhihu.com/api/v4/search_v3?t=general&q=%s&correction=1"):format(M.escape(query))
end

---@param raw table one row of search_v3
---@return table? item
function M.item(raw)
  -- people cards, ring boxes and section separators carry no object: they are
  -- not results, and the feeds' shapes do not describe them
  if type(raw) ~= "table" or type(raw.object) ~= "table" then
    return nil
  end
  local object = raw.object
  local kind = object.type
  local item = feed.item { target = object }
  if item == nil then
    return nil
  end
  if not RENDERABLE[kind] then
    local only = BROWSER_ONLY[kind]
    if only == nil or object.url == nil then
      return nil
    end
    item.tag = only.tag
    item.reason = only.reason
    item.uri = nil
    item.url = object.url
  end
  return item
end

---open one query for paging: the session itself is a feed session, it only
---learns a different way of reading a page
---@param query string
---@return table session
function M.session(query)
  local session = feed.session_at(M.url(query), "search")
  session.query = query
  session.item = M.item
  return session
end

return M
