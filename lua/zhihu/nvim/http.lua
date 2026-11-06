--- fetch in the background: a blocking socket call cannot be interrupted, so a
--- synchronous request freezes the whole editor for as long as zhihu takes to
--- answer (1-3s on the recommend feed). curl is a child process, so the ui keeps
--- running while it waits.
local M = {}

---@return boolean
function M.available()
  return vim.fn ~= nil and vim.fn.executable ~= nil and vim.fn.executable "curl" == 1
end

---@param url string
---@param headers table
---@return string[]
function M.args(url, headers)
  local args = { "curl", "-sS", "-g", "--max-time", "20" }
  local cookie = headers.Cookie or headers.cookie
  if cookie and cookie ~= "" then
    args[#args + 1] = "-H"
    args[#args + 1] = "Cookie: " .. cookie
  end
  local agent = headers["User-Agent"]
  if agent then
    args[#args + 1] = "-H"
    args[#args + 1] = "User-Agent: " .. agent
  end
  args[#args + 1] = url
  return args
end

---@param url string
---@param headers table
---@param cb fun(err: string?, text: string?)
function M.get(url, headers, cb)
  local function fail(err)
    vim.schedule(function()
      cb(tostring(err))
    end)
  end
  if not M.available() then
    return fail "zhihu: 需要 curl 才能在后台拉取"
  end
  local ok, err = pcall(vim.system, M.args(url, headers), { text = true }, function(out)
    vim.schedule(function()
      if out.code ~= 0 then
        local detail = (out.stderr or ""):gsub("%s+$", "")
        return cb(("zhihu: 请求失败 %s %s"):format(tostring(out.code), detail))
      end
      cb(nil, out.stdout)
    end)
  end)
  if not ok then
    fail(err)
  end
end

return M
