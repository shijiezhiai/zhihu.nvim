---list pages of zhihu answers and column articles
local requests = require "requests"
local set_cookie_header = require 'zhihu.api'.set_cookie_header
local M = {
  ---answers per page, must agree with zhihu.list.page_size
  page_size = 20,
  ---@type table<string, string>
  url = {
    answers = "https://www.zhihu.com/api/v4/questions/%s/answers",
    articles = "https://www.zhihu.com/api/v4/columns/%s/items",
  },
  API = {
    url = "",
    headers = {
      ["User-Agent"] =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Safari/537.36",
      ["Accept"] = "application/json",
      ["accept-language"] = "zh-CN,zh;q=0.8,zh-TW;q=0.7,zh-HK;q=0.5,en-US;q=0.3,en;q=0.2",
      ["x-requested-with"] = "XMLHttpRequest",
    }
  }
}

---@param api table?
---@return table api
function M.API:new(api)
  api = api or {}
  setmetatable(api, {
    __index = self
  })
  return api
end

setmetatable(M.API, {
  __call = M.API.new
})

---factory method
---@param list table
---@return table api
function M.API.from_list(list)
  local api = {
    url = ("%s?offset=%d&limit=%d"):format(
      M.url[list.kind]:format(list.id), list.offset or 0, M.page_size),
  }
  return M.API(api)
end

---request
---@return table
function M.API:request()
  set_cookie_header(self)
  return requests.get(self)
end

return M
