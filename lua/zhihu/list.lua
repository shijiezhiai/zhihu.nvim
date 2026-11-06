---a page of zhihu answers or column articles, rendered as plain markdown
---only fetch talks to the network: parse, lines and path are pure
local M = {
  ---answers per page, shared by the api request and the pager links
  page_size = 20,
  ---@type table<string, string>
  url = {
    answers = "zhihu://www.zhihu.com/question/%s/answers%s.md",
    articles = "zhihu://www.zhihu.com/column/%s%s.md",
  },
  ---@type table<string, string>
  entry = {
    answers = "zhihu://www.zhihu.com/question/%s/answer/%s.md",
    articles = "zhihu://zhuanlan.zhihu.com/p/%s.md",
  },
}

M.List = {
  kind = nil,
  id = nil,
  offset = 0,
}

---collapse whitespace of one line of zhihu text
---@param text string?
---@return string
local function first_line(text)
  return (tostring(text or ""):gsub("%s+", " "))
end

---cut text to "limit" utf8 characters, never in the middle of a sequence
---@param text string?
---@param limit integer?
---@return string
local function shorten(text, limit)
  limit = limit or 80
  local line = first_line(text)
  local out, count = {}, 0
  for char in line:gmatch "[%z\1-\127\194-\244][\128-\191]*" do
    if count >= limit then
      out[#out + 1] = "…"
      break
    end
    count = count + 1
    out[#out + 1] = char
  end
  return table.concat(out)
end

---parse the path of a list uri
---"question/<qid>/answers.md", "question/<qid>/answers-<offset>.md",
---"column/<slug>.md" and "column/<slug>-<offset>.md" are lists, while the
---article uris "question/<qid>.md" and "question/<qid>/answer/<aid>.md" are not
---@param url string?
---@return table? list nil when the uri is not a list
local function parse_url(url)
  local path = tostring(url or ""):match "^zhihu://[^/]+/(.+)$"
  if path == nil then
    return nil
  end
  local question_id, name = path:match "^question/(%d+)/([^/]+)$"
  if question_id then
    if name == "answers.md" then
      return { kind = "answers", id = question_id, offset = 0 }
    end
    local offset = name:match "^answers%-(%d+)%.md$"
    if offset then
      return { kind = "answers", id = question_id, offset = tonumber(offset) }
    end
    return nil
  end
  -- the offset form comes first: a slug may hold a dash, the pager adds "-<n>"
  local slug, offset = path:match "^column/([^/]+)%-(%d+)%.md$"
  if slug then
    return { kind = "articles", id = slug, offset = tonumber(offset) }
  end
  slug = path:match "^column/([^/]+)%.md$"
  if slug then
    return { kind = "articles", id = slug, offset = 0 }
  end
  return nil
end

---@param list table?
---@return table list
function M.List:new(list)
  list = list or {}
  setmetatable(list, {
    __index = self
  })
  return list
end

setmetatable(M.List, {
  __call = M.List.new
})

---factory method
---@param url string?
---@return table? list nil when the uri is not a list
function M.List.from_url(url)
  local list = parse_url(url)
  if list == nil then
    return nil
  end
  return M.List(list)
end

---the canonical uri of this page, shared by the buffer name and the pager links
---@return string
function M.List:path()
  local suffix = ""
  if (self.offset or 0) > 0 then
    suffix = "-" .. tostring(self.offset)
  end
  return M.url[self.kind]:format(self.id, suffix)
end

---the uri of the same list at another offset
---@param offset integer
---@return string
function M.List:path_at(offset)
  return M.List({ kind = self.kind, id = self.id, offset = offset }):path()
end

---decode a response body, preferring the json() of lua-requests
---@param resp table?
---@return table? decoded
local function decode(resp)
  if type(resp) ~= "table" then
    return nil
  end
  if type(resp.json) == "function" then
    local ok, decoded = pcall(resp.json)
    if ok and type(decoded) == "table" then
      return decoded
    end
  end
  if type(resp.text) == "string" and resp.text ~= "" then
    local has_json, json = pcall(require, "vim.json")
    if has_json then
      local ok, decoded = pcall(json.decode, resp.text)
      if ok and type(decoded) == "table" then
        return decoded
      end
    end
  end
  return nil
end

---build a readable error for an unusable response, nil when it is fine
---@param status integer?
---@param decoded table?
---@return string? message
function M.List.error_of(status, decoded)
  local error_ = type(decoded) == "table" and decoded.error or nil
  local code = type(error_) == "table" and error_.code or nil
  local reason = type(error_) == "table" and error_.message or nil
  if tonumber(status) == 200 and type(decoded) == "table" and code == nil then
    return nil
  end
  local parts = { "zhihu: " .. tostring(status or "no status") }
  if tonumber(status) == 200 and type(decoded) ~= "table" then
    parts[#parts + 1] = "响应不是 JSON"
  end
  if code ~= nil then
    parts[#parts + 1] = "code=" .. tostring(code)
  end
  if reason ~= nil and reason ~= "" then
    parts[#parts + 1] = tostring(reason)
  end
  return table.concat(parts, " / ")
end

---fetch and decode one page of the list
---@return table decoded
function M.List:fetch()
  local API = require 'zhihu.api.get.list'.API
  local resp = API.from_list(self):request()
  local status = type(resp) == "table" and resp.status_code or nil
  local decoded = decode(resp)
  local reason = M.List.error_of(status, decoded)
  if reason then
    error(reason, 0)
  end
  return decoded
end

---fetch one page in the background: the body arrives in a callback so the
---caller keeps its event loop, and rendering stays with the caller
---@param cb fun(rows: table?, err: string?)
function M.List:fetch_async(cb)
  local API = require 'zhihu.api.get.list'.API
  local api = API.from_list(self)
  require('zhihu.api').set_cookie_header(api)
  require('zhihu.nvim.http').get(api.url, api.headers, function(err, text)
    if err then
      return cb(nil, err)
    end
    local has_json, json = pcall(require, "vim.json")
    if not has_json then
      return cb(nil, "zhihu: 后台解析需要 vim.json")
    end
    local ok, decoded = pcall(json.decode, text or "")
    if not ok or type(decoded) ~= "table" then
      return cb(nil, "zhihu: 接口返回的不是 JSON")
    end
    -- the curl child knows the body but not the status, so a status-less check
    -- treats a decoded error object as the failure it is
    local reason = M.List.error_of(200, decoded)
    if reason == nil and decoded.data == nil then
      local message = type(decoded.error) == "table" and decoded.error.message or "响应里没有 data"
      reason = "zhihu: 请求失败 / " .. tostring(message)
    end
    if reason then
      return cb(nil, reason)
    end
    cb(self:parse(decoded))
  end)
end

---@param list table
---@param item table
---@return table row
local function to_row(list, item)
  local excerpt = first_line(item.excerpt)
  local title = first_line(item.title)
  if title == "" then
    title = excerpt
  end
  local row = {
    id = tostring(item.id),
    title = title,
    excerpt = excerpt,
    author = type(item.author) == "table" and item.author.name or nil,
    votes = tonumber(item.voteup_count) or 0,
    comments = tonumber(item.comment_count) or 0,
  }
  if list.kind == "answers" then
    local question = type(item.question) == "table" and item.question.id or nil
    row.url = M.entry.answers:format(question or list.id, row.id)
  else
    row.url = M.entry.articles:format(row.id)
  end
  return row
end

---turn a decoded page into rows; rows.totals and rows.question_title ride along
---@param decoded table?
---@return table rows
function M.List:parse(decoded)
  local data = type(decoded) == "table" and decoded.data or nil
  local rows = {}
  if type(data) == "table" then
    for _, item in ipairs(data) do
      if type(item) == "table" and item.id ~= nil then
        rows[#rows + 1] = to_row(self, item)
      end
    end
  end
  local paging = type(decoded) == "table" and decoded.paging or nil
  rows.totals = type(paging) == "table" and tonumber(paging.totals) or nil
  local first = type(data) == "table" and data[1] or nil
  local question = type(first) == "table" and type(first.question) == "table" and first.question.title or nil
  rows.question_title = first_line(question)
  return rows
end

---@param rows table
---@return string
function M.List:title(rows)
  local title = rows and rows.question_title
  if title ~= nil and title ~= "" then
    return title
  end
  if self.kind == "articles" then
    return "专栏 " .. tostring(self.id)
  end
  return "问题 " .. tostring(self.id)
end

---@param rows table
---@return boolean
function M.List:has_next(rows)
  local offset = self.offset or 0
  if rows.totals then
    return offset + #rows < rows.totals
  end
  return #rows >= M.page_size
end

---render rows as markdown lines
---@param rows table
---@return string[] lines
function M.List:lines(rows)
  rows = rows or {}
  local label = self.kind == "articles" and "文章" or "答案"
  local offset = self.offset or 0
  local lines = { "# " .. self:title(rows) }
  local header = #rows == 0 and (label .. " 暂无") or ("%s %d–%d"):format(label, offset + 1, offset + #rows)
  if #rows > 0 and rows.totals then
    header = header .. (" / 共 %d · 第 %d 页"):format(rows.totals, math.floor(offset / M.page_size) + 1)
  end
  lines[#lines + 1] = header
  for index, row in ipairs(rows) do
    lines[#lines + 1] = ("%d. **%s** — @%s · 赞 %d · 评论 %d"):format(
      offset + index,
      shorten(row.title),
      row.author or "匿名",
      math.floor(row.votes or 0),
      math.floor(row.comments or 0))
    lines[#lines + 1] = "    `" .. row.url .. "`"
  end
  local pager = {}
  if offset > 0 then
    pager[#pager + 1] = ("[上一页](%s)"):format(self:path_at(math.max(offset - M.page_size, 0)))
  end
  if self:has_next(rows) then
    pager[#pager + 1] = ("[下一页](%s)"):format(self:path_at(offset + M.page_size))
  end
  if #pager > 0 then
    lines[#lines + 1] = table.concat(pager, " · ")
  end
  return lines
end

---fetch, parse and render in one call
---@return string[] lines
function M.List:get_lines()
  return self:lines(self:parse(self:fetch()))
end

return M
