--- a class to get/post/patch zhihu article in HTML
local htmlEntities = require 'htmlEntities'
local fs = require 'vim.fs'
local split = require 'vim.shared'.split
local json = require 'vim.json'
local datafile = require 'datafile'
local parse = require 'htmlparser'.parse
local md_to_html = require "markdown_to_html".md_to_html
local zfh = require "zfh"

local M = {
  selector = ".RichText.ztext",
  error_selector = ".ErrorPage-text",
  attribute = "data-zop",
  Article = {
    title = "Untitled",
    table_of_contents = false,
    delta_time = 30,
    isTitleImageFullScreen = false,
    draft_type = "normal",
    disclaimer_status = "closed",
    disclaimer_type = "none",
    confirm_publish = true,
    thank_inviter_status = "close",
    thank_inviter = "",
    reshipment_settings = "allowed",
    writer = zfh.writer,
    reader = zfh.reader,
  },
}
local _text = ""
local _f = datafile.open("conf/Untitled.md") or
    io.open(debug.getinfo(1).source:match("@?(.*/)[^/]+/[^/]+/[^/]+$") .. "etc/conf/Untitled.md")
if _f then
  _text = _f:read "*a"
  _f:close()
end
-- similar as https://github.com/niudai/VSCode-Zhihu
M.Article.root = parse(md_to_html(_text))
local _meta = getmetatable(M.Article.root)
_meta.__tostring = M.Article.root.gettext
setmetatable(M.Article.root, _meta)

---convert filename to article
---@param url string
---@return Article article
function M.url_to_article(url)
  local id = fs.basename(url):match "^[^.]+" or ""
  local question_id = fs.dirname(url):match "%d+"
  local article = {
    itemId = tonumber(id) and id,
    question_id = question_id,
    title = not tonumber(id) and id or nil,
  }
  return article
end

---the pages themselves only answer with an anti-bot challenge for the
---new-format ids the feeds hand out, these two apis carry the same bodies
M.answer_url = "https://www.zhihu.com/api/v4/answers/%s?include=content"
M.article_url = "https://zhuanlan.zhihu.com/api/articles/%s"

---the api that can serve this target: answers and articles live apart
---@param target table from `url_to_article`
---@return string? url
function M.api_url(target)
  if target == nil or target.itemId == nil then
    return nil
  end
  if target.question_id ~= nil then
    return M.answer_url:format(tostring(target.itemId))
  end
  return M.article_url:format(tostring(target.itemId))
end

---percent-decode the tex zhihu carries in an equation url
---@param text string
---@return string
local function unescape(text)
  return ((tostring(text or ""):gsub("%+", " ")):gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

---zhihu writes every formula as an image and keeps the tex it rendered in the
---url and in the alt text: put the formula back as text, otherwise the pane
---shows a bare <img> tag where the maths should be
---@param html string?
---@return string
function M.equations(html)
  local text = tostring(html or "")
  if text:find("equation", 1, true) == nil then
    return text
  end
  return (text:gsub("<img[^>]+>", function(tag)
    if tag:find("equation", 1, true) == nil then
      return tag
    end
    -- a lazy image keeps the real address in data-actualsrc and a blank svg in
    -- src; a plain one has it in src
    local target = tag:match('data%-actualsrc="([^"]*)"') or tag:match('src="([^"]*)"')
    local tex = target and unescape(target:match('[?&]tex=([^&"]*)'))
    if tex == nil or tex == "" then
      tex = tag:match 'alt="([^"]*)"'
      if tex ~= nil then
        tex = htmlEntities.decode(tex)
      end
    end
    if tex == nil or tex == "" then
      return tag
    end
    return "$" .. tex .. "$"
  end))
end

---a picture is one line the reader can open, not a markdown image: nothing in
---the pane draws it, and the address is what the reader needs when they want to
---look at it. formula images are left to `equations`
---@param html string?
---@return string
function M.images(html)
  local text = tostring(html or "")
  if text:find("<img", 1, true) == nil then
    return text
  end
  local index = 0
  text = text:gsub("<img[^>]-/?>", function(tag)
    if tag:find("equation", 1, true) ~= nil then
      return tag
    end
    -- a lazy image keeps the real address in data-actualsrc and a blank svg in
    -- src; a plain one has it in src
    local target = tag:match('data%-actualsrc="([^"]*)"') or tag:match('src="([^"]*)"')
    if target == nil or target == "" or target:match "^data:" then
      return ""
    end
    index = index + 1
    return ("\n\n[图片 %d] %s\n\n"):format(index, htmlEntities.decode(target))
  end)
  -- a figure is how the page wraps a picture; with the picture turned into text
  -- the writer would still print an image of it, this time without an address
  return (text:gsub("<figure[^>]*>", "<p>"):gsub("</figure>", "</p>"))
end

---@param content string?
---@return string html shaped the way `from_html` expects a page
function M.body_document(content)
  return ('<html><body><div class="RichText ztext">%s</div></body></html>'):format(content or "")
end

---@param body string? api response
---@return string? content the body as html
function M.body_content(body)
  local ok, decoded = pcall(json.decode, tostring(body or ""))
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  -- the answer api answers with the object itself, the article api wraps it:
  -- take whichever level actually carries the body
  local function body_of(node)
    if type(node) ~= "table" then
      return nil
    end
    local content = node.content
    if type(content) == "string" and content ~= "" then
      return content
    end
    return nil
  end
  return body_of(decoded) or body_of(decoded.data)
end

---why a page carried no body: the user needs to know whether to retry, log in
---again, or take it to the browser
---@param html string?
---@return string reason
function M.missing_reason(html)
  local text = tostring(html or "")
  if text:find("zh-zse-ck", 1, true) then
    return "知乎把这一页挡在验证墙后面了，返回的是验证页而不是正文。按 q 回到列表再按 o 到浏览器看，或在浏览器里过一次验证再回来。"
  end
  if text == "" then
    return "拿回来的是空响应。"
  end
  return "拿回来的页面里没有正文，登录态可能已经失效。"
end

---@param target table from `url_to_article`
---@return table headers
function M.api_headers(target)
  local url = M.api_url(target)
  local headers = vim.deepcopy(require('zhihu.api.get').API.headers)
  require('zhihu.api').set_cookie_header { url = url, headers = headers }
  return headers
end

---the body from the api, synchronously
---@param target table from `url_to_article`
---@return string? content
function M.content_sync(target)
  local url = M.api_url(target)
  if url == nil then
    return nil
  end
  for _ = 1, 2 do
    local ok, response = pcall(function()
      return require('requests').get { url = url, headers = M.api_headers(target) }
    end)
    if ok and type(response) == "table" and response.status_code == 200 then
      local content = M.body_content(response.text)
      if content ~= nil then
        return content
      end
    end
  end
  return nil
end

---@param article Article?
---@return Article article
function M.Article:new(article)
  article = article or {}
  -- data-zop carries isPublished; itemId only proves the article exists on the
  -- server, which is also true for an unpublished draft
  if type(article.isPublished) ~= "boolean" then
    article.isPublished = article.itemId ~= nil
  end
  setmetatable(article, {
    __tostring = self.tostring,
    __index = self
  })
  local meta = getmetatable(article.root)
  meta.__tostring = article.root.gettext
  setmetatable(article.root, meta)
  return article
end

---Convert a table<string, string> to string
---@return string
function M.Article:tostring()
  return self.reader(tostring(self.root))
end

setmetatable(M.Article, {
  __call = M.Article.new
})

---factory method. wrap `from_id`
---@param url string
---@return Article article
function M.Article:from_url(url)
  local article = M.url_to_article(url)
  if article.itemId == nil then
    return self(article)
  end
  local content = M.content_sync(article)
  if content then
    local body = self:from_html(M.body_document(content))
    body.itemId = article.itemId
    body.question_id = article.question_id
    return body
  end
  return self:from_id(article.itemId, article.question_id)
end

---the network half of `from_url`, for callers that cannot afford to block:
---the page arrives in a callback and rendering stays with the caller
---@param url string
---@param cb fun(html: string?, err: string?)
function M.Article:fetch_async(url, cb)
  local target = M.url_to_article(url)
  if not target.itemId then
    return cb(nil, ("zhihu: %s 没有可下载的正文"):format(tostring(url)))
  end
  local http = require 'zhihu.nvim.http'
  local set_cookie_header = require('zhihu.api').set_cookie_header
  local function page()
    local Get = require 'zhihu.api.get'.API
    local api = Get.from_id(target.itemId, target.question_id)
    set_cookie_header(api)
    -- http hands back (err, text); this contract is (html, err)
    http.get(api.url, api.headers, function(err, text)
      if err then
        return cb(nil, err)
      end
      cb(text)
    end)
  end
  -- the answer api answers 10003 to a burst of requests; one more try usually
  -- gets the body, and the page underneath is a challenge wall
  local function via_api(attempt)
    http.get(M.api_url(target), M.api_headers(target), function(err, text)
      local content = err == nil and M.body_content(text) or nil
      if content ~= nil then
        return cb(M.body_document(content))
      end
      if attempt < 2 then
        return via_api(attempt + 1)
      end
      page()
    end)
  end
  via_api(1)
end

---factory method. wrap `from_html`
---@param id string
---@param question_id string?
---@return Article article
function M.Article:from_id(id, question_id)
  local Get = require 'zhihu.api.get'.API
  local api = Get.from_id(id, question_id)
  local resp = api:request()
  local text = resp.status_code == 200 and resp.text or resp.status
  local article = self:from_html(text)
  if article.itemId == nil then
    article.itemId = id
  else
    assert(article.itemId == id)
  end
  article.question_id = question_id
  return article
end

---factory method.
---@param html string?
---@return Article article
function M.Article:from_html(html)
  html = M.images(M.equations(html))
  local root = parse(html)
  local tag = root:select(("[%s]"):format(M.attribute))[1]
  local article = json.decode(tag and htmlEntities.decode(tag.attributes[M.attribute]) or "{}")
  local roots = root:select(M.selector)
  -- [1] = question,
  -- [2] = answer,
  local body = roots[#roots] or root:select(M.error_selector)[1]
  if body == nil then
    -- no body element: this is a challenge wall or a signin redirect. keeping
    -- the whole document would put raw html source in the buffer
    article.root = parse "<div></div>"
    article.missing = M.missing_reason(html)
    return self(article)
  end
  article.root = body
  if article.root.root ~= article.root then
    article.root = parse(article.root:gettext())
  end
  return self(article)
end

---ask before overwriting content that is already published, writing to a live
---article by accident is not something undo can fix
---only asked for published content, a first write must never prompt
---@return boolean
function M.Article:confirm_overwrite()
  if not self.confirm_publish then
    return true
  end
  if #vim.api.nvim_list_uis() == 0 then
    vim.notify("zhihu: refusing to overwrite published content without a confirmation prompt",
      vim.log.levels.WARN)
    return false
  end
  return vim.fn.confirm(("Overwrite the published content of %s?"):format(tostring(self.title)), "&Yes\n&No", 2,
    "Question") == 1
end

---write an article or answer
---@param publish boolean?
---@return string? error
---@return boolean? aborted true when the overwrite confirmation was declined
function M.Article:write(publish)
  if publish == nil then
    publish = self.disclaimer_type and self.disclaimer_status and true
  end
  if publish and self.isPublished and not self:confirm_overwrite() then
    return nil, true
  end
  if self.question_id == nil and self.itemId == nil then
    local Post = require 'zhihu.api.post.article'.API
    local api = Post:from_article(self)
    local resp = api:request()
    if resp.status_code ~= 200 then
      return resp.status
    end
    self.itemId = resp.json().id
  end
  if publish then
    return self:publish()
  end
  return self:upload()
end

---publish an article or answer
---@return string? error
function M.Article:publish()
  if self.question_id == nil then
    local error = self:upload()
    if error then
      return error
    end
  end
  local Post = require 'zhihu.api.post.publish'.API
  local api = Post:from_article(self)
  local resp = api:request()
  if resp.status_code ~= 200 then
    return resp.status
  end
  local output = resp.json()
  if output.code ~= 0 then
    return output.message
  end
  local publish = json.decode(output.data.result).publish
  self.title = publish.question and publish.question.title or self.title
  self.isPublished = true
  self.itemId = publish.id
  self.authorName = publish.author and publish.author.name
  assert(self.question_id == (publish.question and publish.question.id))
end

---upload an article or answer to draft box
---@return string? error
function M.Article:upload()
  local API
  if self.question_id then
    API = require 'zhihu.api.post.answer'.API
  else
    API = require 'zhihu.api.patch'.API
  end
  local api = API:from_article(self)
  local resp = api:request()
  if resp.status_code ~= 200 then
    return resp.status
  end
end

---split article to lines
---@return string[]
function M.Article:get_lines()
  if self.missing then
    return { "# 打不开这一条", "", self.missing }
  end
  local text = tostring(self)
  -- CRLF text: splitting on a bare newline leaves the CR glued to every line,
  -- and a buffer line may not carry one
  return split(text, "\r?\n")
end

---set HTML content
---@param html string
function M.Article:set_html(html)
  local root = parse(html)
  self.root = root:select(M.selector)[1] or root
end

---set content
---@param content string
function M.Article:set_content(content)
  self:set_html(self.writer(content))
end

---set lines
---@param lines string[]
function M.Article:set_lines(lines)
  local text = table.concat(lines, "\n")
  self:set_content(text)
end

---get URL
---@param edit boolean?
---@return string url
function M.Article:get_url(edit)
  if edit == nil then
    local publish = self.disclaimer_type and self.disclaimer_status and true
    edit = not publish
  end
  local API = require 'zhihu.api.get'.API
  local api = API.from_id(self.itemId, self.question_id)
  local url = api.url
  if edit and self.itemId then
    url = url .. '/edit'
  end
  return url
end

return M
