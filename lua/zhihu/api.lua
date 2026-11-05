---cache auth for zhihu API
local M = {
  auth = require 'auth.cache'.Auth()
}

---dumps cookies
---@param host string?
---@return string
function M.dumps_cookies(host)
  host = host or ".zhihu.com"
  return tostring(M.auth:get_cookies(host))
end

---derive the cookie domain a url belongs to, e.g. "https://www.zhihu.com/x" -> ".zhihu.com"
---@param url string?
---@return string
local function cookie_domain(url)
  local host = tostring(url or ""):match "^%a[%w+.-]*://([^/:?#]+)" or tostring(url or ""):match "^([^/:?#]+)"
  if host == nil or host == "" then
    return ".zhihu.com"
  end
  local labels = {}
  for label in host:gmatch "[^.]+" do
    table.insert(labels, label)
  end
  if #labels < 2 then
    return host
  end
  return "." .. labels[#labels - 1] .. "." .. labels[#labels]
end

---dumps only the cookies that belong to the host of the url
---@param url string?
---@return string
function M.dumps_cookies_for_url(url)
  return M.dumps_cookies(cookie_domain(url))
end

---attach the Cookie header matching the request url
---@param api table
---@return table api
function M.set_cookie_header(api)
  api.headers = api.headers or {}
  api.headers.Cookie = M.dumps_cookies_for_url(api.url)
  return api
end

return M
