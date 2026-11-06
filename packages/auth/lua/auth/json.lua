---get cookies from json cache
---@module auth.json
local uv = vim.uv or vim.loop
local fs = require 'vim.fs'
local json = require 'vim.json'
local PlatformDirs = require 'platformdirs'.PlatformDirs
local Cookies = require 'auth.auth'.Cookies
local M = {
  Auth = {
    path = fs.joinpath(PlatformDirs { appname = "nvim" }:user_state_dir(), "cookies.json")
  }
}

---@param auth table?
---@return table auth
function M.Auth:new(auth)
  auth = auth or {}
  setmetatable(auth, {
    __index = self
  })
  return auth
end

setmetatable(M.Auth, {
  __call = M.Auth.new
})

---extract cookies from cache
---@param host string The host for which to retrieve cookies.
---@return table<string, string> cookies A table where keys are cookie names and values are cookie values for the specified host.
function M.Auth:get_cookies(host)
  local f = io.open(self.path)
  local text = "{}"
  if f then
    text = f:read "*a"
    f:close()
  end
  local decoded = json.decode(text) or {}
  -- a cookie cached for the registrable domain still applies to its subdomains,
  -- the same way Chrome sends it
  local cookies = decoded[host]
  if cookies == nil then
    for key, value in pairs(decoded) do
      local domain = key:gsub("^%.", "")
      if key:sub(1, 1) == "." and (host == domain or host:sub(-#domain - 1) == "." .. domain) then
        cookies = value
        break
      end
    end
  end
  return Cookies(cookies)
end

---create the cache directory as owner-only, cookies must not be readable by others
---@param dir string
local function make_private_dir(dir)
  vim.fn.mkdir(dir, "p")
  uv.fs_chmod(dir, 448) -- 0700
end

---add cookies to cache
---@param host string The host for which to retrieve cookies.
---@param cookies table<string, string> cookies A table where keys are cookie names and values are cookie values for the specified host.
---@return boolean
function M.Auth:set_cookies(host, cookies)
  local data = {}
  local old = io.open(self.path)
  if old then
    local text = old:read "*a"
    old:close()
    if text ~= "" then
      data = json.decode(text)
    end
  end
  data[host] = cookies
  make_private_dir(fs.dirname(self.path))
  local f = io.open(self.path, "w")
  if f == nil then
    return false
  end
  f:write(json.encode(data))
  f:close()
  uv.fs_chmod(self.path, 384) -- 0600
  return true
end

return M
